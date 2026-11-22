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
      return SegmentationInput(lastComplete: lastComplete, pointBeforeCursor: before, points: points, events: events)
    }
  }

  /// Replaces the still-growing segment(s) with `segments`: the ones that completed since the last
  /// run and the new open one.
  func replaceOpenSegments(with segments: [Segment]) async throws {
    try await pool.write { db in
      try Segment.filter(Segment.Columns.isComplete == false).deleteAll(db)
      for var segment in segments { try segment.insert(db) }
    }
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
