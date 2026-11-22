# S3 Result · Sampling strategy for the 3 % battery target

> Spike for PRODUCT F1 / F2 / F3 / §6, D1, D13, D24, D25. Simulator part done 2026-11-21/22. Device part: **not done** (§6, §7).
> Code: `spikes/S3-sampling/` (separate app target `TraceNotesS3`, "TN S3" on the home screen). Unit tests: `TraceNotesTests/S3MotionStateMachineTests.swift`.
> Simulator evidence: `docs/spikes/S3-simulator-log.txt` (log excerpt), §4.
> **Simulator results say nothing about energy.** The simulator has no GPS, radio or power model and no Core Motion. Every energy statement below is an estimate until the device days in §6 are done.

## 0. Summary

- Three candidate strategies are implemented and switchable in Debug builds:
  - **A**: system live updates.
  - **B**: tiered accuracy, always on.
  - **C**: geofence sleep.
- All three share the same state machine, wake-up paths, pause behaviour and measurements, so only the sampling differs between test days.
- **Simulator:** all three record moving routes at 1 Hz with ≤ 1 s gaps in the background and log every transition. A and B complete moving → stay → leave. **C never woke up from its geofence in the simulator** (§4.2).
- **Preliminary recommendation:** **B as the baseline, A as the challenger**. C only if B and A miss 3 % and C passes the 10-minute device check T-C0 (§5).
- **3 % is not shown to be impossible**, so there is no stop-and-report. But it is tight: 1–2 h of moving with GPS-grade accuracy is the largest cost and is not negotiable under D13. §8 lists the levers, and the rules they would touch, if the device days come out above 3 %.

## 1. Design constraints carried over

| Source | Constraint | Consequence |
|---|---|---|
| S1 (simulator) | Background location sessions can only be **created** in the foreground or on a relaunch; stopping updates got the app **suspended** (S1 strategy B) | Every strategy creates `CLServiceSession(.always)` + `CLBackgroundActivitySession` on **every** launch and never destroys them. Only C stops updates, and only while a wake-up path (geofence, visit, significant change) is armed. C exists to test exactly this on a device |
| S1 / rule 3 | Pause keeps sampling and only skips saving | Pause in S3 is the same; its cost is measured separately (§6 day P) |
| F1 / rule 2 | Poor points are kept and marked | Every point is counted as saved (unless paused), bucketed by accuracy and flagged `poor=true` above 100 m. Poor points never drive state decisions |
| P1 / rule 1 | No user-facing power or accuracy mode | The strategy picker exists only in Debug builds (`#if DEBUG`). Release shows the active strategy as text |
| D13 | Reliability > completeness (moving) = energy (still) | The state machine starts in "moving" and returns to moving on any credible signal. Entering "stationary" needs 3 min of evidence |

**Why a separate app target.** Settings › Battery attributes energy per app. With S1's always-on recorder in the main app, S3 energy could not be read separately, and S1's code must not change. `TraceNotesS3` (bundle id `com.inoxixi.tracenotes.s3`) has its own location permission and battery line. **Disarm S1 (S1 tab → Stop recording) on S3 test days**, or S1's sampling adds noise to the system's location activity.

## 2. Candidate strategies

### 2.1 Shared by all three

| Part | What | Why |
|---|---|---|
| Sessions | `CLServiceSession(authorization: .always)` + `CLBackgroundActivitySession` on every launch | S1: cannot be created later from the background |
| Wake-up paths | Significant-change monitoring + visit monitoring, always on | Relaunch after a kill (F1, §6 "移动约 500 米以内恢复"). Both are low power (cell / Wi-Fi based) |
| Motion | `CMMotionActivityManager` activity updates | Primary signal for still ↔ moving. Falls back to GPS speed when unavailable or denied (F1 state "运动与健身被拒绝") |
| State machine | `S3MotionStateMachine` (pure, unit-tested) | Same decisions for A, B and C |

