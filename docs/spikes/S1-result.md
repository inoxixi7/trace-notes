# S1 Result · Control Center pause / resume

> Spike for PRODUCT F2 / D24. Done 2026-11-21.
> Code: `spikes/S1-control-pause/` (throwaway). Simulator evidence: `docs/spikes/S1-simulator-log.txt`.
> Environment: Xcode 27.0, iOS 26.5 Simulator (iPhone 17 Pro), simulated Always authorization and a simulated walking route (`simctl location`).
> **Simulator results are not proof of device behaviour.** Background execution, suspension, force-quit and energy all behave differently on a real iPhone. Every question below has a row for "simulator" and a row for "device".

## 1. What was built

| Piece | Where | What it does |
|---|---|---|
| Recorder | `App/S1Recorder.swift` | `CLServiceSession(authorization: .always)` + `CLBackgroundActivitySession` + `CLLocationUpdate.liveUpdates(.default)`. Also starts significant-change and visit monitoring as wake-up paths. Re-creates everything on every launch while "armed". Logs session and update diagnostics |
| Pause strategies | `S1Shared.PauseStrategy` | **A · keepUpdates**: sessions and live updates keep running, samples are dropped instead of saved. **B · stopUpdates**: sessions stay, the live-update loop is cancelled while paused and restarted on resume |
| Shared state | `Shared/S1Shared.swift` | `isPaused`, `isArmed`, `pauseStrategy` in App Group `UserDefaults` (`group.com.inoxixi.tracenotes`). A Darwin notification is sent when the extension changes the flag |
| Control Widget | `Widget/S1RecordingControl.swift` | `ControlWidgetToggle` ("on" = recording) + `SetValueIntent`. The intent is compiled **only into the widget extension**, and `openAppWhenRun` stays false |
| Event log | `Shared/S1EventLog.swift` | Append-only text file in the App Group container, written by both processes. Each line holds time, process, event, accuracy and app state. **No coordinates** |
| Log page | `App/S1SpikeView.swift` | Status, pause toggle (synced with Control Center), strategy picker, start / stop, log list, Share and Clear |

The app's own pause toggle calls `ControlCenter.shared.reloadControls(ofKind:)`, so Control Center shows the same state.

## 2. Answers

### Q1 · With the app in the background, does pause / resume from Control Center take effect immediately?

| | Result |
|---|---|
| **Simulator** | **Yes, with strategy A.** Log lines 79–92 of the first session: `intent.perform` ran in the `TraceNotesWidgets` process. The backgrounded app logged `pause.observed source=darwin` **within 1 ms** and the next sample was `saved=false`. Resume worked the same way. The app also reads the flag on every sample, so a missed notification would still be caught by the next sample |
| | **No, with strategy B.** After pausing, the location loop stopped and the app was **suspended** (no CPU, so no Darwin delivery). Resume from Control Center at 21:53:51 did **nothing** until the user opened the app 23 s later, when the queued notification arrived and updates restarted (log lines 85–92). Recording stayed off for the whole time in between |
| **Device** | **Needs device test** (steps T1, T2). Strategy B is expected to fail on a device as well, because without location delivery nothing keeps a backgrounded app awake |

### Q2 · After the app is swiped away (or killed by the system), does resume from Control Center continue recording? If not, how does recording restart?

