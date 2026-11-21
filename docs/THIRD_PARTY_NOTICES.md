# Third-party notices

Trace Notes has no third-party code dependencies. The items below are algorithms that were re-implemented, and data that was derived. Each lists the attribution its licence requires.

## Shipped in the app

### OpenStreetMap data (in `TraceNotes/MapDatum/china-mainland.bin`)

The Hong Kong and Macau parts of the mainland-China display region come from OpenStreetMap boundary relations.

© OpenStreetMap contributors. Available under the Open Database License (ODbL) 1.0, https://www.openstreetmap.org/copyright

**To do before release:** show "© OpenStreetMap contributors" with a link to the copyright page in the app's About / acknowledgements screen. The derived database (`china-mainland.bin`) and the script that builds it (`Tools/geodata/build_boundary.py`) must stay available under ODbL.

### Natural Earth (in `TraceNotes/MapDatum/china-mainland.bin`)

Admin-0 countries, 1:10m. Public domain, https://www.naturalearthdata.com/about/terms-of-use/. No attribution is required; credited here anyway.

### GCJ-02 transform formula (in `TraceNotes/MapDatum/GCJ02.swift`)

The formula was re-implemented in Swift. No source code was copied. The reference implementations used for the formula's constants and the unit-test reference values are:

- **eviltransform**, https://github.com/googollee/eviltransform. Copyright (c) 2015, Googol Lee and contributors. BSD 2-Clause License.
- **coordtransform**, https://github.com/wandergis/coordtransform. Copyright (c) 2015 记忆的残骸 (wandergis). MIT License.

## Debug builds only

### OpenStreetMap data (in `TraceNotes/Debug/MapDatumPresetRoutes.swift`)

Road and rail centrelines for the S2 debug page. © OpenStreetMap contributors, ODbL 1.0. Compiled only in Debug builds.
