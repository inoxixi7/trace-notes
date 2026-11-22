# Trace Notes · ARCHITECTURE.md（v0.2）

> 阶段：CSE Design
> 日期：2026-11-22
> 依据：PRODUCT.md v0.2、DECISIONS.md D1～D30、Spike S1～S3 的模拟器结论
> 状态：**已确认**（第 10 节的选择均已确认）。标有 ⏳ 的部分依赖 Spike 的真机结果，结果出来后再定稿
> 读者：开发者本人 + 编码 Agent。架构决策由用户确认；编码 Agent 不得自行修改，实现不了时停下来报告

---

## 1. 总览

```
┌──────────────────────────────────────────────────────────────┐
│  UI 层（SwiftUI + Liquid Glass）                                │
│  今天 / 日历 / 时间线 / 段落编辑 / 设置                           │
│  地图：MKMapView（UIViewRepresentable）+ 自定义轨迹渲染器          │
└───────────────▲──────────────────────────────▲───────────────┘
                │ 只读查询（按日、按视口）          │ 用户修改
┌───────────────┴──────────────────────────────┴───────────────┐
│  派生层（可重算）                                               │
│  段（停留 / 移动）· 交通方式 · 地点 · 断档原因 · 渲染缓存（LOD）   │
│        ▲ 增量处理管线（Processing Pipeline）                    │
├────────┴─────────────────────────────────────────────────────┤
│  用户修改层：按"时间范围"保存的交通方式 / 地点名称修改              │
├──────────────────────────────────────────────────────────────┤
│  原始层（不可变，只追加）：RawPoint、RecorderEvent               │
└───────────────▲──────────────────────────────────────────────┘
                │ 立即写入
┌───────────────┴──────────────────────────────────────────────┐
│  记录引擎（Recording Engine）                                  │
│  Core Location + Core Motion + CLVisit · 采样策略 ⏳S3          │
│  暂停标志（App Group）← Control Widget（App Intent）⏳S1        │
└──────────────────────────────────────────────────────────────┘
```

核心原则（来自 PRODUCT.md）：
- **原始层只追加、不修改**（P5）。一切加工结果都在派生层，算法改了可以重算
- **数据流单向**：记录引擎 → 原始层 → 管线 → 派生层 → UI。UI 不直接读原始层
- **增量处理**：每个新点只影响"当前未完成的段"，绝不重扫整段历史（旧项目的 O(n) 问题）

---

## 2. 数据模型

### 2.1 原始层（只追加）

**RawPoint**
| 字段 | 说明 |
|---|---|
| id | 自增整数 |
| timestamp | UTC，毫秒 |
| latitude / longitude | **WGS-84**（D16） |
| horizontalAccuracy | 米；精度差的点也保存（F1） |
| altitude / verticalAccuracy | 可空 |
| speed / course | 可空 |
| timeZoneID | 记录时的 IANA 时区（F8 日期划分用） |
| source | `recorded` / `gpxImport` |
| importBatchID | GPX 导入批次，可空 |
| flags | 位标记：`replayed`（启动时系统重放的缓存点，S3 发现）、`lowAccuracy`、`paused`（不会出现，暂停时不保存，预留） |

**RecorderEvent**（记录引擎自身发生了什么，用于断档原因 F6）
| 字段 | 说明 |
|---|---|
| timestamp | UTC |
| kind | `launch`、`backgroundRelaunch`、`terminatedDetected`（下次启动时推断）、`pause`、`resume`、`authorizationChanged`、`locationServicesOff`、`lowPowerModeOn/Off`、`motionActivity`（步行/跑步/骑行/汽车/静止，含置信度）、`altitudeTrend`（气压，地铁判定辅助）、`visitArrive/Depart` |
| payload | 少量附加值（不含精确坐标以外的敏感信息） |

### 2.2 用户修改层

**SegmentOverride**
| 字段 | 说明 |
|---|---|
| id | — |
| startTime / endTime | 修改所针对的时间范围 |
| field | `transportMode` 或 `placeName` |
| value | 用户选择的交通方式或输入的名称 |
| createdAt | — |