**State machine** (`spikes/S3-sampling/Core/S3MotionStateMachine.swift`)

| States | `stationary` and `moving(walking / running / cycling / automotive / unknown)`. Starts as `moving(unknown)` |
|---|---|
| moving → stationary | (a) **dwell**: every usable fix (accuracy ≤ 100 m) stays within **50 m** for **3 min**, and Core Motion's latest reading is not a moving one; or (b) **motion dwell**: Core Motion says stationary for 3 min (works indoors with no usable fix); or (c) strategy A only: Core Location reports `stationary` and Core Motion does not say moving |
| stationary → moving | Any of: Core Motion reports walking / running / cycling / automotive; a usable fix more than **150 m** (beyond its accuracy) from the stay anchor; geofence exit (C); visit departure; a significant-change fix beyond 150 m |
| Activity kind | Core Motion's latest moving reading. Without Core Motion, GPS speed: < 0.6 m/s unknown, < 2.8 walking, < 7 cycling, else automotive. A speed-based change needs 5 consecutive fixes (no flapping) |
| Vehicle rule | A Core Motion reading that is both *automotive* and *stationary* (a car at a light, a train at a station) counts as **automotive**. Core Motion reports changes only, so one "automotive" reading holds for the whole ride |

The numbers are named constants in `S3MotionStateMachine.Configuration`, each with a comment saying why.

### 2.2 A · System live updates (`A-systemLive`)

| State | API and configuration |
|---|---|
| moving walking / running / cycling | `CLLocationUpdate.liveUpdates(.fitness)` |
| moving automotive | `liveUpdates(.otherNavigation)` (trains: no snapping to roads) |
| moving unknown / stationary | `liveUpdates(.default)` |
| Still | Nothing extra: Core Location's built-in stationary detection pauses delivery and sets `CLLocationUpdate.stationary`. It resumes delivery by itself when the device moves |

- **Expected energy.** Lowest effort and Apple's recommended path. The system decides accuracy and idles the GPS when still. `liveUpdates` exposes no accuracy or filter knob, so our only lever is the configuration.
- **Completeness risk.** Resume latency after a stay (how many metres are lost when leaving home) is unknown. A smooth train ride might be judged "stationary" by the system. The state machine ignores `stationary` while Core Motion says automotive, but the *delivery* pause is the system's decision, not ours.
- **Unknowns.** How often it wakes the app while still, and whether still periods cost anything. MetricKit's accuracy buckets will tell.

### 2.3 B · Tiered accuracy, always on (`B-tieredAccuracy`)

| State | `CLLocationManager` standard updates (`allowsBackgroundLocationUpdates`, `pausesLocationUpdatesAutomatically = false`) |
|---|---|
| moving walking / running / cycling / unknown | `desiredAccuracy = 10 m`, `distanceFilter = none`, `activityType = .fitness` |
| moving automotive | 10 m, none, `.otherNavigation` |
| stationary | `desiredAccuracy = 100 m` (Wi-Fi / cell, GPS off), `distanceFilter = 25 m`, `.other` |

- **No distance filter while moving.** This is deliberate. A still phone must keep producing fixes, or the dwell rule can never fire without Core Motion. The cost is ~1 Hz CPU wake-ups while moving; the GPS is on either way. This was found while building the spike: an earlier draft used 10–30 m filters and could never leave "moving".
- **Expected energy.** Moving: GPS-grade. Still: Wi-Fi/cell positioning. That is cheap but not free, because the process stays alive all day. The 25 m filter keeps drift points coming, which F3 needs, and lets displacement wake us.
- **Completeness.** Best of the three. Updates never stop, so leaving a stay is detected by motion or by the 100 m-accuracy stream within ~150 m.
- **Risks.** The still-period cost of an always-running process with 100 m accuracy: is it < 1 %/day? Indoors, 100 m fixes might drift past 150 m and cause false "moving" spells (they raise accuracy to 10 m for ≥ 3 min). The log and stats show these as transitions.

