import Foundation
import GRDB

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

      // The raw layer is append-only (P5). "Delete all data" removes the database file instead.
      for table in [RawPoint.databaseTableName, RecorderEvent.databaseTableName] {
        for operation in ["UPDATE", "DELETE"] {
          try db.execute(
            sql: """
              CREATE TRIGGER \(table)_no_\(operation.lowercased()) BEFORE \(operation) ON \(table)
              BEGIN SELECT RAISE(ABORT, '\(table) is append-only'); END
              """)
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

  /// The newest timestamp of any point or event, i.e. the last sign of life of the recorder.
  func lastActivity() async throws -> Date? {
    try await pool.read { db in
      let point = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM raw_points")
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
      let before = try RawPoint
        .filter(RawPoint.Columns.timestamp < cursorMilliseconds)
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
    try await pool.write { db in
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

  /// The box around every completed move's track (the overview's first frame, D44); nil before the
  /// first move completes. Re-emitted when moves complete.
  func observeOverviewBounds() -> AsyncValueObservation<GeoBox?> {
    ValueObservation
      .tracking { db -> GeoBox? in
        guard
          let row = try Row.fetchOne(
            db, sql: """
              SELECT MIN(minLatitude), MAX(maxLatitude), MIN(minLongitude), MAX(maxLongitude) FROM track_bounds
              """),
          let minLatitude = row[0] as Int64?, let maxLatitude = row[1] as Int64?,
          let minLongitude = row[2] as Int64?, let maxLongitude = row[3] as Int64?
        else { return nil }
        let degrees = { (value: Int64) in Double(value) / RawPoint.coordinateScale }
        return GeoBox(
          latitudes: degrees(minLatitude)...degrees(maxLatitude), longitudes: [degrees(minLongitude)...degrees(maxLongitude)])
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
      .tracking(region: Segment.all(), Place.all()) { db in
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
      .removeDuplicates()
      .values(in: pool)
  }

  /// The newest recorded (not replayed) point at or before `instant`, as the gap explainer uses
  /// for a gap's entry (`TrackProcessor`).
  private static func usablePoint(_ db: Database, before instant: Date) throws -> RawPoint? {
    try RawPoint
      .filter(RawPoint.Columns.timestamp <= RawPoint.milliseconds(instant))
      .filter(sql: "(flags & ?) = 0", arguments: [RawPoint.Flags.replayed.rawValue])
      .order(RawPoint.Columns.timestamp.desc, RawPoint.Columns.id.desc)
      .fetchOne(db)
  }

  /// The oldest recorded (not replayed) point at or after `instant`, a gap's exit.
  private static func usablePoint(_ db: Database, after instant: Date) throws -> RawPoint? {
    try RawPoint
      .filter(RawPoint.Columns.timestamp >= RawPoint.milliseconds(instant))
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
    return try RawPoint
      .filter(RawPoint.Columns.timestamp >= lower && RawPoint.Columns.timestamp < upper)
      .order(RawPoint.Columns.timestamp, RawPoint.Columns.id)
      .fetchAll(db)
  }
}