**关键设计：修改按"时间范围"保存，不按段的 ID 保存。** 派生层重算后段的 ID 会变，但时间不变。重算时，把修改应用到与其时间范围重叠最多的新段上（重叠 < 50% 时不应用，并记录日志）。这样保证"重算时保留用户修改"（F4、F5）。

### 2.3 派生层（可重算）

| 表 | 内容 |
|---|---|
| **Segment** | 类型（停留 / 移动 / 断档）、开始和结束时间、关联的 RawPoint 范围、交通方式（自动值 + 置信度）、距离、本地日期（按 timeZoneID） |
| **Stay**（Segment 的扩展） | 中心坐标（WGS-84）、半径、地点 ID |
| **Gap**（Segment 的扩展） | 原因：`paused` / `deviceOffOrNotRunning` / `permissionChanged` / `locationOff` / `lowPower` / `underground` / `unknown`；地铁时附进出站点 |
| **Place** | 坐标、反向地理编码结果（名称、地址）、获取状态（成功 / 失败待重试）、最后尝试时间 |
| **RenderCache** | 每个移动段在多个缩放级别的简化点列（见第 5 节） |
| **DaySummary** | 每天的统计（距离、时长、有无记录），供日历快速显示 |

派生数据的版本号：管线算法改动时提升版本号，App 启动后在后台按天重算旧版本的数据。

### 2.4 共享状态（App Group，App 与 Widget 共用）
- `isPaused`、`pausedSince`
- 不放轨迹数据；Widget 不访问数据库

---

## 3. 存储

**确定：GRDB（D26），使用 DatabasePool（WAL 模式），单一数据库文件。**

选型记录：系统 SQLite（零依赖但要自己写并发、迁移、观察，容易埋可靠性隐患）、SwiftData（百万级点的性能和迁移可控性不确定）、自定义二进制（不值得）均未采用。

存储规则：
- **每个点立即写入**（或最多攒 5 秒一批，在事务中提交）。S3 发现"被杀时最多丢 120 个点"，这违反 P3"已记录的数据不丢"，必须修正
- **紧凑格式（D29 第一步）**：timestamp 存 INTEGER（UTC 毫秒）；latitude / longitude 存 INTEGER（度 × 10⁷，精度约 1 厘米）；accuracy、altitude、speed、course 存小精度 INTEGER 或 REAL（Design 细化时选择）；不要用文本时间戳（旧项目的做法）
- **压缩分块（D29 第二步，上架前）**：完成的段打包成"差值编码 + 系统 Compression 框架压缩"的 BLOB；未完成的段保持普通行。所有读取只经过"按时间范围取点"的接口
- 数据库文件放在 App 沙盒的 Application Support，开启文件保护等级 `completeUntilFirstUserAuthentication`（锁屏后台也能写入）
- 索引：RawPoint(timestamp)、Segment(localDate)、Segment(startTime)
- 视口查询：RenderCache 按包围盒查询。⏳ 先确认 iOS 系统 SQLite 是否开启 R*Tree；没有就用"按网格编号建普通索引"代替
- 结构迁移：用 GRDB 的 DatabaseMigrator，迁移按顺序注册，必须有测试
- UI 刷新：用 GRDB 的 ValueObservation 监听"今天"的派生数据
- "删除全部数据"（F10）：关闭连接 → 删除数据库文件 → 重建空库

---

## 4. 记录引擎

### 4.1 职责
- 管理定位 session、采样策略、暂停标志、系统唤醒
- 把每个点和事件写入原始层
- **不做**任何轨迹加工（加工是管线的事）

### 4.2 生命周期
- 首次授权后，在前台启动 `CLServiceSession(.always)` + `CLBackgroundActivitySession` + `liveUpdates`（S1：后台只能重新加入，不能新建）
- 同时注册系统唤醒途径：到访检测（CLVisit）、显著位置变化。被杀后由系统拉起时，在 `application(_:didFinishLaunchingWithOptions:)` 阶段重新加入 session 并恢复采样
- 每次启动写 `launch` 或 `backgroundRelaunch` 事件；如果上一次运行没有正常结束，补写 `terminatedDetected`（用于断档原因）
- 启动时系统重放的旧缓存点：照常保存，标记 `replayed`，不参与管线判定（S3 发现）