### 2.4 C · Geofence sleep (`C-geofenceSleep`)

| State | Configuration |
|---|---|
| moving | Same as B |
| stationary | **Stop** standard updates; add a `CLMonitor` circular condition (**150 m**, the exit radius) around the stay anchor. Wake on: geofence exit, visit departure, significant change beyond 150 m, or Core Motion moving (only while the process is still running). Then restart updates |

- **Expected energy.** Lowest while still: no location service except the wake-up monitors.
- **Completeness risk.** The first minutes after leaving: geofence exits typically need ~100–200 m plus some delay. More importantly, **restarting updates from the background after the process was suspended is exactly what failed in S1 (strategy B)**. The difference: here a geofence or visit event wakes the app, and S1 had no such event. The `CLBackgroundActivitySession` is still alive. Whether `startUpdatingLocation()` then works in the background is the key device question (T-C1).
- **Failure modes.** No geofence exit at all (a short walk inside 150 m: acceptable under D13). An exit delivered late. After a reboot, no relaunch until the first unlock (Data Protection).

### 2.5 Comparison (expectations to be replaced by device data)

| | A · system live | B · tiered | C · geofence sleep |
|---|---|---|---|
| Still: GPS | System decides (expected off) | Off (100 m Wi-Fi/cell) | Off, no location service |
| Still: process | Mostly suspended (expected) | Always running | Suspended |
| Leaving a stay detected by | System resume + motion | Motion / 100 m stream / visit | Geofence / visit / SLC / motion |
| Expected still cost | Low | Low–medium | Lowest |
| Expected moving cost | GPS (system-tuned) | GPS 10 m, 1 Hz callbacks | Same as B |
| Completeness risk | System's own stationary pause on smooth rides | Lowest | Gap after leaving; background restart (T-C1) |
| Implementation risk | Few knobs | Most predictable | Depends on undocumented background behaviour |

## 3. Measurements built into the spike

| Requirement | Where |
|---|---|
| Log state changes, each point's accuracy level and saved flag, per-hour point counts, wake-ups / suspension | `Documents/s3-events.log`. Lines: `state … reason=…`, `pt src=… acc=…m bucket=… saved=… poor=… state=… app=… [replayed=true]`, `hour.summary`, `app.launch`, `scene.phase`, `geofence.*`, `visit`, `motion`, `power.lowPowerMode`, `sampling.apply`. **No coordinates** |
| Suspension | iOS gives no callback for suspension. The stats record the **longest silence** (time with no event at all while recording); a background relaunch is an `app.launch` not followed by `scene.phase active` |
| MetricKit, local only | `S3MetricStore`: every `MXMetricPayload` / `MXDiagnosticPayload` is saved as JSON in `Documents/metrics`, plus a summary with location activity time per accuracy level (bestForNavigation … 3 km), background location time, foreground / background time and CPU time. Shown in the app, shareable |
| Today's stats in the app | Stationary / moving / paused time, saved / skipped points, **longest moving gap**, longest silence, **max stay drift** (F3), transitions, launches, accuracy buckets, time per strategy, points per hour. Saved as `Documents/stats/<day>.json` |
| Share | Share links for the log, every stats day and every MetricKit file |

## 4. Simulator results

Runs on 2026-11-21/22, iPhone 17 Pro simulator, iOS 26.5, Debug build, app in the background unless noted. Excerpt with segment summaries: `docs/spikes/S3-simulator-log.txt`.

**Simulator limits that shape these results:**
- No Core Motion (`motion.unavailable`). Activity and stays come from GPS speed and the dwell rule only.
- A fixed simulated location (`simctl location set`) yields **one** fix and then `kCLErrorLocationUnknown`, never a stream of still fixes. A "still" phase with a fixed location therefore cannot reach `stationary`. The dwell scenario (round 2) instead keeps the location moving back and forth within 8 m, so fixes keep coming.
- No energy, radio or GPS model. **Nothing here says anything about battery.**

