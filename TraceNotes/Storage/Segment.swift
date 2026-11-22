import Foundation
import GRDB

/// One piece of a day in the derived layer (ARCHITECTURE §2.3): a stay, a move, or a gap with no
/// points. Derived data is recomputable from the raw layer, so it may be replaced; raw data never.
///
/// A segment owns the raw points with `start <= timestamp <= end`; neighbouring segments share
/// their boundary point so the track stays connected.
nonisolated struct Segment: Equatable, Sendable {
  var id: Int64?
  var kind: Kind
  var start: Date
  var end: Date
  /// Zone of the segment's start; decides `localDay` and the times shown for it (F8).
  var timeZoneID: String
  var localDay: LocalDay
  /// `false` only for the newest segment, which still grows (ARCHITECTURE §5.2).
  var isComplete: Bool
  /// Cut at the end of its local day (D30); the next segment continues it.
  var continuesNextDay: Bool
  var pointCount: Int
  /// Metres along the usable points; moves only.
  var distance: Double
  /// WGS-84 centre and the largest distance of a usable point from it; stays only.
  var centerLatitude: Double?
  var centerLongitude: Double?
  var radius: Double?
  /// The pipeline that produced the row; rows of another version are recomputed (§2.3).
  var pipelineVersion: Int
  /// Moves only: the automatic mode (pipeline step ④) and the share of the move that voted for it.
  var transportMode: TransportMode? = nil
  var modeConfidence: Double? = nil
  /// Moves only: the user's choice, from the newest matching override (ARCHITECTURE §2.2).
  var userTransportMode: TransportMode? = nil

  /// Stays only: the place it belongs to (F5), assigned when the segment is stored.
  var placeID: Int64? = nil

  /// What the timeline shows: the user's choice wins (F4).
  var displayedTransportMode: TransportMode? { userTransportMode ?? transportMode }

  enum Kind: String, Sendable, DatabaseValueConvertible {
    case stay
    case move
    case gap
  }
}

nonisolated extension Segment: FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "segments"

  enum Columns {
    static let id = Column("id")
    static let kind = Column("kind")
    static let start = Column("start")
    static let end = Column("end")
    static let timeZoneID = Column("timeZoneID")
    static let localDay = Column("localDay")
    static let isComplete = Column("isComplete")
    static let continuesNextDay = Column("continuesNextDay")
    static let pointCount = Column("pointCount")
    static let distance = Column("distance")
    static let centerLatitude = Column("centerLatitude")
    static let centerLongitude = Column("centerLongitude")
    static let radius = Column("radius")
    static let pipelineVersion = Column("pipelineVersion")
    static let transportMode = Column("transportMode")
    static let modeConfidence = Column("modeConfidence")
    static let userTransportMode = Column("userTransportMode")
    static let placeID = Column("placeID")
  }

  init(row: Row) throws {
    id = row[Columns.id]
    kind = row[Columns.kind]
    start = RawPoint.date(milliseconds: row[Columns.start])
    end = RawPoint.date(milliseconds: row[Columns.end])
    timeZoneID = row[Columns.timeZoneID]
    let day: String = row[Columns.localDay]
    guard let localDay = LocalDay(string: day) else {
      throw DatabaseError(message: "segments.localDay is not yyyy-MM-dd: \(day)")
    }
    self.localDay = localDay
    isComplete = row[Columns.isComplete]
    continuesNextDay = row[Columns.continuesNextDay]
    pointCount = row[Columns.pointCount]
    distance = row[Columns.distance]
    centerLatitude = (row[Columns.centerLatitude] as Int64?).map { Double($0) / RawPoint.coordinateScale }
    centerLongitude = (row[Columns.centerLongitude] as Int64?).map { Double($0) / RawPoint.coordinateScale }
    radius = row[Columns.radius]
    pipelineVersion = row[Columns.pipelineVersion]
    transportMode = row[Columns.transportMode]
    modeConfidence = row[Columns.modeConfidence]
    userTransportMode = row[Columns.userTransportMode]
    placeID = row[Columns.placeID]
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.id] = id
    container[Columns.kind] = kind
    container[Columns.start] = RawPoint.milliseconds(start)
    container[Columns.end] = RawPoint.milliseconds(end)
    container[Columns.timeZoneID] = timeZoneID
    container[Columns.localDay] = localDay.description
    container[Columns.isComplete] = isComplete
    container[Columns.continuesNextDay] = continuesNextDay
    container[Columns.pointCount] = pointCount
    container[Columns.distance] = distance
    container[Columns.centerLatitude] = centerLatitude.map(RawPoint.scaled)
    container[Columns.centerLongitude] = centerLongitude.map(RawPoint.scaled)
    container[Columns.radius] = radius
    container[Columns.pipelineVersion] = pipelineVersion
    container[Columns.transportMode] = transportMode
    container[Columns.modeConfidence] = modeConfidence
    container[Columns.userTransportMode] = userTransportMode
    container[Columns.placeID] = placeID
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
