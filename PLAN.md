# Trace Notes · PLAN.md

> Updated by the coding agent at the end of each slice. Product decisions live in PRODUCT.md / DECISIONS.md.

## Current stage

**Define is complete. Next: Design and the technical spikes.**

The workflow is Discover → Define → Design → Package → Execute & Verify. Discover (2026-11-21) produced decisions D1–D25. Define produced PRODUCT.md v0.1.

## Completed

| Date | Task | Result |
|---|---|---|
| 2026-11-21 | Docs | PRODUCT.md, DECISIONS.md, AGENTS.md, CLAUDE.md committed |
| 2026-11-21 | T0 · repo init | Xcode project `TraceNotes.xcodeproj`: app target `TraceNotes` (SwiftUI, iPhone only, iOS 26) and an empty `TraceNotesWidgets` extension. Background Modes → Location updates is on. Location (Always / When In Use) and Motion purpose strings, plus the localized display name, are in en / ja / zh-Hans via `InfoPlist.xcstrings`. An empty `Localizable.xcstrings` is in place. App launches to a blank screen |
| 2026-11-21 | T0 · legacy inventory | `docs/LEGACY_INVENTORY.md`: 7 files proposed for migration, awaiting confirmation |

## Spikes

| # | Question | Source | Status |
|---|---|---|---|
| S1 | Can a Control Widget pause / resume recording from Control Center while the app is in the background **and** after it has been killed, without destroying the background location session? | PRODUCT F2, D24 | Not started (next task) |
| S2 | How do we tell whether the current MapKit base map uses GCJ-02, so WGS-84 points can be converted only when needed? Needs on-device verification in mainland China | PRODUCT F7, D16, D17 | Not started (needs a trip to China) |
| S3 | What sampling strategy (accuracy / distance filter / activity type, CLVisit and significant-change wake-ups, stationary sleep) meets **< 3 % battery per day** while keeping moving gaps ≤ 2 min? | PRODUCT §6, D13, D25 | Not started |

Note: PRODUCT.md and DECISIONS.md only name S1 and S2. S3 is defined in the task prompt list (CLAUDE_CODE_PROMPTS.md, "3% 耗电目标下的采样策略").

## Next

1. S1: Control Center pause / resume spike
2. S2: GCJ-02 base map detection
3. S3: sampling strategy for the 3 % target
4. Design: data model layers, storage choice, rendering (smooth curves + LOD) → ARCHITECTURE.md
5. Package: split into vertical slices

## Known risks

- **Background session lifetime (S1)**: `CLBackgroundActivitySession` / `CLServiceSession` can only be started in the foreground. If the system kills the app, it is unclear whether resuming from Control Center can restart recording without bringing the app to the foreground.
- **GCJ-02 detection (S2)**: MapKit does not report the base map's coordinate system (D17).
- **Battery vs. completeness (S3)**: all-day recording under 3 % is the hardest quantitative target.
- **Legacy stabilizer at all-day scale**: it holds the whole session in memory and does several O(n) copies or scans per sample (see LEGACY_INVENTORY §4.2). Its session `finish()` has no direct equivalent under D1.
- **Toolchain**: the machine has Xcode 27.0 (iOS 27 SDK) with an iOS 26.5 simulator runtime. The deployment target is 26.0.