### 4.1 Simulator verified

| What | A | B | C | Evidence |
|---|---|---|---|---|
| Moving, City Run 300 s: points / longest gap | 302 / 1 s | 300 / 1 s | 300 / 1 s | Round 1 |
| Moving, Freeway Drive 240 s: points / longest gap | 242 / 1 s | 241 / 1 s | 241 / 1 s | Round 1 |
| Activity transitions while moving | `moving.unknown → cycling` (City Run pace), `→ walking → automotive` within 10 s on the freeway (speed ramp-up at the route start, 5-fix confirmation) | same | same | `state …` lines |
| Sampling follows the state | `live=fitness` / `otherNavigation` | `acc=10m filter=none`, `type=3` / `type=4` | same as B while moving | `sampling.apply` lines |
| Background delivery | `pt … app=background` throughout | same | same | |
| Dwell → `stationary` | after 3 min within 8 m (`reason=dwell`) | same; switches to `acc=100m filter=25m` | same; stops updates, adds a 150 m `CLMonitor` condition (`geofence.add`) | Round 2 |
| Leaving the stay | `stationary → moving.walking reason=displacement` after ~107 s (≈ 150 m at 1.4 m/s) | same, ~108 s; points every ≤ 18 s while in 100 m mode | **never** (see 4.2) | Round 2 |
| Background relaunch | Core Location relaunched the app in the background right after `simctl terminate`, before any user launch; it recreated the sessions and resumed recording with the stored strategy | | | `app.launch state=background` not followed by `scene.phase active` |
| No coordinates in log / stats | checked (`grep` for coordinate patterns: none) | | | |

### 4.2 Findings

1. **C did not wake up in the simulator, in the background or in the foreground.** After `geofence.add`, walking 300 m away for 220 s produced no `geofence.event`, no visit and no significant-change fix, so no point at all. The `CLMonitor` produced not even its initial state event. Two explanations, which the simulator cannot tell apart: the simulator does not evaluate `CLMonitor` conditions while no location updates are running, or our use of `CLMonitor` is wrong. Either way C's key path is **unverified**, and a missed exit would lose the whole departure (D13 says reliability first). Device test **T-C0** (§6) settles it in 10 minutes before any C day.
2. **A's system stationary pause never happened in the simulator.** With fixes coming in, `liveUpdates` kept delivering 1 Hz and never set `stationary`. Whether A really idles when still is a device question (day A1, MetricKit GPS-level time).
3. **B's leaving delay is the exit radius.** Without Core Motion, leaving is only noticed at 150 m + accuracy. On a device Core Motion's walking reading should end the stay within seconds; day W measures "first point after leaving".
4. **Four measurement bugs found and fixed in this slice:**
   - *Cached replay.* On every launch significant-change monitoring delivers the last known fix with its **old** timestamp. It was counted as the previous point, giving a false "longest moving gap" of 6808 s, and it could have faked a dwell (old time + 3 min). Now a fix older than the process launch is saved and logged with `replayed=true` (F1 keeps it), but neither decides the state nor starts or ends a gap.
   - *Time lost on a kill.* iOS kills suspended apps without a callback. The interval after the last event was dropped, e.g. a whole night's stay. The last event is now persisted in the day file, so the next process accrues that interval to the last state (and to "longest silence").
   - *Old state stamped at a transition* (found in round 3). The last event is stamped before a transition is applied, then saved, so a kill during a stay would have put the whole stay into "moving". Saving now stamps the current state first.
   - *The point that ends a stay counted as drift* (round 3: 306 m "drift"). Drift now counts only points that kept the stay.
   The first two have unit tests; the last two live in the recorder and were checked by a kill-during-stay run (§4.3).
5. **Pause** is covered by unit tests only (`pauseIsNotAMovingGap`, skipped-point counting). Its energy is a device question (day P).

