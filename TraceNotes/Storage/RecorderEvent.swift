import Foundation
import GRDB

/// What the recording engine itself did or saw (ARCHITECTURE §2.1), used later to explain gaps
/// (F6). Append-only like raw points. The payload never contains coordinates.
nonisolated struct RecorderEvent: Equatable, Sendable {
  var id: Int64?
  var timestamp: Date
  var kind: Kind
  /// Short `key=value` pairs, e.g. `status=always` or `activity=walking confidence=high`.
  var payload: String?

  enum Kind: String, Sendable, DatabaseValueConvertible {
    /// The process started and the user brought it to the screen.
    case launch
    /// The system started the process in the background (for a location event).
    case backgroundRelaunch
    /// Written at launch when the previous process ended without `applicationWillTerminate`.
    case terminatedDetected
    case authorizationChanged
    case locationServicesOff
    case lowPowerModeOn
    case lowPowerModeOff
    case motionActivity
    case visitArrive
    case visitDepart
    /// Hourly count of points the stationary heartbeat did not save (D28).
    case heartbeatSkipped
    /// The whole phone's battery level or power state changed (D56), e.g.
    /// `level=63 power=unplugged engine=stationary`. For the diagnostic report's drain table.
    case battery
  }
}

nonisolated extension RecorderEvent: FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "recorder_events"

  enum Columns {
    static let id = Column("id")
    static let timestamp = Column("timestamp")
    static let kind = Column("kind")
    static let payload = Column("payload")
  }

  init(row: Row) throws {
    id = row[Columns.id]
    timestamp = RawPoint.date(milliseconds: row[Columns.timestamp])
    kind = row[Columns.kind]
    payload = row[Columns.payload]
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.id] = id
    container[Columns.timestamp] = RawPoint.milliseconds(timestamp)
    container[Columns.kind] = kind
    container[Columns.payload] = payload
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