### 4.3 采样策略 ⏳S3
- 以 S3 真机结果为准。当前候选：**B 作为基线，A 作为挑战者**；C（地理围栏唤醒）待 T-C0 检查
- 架构要求：策略是记录引擎内部的一个可替换组件，接口只有"根据当前状态和信号，给出定位配置"。Release 构建只内置最终选定的一个策略（P1，不给用户选）
- 停留中被杀后，重启要等 3 分钟才回到停留状态（S3 观察到）：**改为把引擎状态（当前状态、停留中心、进入时间）持久化到 App Group**，重启时直接恢复，避免多开 3 分钟 GPS
- **静止心跳（D28）**：引擎处于"停留"状态时，每 5 分钟（默认）保存 1 个点；收到超出停留半径的点立即保存，并切换为"移动"。心跳间隔和停留半径是策略参数，⏳ 以 S3 真机结果为准。被心跳规则跳过的点不写入 RawPoint，但每小时在 RecorderEvent 里记一次"跳过了多少个点"，便于诊断

### 4.4 暂停 ⏳S1
- 按 S1 方案 A：暂停时定位继续，但不写入 RawPoint；只写 `pause` / `resume` 事件
- 引擎每收到一个点，先读 App Group 里的暂停标志；Widget 切换后发系统通知让引擎立即刷新
- 暂停期间可以把采样降到最低档以省电（具体由 S3 测出的暂停耗电决定）
- 状态栏定位图标在暂停时仍会亮（S1 发现）：UI 上必须明确显示"已暂停"（App 内顶部状态、Control Widget 图标与文字），见第 7 节
- 用户手动划掉 App 后的恢复方式：⏳ 等 S1 的 T4 真机结果

---

## 5. 处理管线（增量）

### 5.1 结构
```
新 RawPoint / RecorderEvent
   │
   ▼
① 预过滤：跳过 replayed；精度差的点标记但保留，供⑤使用
   │
   ▼
② 稳定化（Stabilizer）：在线滑动窗口，抑制漂移和尖刺
   │                     （改造自旧项目 TraceStabilizer，去掉"结束记录时收尾"）
   ▼
③ 分段器（Segmenter）：维护"当前未完成的段"
   │   - 判定进入停留：在半径 R 内停留超过 T（参数来自 S3），或收到 visitArrive
   │   - 判定离开停留：离开半径 R，或收到 visitDepart / 运动传感器显示移动
   │   - 断档：两个点的时间差超过阈值 → 生成 Gap 段，交给⑥判断原因
   ▼
④ 交通方式识别：段完成时（或移动中每 N 分钟）按速度区间 + motionActivity 投票
   ▼
⑤ 地点解析：停留段完成后，放入反向地理编码队列（异步、限速、失败重试、离线时延后）
   ▼
⑥ 断档原因：根据 RecorderEvent 推断（暂停、被杀、权限、低电量、地下）
   │   地下 / 地铁：GPS 消失 + motionActivity=汽车（乘车）+ 可选气压下降 → underground
   ▼
⑦ 渲染缓存：段完成时生成多级简化点列；未完成的段只缓存最新的简化结果
   ▼
写入派生层 → 通知 UI 刷新"今天"
```

### 5.2 "没有结束时刻"的问题（旧 TraceStabilizer 的冲突）
- 旧代码依赖"结束记录"时收尾。新架构改为：**段在以下任一时刻完成**——进入停留、出现断档、跨越本地日期零点（按 timeZoneID）、或未完成的段持续超过 30 分钟时做一次"检查点"（保存中间结果，段继续）
- 被杀重启后，从数据库中恢复"当前未完成的段"的状态，继续处理

### 5.3 重算
- 以"本地日期"为单位重算：删除该日派生数据 → 用该日原始数据重跑管线 → 应用用户修改层
- 触发：管线版本号变化、GPX 导入影响到的日期、用户手动操作不触发重算（修改只写修改层）

