# S2 Result · When does MapKit need GCJ-02?

> Spike for PRODUCT F7 / D16 / D17. Japan-side part done 2026-11-21. Mainland China device test: **not done** (§6).
> Code: `TraceNotes/MapDatum/` (production modules), `TraceNotesTests/` (unit tests), `TraceNotes/Debug/` (Debug-only page), `Tools/geodata/` (data build scripts).
> Environment: Xcode 27.0, iOS 26.5 Simulator (iPhone 17 Pro) on a Japanese network, `simctl location` for simulated positions.

## 0. Headline: one observation conflicts with the default rule

**Stop-and-report item.** Seen from Japan, Apple Maps draws **mainland China in WGS-84**, not GCJ-02.

On the Debug page, the OSM centrelines (WGS-84, red) lie exactly on the roads of the MapKit base map. The converted lines (GCJ-02, blue) sit 480–600 m off:

- Beijing: Chang'an Avenue.
- Shanghai: Nanjing Road East. The red line ends at Zhongshan Rd E1 on the Bund; the blue one ends in the Huangpu River.
- Shenzhen: the Lo Wu rail line.
- Zhuhai: Gongbei.

The attribution logo reads "Apple 地图", not 高德 (Amap). This held with all three of these:

- simulated device location in Beijing, Shanghai, Hong Kong or Tokyo;
- Locale region JP;
- Locale region CN (`AppleLocale zh-Hans_CN`, after a reboot; tiles may have been cached, so this is weak evidence).

What this means for the rules:

| Fixed rule | Conflict? |
|---|---|
| 1 · Decide by "is the displayed base map the mainland GCJ-02 map", not by where the app was installed | **No.** The observation supports this rule: the base map really is different depending on the environment |
| 2 · Default rule: point in mainland → GCJ-02; HK/Macau/Taiwan → none; precise polygon; per point | **Yes, partly.** "Point is inside the mainland polygon" is **not sufficient**. In the environment we could test, the default rule moves mainland tracks **off** the roads by about 500 m. The polygon and per-point parts are still needed. But the conversion must also depend on *which* base map is being served, and no reliable signal for that exists yet (§2) |
| 3 · No user setting for the coordinate system | **Not yet**, but at risk. If the mainland test cannot find an automatic signal for "China map served", the options are: always assume one case, or ask the user. Asking would break rule 3 |
| 4 · Convert in the display layer only, store WGS-84 | No conflict |

I did **not** change any rule. `MapDatumPolicy` implements the default rule exactly as specified. The decision below is yours.

**Decision needed (you):** for users who view mainland tracks outside mainland China, either:

- **(a)** keep the default rule as written, accepting a ~500 m offset outside China until the mainland test; or
- **(b)** amend rule 2 to "convert a mainland point **only when the China base map is being served**". The signal for that is still to be found (§3, §6).

DECISIONS.md is unchanged. I will add an entry once you confirm.

## 1. What was built

| Piece | Where | Notes |
|---|---|---|
| WGS-84 → GCJ-02 transform | `TraceNotes/MapDatum/GCJ02.swift` | Own implementation of the public formula (Krasovsky constants a = 6378245, e² = 0.00669342162296594323). The same algorithm as eviltransform (BSD-2-Clause) and coordtransform (MIT). No code was copied; reference vectors came from their tests and README. Unconditional: it does no "is this in China" check |
| Mainland region | `TraceNotes/MapDatum/ChinaMainlandRegion.swift` + `china-mainland.bin` (73,520 bytes) | Mainland China **excluding** Hong Kong, Macau and Taiwan-controlled islands (incl. Kinmen), extended ~10 km out to sea. 14 polygons, 9,165 points, int32·1e6 little-endian (format in `Tools/geodata/build_boundary.py`). Lookup: even-odd ray casting over a 0.02° latitude-band edge index. Malformed data throws `LoadError` |
| Policy | `TraceNotes/MapDatum/MapDatumPolicy.swift` | Default rule, per point. `displayCoordinate(s)(for:)` returns new values and never touches the stored ones |
| Unit tests | `TraceNotesTests/` (new target, Swift Testing, not hosted, so no app launch and no S1 recorder) | 13 tests / 32 cases, all pass (§5) |
| Debug page | `TraceNotes/Debug/MapDatumDebugView.swift`, `MapDatumPresetRoutes.swift` (generated) | `#if DEBUG` only, as the second tab next to S1. Six preset routes or manual "lat, lon" lines. Red = stored WGS-84, blue = displayed. Shows the signals and the decision. Nothing is logged |
| Data build scripts | `Tools/geodata/fetch_osm.py`, `build_boundary.py`, `build_routes.py` | Development only. Inputs: Natural Earth 1:10m (public domain), OSM boundary relations for HK/MO and road/rail ways (ODbL). Raw downloads are not committed |

