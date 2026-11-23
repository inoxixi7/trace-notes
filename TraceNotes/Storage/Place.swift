import Foundation
import GRDB

/// A place where the user stayed (ARCHITECTURE §2.3, F5). Stays within `matchRadius` of a place's
/// centre share it, so its name is looked up once and a name the user gives it shows on every
/// visit (D37). Processing never deletes places: they hold the user's names.
nonisolated struct Place: Equatable, Sendable {
  var id: Int64?
  /// WGS-84 centre of the stay that created the place.
  var latitude: Double
  var longitude: Double
  /// Nearest point of interest, or nil when the lookup found only an address.
  var name: String?
  var address: String?
  var status: Status
  var attempts: Int
  var lastAttemptAt: Date?
  /// When a failed lookup is retried.
  var nextAttemptAt: Date?
  /// The user's name; wins over the looked-up one (F5).
  var userName: String?
  var createdAt: Date
  /// ISO 3166 region code from reverse geocoding (D50); nil until looked up, or where the lookup
  /// names no region (open sea).
  var countryCode: String? = nil
  /// Places named before the statistics slice still need their region: they are looked up again
  /// for it alone, without touching their names (D50).
  var countryStatus: Status = .pending

  enum Status: String, Sendable, DatabaseValueConvertible {
    case pending
    case resolved
    case failed
  }

  /// A stay belongs to a place whose centre is this close to its own (the S3 dwell radius).
  static let matchRadius = 50.0

  /// Waits before the 1st, 2nd, … retry of a failed lookup; the last one repeats.
  static let retryDelays: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60, 6 * 60 * 60]
}

nonisolated extension Place: FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "places"

  enum Columns {
    static let id = Column("id")
    static let latitude = Column("latitude")
    static let longitude = Column("longitude")
    static let name = Column("name")
    static let address = Column("address")
    static let status = Column("status")
    static let attempts = Column("attempts")
    static let lastAttemptAt = Column("lastAttemptAt")
    static let nextAttemptAt = Column("nextAttemptAt")
    static let userName = Column("userName")
    static let createdAt = Column("createdAt")
    static let countryCode = Column("countryCode")
    static let countryStatus = Column("countryStatus")
  }

  init(row: Row) throws {
    id = row[Columns.id]
    latitude = Double(row[Columns.latitude] as Int64) / RawPoint.coordinateScale
    longitude = Double(row[Columns.longitude] as Int64) / RawPoint.coordinateScale
    name = row[Columns.name]
    address = row[Columns.address]
    status = row[Columns.status]
    attempts = row[Columns.attempts]
    lastAttemptAt = (row[Columns.lastAttemptAt] as Int64?).map(RawPoint.date(milliseconds:))
    nextAttemptAt = (row[Columns.nextAttemptAt] as Int64?).map(RawPoint.date(milliseconds:))
    userName = row[Columns.userName]
    createdAt = RawPoint.date(milliseconds: row[Columns.createdAt])
    countryCode = row[Columns.countryCode]
    countryStatus = row[Columns.countryStatus]
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.id] = id
    container[Columns.latitude] = RawPoint.scaled(latitude)
    container[Columns.longitude] = RawPoint.scaled(longitude)
    container[Columns.name] = name
    container[Columns.address] = address
    container[Columns.status] = status
    container[Columns.attempts] = attempts
    container[Columns.lastAttemptAt] = lastAttemptAt.map(RawPoint.milliseconds)
    container[Columns.nextAttemptAt] = nextAttemptAt.map(RawPoint.milliseconds)
    container[Columns.userName] = userName
    container[Columns.createdAt] = RawPoint.milliseconds(createdAt)
    container[Columns.countryCode] = countryCode
    container[Columns.countryStatus] = countryStatus
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

nonisolated extension Place {
  /// The place among `places` nearest to the coordinate, if within `matchRadius`.
  static func nearest(to latitude: Double, _ longitude: Double, in places: [Place]) -> Place? {
    places
      .map { ($0, MotionStateMachine.distance(from: ($0.latitude, $0.longitude), to: (latitude, longitude))) }
      .filter { $0.1 <= matchRadius }
      .min { $0.1 < $1.1 }?.0
  }

  /// The state after a failed lookup at `now`. A place that already has its name keeps it and
  /// waits only for its region.
  mutating func recordFailure(at now: Date) {
    if status == .resolved {
      countryStatus = .failed
    } else {
      status = .failed
    }
    attempts += 1
    lastAttemptAt = now
    nextAttemptAt = now.addingTimeInterval(Self.retryDelays[min(attempts, Self.retryDelays.count) - 1])
  }

  /// Whether the next lookup is only for the region (the name is already resolved).
  var needsCountryOnly: Bool {
    status == .resolved && countryStatus != .resolved
  }
}

nonisolated extension Place {
  /// What the timeline shows (F5): the user's name, the nearby point of interest, else the address.
  /// Nil while the lookup is due or after it failed ("unknown place").
  var displayName: String? {
    userName ?? name ?? address
  }
}