| | Result |
|---|---|
| **Simulator, killed while recording, moving** | `simctl terminate` (comparable to a system kill, **not** a user swipe). About 1 s later Core Location **relaunched the app in the background**: `app.launch` with no `scene.phase active` after it. The app re-created `CLServiceSession` + `CLBackgroundActivitySession` there; the diagnostics reported nothing wrong (no `insufficientlyInUse` and no other flag). Recording continued (log lines 106–126) |
| **Simulator, killed while paused, stationary** | No relaunch for 45 s. Pressing **resume** in Control Center relaunched the app in the background **0.8 s after** `intent.perform`, and recording continued (`saved=true`) |
| **Simulator, killed while recording, stationary** | No relaunch for 45 s. Pressing **pause** relaunched the app 0.8 s after `intent.perform` |
| **Interpretation** | Two separate relaunch paths showed up: (a) location events relaunch an app that had live sessions, and (b) **running the control's intent was followed by a background relaunch of the containing app every time (2 of 2)**. I could not determine the mechanism behind (b). The intent ran in the extension, the app target has no App Intents, and `didFinishLaunching` really ran, so it is not prewarming. **Do not design F2 around (b) until it is seen on a device** |
| **Device** | **Needs device test** (steps T3–T5). The important difference: on iOS, a **user force-quit (swipe up)** generally stops background relaunches until the user opens the app again. Significant-change and visit monitoring are the documented exceptions to check. That is why the spike also starts both |

If resume after a force-quit does **not** restart recording on a device, the app needs one of these:
1. **Wait for a wake-up event.** Significant-change or a visit relaunches the app, and it re-creates the sessions in `didFinishLaunching`. Cost: the gap until the next wake-up (typically about 500 m of movement, which matches the PRODUCT §6 recovery target).
2. **Open the app from the control** (see Q3, option C). Cost: unlock plus the app appearing on screen.
3. **Accept it and show it.** The timeline marks the gap as "App was not running" (F6 already requires this).

### Q3 · Does the App Intent need to bring the app to the foreground (`openAppWhenRun`)? What does that mean for the user?

| | Result |
|---|---|
| **Simulator** | **No.** With `openAppWhenRun = false` and the intent compiled only into the extension, the toggle ran without unlocking or showing the app, and the backgrounded app reacted to it (Q1) |
| **UX** | Foregrounding would make every toggle open Trace Notes (and require unlock from the Lock Screen). That breaks "不打开 App 也能切换" in F2 |
| **Option C (not built)** | Its own intent that opens the app (`openAppWhenRun`, `OpenIntent`, or `ForegroundContinuableIntent`) only when the app is **not** running and recording must restart. The intent cannot know that the app is not running, so this needs a heartbeat timestamp in the App Group. Worth building only if T4 fails |
| **Device** | **Needs device test** (T1 covers the no-open behaviour on device; T6 the Lock Screen) |

### Q4 · Energy while paused (session not destroyed)

| | Result |
|---|---|
| **Simulator** | **Cannot be measured.** The simulator has no real GPS or radio power model |
| **Expectation** | **Strategy A** costs **the same as recording**: live updates continue and only the database write is skipped. When the device is still, Core Location's own stationary detection reduces delivery (`stationary` flag), which helps both strategies equally. **Strategy B** would be cheap, but it fails Q1 |
| | One more observation: with strategy B the status-bar location arrow disappeared while paused. With A it stays, so users see "location in use" while paused. Users may read that as the pause not working (relevant to P4) |
| **Device** | **Needs device test** (T7): Xcode → Debug navigator → Energy Impact / Instruments "Location Energy Model", plus Settings → Battery per-app usage over 2–3 h |

## 3. Conclusion

**Partially feasible.**

- **Feasible (simulator-verified):** with the app alive in the background, the candidate design works: Control Widget → intent in the extension → App Group flag + Darwin notification → the app keeps its sessions and skips saving. It needs no `openAppWhenRun`, and it takes effect on the next sample.
- **Not feasible (simulator-verified):** stopping live updates while paused (strategy B) loses the ability to resume from the background, because the app gets suspended.
- **Unknown until device test:** resume after a user force-quit, the "intent relaunches the app" effect, and the energy cost of strategy A while paused.

### Recommendation (pending device results)

Implement F2 as **strategy A** (sessions and updates stay up, samples are dropped). It is the only variant that met "立即生效" in the background. Keep the shared flag as the single source of truth, read on every sample. Then choose by the outcome of T4:

| T4 outcome on device | F2 approach | Cost |
|---|---|---|
| Resume after force-quit restarts recording (relaunch seen) | Strategy A as-is | Paused energy ≈ recording energy |
| No relaunch, but a significant change / visit relaunches later | Strategy A + rely on wake-ups, and label the gap "App was not running" | Gap up to the next wake-up (≈ 500 m) |
| No relaunch at all until opened | Strategy A + option C (open the app only when its heartbeat is stale) | One app open after a force-quit |

If T7 shows paused energy is too high, the alternative to evaluate is **A′**: while paused, keep the sessions but swap the live-update stream for a sparser source (a different `CLLocationUpdate.LiveConfiguration`, or significant-change delivery only). The app stays alive through the continued (sparse) delivery. Cost: resume may take effect only at the next sparse sample, not immediately. This needs its own short test. It was not built here.

## 4. Device test steps (for you)

Preparation:
1. Open `TraceNotes.xcodeproj` in Xcode, select your iPhone, and let automatic signing register the App Group `group.com.inoxixi.tracenotes` for both targets. Run once.
2. In the app, tap **Start recording**, allow location → later choose **Change to Always Allow** when iOS asks (or set it in Settings → Privacy → Location → 轨迹笔记 → Always + Precise).
3. Control Center → `+` → Add a Control → 轨迹笔记 → **Recording (S1)**.
4. Tap **Clear** in the log before each test. After each test, tap **Share** and send the log (it contains no coordinates).

Reading the log: `[TraceNotes]` is the app and `[TraceNotesWidgets]` is the extension. A **user launch** is `app.launch` followed by `scene.phase active`. A **system relaunch** is `app.launch` with no `scene.phase active` after it. (In a scene-based app, the state at `app.launch` is always `background`, even for a user launch.)

| # | Scenario | Steps | What to look for |
|---|---|---|---|
| T1 | Background pause / resume, strategy A | Strategy "Keep updates". Lock the phone, walk outside for 2 min. Pause from Control Center (on the Lock Screen), walk 2 min, resume, walk 2 min | `intent.perform` → `pause.observed` within ~1 s → `saved=false` until resume → `saved=true`. The app was not opened |
| T2 | Background pause / resume, strategy B | Same as T1 with "Stop updates, keep sessions" | Whether `pause.observed paused=false` appears at resume time or only when you next open the app |
| T3 | System-style kill | Strategy A, recording. With the app in the background and Xcode attached, press Stop (■) in Xcode (this ends the process like a system kill, not like a user swipe). Then disconnect the cable and walk 500 m | `app.launch` without `scene.phase active`, then `session.start` and `location saved=true`. Note the distance or time until relaunch |
| T4 | **User force-quit** | Strategy A, recording, paused. Swipe the app away in the app switcher. Wait 1 min standing still. Resume from Control Center. Wait 1 min, then walk 500 m–1 km | (a) any `app.launch` right after `intent.perform`? (b) if not, which event relaunches it (`slc.update` / `visit`) and when? (c) any `insufficientlyInUse` / `serviceSessionRequired` in diagnostics after a relaunch? |
| T5 | Force-quit while recording | Same as T4 without pausing: swipe away, then walk 1 km | Whether and when recording comes back, and how big the gap is |
| T6 | Lock Screen | With the phone locked, toggle from Control Center | Whether iOS asks to unlock (it should not with `openAppWhenRun=false`) |
| T7 | Energy | Day 1: strategy A, paused for 3 h while carrying the phone normally. Day 2: recording for 3 h. Also attach Xcode → Debug navigator → Energy Impact for 10 min in each state | Settings → Battery per-app usage, and the Energy Impact level paused vs. recording |

After the device tests, F2 can be finalized. Possible outcomes are a new decision such as "pause keeps the location session running" or a change to D24's wording. **Both need your confirmation**, so I have not written anything to DECISIONS.md.