### 4.3 Rounds 3–4 · stats after the fixes

- **Round 3, B dwell** (fresh log and stats): same cycle as round 2 (stay after 186 s, leave detected after 109 s). Replayed fixes on launch are flagged `replayed=true` and no longer produce a false gap. Round 3's A run is **not used**: the Mac slept during it and froze the simulator for hours. That exposed the last two bugs in §4.2 item 4.
- **Round 4, B killed during the stay** (`simctl terminate` 54 s after entering the stay, relaunched 60 s later): the day file shows **stationary 116 s** = entering the stay → relaunch, the killed minute included. Max stay drift 0 m: the 8 m jitter stays under the 25 m filter, and the point that ends the stay is no longer counted. Longest moving gap 25 s, around the relaunch.
- **Seen in round 4, by design:** a relaunched process starts in `moving(unknown)`, so after a kill during a stay it needs another 3 min of fixes before it is `stationary` again. On a device that costs ~3 min of GPS per kill during a stay. Day K and the `launches` count show how often this happens.
- **Known loss:** counts since the last save (at most `pointsPerStatsSave` = 120 points, about 2 min while moving) are lost on a kill. Time is not lost; it is accrued from the persisted last event.

### 4.4 Pending device verification

Everything about energy; A's system stationary pause; Core Motion transitions and the vehicle rule; C's wake-up (T-C0, T-C1); drift indoors with real Wi-Fi/cell fixes (D); completeness on a real walk and train (W, T); kill recovery distance (K); MetricKit payloads (none arrive in the simulator).

## 5. Preliminary recommendation

1. **B (tiered accuracy) as the baseline.** It completed the full cycle in the simulator (moving → stay → leave) with the most predictable behaviour, and it never depends on the system deciding to resume. Its open risk is the cost of staying alive all day at 100 m accuracy.
2. **A (system live updates) as the challenger.** Same cycle verified. It may be cheaper while still if the system's stationary pause works on a device, but that pause was not observable here, and its resume latency is unknown.
3. **C (geofence sleep) last, and only after T-C0 passes.** Its wake-up path failed in the simulator. If T-C0 shows no `geofence.event` on a device either, drop C without spending a test day on it.

Device order: **B1 → A1 → P** (pause, with the better of the two) **→ D / W / T** for both **→ K → T-C0 → C1** only if B and A both miss 3 %.

## 6. Device test plan

### Setup (once)

1. Install **TN S3** (scheme `TraceNotesS3`, Debug) on the iPhone used every day. Allow location **Always** and **Motion & Fitness**.
2. In Trace Notes, open the S1 tab and tap **Stop recording**, so that S1 does not sample on S3 days. Run S1's device tests T1–T7 on other days.
3. Do not force-quit TN S3 during a test day. That is test T-K, on its own day.
4. Low Power Mode off, unless the day is about it. Note the iOS version and the battery health (Settings › Battery › Battery Health).
5. Each morning: pick the strategy for the day in TN S3 (Debug picker) and check it says "Recording". Note the start time.

**Reading energy.** Settings › Battery shows a per-app share for the last 24 hours / 10 days. A share is relative to total use, so also note the **total battery drop**. TN S3's absolute cost ≈ share × total drop. Example: 4 % share of a 60 % drop = 2.4 % of the battery. Take the reading the next morning, for the full 24 h window. Screenshot it.

### Days (one strategy per day, at least one full "ordinary day" each; D25 scenario)