### Boundary accuracy (distance from test point to the region edge)

| Pair | Inside point | Outside point |
|---|---|---|
| Shenzhen / HK at Lo Wu | Luohu 22.5390, 114.1180: ~440 m | Lo Wu 22.5280, 114.1130: ~190 m |
| Zhuhai / Macau at Gongbei | Gongbei 22.2180, 113.5490: ~130 m | Portas do Cerco 22.2140, 113.5500: ~240 m |
| Xiamen / Kinmen | Xiamen 24.4798, 118.0894 | Kinmen 24.4320, 118.3170 |
| Dandong / Sinuiju | Dandong 40.1290, 124.3940: ~1 km | Sinuiju 40.1000, 124.3980: ~1.5 km |

The land border is NE 1:10m everywhere except HK and Macau, which use OSM. Precision is a few hundred metres on the land border with other countries (Dandong, Myanmar, etc.) and tens of metres at HK/Macau. Simplification tolerance is ~20 m.

**Interpretation for you to confirm:** near-shore sea within ~10 km (ferries, piers, beaches) counts as "mainland". Waters next to HK and Macau and within ~1 km of Taiwan-controlled islands do not.

## 2. Candidate signals

| Signal | What it tells | Reliability | Testable in Japan? | Failure mode |
|---|---|---|---|---|
| **A. Point in mainland polygon** (`ChinaMainlandRegion`) | Whether the *place* is one where a China map *can* be GCJ-02 | Exact for what it measures. Not sufficient alone (§0) | Yes, done | A few hundred m error at NE-precision land borders. The ~10 km sea buffer is an interpretation |
| **B. Device location in mainland** (Core Location + A) | Where the phone is now | Good when a fix is available | Partly (simulated location); it did **not** switch the tiles in the simulator | No fix or no permission. A trip viewed after returning home. Thread 797697 suggests that HK tracks go wrong when the device is in mainland, so this may matter |
| **C. `Locale.current.region`** | User's region setting | Weak: a user setting, not what Apple serves | Yes. Region CN did not switch the tiles (weak, cache possible) | Japanese users with region JP travelling in China; Chinese users abroad |
| **D. Map attribution (Apple 地图 vs 高德)** | Which map provider is drawn **right now**: the closest thing to rule 1 | High as a fact, but **not readable by public API**. The attribution views draw their text with no label or accessibility text (checked: `MKAttributionLabel` and `MKAppleLogoLabel` expose nothing) | Yes (visual) | Usable only by a human (debug page, device test). Private view inspection was tried and dropped |
| **E. MapKit `userLocation` vs Core Location** | Whether MapKit reports its own dot in a shifted datum | Low. Both were 0 m apart in Beijing, HK and Tokyo; Apple DTS says MapKit coordinates are WGS-84 | Yes, 0 m | Probably always 0 m, even on the China map |
| **F. MKLocalSearch result vs a known WGS-84 landmark** | Whether the Search service returns GCJ-02 in China (thread 814519 hypothesis) | Unknown | No (needs mainland network) | Network dependent, slow, not suitable as a render-time signal. Research only, not on the debug page |
| **G. Carrier / network country** | Whether the device is on a Chinese network | `CTCarrier` is deprecated and returns placeholder values since iOS 16. No public replacement | No | Not usable |
| **H. Apple API for the datum** | Direct answer | **Does not exist.** DTS asks for an enhancement request (Feedback) | — | — |

