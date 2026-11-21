# Trace Notes · PLAN.md

> Updated by the coding agent at the end of each slice. Product decisions live in PRODUCT.md / DECISIONS.md.

## Current stage

**Define is complete. Technical spikes in progress (S1 and S2 waiting for device tests).**

The workflow is Discover → Define → Design → Package → Execute & Verify. Discover (2026-11-21) produced decisions D1–D25. Define produced PRODUCT.md v0.1.

## Completed

| Date | Task | Result |
|---|---|---|
| 2026-11-21 | Docs | PRODUCT.md, DECISIONS.md, AGENTS.md, CLAUDE.md committed |
| 2026-11-21 | T0 · repo init | Xcode project `TraceNotes.xcodeproj`: app target `TraceNotes` (SwiftUI, iPhone only, iOS 26) and an empty `TraceNotesWidgets` extension. Background Modes → Location updates is on. Location (Always / When In Use) and Motion purpose strings, plus the localized display name, are in en / ja / zh-Hans via `InfoPlist.xcstrings`. An empty `Localizable.xcstrings` is in place. App launches to a blank screen |
| 2026-11-21 | T0 · legacy inventory | `docs/LEGACY_INVENTORY.md`: 7 files proposed for migration, awaiting confirmation |
| 2026-11-21 | S1 · Control Center pause (simulator part) | `spikes/S1-control-pause/` + `docs/spikes/S1-result.md`. Simulator: strategy A (keep sessions and updates, skip saving) pauses and resumes immediately from the background; strategy B (stop updates) fails because the app gets suspended. Conclusion **partially feasible**, waiting for device tests T1–T7 |
| 2026-11-21 | S2 · GCJ-02 base map (Japan-side part) | `TraceNotes/MapDatum/` (GCJ-02 transform, mainland region 73.5 KB, per-point policy = default rule), new `TraceNotesTests` target (13 tests pass), Debug-only datum page (`TraceNotes/Debug/`), `Tools/geodata/` build scripts, `docs/spikes/S2-result.md`, `docs/THIRD_PARTY_NOTICES.md`. **Finding: seen from Japan, Apple Maps draws mainland China in WGS-84**, so the default rule alone would shift mainland tracks off the roads. Waiting for a decision (S2-result §0) and the mainland device test (§6) |

## Spikes

| # | Question | Source | Status |
|---|---|---|---|
| S1 | Can a Control Widget pause / resume recording from Control Center while the app is in the background **and** after it has been killed, without destroying the background location session? | PRODUCT F2, D24 | Simulator done, **waiting for device tests** (`docs/spikes/S1-result.md` §4) |
| S2 | How do we tell whether the current MapKit base map uses GCJ-02, so WGS-84 points can be converted only when needed? Needs on-device verification in mainland China | PRODUCT F7, D16, D17 | Japan-side done. **Decision needed** on the default rule (`docs/spikes/S2-result.md` §0), then mainland device test M1–M7 (§6) |
| S3 | What sampling strategy (accuracy / distance filter / activity type, CLVisit and significant-change wake-ups, stationary sleep) meets **< 3 % battery per day** while keeping moving gaps ≤ 2 min? | PRODUCT §6, D13, D25 | Not started |

Note: PRODUCT.md and DECISIONS.md only name S1 and S2. S3 is defined in the task prompt list (CLAUDE_CODE_PROMPTS.md, "3% 耗电目标下的采样策略").

## Next

1. S1 device tests (you), then decide the final F2 approach
2. S2: decide (a) keep the default rule or (b) convert only when the China base map is served (you); mainland device test on the next trip
3. S3: sampling strategy for the 3 % target
4. Design: data model layers, storage choice, rendering (smooth curves + LOD) → ARCHITECTURE.md
5. Package: split into vertical slices

## Known risks

- **Background session lifetime (S1)**: in the simulator, a killed app was relaunched in the background and re-created both sessions without diagnostics. A user force-quit on a device is still untested (T4/T5). Running the control's intent was followed by an app relaunch in the simulator (2 of 2) for an unknown reason; not to be relied on until seen on a device.
- **Paused energy (S1)**: strategy A keeps location running while paused, so paused energy ≈ recording energy until measured (T7).
- **Spike code in the app**: `TraceNotesApp` shows `S1SpikeView`, and the widget bundle registers `S1RecordingControl`. Both must be removed or replaced when F2 is implemented for real.
- **GCJ-02 detection (S2)**: MapKit does not report the base map's coordinate system (D17). From Japan the mainland tiles are WGS-84, so whether to convert depends on which map Apple serves, and no public signal for that is known yet. If none is found, rule 3 (no user setting) is at risk.
- **Border jump (S2)**: per-point conversion makes a ~500 m jump where a track crosses into HK or Macau. Rendering has to decide how to draw it.
- **OSM attribution (S2)**: `china-mainland.bin` contains ODbL data; "© OpenStreetMap contributors" must appear in the app before release (`docs/THIRD_PARTY_NOTICES.md`).
- **Spike wiring (S2)**: Debug builds show a TabView (S1 + S2 Datum) in `TraceNotesApp`; remove it along with the S1 wiring.
- **Battery vs. completeness (S3)**: all-day recording under 3 % is the hardest quantitative target.
- **Legacy stabilizer at all-day scale**: it holds the whole session in memory and does several O(n) copies or scans per sample (see LEGACY_INVENTORY §4.2). Its session `finish()` has no direct equivalent under D1.
- **Toolchain**: the machine has Xcode 27.0 (iOS 27 SDK) with an iOS 26.5 simulator runtime. The deployment target is 26.0.
