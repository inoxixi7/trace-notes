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

  private static func points(_ db: Database, in range: Range<Date>) throws -> [RawPoint] {
    let lower = RawPoint.milliseconds(range.lowerBound)
    let upper = RawPoint.milliseconds(range.upperBound)
    return try RawPoint
      .filter(RawPoint.Columns.timestamp >= lower && RawPoint.Columns.timestamp < upper)
      .order(RawPoint.Columns.timestamp, RawPoint.Columns.id)
      .fetchAll(db)
  }
}