### 5.4 GPX 导入（F9）
- 解析 GPX 1.1 的 trk / rte → 写入 RawPoint（source=gpxImport，同一批次同一个 importBatchID）
- 去重：同一来源下 timestamp + 坐标相同的点不重复写入
- 与自动记录时间重叠：两者都保存；**显示时重叠时段以 recorded 为准**（在管线③里按时间段选择数据源）
- 导入完成后，对受影响的日期触发重算

---

## 6. 地图与渲染

### 6.1 地图容器
- 使用 **MKMapView（通过 UIViewRepresentable 包装）**，而不是 SwiftUI 的 `Map`
  - 原因（D27）：SwiftUI `Map` 的 `MapPolyline` 也能画虚线和按像素控制线宽，但一年数据量下需要把几千条线整批交给系统、缩放时整批重算；自定义 `MKOverlayRenderer` 可以按缩放级别取简化缓存、只画视口内的段。以后的迷雾、热力视图也必须用自定义渲染器
- 地图上的浮层（今天的摘要卡片、日期切换、按钮）用 SwiftUI + Liquid Glass，叠在地图之上

### 6.2 平滑曲线（F7、D22）
- 在显示层，对简化后的点列做 **centripetal Catmull-Rom 样条**（不会产生自交和过冲，比普通样条更不容易"抹圆"急转弯）
- 原始点和派生层的坐标都不改
- 限制：相邻两点之间转角过大时（掉头、急转），在该点退化为直线连接，避免曲线越过建筑物

### 6.3 清晰度与 LOD
- **线宽按屏幕像素**（不按地理距离），任何缩放级别都一样粗细（旧项目按地面 20 米导致糊成一片）
- **不使用半透明叠加**：同一天的轨迹画在同一条路径里再描边，交叉处不会颜色变深（旧项目的重叠问题）
- RenderCache 为每个移动段预先计算 4～5 个缩放级别的简化点列（Douglas-Peucker，容差随级别递增）；渲染时按当前缩放级别选一档
- 只渲染与当前视口相交的段

### 6.4 坐标系（D16、D17）⏳S2
- 渲染前经过一个"显示坐标转换"函数：输入 WGS-84 点 → 判定是否需要转 GCJ-02 → 输出显示坐标
- 判定模块和转换模块来自 S2（正式代码质量）；最终判定策略以 S2 结论 + 中国大陆实机验证为准
- **转换结果只用于显示，绝不写回任何一层存储**

### 6.5 性能预算
- 打开 App 到看见今天的轨迹 ≤ 1 秒：今天的数据从 RenderCache 读，未完成的段从内存读
- 一年数据量下地图操作不掉帧：渲染只用简化后的点列，绘制在后台线程准备

---

## 7. UI 结构

```
App
├── 今天（默认首页）
│   ├── 地图（全屏）
│   ├── 顶部状态胶囊（玻璃）：记录中 / 已暂停 / 权限问题
│   └── 底部时间线面板（玻璃，可上拉）：停留、移动段、断档
├── 日历（从首页进入）：选择任意一天 → 同样的地图 + 时间线
├── 段落详情（点时间线或地图上的段）
│   ├── 交通方式选择（F4）
│   └── 地点名称编辑（F5）
├── 设置（F10，极简）
└── 首次启动引导（F1）：一屏说明 → 定位权限 → 运动与健身权限
```

- 视觉：iOS 26 Liquid Glass；浅色、深色模式都要在地图上保证可读（D23）
- "已暂停"必须在三处都看得见：顶部状态胶囊、Control Widget、时间线上的暂停段（解决 S1 发现的状态栏图标问题）
- 交通方式配色：每种方式一个颜色，浅色和深色各一套，对比度达标
- 本地化：ja / zh-Hans / en，String Catalog；日文由开发者本人审校

---

## 8. 模块划分（文件夹 / target）

