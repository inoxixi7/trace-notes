import Foundation
import GRDB

/// A user correction (ARCHITECTURE §2.2), kept by time range rather than segment ID so it survives
/// recomputation: it applies to the new segment it overlaps most, if that is at least half of its
/// range. Never deleted by processing.
nonisolated struct SegmentOverride: Equatable, Sendable {
  var id: Int64?
  var startTime: Date
  var endTime: Date
  var field: Field
  var value: String
  var createdAt: Date

  enum Field: String, Sendable, DatabaseValueConvertible {
    case transportMode
    /// VS5.
    case placeName
  }
}

nonisolated extension SegmentOverride: FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "segment_overrides"

  enum Columns {
    static let id = Column("id")
    static let startTime = Column("startTime")
    static let endTime = Column("endTime")
    static let field = Column("field")
    static let value = Column("value")
    static let createdAt = Column("createdAt")
  }

  init(row: Row) throws {
    id = row[Columns.id]
    startTime = RawPoint.date(milliseconds: row[Columns.startTime])
    endTime = RawPoint.date(milliseconds: row[Columns.endTime])
    field = row[Columns.field]
    value = row[Columns.value]
    createdAt = RawPoint.date(milliseconds: row[Columns.createdAt])
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.id] = id
    container[Columns.startTime] = RawPoint.milliseconds(startTime)
    container[Columns.endTime] = RawPoint.milliseconds(endTime)
    container[Columns.field] = field
    container[Columns.value] = value
    container[Columns.createdAt] = RawPoint.milliseconds(createdAt)
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

nonisolated extension SegmentOverride {
  /// An override applies only where it covers a segment for at least this share of its range (§2.2).
  static let minimumOverlapShare = 0.5

  /// Sets `userTransportMode` on the moves and gaps these transport-mode overrides match (a gap's
  /// mode is how it was travelled, D42), in creation order so the newest wins. Returns how many
  /// overrides matched nothing (overlap under half).
  static func applyTransportModes(_ overrides: [SegmentOverride], to segments: inout [Segment]) -> Int {
    var unmatched = 0
    for override in overrides.sorted(by: { $0.createdAt < $1.createdAt }) where override.field == .transportMode {
      guard let mode = TransportMode(rawValue: override.value) else {
        unmatched += 1
        continue
      }
      let length = override.endTime.timeIntervalSince(override.startTime)
      let best = segments.indices
        .filter { segments[$0].kind != .stay }
        .map { index -> (index: Int, overlap: TimeInterval) in
          let overlap = min(segments[index].end, override.endTime).timeIntervalSince(max(segments[index].start, override.startTime))
          return (index, overlap)
        }
        .max { $0.overlap < $1.overlap }
      guard let best, length > 0, best.overlap / length >= minimumOverlapShare else {
        unmatched += 1
        continue
      }
      segments[best.index].userTransportMode = mode
    }
    return unmatched
  }
}