| Day | What | Read / export |
|---|---|---|
| **A1, B1, C1** | Ordinary day: commute 1–2 h (walk + train), the rest indoors. Same weekday pattern if possible | Battery screenshot (share + total drop); share `stats/<day>.json`, `s3-events.log`, and the MetricKit file that arrives the next day |
| **P** (with the best of A/B) | Same as an ordinary day, but **pause for 2 h** while indoors (app toggle) | As above. Compare with the same strategy's ordinary day. Rule 3 says paused ≈ recording cost |
| **D** (each strategy, can be on the same day) | **Stationary drift:** phone flat indoors for 30 min, untouched | `Max stay drift`, transitions during the 30 min. Pass = one stay, no point > 50 m from the anchor (F3) |
| **W** (each strategy) | **Walking completeness:** the same fixed walking route, ~20 min, outdoors | `Longest moving gap` for that window (from the log). Pass = ≤ 2 min (§6). Also: how far from the door was the first point after leaving the stay? |
| **T** (each strategy) | **Train completeness:** the same fixed above-ground train section | Longest moving gap, and any `state … -> stationary` while on the train (= misjudged as stationary) |
| **K** (best strategy) | **Kill recovery:** swipe TN S3 away at home, then go out | Distance from home of the first `pt` after `app.launch` (estimate from the time and route). Pass = within ~500 m (§6) |
| **T-C0** (C only, before any C day, 10 min) | With TN S3 **in the foreground**, strategy C: stay still ≥ 4 min until `geofence.add`, then walk 300 m away | Must show `geofence.event … unsatisfied` → `state stationary -> moving…`. If not: drop C (§4.2) |
| **T-C1** (C only) | After a stay of ≥ 10 min with the screen locked, walk away | The log must show `geofence.event … unsatisfied` or `visit departure` → `state stationary -> moving…` → `pt src=stream … app=background`. If no `pt` follows until the app is opened, C cannot work: drop C |

## 7. Record sheet

Copy one row per test day. Add the shared files (stats JSON, log, MetricKit JSON) to a folder named by the date.

| Date | Strategy | iOS / model / battery health | Start–end | Moving time (h) / stationary (h) | Commute (walk min / train min) | Total battery drop (%) | TN S3 share (%) | TN S3 cost = share × drop (%) | Paused (h) | Longest moving gap (s) / where | Max stay drift (m) | Transitions | Launches | MetricKit: GPS-level time (best+10 m, min) / 100 m+ time (min) / CPU (s) | Misjudged stationary on train? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | | | | | | | | |

**Pass criteria per day:**
- Cost < 3 %.
- Longest moving gap ≤ 120 s on W and T.
- Drift ≤ 50 m with a single stay on D.
- K recovers within ~500 m.

## 8. Is 3 % reachable under the rules?

**Not proven either way. No stop-and-report.** A rough budget, using **assumed** order-of-magnitude figures (to be replaced by MetricKit and Settings › Battery data):

- A current iPhone battery holds ~13–18 Wh, so 3 % ≈ **0.4–0.55 Wh per day**.
- **Moving, 1–2 h with GPS-grade accuracy:** probably the largest item, plausibly around 1–2 % of the battery. D13 makes this part non-negotiable.
- **Still, ~22 h:** what is left must cover ~22 hours, i.e. roughly **≤ 1 %**. A has the best chance if the system really idles; C has the best chance if T-C1 works; B is the risk.

If every strategy lands above 3 % on device, these are the levers, in order of how little they cost the product. Items 1–3 stay within the current rules; items 4–6 would each need your decision first:

| # | Lever | Rule touched |
|---|---|---|
| 1 | While moving, add a distance filter and rely on Core Motion for the dwell. Keep 1 Hz only when Core Motion is unavailable or denied | None (internal) |
| 2 | Shorter dwell (3 → 2 min), so stays start sooner | None (F3 still holds) |
| 3 | 100 m accuracy while `automotive` (trains), 10 m for walking | None. Lines on rail are less smooth, which touches the F7 look, not a rule |
| 4 | During pause, drop to stationary-level sampling instead of full sampling | **Rule 3** (pause = sampling continues unchanged). F2 itself allows "降低采样" |
| 5 | Relax the moving-gap target from 2 min | **PRODUCT §6** completeness target |
| 6 | Accept > 3 % on heavy-commute days, or define the target for a shorter commute | **D25** measurement scenario |

