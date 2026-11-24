import Foundation
import GRDB
import os

/// The app's single database (ARCHITECTURE §3): a GRDB `DatabasePool` in WAL mode, so the
/// recording engine can write in the background while the UI reads.
///
/// Upper layers use only the methods below; no SQL leaves this module.
nonisolated final class AppDatabase: Sendable {
  private let pool: DatabasePool

  /// Opens (creating if needed) the database at `url` and migrates it to the latest version.
  init(url: URL) throws {
    pool = try DatabasePool(path: url.path(percentEncoded: false))
    try Self.migrator.migrate(pool)
  }

  /// The app's database in Application Support, protected with
  /// `completeUntilFirstUserAuthentication` so it stays writable while the phone is locked.
  static func openShared() throws -> AppDatabase {
    let directory = URL.applicationSupportDirectory.appending(path: "Database", directoryHint: .isDirectory)
    let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
    // Files created later in this directory (the -wal and -shm files) inherit its class.
    try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path(percentEncoded: false))
    let database = try AppDatabase(url: directory.appending(path: "TraceNotes.sqlite"))
    try FileManager.default.setAttributes(
      protection, ofItemAtPath: directory.appending(path: "TraceNotes.sqlite").path(percentEncoded: false))
    return database
  }

  // MARK: - Schema

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: RawPoint.databaseTableName) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("timestamp", .integer).notNull()  // UTC milliseconds
        table.column("latitude", .integer).notNull()  // degrees × 10⁷, WGS-84
        table.column("longitude", .integer).notNull()  // degrees × 10⁷, WGS-84
        table.column("horizontalAccuracy", .double).notNull()
        table.column("altitude", .double)
        table.column("verticalAccuracy", .double)
        table.column("speed", .double)
        table.column("course", .double)
        table.column("timeZoneID", .text).notNull()
        table.column("source", .text).notNull()
          .check { [RawPoint.Source.recorded.rawValue, RawPoint.Source.gpxImport.rawValue].contains($0) }
        table.column("importBatchID", .integer)
        table.column("flags", .integer).notNull().defaults(to: 0)
      }
      try db.create(index: "raw_points_on_timestamp", on: RawPoint.databaseTableName, columns: ["timestamp"])

      try db.create(table: RecorderEvent.databaseTableName) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("timestamp", .integer).notNull()  // UTC milliseconds
        table.column("kind", .text).notNull()
        table.column("payload", .text)
      }
      try db.create(index: "recorder_events_on_timestamp", on: RecorderEvent.databaseTableName, columns: ["timestamp"])

      // The raw layer is append-only (P5); only "Delete all data" lifts this (`deleteAllData`).
      for table in Self.rawTables {
        for operation in ["UPDATE", "DELETE"] {
          try db.execute(sql: Self.appendOnlyTrigger(on: table, refusing: operation))
        }
      }
    }

    // VS2: the derived layer's segments (ARCHITECTURE §2.3). Recomputable, so not append-only.
    migrator.registerMigration("v2") { db in
      try db.create(table: Segment.databaseTableName) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("kind", .text).notNull()
          .check { [Segment.Kind.stay.rawValue, Segment.Kind.move.rawValue, Segment.Kind.gap.rawValue].contains($0) }
        table.column("start", .integer).notNull()  // UTC milliseconds
        table.column("end", .integer).notNull()  // UTC milliseconds
        table.column("timeZoneID", .text).notNull()
        table.column("localDay", .text).notNull()  // yyyy-MM-dd in timeZoneID
        table.column("isComplete", .boolean).notNull()
        table.column("continuesNextDay", .boolean).notNull()
        table.column("pointCount", .integer).notNull()
        table.column("distance", .double).notNull()
        table.column("centerLatitude", .integer)  // degrees × 10⁷, WGS-84
        table.column("centerLongitude", .integer)  // degrees × 10⁷, WGS-84
        table.column("radius", .double)
        table.column("pipelineVersion", .integer).notNull()
      }
      try db.create(index: "segments_on_localDay", on: Segment.databaseTableName, columns: ["localDay", "start"])
      try db.create(index: "segments_on_end", on: Segment.databaseTableName, columns: ["end"])
    }

    // VS3: simplified tracks of completed moves (ARCHITECTURE §6.3), removed with their segment.
    migrator.registerMigration("v3") { db in
      try db.create(table: RenderCacheEntry.databaseTableName) { table in
        table.column("segmentID", .integer).notNull()
          .references(Segment.databaseTableName, onDelete: .cascade)
        table.column("level", .integer).notNull()
        table.column("coordinates", .blob).notNull()
        table.primaryKey(["segmentID", "level"])
      }
    }

    // VS4: transport modes on moves, and the user modification layer (ARCHITECTURE §2.2), which is
    // user data: processing never deletes it.
    migrator.registerMigration("v4") { db in
      try db.alter(table: Segment.databaseTableName) { table in
        table.add(column: "transportMode", .text)
        table.add(column: "modeConfidence", .double)
        table.add(column: "userTransportMode", .text)
      }
      try db.create(table: SegmentOverride.databaseTableName) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("startTime", .integer).notNull()  // UTC milliseconds
        table.column("endTime", .integer).notNull()  // UTC milliseconds
        table.column("field", .text).notNull()
          .check { [SegmentOverride.Field.transportMode.rawValue, SegmentOverride.Field.placeName.rawValue].contains($0) }
        table.column("value", .text).notNull()
        table.column("createdAt", .integer).notNull()  // UTC milliseconds
      }
      try db.create(index: "segment_overrides_on_endTime", on: SegmentOverride.databaseTableName, columns: ["endTime"])
    }

    // VS5: places (F5). They hold the user's names, so processing never deletes them (D37).
    migrator.registerMigration("v5") { db in
      try db.create(table: Place.databaseTableName) { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("latitude", .integer).notNull()  // degrees × 10⁷, WGS-84
        table.column("longitude", .integer).notNull()  // degrees × 10⁷, WGS-84
        table.column("name", .text)
        table.column("address", .text)
        table.column("status", .text).notNull()
          .check { [Place.Status.pending.rawValue, Place.Status.resolved.rawValue, Place.Status.failed.rawValue].contains($0) }
        table.column("attempts", .integer).notNull().defaults(to: 0)
        table.column("lastAttemptAt", .integer)  // UTC milliseconds
        table.column("nextAttemptAt", .integer)  // UTC milliseconds
        table.column("userName", .text)
        table.column("createdAt", .integer).notNull()  // UTC milliseconds
      }
      try db.create(index: "places_on_latitude", on: Place.databaseTableName, columns: ["latitude"])
      try db.alter(table: Segment.databaseTableName) { table in
        table.add(column: "placeID", .integer).references(Place.databaseTableName, onDelete: .setNull)
      }
    }
    // VS6: gap reasons (F6, D42).
    migrator.registerMigration("v6") { db in
      try db.alter(table: Segment.databaseTableName) { table in
        table.add(column: "gapReason", .text)
          .check { GapReason.allCases.map(\.rawValue).contains($0) }
      }
    }
    // Overview (D44): the box around each completed move's track, for the viewport query. Filled
    // from the render cache that is already stored; afterwards written with the cache.
    migrator.registerMigration("v7") { db in
      try db.create(table: TrackBounds.databaseTableName) { table in
        table.primaryKey("segmentID", .integer)
          .references(Segment.databaseTableName, onDelete: .cascade)
        table.column("minLatitude", .integer).notNull()  // degrees × 10⁷, WGS-84
        table.column("maxLatitude", .integer).notNull()
        table.column("minLongitude", .integer).notNull()
        table.column("maxLongitude", .integer).notNull()
      }
      let finest = try RenderCacheEntry.filter(RenderCacheEntry.Columns.level == 0).fetchCursor(db)
      while let entry = try finest.next() {
        try TrackBounds(segmentID: entry.segmentID, finest: entry.coordinates)?.insert(db)
      }
    }
    // Statistics (D50): the region of each place. Places named earlier are looked up again for
    // the region alone.
    migrator.registerMigration("v8") { db in
      try db.alter(table: Place.databaseTableName) { table in
        table.add(column: "countryCode", .text)
        table.add(column: "countryStatus", .text).notNull().defaults(to: Place.Status.pending.rawValue)
          .check { [Place.Status.pending.rawValue, Place.Status.resolved.rawValue, Place.Status.failed.rawValue].contains($0) }
      }
    }
    // Fog of World (F12, D54): explored pixels by block, without times, and when they were imported.
    // Not part of the raw layer: a new import replaces them, and they can be removed.
    migrator.registerMigration("v9") { db in
      try db.create(table: "fog_blocks", options: .withoutRowID) { table in
        table.column("x", .integer).notNull()  // block column, 0 ..< 65536 from 180° W
        table.column("y", .integer).notNull()  // block row, 0 ..< 65536 from the north
        table.column("pixels", .blob).notNull()  // FogOfWorld.StoredBlock.pixels
        table.column("pixelCount", .integer).notNull()
        table.column("length", .double).notNull()  // metres of centre line
        table.primaryKey(["x", "y"])
      }
      try db.create(table: "fog_import") { table in
        table.primaryKey("id", .integer).check { $0 == 1 }
        table.column("importedAt", .integer).notNull()  // UTC milliseconds
      }
    }
    migrator.registerMigration("v10") { db in
      // D55 ⑤: MetricKit's reports, kept on the phone for the diagnostic report only.
      try db.create(table: "metric_reports") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("receivedAt", .integer).notNull().indexed()  // UTC milliseconds
        table.column("kind", .text).notNull()  // MetricReport.Kind
        table.column("json", .text).notNull()
      }
    }
    return migrator
  }

  // MARK: - Writing (append only)

  /// Appends points and events in one transaction, in the given order.
  func append(points: [RawPoint], events: [RecorderEvent]) async throws {
    try await pool.write { db in
      for var point in points { try point.insert(db) }
      for var event in events { try event.insert(db) }
    }
  }

  // MARK: - Reading

  /// Points with `range.lowerBound <= timestamp < range.upperBound`, oldest first.
  func points(in range: Range<Date>) async throws -> [RawPoint] {
    try await pool.read { db in try Self.points(db, in: range) }
  }

  /// The points of one local day (each point's own time zone decides, F8), oldest first. Emits
  /// again after every write that changes them.
  func observePoints(on day: LocalDay) -> AsyncValueObservation<[RawPoint]> {
    ValueObservation
      .tracking { db in
        try Self.points(db, in: day.possibleInstants)
          .filter { LocalDay($0.timestamp, timeZoneID: $0.timeZoneID) == day }
      }
      .values(in: pool)
  }

  /// The newest timestamp of any recorded point or event, i.e. the last sign of life of the
  /// recorder (imported points are not).
  func lastActivity() async throws -> Date? {
    try await pool.read { db in
      let point = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM raw_points WHERE source = ?", arguments: [RawPoint.Source.recorded])
      let event = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM recorder_events")
      return [point, event].compactMap { $0 }.max().map(RawPoint.date(milliseconds:))
    }
  }

  // MARK: - Derived layer (segments)

  /// What the segmenter needs to continue after the last completed segment, read in one
  /// transaction so points and events are consistent.
  struct SegmentationInput: Sendable {
    /// The newest completed segment; processing continues from its end.
    var lastComplete: Segment?
    /// The newest point before `lastComplete.end`, for continuing a segment cut at midnight.
    var pointBeforeCursor: RawPoint?
    /// Points and events from `lastComplete.end` (inclusive) on, oldest first.
    var points: [RawPoint]
    var events: [RecorderEvent]
    /// The newest Motion & Fitness reading before the cursor, still in force at its first point.
    var activityBeforeCursor: RecorderEvent?
    /// The newest Low Power Mode change before the cursor, for gaps that start in it (F6).
    var lowPowerBeforeCursor: RecorderEvent?
    /// User overrides that lie at least half after the cursor, so only new segments can match them.
    var overrides: [SegmentOverride]
    /// The points of `lastComplete` before the cursor when it is a stay, for drawing the way out of
    /// it (D52).
    var lastStayPoints: [RawPoint] = []
  }

  func segmentationInput() async throws -> SegmentationInput {
    try await pool.read { db in
      let lastComplete = try Segment
        .filter(Segment.Columns.isComplete == true)
        .order(Segment.Columns.end.desc, Segment.Columns.id.desc)
        .fetchOne(db)
      let cursor = lastComplete?.end ?? .distantPast
      let cursorMilliseconds = RawPoint.milliseconds(cursor)
      let before = try Self.visible(RawPoint.filter(RawPoint.Columns.timestamp < cursorMilliseconds))
        .order(RawPoint.Columns.timestamp.desc, RawPoint.Columns.id.desc)
        .fetchOne(db)
      let points = try Self.points(db, in: cursor..<Date.distantFuture)
      let events = try RecorderEvent
        .filter(RecorderEvent.Columns.timestamp >= cursorMilliseconds)
        .order(RecorderEvent.Columns.timestamp, RecorderEvent.Columns.id)
        .fetchAll(db)
      let activity = try RecorderEvent
        .filter(RecorderEvent.Columns.kind == RecorderEvent.Kind.motionActivity && RecorderEvent.Columns.timestamp < cursorMilliseconds)
        .order(RecorderEvent.Columns.timestamp.desc, RecorderEvent.Columns.id.desc)
        .fetchOne(db)
      let lowPower = try RecorderEvent
        .filter([RecorderEvent.Kind.lowPowerModeOn, .lowPowerModeOff].contains(RecorderEvent.Columns.kind) && RecorderEvent.Columns.timestamp < cursorMilliseconds)
        .order(RecorderEvent.Columns.timestamp.desc, RecorderEvent.Columns.id.desc)
        .fetchOne(db)
      let overrides = try SegmentOverride
        .filter(SegmentOverride.Columns.endTime > cursorMilliseconds)
        .order(SegmentOverride.Columns.createdAt, SegmentOverride.Columns.id)
        .fetchAll(db)
        .filter { $0.endTime.timeIntervalSince(cursor) >= $0.endTime.timeIntervalSince($0.startTime) * SegmentOverride.minimumOverlapShare }
      let lastStayPoints = try lastComplete.map { $0.kind == .stay ? try Self.points(db, in: $0.start..<cursor) : [] } ?? []
      return SegmentationInput(
        lastComplete: lastComplete, pointBeforeCursor: before, points: points, events: events,
        activityBeforeCursor: activity, lowPowerBeforeCursor: lowPower, overrides: overrides, lastStayPoints: lastStayPoints)
    }
  }

  /// Replaces the still-growing segment(s) with `segments`: the ones that completed since the last
  /// run and the new open one.
  /// `renderLevels[i]` are the simplification levels of `segments[i]` (completed moves only).
  func replaceOpenSegments(with segments: [Segment], renderLevels: [Int: [[RenderCache.Coordinate]]] = [:]) async throws {
    try await pool.write { db in try Self.replaceOpenSegments(db, with: segments, renderLevels: renderLevels) }
  }

  /// The same, for segments made from `input`: writes nothing and returns false when the newest
  /// completed segment is no longer `input.lastComplete`, because all data was deleted while the
  /// run worked (D55 ②) or another run stored first. The caller reads again.
  func replaceOpenSegments(
    madeFrom input: SegmentationInput, with segments: [Segment], renderLevels: [Int: [[RenderCache.Coordinate]]]
  ) async throws -> Bool {
    try await pool.write { db in
      let lastComplete = try Int64.fetchOne(
        db, sql: "SELECT id FROM segments WHERE isComplete = 1 ORDER BY \"end\" DESC, id DESC LIMIT 1")
      guard lastComplete == input.lastComplete?.id else { return false }
      try Self.replaceOpenSegments(db, with: segments, renderLevels: renderLevels)
      return true
    }
  }

  private static func replaceOpenSegments(
    _ db: Database, with segments: [Segment], renderLevels: [Int: [[RenderCache.Coordinate]]]
  ) throws {
    try Segment.filter(Segment.Columns.isComplete == false).deleteAll(db)
    for (index, var segment) in segments.enumerated() {
      if segment.kind == .stay, let latitude = segment.centerLatitude, let longitude = segment.centerLongitude {
        segment.placeID = try Self.placeID(db, latitude: latitude, longitude: longitude, createdAt: segment.start)
      }
      try segment.insert(db)
      guard let levels = renderLevels[index], let segmentID = segment.id else { continue }
      for (level, coordinates) in levels.enumerated() {
        try RenderCacheEntry(segmentID: segmentID, level: level, coordinates: coordinates).insert(db)
      }
      if let finest = levels.first { try TrackBounds(segmentID: segmentID, finest: finest)?.insert(db) }
    }
  }

  /// The place for a stay centred here (F5): the nearest one within `Place.matchRadius`, otherwise a
  /// new one waiting for its name.
  private static func placeID(_ db: Database, latitude: Double, longitude: Double, createdAt: Date) throws -> Int64? {
    // A latitude band of the match radius narrows the candidates; `nearest` measures exactly.
    let band = Place.matchRadius / 111_000 * RawPoint.coordinateScale
    let scaled = Double(RawPoint.scaled(latitude))
    let candidates = try Place
      .filter(Place.Columns.latitude >= Int64(scaled - band) && Place.Columns.latitude <= Int64(scaled + band))
      .fetchAll(db)
    if let place = Place.nearest(to: latitude, longitude, in: candidates) { return place.id }
    var place = Place(
      id: nil, latitude: latitude, longitude: longitude, name: nil, address: nil, status: .pending, attempts: 0,
      lastAttemptAt: nil, nextAttemptAt: nil, userName: nil, createdAt: createdAt)
    try place.insert(db)
    return place.id
  }

  /// Places whose name is due to be looked up at `now`: new ones, then failed ones whose retry time
  /// has come, oldest first.
  func placesToResolve(at now: Date, limit: Int) async throws -> [Place] {
    try await pool.read { db in
      try Place
        .filter(
          Place.Columns.status == Place.Status.pending
            || (Place.Columns.status == Place.Status.failed && Place.Columns.nextAttemptAt <= RawPoint.milliseconds(now))
            || (Place.Columns.status == Place.Status.resolved
              && (Place.Columns.countryStatus == Place.Status.pending
                || (Place.Columns.countryStatus == Place.Status.failed
                  && Place.Columns.nextAttemptAt <= RawPoint.milliseconds(now)))))
        .order(Place.Columns.createdAt, Place.Columns.id)
        .limit(limit)
        .fetchAll(db)
    }
  }

  /// Stores a lookup result or failure. Leaves the user's name as it is in the database, in case
  /// the user renamed the place while the lookup ran.
  func saveLookup(of place: Place) async throws {
    guard let id = place.id else { throw DatabaseError(message: "place has no ID") }
    try await pool.write { db in
      _ = try Place.filter(Place.Columns.id == id).updateAll(
        db,
        Place.Columns.name.set(to: place.name),
        Place.Columns.address.set(to: place.address),
        Place.Columns.status.set(to: place.status),
        Place.Columns.attempts.set(to: place.attempts),
        Place.Columns.lastAttemptAt.set(to: place.lastAttemptAt.map(RawPoint.milliseconds)),
        Place.Columns.nextAttemptAt.set(to: place.nextAttemptAt.map(RawPoint.milliseconds)),
        Place.Columns.countryCode.set(to: place.countryCode),
        Place.Columns.countryStatus.set(to: place.countryStatus))
    }
  }

  /// The user names a place (F5); nil or blank goes back to the looked-up name. Applies to every
  /// visit of the place (D37).
  func renamePlace(id: Int64, to name: String?) async throws {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed?.isEmpty == false ? trimmed : nil
    try await pool.write { db in
      _ = try Place.filter(Place.Columns.id == id).updateAll(db, Place.Columns.userName.set(to: value))
    }
  }

  /// The places of one local day's stays, by ID, re-emitted after every change.
  func observePlaces(on day: LocalDay) -> AsyncValueObservation<[Int64: Place]> {
    ValueObservation
      .tracking { db in
        let places = try Place.fetchAll(
          db,
          sql: "SELECT * FROM places WHERE id IN (SELECT placeID FROM segments WHERE localDay = ? AND placeID IS NOT NULL)",
          arguments: [day.description])
        return Dictionary(uniqueKeysWithValues: places.compactMap { place in place.id.map { ($0, place) } })
      }
      .values(in: pool)
  }

  /// Emits now, when a place starts waiting for its name, and after every raw append (the clock
  /// for retries: points arrive at least every heartbeat, D28).
  func observePlaceWork() -> AsyncValueObservation<PlaceWorkMarker> {
    ValueObservation
      .tracking { db in
        PlaceWorkMarker(
          pendingPlaceIDs: try Int64.fetchAll(
            db, sql: "SELECT id FROM places WHERE status = 'pending' OR countryStatus = 'pending' ORDER BY id"),
          lastPointID: try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM raw_points"),
          lastEventID: try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM recorder_events"))
      }
      .removeDuplicates()
      .values(in: pool)
  }

  struct PlaceWorkMarker: Equatable, Sendable {
    var pendingPlaceIDs: [Int64]
    var lastPointID: Int64?
    var lastEventID: Int64?
  }

  /// The user picked `mode` for a move (F4): saves the override by time range and shows it at once.
  /// Processing re-applies it whenever the segments are rebuilt.
  func setTransportMode(_ mode: TransportMode, for segment: Segment, at now: Date = .now) async throws {
    guard let segmentID = segment.id else { throw DatabaseError(message: "segment has no ID") }
    try await pool.write { db in
      var override = SegmentOverride(
        id: nil, startTime: segment.start, endTime: segment.end, field: .transportMode, value: mode.rawValue, createdAt: now)
      try override.insert(db)
      try Segment.filter(Segment.Columns.id == segmentID)
        .updateAll(db, Segment.Columns.userTransportMode.set(to: mode))
    }
  }

  /// The render cache of one local day's completed moves: segment ID → levels, finest first.
  func observeRenderCache(on day: LocalDay) -> AsyncValueObservation<[Int64: [[RenderCache.Coordinate]]]> {
    ValueObservation
      .tracking { db in
        let entries = try RenderCacheEntry
          .fetchAll(db, sql: """
            SELECT render_cache.* FROM render_cache
            JOIN segments ON segments.id = render_cache.segmentID
            WHERE segments.localDay = ?
            ORDER BY render_cache.segmentID, render_cache.level
            """, arguments: [day.description])
        return Dictionary(grouping: entries, by: \.segmentID).mapValues { $0.map(\.coordinates) }
      }
      .values(in: pool)
  }

  /// The box around every completed move's track (the overview's first frame, D44), and around
  /// Fog of World's explored areas when they are shown (D54 ⑧); nil before there is anything.
  /// Re-emitted when moves complete.
  func observeOverviewBounds(includingFogOfWorld: Bool) -> AsyncValueObservation<GeoBox?> {
    ValueObservation
      .tracking { db -> GeoBox? in
        let fog = includingFogOfWorld ? try Self.fogOfWorldBounds(db) : nil
        guard
          let row = try Row.fetchOne(
            db, sql: """
              SELECT MIN(minLatitude), MAX(maxLatitude), MIN(minLongitude), MAX(maxLongitude) FROM track_bounds
              """),
          let minLatitude = row[0] as Int64?, let maxLatitude = row[1] as Int64?,
          let minLongitude = row[2] as Int64?, let maxLongitude = row[3] as Int64?
        else { return fog }
        let degrees = { (value: Int64) in Double(value) / RawPoint.coordinateScale }
        let tracks = GeoBox(
          latitudes: degrees(minLatitude)...degrees(maxLatitude), longitudes: [degrees(minLongitude)...degrees(maxLongitude)])
        guard let fog, let fogLongitudes = fog.longitudes.first, let trackLongitudes = tracks.longitudes.first else { return tracks }
        return GeoBox(
          latitudes: min(fog.latitudes.lowerBound, tracks.latitudes.lowerBound)...max(fog.latitudes.upperBound, tracks.latitudes.upperBound),
          longitudes: [min(fogLongitudes.lowerBound, trackLongitudes.lowerBound)...max(fogLongitudes.upperBound, trackLongitudes.upperBound)])
      }
      .removeDuplicates()
      .values(in: pool)
  }

  /// The overview's tracks (D44): every completed move whose box meets `box`, at one render-cache
  /// level, by segment ID. Re-emitted when moves complete.
  func observeOverviewTracks(in box: GeoBox, level: Int) -> AsyncValueObservation<[Int64: [RenderCache.Coordinate]]> {
    let longitudes = box.longitudes.map { _ in "(track_bounds.maxLongitude >= ? AND track_bounds.minLongitude <= ?)" }
    let bounds = [box.latitudes] + box.longitudes
    let arguments = StatementArguments(
      [Int64(level)] + bounds.flatMap { [RawPoint.scaled($0.lowerBound), RawPoint.scaled($0.upperBound)] })
    let sql = """
      SELECT render_cache.* FROM track_bounds
      JOIN render_cache ON render_cache.segmentID = track_bounds.segmentID AND render_cache.level = ?
      WHERE track_bounds.maxLatitude >= ? AND track_bounds.minLatitude <= ?
      AND (\(longitudes.isEmpty ? "0" : longitudes.joined(separator: " OR ")))
      """
    return ValueObservation
      .tracking { db in
        let entries = try RenderCacheEntry.fetchAll(db, sql: sql, arguments: arguments)
        return Dictionary(entries.map { ($0.segmentID, $0.coordinates) }, uniquingKeysWith: { first, _ in first })
      }
      .values(in: pool)
  }

  /// Drops every segment made by another pipeline version; they are rebuilt from the raw layer.
  /// Returns how many were dropped.
  @discardableResult
  func deleteSegments(otherThan version: Int) async throws -> Int {
    try await pool.write { db in
      try Segment.filter(Segment.Columns.pipelineVersion != version).deleteAll(db)
    }
  }

  /// The segments of one local day, oldest first, re-emitted after every change.
  func observeSegments(on day: LocalDay) -> AsyncValueObservation<[Segment]> {
    ValueObservation
      .tracking { db in
        try Segment
          .filter(Segment.Columns.localDay == day.description)
          .order(Segment.Columns.start, Segment.Columns.id)
          .fetchAll(db)
      }
      .values(in: pool)
  }

  /// The local days with at least one stay or move, for the calendar (F8). Read from the
  /// segments' day index instead of a summary table (VS7, D43); one year is a few thousand rows.
  func observeRecordedDays() -> AsyncValueObservation<Set<LocalDay>> {
    ValueObservation
      .tracking { db in
        let days = try String.fetchAll(
          db, sql: "SELECT DISTINCT localDay FROM segments WHERE kind IN (?, ?)",
          arguments: [Segment.Kind.stay.rawValue, Segment.Kind.move.rawValue])
        return Set(days.compactMap(LocalDay.init(string:)))
      }
      .removeDuplicates()
      .values(in: pool)
  }

  /// What the overview's statistics are computed from (D50), re-emitted when segments or places
  /// change. Points are read only for the ends of travelled gaps and are not observed, so new
  /// points alone do not recompute it.
  func observeStatisticsInput() -> AsyncValueObservation<TravelStatistics.Input> {
    ValueObservation
      .tracking(region: Segment.all(), Place.all()) { db in try Self.statisticsInput(db) }
      .removeDuplicates()
      .values(in: pool)
  }

  private static func statisticsInput(_ db: Database) throws -> TravelStatistics.Input {
    let segments = try Segment
      .order(Segment.Columns.start, Segment.Columns.id)
      .fetchAll(db)
      .filter { $0.kind != .gap || $0.gapTravelMode != nil }
    var gapDistances: [Int64: Double] = [:]
    for gap in segments where gap.kind == .gap {
      guard let id = gap.id,
        let entry = try Self.usablePoint(db, before: gap.start),
        let exit = try Self.usablePoint(db, after: gap.end)
      else { continue }
      gapDistances[id] = MotionStateMachine.distance(
        from: (entry.latitude, entry.longitude), to: (exit.latitude, exit.longitude))
    }
    let countries = try Row.fetchAll(
      db, sql: "SELECT id, countryCode FROM places WHERE countryCode IS NOT NULL")
    let awaiting = try Int.fetchOne(
      db, sql: "SELECT COUNT(*) FROM places WHERE countryStatus != ?",
      arguments: [Place.Status.resolved.rawValue]) ?? 0
    return TravelStatistics.Input(
      segments: segments,
      countryOfPlace: Dictionary(uniqueKeysWithValues: countries.map { ($0["id"], $0["countryCode"]) }),
      gapDistances: gapDistances,
      placesAwaitingCountry: awaiting)
  }

  /// The newest recorded (not replayed) point at or before `instant`, as the gap explainer uses
  /// for a gap's entry (`TrackProcessor`).
  private static func usablePoint(_ db: Database, before instant: Date) throws -> RawPoint? {
    try visible(RawPoint.filter(RawPoint.Columns.timestamp <= RawPoint.milliseconds(instant)))
      .filter(sql: "(flags & ?) = 0", arguments: [RawPoint.Flags.replayed.rawValue])
      .order(RawPoint.Columns.timestamp.desc, RawPoint.Columns.id.desc)
      .fetchOne(db)
  }

  /// The oldest recorded (not replayed) point at or after `instant`, a gap's exit.
  private static func usablePoint(_ db: Database, after instant: Date) throws -> RawPoint? {
    try visible(RawPoint.filter(RawPoint.Columns.timestamp >= RawPoint.milliseconds(instant)))
      .filter(sql: "(flags & ?) = 0", arguments: [RawPoint.Flags.replayed.rawValue])
      .order(RawPoint.Columns.timestamp, RawPoint.Columns.id)
      .fetchOne(db)
  }

  /// Emits once now and again whenever a point or an event has been appended.
  func observeRawAppends() -> AsyncValueObservation<RawAppendMarker> {
    ValueObservation
      .tracking { db in
        RawAppendMarker(
          lastPointID: try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM raw_points"),
          lastEventID: try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM recorder_events"))
      }
      .removeDuplicates()
      .values(in: pool)
  }

  struct RawAppendMarker: Equatable, Sendable {
    var lastPointID: Int64?
    var lastEventID: Int64?
  }

  private static func points(_ db: Database, in range: Range<Date>) throws -> [RawPoint] {
    let lower = RawPoint.milliseconds(range.lowerBound)
    let upper = RawPoint.milliseconds(range.upperBound)
    return try visible(RawPoint.filter(RawPoint.Columns.timestamp >= lower && RawPoint.Columns.timestamp < upper))
      .order(RawPoint.Columns.timestamp, RawPoint.Columns.id)
      .fetchAll(db)
  }

  /// F9, D53 ③: where recording and an import overlap, recording wins. An imported point within
  /// the gap interval of a recorded point is kept but takes no part in processing or display.
  private static func visible(_ request: QueryInterfaceRequest<RawPoint>) -> QueryInterfaceRequest<RawPoint> {
    let window = Int64(Segmenter.Parameters().gapInterval * 1000)
    return request.filter(
      sql: """
        (raw_points.source = ? OR NOT EXISTS (
          SELECT 1 FROM raw_points AS recorded
          WHERE recorded.source = ? AND recorded.timestamp BETWEEN raw_points.timestamp - ? AND raw_points.timestamp + ?))
        """,
      arguments: [RawPoint.Source.recorded, RawPoint.Source.recorded, window, window])
  }

  // MARK: - GPX (F9)

  struct GPXImport: Sendable, Equatable {
    /// New points written.
    var added: Int
    /// Points the database already had from an earlier import (same time and position).
    var duplicates: Int
  }

  /// Writes an import as one batch, skipping points an earlier import already wrote (F9), and
  /// drops the segments from the earliest new point on, so the processor recomputes them with the
  /// new points (ARCHITECTURE §5.3, §5.4). `points` must be oldest first.
  func importGPX(_ points: [RawPoint]) async throws -> GPXImport {
    try await pool.write { db in
      let batch = (try Int64.fetchOne(db, sql: "SELECT MAX(importBatchID) FROM raw_points") ?? 0) + 1
      var added: [Date] = []
      for var point in points {
        let exists = try RawPoint
          .filter(RawPoint.Columns.source == RawPoint.Source.gpxImport)
          .filter(RawPoint.Columns.timestamp == RawPoint.milliseconds(point.timestamp))
          .filter(RawPoint.Columns.latitude == RawPoint.scaled(point.latitude))
          .filter(RawPoint.Columns.longitude == RawPoint.scaled(point.longitude))
          .isEmpty(db) == false
        guard !exists else { continue }
        point.source = .gpxImport
        point.importBatchID = batch
        try point.insert(db)
        added.append(point.timestamp)
      }
      if let earliest = added.min() {
        try Segment.filter(Segment.Columns.end >= RawPoint.milliseconds(earliest)).deleteAll(db)
      }
      return GPXImport(added: added.count, duplicates: points.count - added.count)
    }
  }

  /// D53 ②: the points of the local days `days` as the map shows them: visible (recording wins
  /// over imports), not replayed, within the decision accuracy. Oldest first.
  func exportPoints(on days: ClosedRange<LocalDay>) async throws -> [RawPoint] {
    let maximumAccuracy = Segmenter.Parameters().maximumDecisionAccuracy
    return try await pool.read { db in
      try Self.points(db, in: days.lowerBound.possibleInstants.lowerBound..<days.upperBound.possibleInstants.upperBound)
        .filter {
          !$0.flags.contains(.replayed) && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maximumAccuracy
            && days.contains(LocalDay($0.timestamp, timeZoneID: $0.timeZoneID))
        }
    }
  }

  /// The first and last local day with any point, for "All Records" (D53 ④); nil before the first
  /// point.
  func pointDays() async throws -> ClosedRange<LocalDay>? {
    try await pool.read { db in
      guard
        let first = try RawPoint.order(RawPoint.Columns.timestamp).fetchOne(db),
        let last = try RawPoint.order(RawPoint.Columns.timestamp.desc).fetchOne(db)
      else { return nil }
      return LocalDay(first.timestamp, timeZoneID: first.timeZoneID)...LocalDay(last.timestamp, timeZoneID: last.timeZoneID)
    }
  }

  // MARK: - Fog of World (F12, D54)

  struct FogOfWorldSummary: Equatable, Sendable {
    var importedAt: Date
    /// Explored pixels (about 10 m across), the "cells" the settings show.
    var pixelCount: Int
  }

  /// Replaces whatever an earlier import left with these blocks (D54 ⑥).
  func replaceFogOfWorld(_ blocks: [FogOfWorld.StoredBlock], importedAt: Date) async throws {
    try await pool.write { db in
      try db.execute(sql: "DELETE FROM fog_blocks")
      let insert = try db.makeStatement(sql: "INSERT INTO fog_blocks (x, y, pixels, pixelCount, length) VALUES (?, ?, ?, ?, ?)")
      for block in blocks {
        try insert.execute(arguments: [block.key.x, block.key.y, block.pixels, block.pixelCount, block.length])
      }
      try db.execute(
        sql: "INSERT OR REPLACE INTO fog_import (id, importedAt) VALUES (1, ?)", arguments: [RawPoint.milliseconds(importedAt)])
    }
  }

  /// D54 ⑦: removes the imported layer only.
  func removeFogOfWorld() async throws {
    try await pool.write { db in
      try db.execute(sql: "DELETE FROM fog_blocks")
      try db.execute(sql: "DELETE FROM fog_import")
    }
  }

  /// The imported layer, or nil when there is none.
  func observeFogOfWorld() -> AsyncValueObservation<FogOfWorldSummary?> {
    ValueObservation
      .tracking { db -> FogOfWorldSummary? in
        guard let importedAt = try Int64.fetchOne(db, sql: "SELECT importedAt FROM fog_import WHERE id = 1") else { return nil }
        let pixels = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(pixelCount), 0) FROM fog_blocks") ?? 0
        return FogOfWorldSummary(importedAt: Date(timeIntervalSince1970: Double(importedAt) / 1000), pixelCount: pixels)
      }
      .removeDuplicates()
      .values(in: pool)
  }

  /// D54 ④: the explored cells in `box` on the pixel grid coarsened by `shift` (cells are 2^shift
  /// pixels across), for drawing. Cells are read whole, so some lie a little outside the box.
  func observeFogOfWorldCells(in box: GeoBox, shift: Int) -> AsyncValueObservation<Set<FogOfWorld.Cell>> {
    Self.fogOfWorldCells(in: box, shift: shift).values(in: pool)
  }

  /// D54 ④: the lines that draw the explored cells in `box` (`FogOfWorld.lines`), in cells of
  /// 2^shift pixels. They are built off the main thread, with the read.
  func observeFogOfWorldLines(in box: GeoBox, shift: Int) -> AsyncValueObservation<[[FogOfWorld.LinePoint]]> {
    Self.fogOfWorldCells(in: box, shift: shift).map(FogOfWorld.lines(of:)).values(in: pool)
  }

  private static func fogOfWorldCells(in box: GeoBox, shift: Int) -> ValueObservation<ValueReducers.Fetch<Set<FogOfWorld.Cell>>> {
    let ranges = blockRanges(of: box)
    return ValueObservation
      .tracking { db in
        var cells = Set<FogOfWorld.Cell>()
        for range in ranges {
          let arguments: StatementArguments = [range.x.lowerBound, range.x.upperBound, range.y.lowerBound, range.y.upperBound]
          if shift >= FogOfWorld.blockShift {
            let blockShift = shift - FogOfWorld.blockShift
            let rows = try Row.fetchAll(
              db, sql: "SELECT DISTINCT x >> \(blockShift), y >> \(blockShift) FROM fog_blocks WHERE x BETWEEN ? AND ? AND y BETWEEN ? AND ?",
              arguments: arguments)
            for row in rows { cells.insert(FogOfWorld.Cell(x: row[0], y: row[1])) }
          } else {
            let rows = try Row.fetchAll(
              db, sql: "SELECT x, y, pixels FROM fog_blocks WHERE x BETWEEN ? AND ? AND y BETWEEN ? AND ?", arguments: arguments)
            for row in rows {
              let blockX: Int = row[0]
              let blockY: Int = row[1]
              for index in FogOfWorld.pixelIndices(row[2]) {
                let x = blockX * FogOfWorld.pixelsPerBlock + index % FogOfWorld.pixelsPerBlock
                let y = blockY * FogOfWorld.pixelsPerBlock + index / FogOfWorld.pixelsPerBlock
                cells.insert(FogOfWorld.Cell(x: Int32(x >> shift), y: Int32(y >> shift)))
              }
            }
          }
        }
        return cells
      }
  }

  /// The block columns and rows a box covers, one pair per longitude range.
  private static func blockRanges(of box: GeoBox) -> [(x: ClosedRange<Int>, y: ClosedRange<Int>)] {
    let last = FogOfWorld.pixelsPerSide - 1
    let block = { (pixel: Double) in min(last, max(0, Int(pixel.rounded(.down)))) >> FogOfWorld.blockShift }
    let top = block(FogOfWorld.pixel(latitude: box.latitudes.upperBound, longitude: 0).y)
    let bottom = block(FogOfWorld.pixel(latitude: box.latitudes.lowerBound, longitude: 0).y)
    return box.longitudes.map { longitudes in
      let west = block(FogOfWorld.pixel(latitude: 0, longitude: longitudes.lowerBound).x)
      let east = block(FogOfWorld.pixel(latitude: 0, longitude: longitudes.upperBound).x)
      return (west...east, top...bottom)
    }
  }

  /// The box around every explored block, or nil without an import.
  private static func fogOfWorldBounds(_ db: Database) throws -> GeoBox? {
    guard
      let row = try Row.fetchOne(db, sql: "SELECT MIN(x), MAX(x), MIN(y), MAX(y) FROM fog_blocks"),
      let west = row[0] as Int?, let east = row[1] as Int?, let north = row[2] as Int?, let south = row[3] as Int?
    else { return nil }
    let size = Double(FogOfWorld.pixelsPerBlock)
    let northWest = FogOfWorld.coordinate(x: Double(west) * size, y: Double(north) * size)
    let southEast = FogOfWorld.coordinate(x: Double(east + 1) * size, y: Double(south + 1) * size)
    return GeoBox(
      latitudes: southEast.latitude...northWest.latitude, longitudes: [northWest.longitude...southEast.longitude])
  }

  /// D54 ⑤: the estimated length of the explored areas' centre line, in metres, less the parts
  /// within about `tolerance` of Trace Notes' own completed moves; nil without an import.
  /// Re-emitted when a move completes or the import changes.
  func observeFogOfWorldDistance(tolerance: Double) -> AsyncValueObservation<Double?> {
    ValueObservation
      .tracking { db -> Double? in
        guard let total = try Double.fetchOne(db, sql: "SELECT SUM(length) FROM fog_blocks") else { return nil }
        let tracks = try RenderCacheEntry.filter(RenderCacheEntry.Columns.level == 0).fetchAll(db).map(\.coordinates)
        let own = FogOfWorld.OwnTracks(tracks: tracks, tolerance: tolerance)
        let statement = try db.cachedStatement(sql: "SELECT pixels, pixelCount, length FROM fog_blocks WHERE x = ? AND y = ?")
        var overlap = 0.0
        for key in own.reachableBlocks {
          guard let row = try Row.fetchOne(statement, arguments: [key.x, key.y]) else { continue }
          let count: Int = row[1]
          guard count > 0 else { continue }
          let length: Double = row[2]
          // The block's length shared out evenly over its pixels.
          let covered = FogOfWorld.pixelIndices(row[0]).filter { index in
            own.covers(
              pixelX: Int(key.x) * FogOfWorld.pixelsPerBlock + index % FogOfWorld.pixelsPerBlock,
              y: Int(key.y) * FogOfWorld.pixelsPerBlock + index / FogOfWorld.pixelsPerBlock)
          }.count
          overlap += length * Double(covered) / Double(count)
        }
        return max(0, total - overlap)
      }
      .removeDuplicates()
      .values(in: pool)
  }

  // MARK: - Delete all data (F10, D55 ②)

  private static let rawTables = [RawPoint.databaseTableName, RecorderEvent.databaseTableName]

  private static func appendOnlyTrigger(on table: String, refusing operation: String) -> String {
    """
    CREATE TRIGGER \(table)_no_\(operation.lowercased()) BEFORE \(operation) ON \(table)
    BEGIN SELECT RAISE(ABORT, '\(table) is append-only'); END
    """
  }

  /// Empties every table: raw points and events, the derived layer, the user's corrections and
  /// names, Fog of World and the MetricKit reports. The raw layer's delete guard is lifted for this
  /// one transaction only (P5's single exception). Rows are deleted in one transaction instead of
  /// replacing the file, so the recording engine's writer and every observation keep their
  /// connections and recording goes on into the empty tables (D55 ③). IDs are never reused
  /// (AUTOINCREMENT), so a place lookup that started before writes nowhere, and a processing run
  /// that started before is refused (`replaceOpenSegments(madeFrom:…)`). VACUUM and a checkpoint
  /// then rewrite the files without the freed pages.
  func deleteAllData() async throws {
    try await pool.write { db in
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'")
      for table in Self.rawTables { try db.execute(sql: "DROP TRIGGER \(table)_no_delete") }
      for table in tables { try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)") }
      for table in Self.rawTables { try db.execute(sql: Self.appendOnlyTrigger(on: table, refusing: "DELETE")) }
    }
    try await pool.vacuum()
    do {
      _ = try await pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
      // A reader holds the log; SQLite's automatic checkpoints copy the vacuumed pages later.
      AppLog.storage.notice("checkpoint after deleting all data deferred: a reader is busy")
    }
  }

  /// What deleting all data removes (D55 ④): recorded days and distance as the statistics count
  /// them, and whether Fog of World data is stored.
  struct DataSummary: Equatable, Sendable {
    var days: Int
    var metres: Double
    var hasFogOfWorld: Bool
  }

  func observeDataSummary() -> AsyncValueObservation<DataSummary> {
    ValueObservation
      .tracking { db in
        let input = try Self.statisticsInput(db)
        let statistics = TravelStatistics(input, year: nil)
        let hasFog = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM fog_import)") ?? false
        return DataSummary(days: statistics.recordedDays, metres: statistics.distance, hasFogOfWorld: hasFog)
      }
      .removeDuplicates()
      .values(in: pool)
  }

  // MARK: - Diagnostics (D55 ⑤)

  /// Stores a MetricKit report and drops those older than `MetricReport.retention`.
  func saveMetricReport(_ report: MetricReport) async throws {
    try await pool.write { db in
      var report = report
      try report.insert(db)
      try db.execute(
        sql: "DELETE FROM metric_reports WHERE receivedAt < ?",
        arguments: [RawPoint.milliseconds(report.receivedAt.addingTimeInterval(-MetricReport.retention))])
    }
  }

  /// What the diagnostic report is made of, since `start`. Segments come with coordinates, which
  /// the report leaves out (`DiagnosticReport`).
  struct DiagnosticsInput: Sendable {
    var events: [RecorderEvent]
    var segments: [Segment]
    var metricReports: [MetricReport]
  }

  func diagnosticsInput(since start: Date) async throws -> DiagnosticsInput {
    let milliseconds = RawPoint.milliseconds(start)
    return try await pool.read { db in
      DiagnosticsInput(
        events: try RecorderEvent
          .filter(RecorderEvent.Columns.timestamp >= milliseconds)
          .order(RecorderEvent.Columns.timestamp, RecorderEvent.Columns.id)
          .fetchAll(db),
        segments: try Segment
          .filter(Segment.Columns.end >= milliseconds)
          .order(Segment.Columns.start, Segment.Columns.id)
          .fetchAll(db),
        metricReports: try MetricReport
          .filter(MetricReport.Columns.receivedAt >= milliseconds)
          .order(MetricReport.Columns.receivedAt, MetricReport.Columns.id)
          .fetchAll(db))
    }
  }
}
