# Trace Notes · PLAN.md

> Updated by the coding agent at the end of each slice. Product decisions live in PRODUCT.md / DECISIONS.md.

## Current stage

**Execute & Verify: VS1 (record → store → today on the map), VS2 (stay detection + today's timeline) and VS3 (track display layer) are done in the simulator and wait for device checks. Spikes S1–S3 still wait for device tests.**

The workflow is Discover → Define → Design → Package → Execute & Verify. Discover (2026-11-21) produced decisions D1–D25. Define produced PRODUCT.md (now v0.2). Design produced ARCHITECTURE.md and D26–D30 (2026-11-22); the slice order is ARCHITECTURE §12.

## Completed

| Date | Task | Result |
|---|---|---|
| 2026-11-21 | Docs | PRODUCT.md, DECISIONS.md, AGENTS.md, CLAUDE.md committed |
| 2026-11-21 | T0 · repo init | Xcode project `TraceNotes.xcodeproj`: app target `TraceNotes` (SwiftUI, iPhone only, iOS 26) and an empty `TraceNotesWidgets` extension. Background Modes → Location updates is on. Location (Always / When In Use) and Motion purpose strings, plus the localized display name, are in en / ja / zh-Hans via `InfoPlist.xcstrings`. An empty `Localizable.xcstrings` is in place. App launches to a blank screen |
| 2026-11-21 | T0 · legacy inventory | `docs/LEGACY_INVENTORY.md`: 7 files proposed for migration, awaiting confirmation |
| 2026-11-21 | S1 · Control Center pause (simulator part) | `spikes/S1-control-pause/` + `docs/spikes/S1-result.md`. Simulator: strategy A (keep sessions and updates, skip saving) pauses and resumes immediately from the background; strategy B (stop updates) fails because the app gets suspended. Conclusion **partially feasible**, waiting for device tests T1–T7 |
| 2026-11-21 | S2 · GCJ-02 base map (Japan-side part) | `TraceNotes/MapDatum/` (GCJ-02 transform, mainland region 73.5 KB, per-point policy = default rule), new `TraceNotesTests` target (14 tests pass), Debug-only datum page (`TraceNotes/Debug/`), `Tools/geodata/` build scripts, `docs/spikes/S2-result.md`, `docs/THIRD_PARTY_NOTICES.md`. **Finding: seen from Japan, Apple Maps draws mainland China in WGS-84**, so the default rule alone would shift mainland tracks off the roads. Decided as **D31**: convert only inside the mainland **and** when the China base map is served (policy input, `false` until the signal is known). Waiting for the mainland device test (§6) |
| 2026-11-21 | S3 · sampling strategy (simulator part) | Separate spike app `TraceNotesS3` (`spikes/S3-sampling/`): strategies A (system live updates), B (tiered accuracy, always on), C (geofence sleep), switchable in Debug; shared state machine (unit-tested), event log, day stats, MetricKit store. `docs/spikes/S3-result.md`: strategies, simulator results, device test plan, record sheet. Simulator: all three record City Run / Freeway at 1 Hz with ≤ 1 s gaps in the background; A and B complete moving → stay → leave; **C's geofence never fired in the simulator** (device check T-C0 first). Fixed two measurement bugs (cached replayed fixes, time lost after a kill). Preliminary pick: B baseline, A challenger. Waiting for device days |
| 2026-11-22 | Docs v0.2 | PRODUCT.md v0.2, DECISIONS.md D26–D30, new ARCHITECTURE.md. The old D26 (GCJ-02 rule) was renumbered **D31** because of a number clash |
| 2026-11-22 | VS1 · record → store → today on the map (simulator part) | **Storage** (`TraceNotes/Storage/`): GRDB 7.12 (only dependency), WAL `DatabasePool` in Application Support with `completeUntilFirstUserAuthentication`, migration v1 = `raw_points` + `recorder_events`, ms INTEGER timestamps, coordinates as INTEGER degrees × 1e7, append-only triggers, reads only by time range and "observe a local day" (each point's own `timeZoneID`). **Recording** (`TraceNotes/Recording/`): one `RecordingEngine` on `CLLocationManager` with strategy B (S3 pick) behind a replaceable `SamplingStrategy`, `CLServiceSession(.always)` + `CLBackgroundActivitySession`, visits + significant change as wake-ups, motion activity; pure `RecordingCore` decides saving: D28 heartbeat (1 point / 5 min while stationary, a point outside the stay at once, skipped count reported per hour), replayed fixes saved with a flag but never deciding; engine state persisted in the App Group and restored after a kill; launch / backgroundRelaunch / terminatedDetected and the other prompt events written. **UI**: onboarding (explanation → Always → Motion → Today), Today = `MKMapView` polyline with live `ValueObservation`, status capsule for every F1 state with Settings links, empty and error states; ja / zh-Hans / en. **Spikes**: S1's two temporary hooks removed from the app entry and widget bundle; S1 + S2 pages only behind a Debug "Developer" button, absent from Release; the engine yields while the S1 recorder is armed. 47 tests pass |
| 2026-11-22 | VS2 · stay detection + today's timeline (simulator part) | No written task prompt existed for VS2; the contract was drafted from ARCHITECTURE §5/§7/§12 and the three missing product rules were confirmed by the user (**D32**: stays ≥ 5 min, gap = > 5 min silence *and* moved beyond the stay radius, stays drawn as one marker). **Processing** (`TraceNotes/Processing/`): pure `Segmenter` (pipeline steps ① + ③): dwell 50 m / 5 min, stay radius 150 m (+ accuracy, as in the recorder), stay centre from its core only, silent-in-place = stay, visit arrival (after 5 min) and departure as time signals, cuts at local midnight in the segment's own zone with continuation (D30). `TrackProcessor` re-derives only the tail after the last completed segment on every raw append, so it holds no state across kills (§5.2) and the open segment doubles as the 30-min checkpoint; runs while the app is in the foreground and catches up on return. **Storage**: migration v2, derived `segments` table (ms / ×1e7 integer columns, `pipelineVersion`; other versions are dropped and rebuilt). **UI**: Today's timeline in a bottom sheet (three detents, map stays interactive, newest row in view, times in each segment's zone), map draws moves as lines and stays as one marker, tapping a row focuses the map; ja / zh-Hans / en. 62 tests pass |
| 2026-11-22 | VS3 · track display layer (simulator part) | No written task prompt; contract drafted from ARCHITECTURE §5.1 ⑦ / §6, and the user chose to keep the trace stabilizer out of VS3 (its own slice later). **Geo** (`TraceNotes/Geo/`): iterative Douglas-Peucker in local metres; centripetal Catmull-Rom (α = 0.5) as Bézier spans, with straight spans at real corners (≥ 45° and both legs ≥ 8 m, legacy values), flattened by Wang's formula to a polyline within the level's tolerance. **Render cache** (pipeline step ⑦): 5 levels at 0.5 / 2 / 8 / 32 / 128 m, written with each completed move (migration v3, `render_cache`, deleted with its segment); the open move is simplified in memory; pipeline v3. **Map**: the level follows the zoom (simplification ≤ ½ screen point); all moves are one `MKMultiPolyline` per layer, an 8 pt background-coloured outline under a 5 pt accent line, opaque, so crossings never darken; drawn in display coordinates (D31, `DisplayProjection`). Simulator finding: a custom overlay renderer (and a custom `MKOverlayPathRenderer`) is rasterised per tile level, so the width jumped between 2.5 and 7–10 pt with the zoom; MapKit draws only its own polyline renderers as vectors, hence the flattened polylines (**D33**, revises D27; confirmed by the user). Measured 5.0 pt at three zoom levels; corner kept; dark mode re-colours live. 73 tests pass, Release build 0 warnings |

## Spikes

| # | Question | Source | Status |
|---|---|---|---|
| S1 | Can a Control Widget pause / resume recording from Control Center while the app is in the background **and** after it has been killed, without destroying the background location session? | PRODUCT F2, D24 | Simulator done, **waiting for device tests** (`docs/spikes/S1-result.md` §4) |
| S2 | How do we tell whether the current MapKit base map uses GCJ-02, so WGS-84 points can be converted only when needed? Needs on-device verification in mainland China | PRODUCT F7, D16, D17 | Japan-side done, rule decided (D31). **Waiting for mainland device test** M1–M7 to find the "China base map served" signal (`docs/spikes/S2-result.md` §6) |
| S3 | What sampling strategy (accuracy / distance filter / activity type, CLVisit and significant-change wake-ups, stationary sleep) meets **< 3 % battery per day** while keeping moving gaps ≤ 2 min? | PRODUCT §6, D13, D25 | Simulator done, **waiting for device days** (`docs/spikes/S3-result.md` §6–7) |

Note: PRODUCT.md and DECISIONS.md only name S1 and S2. S3 is defined in the task prompt list (CLAUDE_CODE_PROMPTS.md, "3% 耗电目标下的采样策略").

## Next

1. VS1 + VS2 + VS3 device checks (you): see the lists below
2. Trace stabilizer slice (drift / jump suppression before display; LEGACY_INVENTORY §3 values need your confirmation), then VS4 · transport modes (ARCHITECTURE §12); each needs its task prompt
3. S1 device tests (you), then decide the final F2 approach. The main app no longer ships S1's Control Center widget: run T1–T7 from a build of commit `f75ba95` or earlier
4. S2: mainland device test on the next trip (finds the signal D31 needs)
5. S3 device days (you). TN S3 and the formal app must not record at the same time: on S3 days set Trace Notes' location access to Never

## VS1 device checks

1. Install a Release (or Debug) build, finish onboarding with Always + Motion allowed. Today shows "Recording".
2. Live one ordinary day without opening the app. In the evening, Today's track covers the day's trips without long straight jumps.
3. Swipe the app away in the app switcher, then go out. Later the track continues after the force-quit (the system relaunches the app on a visit or significant change); note how long the gap is.
4. Settings → Trace Notes → Location → While Using: Today shows the "Always" hint with a Settings link. Set back to Always.
5. Turn Location Services off globally: Today shows the Location Services hint. Turn it back on.
6. Low Power Mode on for a while: recording continues.
7. Optional, for diagnosis: Xcode → Devices → download the app container and look at `recorder_events` (launch / backgroundRelaunch / terminatedDetected / heartbeatSkipped).

## VS2 device checks

1. A normal day with a few stops: each stop of 5 minutes or more is one "Stay" row and one marker; red lights and short shop visits stay inside "Moving".
2. Phone lying indoors 30 min (PRODUCT §6 drift test): one stay, no scribble on the map.
3. Overnight at home: yesterday's last stay ends at 24:00, today starts with a stay from 00:00.
4. Leave home after the night: the stay ends near the departure time (visit or the first point outside 150 m), not hours later.
5. Phone off for a while, then switched on somewhere else: a "No record" row covers the time.
6. Tap rows: the map moves to the stay or trip above the panel.
7. Open the app after hours in the background: the timeline catches up within about a second (F8 "≤ 1 s").

## VS3 device checks

1. A day with curvy roads: the track follows bends as smooth curves; right-angle street corners stay sharp, not cut across blocks.
2. Pinch from city to street level: the line keeps the same width; detail appears as you zoom in, without a visible jump.
3. Routes that cross or repeat (there and back): the overlap is not darker than the rest.
4. While walking with the app open: the newest part of the line grows smoothly, no flicker of the whole track.
5. Switch dark mode on and off: the outline follows the map (light outline on light, dark on dark).
6. A long day (many trips): panning and zooming stay fluid.

## Known risks

- **Background session lifetime (S1)**: in the simulator, a killed app was relaunched in the background and re-created both sessions without diagnostics. A user force-quit on a device is still untested (T4/T5). Running the control's intent was followed by an app relaunch in the simulator (2 of 2) for an unknown reason; not to be relied on until seen on a device.
- **Paused energy (S1)**: strategy A keeps location running while paused, so paused energy ≈ recording energy until measured (T7).
- **Spike code in the app**: resolved in VS1. S1 and S2 pages are only reachable from the Debug "Developer" menu; `S1RecordingControl` is out of the widget bundle (S1 device tests need an older build, see Next).
- **GCJ-02 detection (S2)**: MapKit does not report the base map's coordinate system (D17). From Japan the mainland tiles are WGS-84, so whether to convert depends on which map Apple serves, and no public signal for that is known yet. If none is found, rule 3 (no user setting) is at risk.
- **Border jump (S2)**: per-point conversion makes a ~500 m jump where a track crosses into HK or Macau. Rendering has to decide how to draw it.
- **OSM attribution (S2)**: `china-mainland.bin` contains ODbL data; "© OpenStreetMap contributors" must appear in the app before release (`docs/THIRD_PARTY_NOTICES.md`).
- **Battery vs. completeness (S3)**: all-day recording under 3 % is the hardest quantitative target. Not shown impossible; levers and the rules they touch are in S3-result §8.
- **Strategy C wake-up (S3)**: no `CLMonitor` event at all in the simulator, foreground or background (S3-result §4.2). T-C0 on a device decides whether C is viable; restarting updates from that wake-up in the background (T-C1) is a second unknown.
- **Replayed fixes (S3)**: handled in VS1. Fixes older than the process launch are saved with the `replayed` flag, never decide the state, and are not drawn on Today.
- **Two location apps on the device (S3)**: Trace Notes now records by itself after onboarding. TN S3 is a separate app with its own engine; running both on one device breaks "one engine at a time" and mixes up the battery numbers.
- **Launch classification (VS1)**: iOS 26 deprecates `launchOptions[.location]`. `launch` vs. `backgroundRelaunch` is decided by whether the connected scene is in the foreground at the first fix (a simulator probe showed UIKit connects a scene on both kinds of launch). If a device ever relaunches without connecting a scene, no launch event is written for that process; `terminatedDetected` is unaffected.
- **Stationary + killed (VS1)**: while stationary the 25 m distance filter delivers no fixes, so after a kill the system only relaunches the app on movement (visit / significant change). In the simulator a killed stationary app stayed down; leaving the place relaunches it on a device (to check in device check 3).
- **Write window on a kill (VS1)**: points are written one by one through a single async writer; a point received in the last moment before a kill can be lost.
- **Processing only in the foreground (VS2)**: segments are derived while the app is on screen. Nothing else reads them yet; a future widget or notification would need background processing.
- **Stay start is approximate (VS2)**: the dwell anchor is checked against the newest point only, so a stay can begin up to ~30 s before the real arrival (simulator: 12:13:12 for an arrival at 12:13:43).
- **Visits carry no coordinates (VS2)**: VS1 stores only visit times, so a visit-only stay takes its centre from nearby points.
- **Indoor drift beyond 50 m (VS2)**: dwell needs usable points within 50 m for 5 minutes. Indoor drift wider than that is caught by the visit arrival or the silent-in-place rule; to check in device check 2.
- **No stabilizer yet (VS3)**: GPS jumps and indoor drift inside a move are smoothed, not removed; a long jump still shows as a curve between two places. The stabilizer slice handles it.
- **Whole-day redraw (VS3)**: every change of the open move (about once a second while moving, app open) rebuilds both day overlays. Fine for a few thousand cached points in the simulator; a long day on an older phone may stutter (device check 6). A split into a static overlay for completed moves and a small one for the open move is the fix if needed.
- **Level switch on zoom (VS3)**: crossing a level boundary replaces the overlays; MapKit may show one frame without the track. Not visible in the simulator.
- **Corner test uses the cached level's points (VS3)**: at coarse levels the legs are long, so more turns qualify as corners and are drawn straight; looks angular at city scale for winding roads.
- **Legacy stabilizer at all-day scale**: it holds the whole session in memory and does several O(n) copies or scans per sample (see LEGACY_INVENTORY §4.2). Its session `finish()` has no direct equivalent under D1.
- **Toolchain**: the machine has Xcode 27.0 (iOS 27 SDK) with an iOS 26.5 simulator runtime. The deployment target is 26.0.