## 3. Recommended strategy

1. **Keep A (polygon, per point) as the only automatic geometric test.** It is correct for "where" and is required under any rule.
2. **Add an environment condition before converting.** This needs your decision (§0). The candidate is "the China base map is served", derived from B and/or C. Which of the two (or neither) predicts the served map is exactly what the mainland test must find out (§6, M3).
3. Until then, `MapDatumPolicy` stays on the default rule. The environment condition would become a second input to `MapDatumPolicy`. That is one boolean, with no change to storage or to the per-point logic.
4. Optionally file a Feedback asking for a MapKit API that exposes the base map datum (H).

How this relates to the default rule: steps 1, 3 and 4 are the default rule unchanged. Step 2 narrows it ("only when the China map is served") and needs your confirmation.

## 4. What the debug page shows (simulator, verified)

| Simulated location | Track | Decision | Device in mainland | Locale | userLocation − CL | Base map |
|---|---|---|---|---|---|---|
| Beijing 39.9042, 116.4074 | Beijing · Chang'an | GCJ-02 (69/69) | yes | JP | 0 m (GCJ offset 556 m) | Red on road → **WGS-84 tiles** |
| Shanghai 31.2304, 121.4737 | Shanghai · Nanjing Rd E | GCJ-02 (13/13) | yes | JP | 0 m (481 m) | Red on road → WGS-84 tiles |
| Hong Kong 22.3193, 114.1694 | Shenzhen → HK · Lo Wu | Mixed (37/143) | no | JP | 0 m | Red on rail both sides. Blue jumps ~500 m at the border (expected for per-point conversion) |
| Hong Kong | Zhuhai → Macau · Gongbei | Mixed (44/75) | no | JP | 0 m | Same pattern |
| Tokyo 35.6762, 139.6503 | Tokyo · Chuo-dori | WGS-84 (0/125) | no | JP | 0 m | Lines coincide |
| Beijing, region CN | Beijing · Chang'an | GCJ-02 (69/69) | yes | CN | 0 m | Still WGS-84 tiles (cache possible) |

**Display jump at the border.** A real track crossing Lo Wu or Gongbei will show a ~500 m jump at the boundary under per-point conversion. That is a consequence of rule 2 (convert only the inside points). How to draw it (break the line, or leave the jump) is a later rendering decision.

## 5. Validation results

| Check | Result |
|---|---|
| Transform within 1 m of reference: Beijing (2 sources), Shanghai, Shenzhen | Pass (`GCJ02Tests.matchesReference`, 4 cases) |
| Tokyo, Seoul, New York, Taipei outside; Beijing, Shanghai inside | Pass |
| Border pairs Lo Wu, Gongbei, Xiamen/Kinmen, Dandong/Sinuiju | Pass (14 cases in `ChinaMainlandRegionTests.classifies`) |
| Per-point conversion on a crossing track; HK/Macau/Taipei/Tokyo unchanged | Pass (`MapDatumPolicyTests`) |
| Loader: bad magic, unknown version, truncated, empty, polygon with hole, non-finite input | Pass |
| Debug page in simulator: Beijing, Shanghai, HK, Tokyo | Pass (§4) |
| Debug page absent from Release | Pass. Release binary contains no debug-page strings or symbols (`Map datum`, preset routes, signal labels: 0 hits). Only the empty object file name `MapDatumDebugView.o` appears in the debug-map path table |
| No compiler warnings (Debug, Release, tests) | Pass. One tooling log line, "Metadata extraction skipped, no AppIntents.framework dependency found", from the new test target's App Intents metadata step. It is not a compiler warning |
| No precise coordinates in logs | Pass. The new code does not log at all |

## 6. Mainland China device test

