import Foundation
import GRDB

/// A MetricKit report as the system delivered it (D55 ⑤), kept on the phone for the diagnostic
/// report the user may share. MetricKit's JSON has no locations.
nonisolated struct MetricReport: Equatable, Sendable {
  var id: Int64?
  var receivedAt: Date
  var kind: Kind
  var json: String

  enum Kind: String, Sendable, DatabaseValueConvertible {
    /// Crashes, hangs, CPU and disk exceptions (`MXDiagnosticPayload`).
    case diagnostics
    /// A day's usage: energy, location activity, launches (`MXMetricPayload`).
    case metrics
  }

  /// Reports are kept for the same 30 days the diagnostic report covers.
  static let retention: TimeInterval = DiagnosticReport.period
}

nonisolated extension MetricReport: FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "metric_reports"

  enum Columns {
    static let id = Column("id")
    static let receivedAt = Column("receivedAt")
    static let kind = Column("kind")
    static let json = Column("json")
  }

  init(row: Row) throws {
    id = row[Columns.id]
    receivedAt = RawPoint.date(milliseconds: row[Columns.receivedAt])
    kind = row[Columns.kind]
    json = row[Columns.json]
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.id] = id
    container[Columns.receivedAt] = RawPoint.milliseconds(receivedAt)
    container[Columns.kind] = kind
    container[Columns.json] = json
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
