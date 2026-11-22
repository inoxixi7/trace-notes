import Foundation
import GRDB

/// One location fix in the raw layer (ARCHITECTURE §2.1). Raw points are append-only (P5).
///
/// Stored compactly (D26, D29 step 1): the timestamp as UTC milliseconds and the coordinates as
/// degrees × 10⁷ (about 1 cm), both INTEGER. Coordinates are WGS-84 (D16).
nonisolated struct RawPoint: Equatable, Sendable {
  var id: Int64?
  var timestamp: Date
  var latitude: Double
  var longitude: Double
  /// Metres. Poor fixes are stored too and flagged `lowAccuracy` (F1).
  var horizontalAccuracy: Double
  var altitude: Double?
  var verticalAccuracy: Double?
  var speed: Double?
  var course: Double?
  /// IANA time zone where the point was recorded; decides its local day (F8).
  var timeZoneID: String
  var source: Source
  var importBatchID: Int64?
  var flags: Flags

  enum Source: String, Sendable, DatabaseValueConvertible {
    case recorded
    case gpxImport
  }

  struct Flags: OptionSet, Sendable, DatabaseValueConvertible {
    let rawValue: Int64
    /// A cached fix the system delivered again on launch with its old timestamp (S3 finding).
    /// Saved, but never used for decisions.
    static let replayed = Flags(rawValue: 1 << 0)
    /// Horizontal accuracy worse than the decision limit, or invalid.
    static let lowAccuracy = Flags(rawValue: 1 << 1)
    /// Reserved: points are not saved while paused.
    static let paused = Flags(rawValue: 1 << 2)
  }
}

// MARK: - Compact encoding

nonisolated extension RawPoint {
  static let coordinateScale = 10_000_000.0

  static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  static func date(milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  static func scaled(_ degrees: Double) -> Int64 {
    Int64((degrees * coordinateScale).rounded())
  }
}

nonisolated extension RawPoint: FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "raw_points"

  enum Columns {
    static let id = Column("id")
    static let timestamp = Column("timestamp")
    static let latitude = Column("latitude")
    static let longitude = Column("longitude")
    static let horizontalAccuracy = Column("horizontalAccuracy")
    static let altitude = Column("altitude")
    static let verticalAccuracy = Column("verticalAccuracy")
    static let speed = Column("speed")
    static let course = Column("course")
    static let timeZoneID = Column("timeZoneID")
    static let source = Column("source")
    static let importBatchID = Column("importBatchID")
    static let flags = Column("flags")
  }

  init(row: Row) throws {
    id = row[Columns.id]
    timestamp = Self.date(milliseconds: row[Columns.timestamp])
    latitude = Double(row[Columns.latitude] as Int64) / Self.coordinateScale
    longitude = Double(row[Columns.longitude] as Int64) / Self.coordinateScale
    horizontalAccuracy = row[Columns.horizontalAccuracy]
    altitude = row[Columns.altitude]
    verticalAccuracy = row[Columns.verticalAccuracy]
    speed = row[Columns.speed]
    course = row[Columns.course]
    timeZoneID = row[Columns.timeZoneID]
    source = row[Columns.source]
    importBatchID = row[Columns.importBatchID]
    flags = row[Columns.flags]
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.id] = id
    container[Columns.timestamp] = Self.milliseconds(timestamp)
    container[Columns.latitude] = Self.scaled(latitude)
    container[Columns.longitude] = Self.scaled(longitude)
    container[Columns.horizontalAccuracy] = horizontalAccuracy
    container[Columns.altitude] = altitude
    container[Columns.verticalAccuracy] = verticalAccuracy
    container[Columns.speed] = speed
    container[Columns.course] = course
    container[Columns.timeZoneID] = timeZoneID
    container[Columns.source] = source
    container[Columns.importBatchID] = importBatchID
    container[Columns.flags] = flags
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