### Questions

| # | Question | Why it matters |
|---|---|---|
| M1 | On a device **in** mainland China, are mainland tiles GCJ-02 (blue on road, red off road)? Is the logo 高德? | Confirms the core assumption of D16 |
| M2 | Same device in mainland: are **HK / Macau** tracks drawn correctly in WGS-84 (red on road)? Thread 797697 reports they are offset when the device is in mainland | If not, HK/Macau also need conversion in that situation. That contradicts the second part of rule 2 → report |
| M3 | What switches the base map: device location (B), network (China SIM / China Wi-Fi), region setting (C), or a China-model iPhone? | Decides the environment condition in §3 |
| M4 | After returning to Japan, do the same mainland tracks go back to WGS-84 tiles? How soon (cached tiles)? | Decides whether "trip viewed at home" needs conversion |
| M5 | `MapKit userLocation − Core Location` in mainland: 0 m or ~500 m? | Whether signal E is useful at all |
| M6 | At Lo Wu / Gongbei: where does the base map's own datum switch, compared with our polygon? | Whether per-point conversion lines up with Apple's tile boundary |
| M7 | (Optional) Search a landmark with Apple Maps / MKLocalSearch. Is the result GCJ-02? | Signal F, and a future search feature |

### Steps (Debug build, second tab "S2 Datum")

Preparation:

- Install a Debug build before the trip.
- Allow location "While Using" or better.
- Note the iPhone model (China model or not), the SIM, and the region setting.
- In Japan before leaving, take a screenshot of the Beijing and Shanghai presets for comparison.

1. **Arrival, Japanese SIM roaming, region JP.**
   - Open S2 Datum.
   - For each of the Beijing, Shanghai, Lo Wu, Gongbei and Nathan Road presets, screenshot the whole screen with the map logo and all signal rows visible.
   - Note which line lies on the road (M1, M2, M5).
2. **Same place, connected to local Wi-Fi** (China network).
   - Force-quit the app and reopen it.
   - Repeat step 1 (M3: network).
3. **Same place, region set to China** (Settings → General → Language & Region).
   - Repeat step 1 (M3: region).
   - Set the region back afterwards.
4. **If a Chinese SIM is available:** repeat step 1 (M3: carrier).
5. **Live track:**
   - Choose Manual coordinates.
   - Enter your current position from a WGS-84 source, e.g. the S1 tab or a GPX logger. Do not read it off Apple Maps.
   - Check which line lies on the street you stand on.
   - The blue dot (MapKit) should be on your street. Note whether it agrees with red or blue.
6. **Border** (if crossing at Lo Wu or Gongbei): on each side, repeat step 5 and the matching preset (M6).
7. **Back in Japan:**
   - Open the Beijing preset immediately, then again after a day.
   - Compare with the screenshots from before the trip (M4).
8. **(Optional, M7)** Search for 天安门 in Apple Maps and drop a pin. Compare it with the known WGS-84 position 39.9087, 116.3975.

Record results as a table (step × preset → which line is on the road, logo, signal values). Do not record coordinates beyond what the steps need.

## 7. Sources

- Apple Developer Forums [thread 797697](https://developer.apple.com/forums/thread/797697), as claimed by the asker: the same HK point is correct with the device in HK ("Apple Maps") and offset with the device in mainland ("Amap").
- [Thread 853019](https://developer.apple.com/forums/thread/853019): Apple Fitness double-converts leading samples; the asker states that MapKit does no conversion.
- [Thread 814519](https://developer.apple.com/forums/thread/814519): hypothesis that MKLocalSearch returns GCJ-02 in China.
- Apple DTS replies in these threads: `CLLocationCoordinate2D` is WGS-84; no API reports the base map datum; file an enhancement request.
- Algorithms and reference vectors: eviltransform (BSD-2-Clause) and coordtransform (MIT). Data: Natural Earth (public domain) and OpenStreetMap (ODbL). See `docs/THIRD_PARTY_NOTICES.md`.