| 模块 | 内容 | 依赖 |
|---|---|---|
| `Recording` | 记录引擎、采样策略、暂停标志读取、系统唤醒处理 | Storage |
| `Storage` | GRDB（DatabasePool）、表结构、迁移、各层的读写接口 | GRDB |
| `Processing` | 管线①～⑦，纯逻辑为主，便于单元测试 | Storage、Geo |
| `Geo` | 距离计算、Douglas-Peucker、Catmull-Rom、GCJ-02 转换、中国大陆边界判定（来自 S2） | — |
| `MapRendering` | MKMapView 包装、轨迹渲染器 | Geo、Storage（RenderCache） |
| `Features/Today`、`Features/Calendar`、`Features/SegmentDetail`、`Features/Settings`、`Features/Onboarding` | 各页面 | Storage、MapRendering |
| `ImportExport` | GPX 解析与生成 | Storage、Processing |
| `Entitlements` | 统一的功能开关（F11），MVP 中所有开关默认开启 | — |
| `Diagnostics` | 本地日志、MetricKit 接收、诊断日志导出（脱敏） | — |
| `TraceNotesWidgets`（扩展） | Control Widget + App Intent | App Group 共享状态 |

规则：
- 不为了"架构好看"而加协议、依赖注入容器、Coordinator 等抽象（AGENTS.md）。只有记录引擎的"采样策略"和"系统定位接口"需要可替换（为了测试和 S3 结论）
- Spike 代码（spikes/）不进入正式模块；正式实现时按需重写或搬运，并删除 S1 在正式入口留下的两处临时改动

---

## 9. 测试策略

| 层 | 怎么测 |
|---|---|
| Geo、Processing | 单元测试为主。用合成轨迹（直线、急转、静止漂移、断档、跨日零点、跨时区）做固定输入，断言输出的段、交通方式、断档原因 |
| Storage | 迁移测试、写入后强杀恢复测试、百万点写入与查询压测 |
| Recording | 系统定位接口可替换为"回放 GPX"的假实现；后台和被杀行为只能真机验证 |
| MapRendering | 一年合成数据的帧率测试（Instruments） |
| 验收（PRODUCT.md 第 6 节） | 真机测试清单，每个 Vertical Slice 完成时跑相关项 |

测试数据里不使用真实的个人轨迹；需要真实数据时用开发者自己同意导出的 GPX，并且不提交到仓库。

---

## 10. 已确认的设计选择（2026-11-22）

| # | 选择 | 结论 |
|---|---|---|
| A1 | 存储方案 | GRDB + DatabasePool（D26），紧凑整数列，上架前加压缩分块（D29） |
| A2 | 地图容器 | MKMapView（UIViewRepresentable），不用 SwiftUI `Map`（D27） |
| A3 | 平滑算法 | centripetal Catmull-Rom，急转处退化为直线 |
| A4 | 用户修改的保存方式 | 按时间范围保存，重算时按重叠匹配 |
| A5 | 写入策略 | 每点立即写入（最多 5 秒一批） |
| A6 | 段的完成时机 | 进入停留 / 断档 / 跨日 / 每 30 分钟检查点 |

## 11. 等 Spike 真机结果才能定稿的部分
- 4.3 采样策略（S3）
- 4.4 用户划掉 App 后的恢复方式（S1 T4）
- 6.4 GCJ-02 判定策略（S2 + 中国大陆实机）

---

## 12. Package：Vertical Slice 顺序

每个 Slice 都是"UI → 逻辑 → 存储 → 结果"可以独立验证的完整路径。

| # | Slice | 依赖的 Spike |
|---|---|---|
| VS1 | 记录 → 存储 → 今天的原始轨迹（简单折线）显示在地图上 | S3（先用基线策略 B） |
| VS2 | 停留检测 + 今天的时间线列表 | — |
| VS3 | 平滑曲线 + LOD + 像素线宽 + GCJ-02 显示转换 | S2 |
| VS4 | 交通方式识别 + 按段修改 | — |
| VS5 | 地点识别 + 名称修改 | — |
| VS6 | 断档原因 + 地铁推测 | — |
| VS7 | 日历 + 跨日 / 跨时区 | — |
| VS8 | GPX 导入 / 导出 | — |
| VS9 | 控制中心暂停 / 恢复（正式） | S1 |
| VS10 | 设置、删除全部数据、诊断日志、功能开关 | — |
| VS11 | Liquid Glass 打磨、浅色/深色、三语文案 | — |
