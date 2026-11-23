import Foundation
import GRDB

/// A WGS-84 latitude/longitude box. A box across the antimeridian has two longitude ranges.
nonisolated struct GeoBox: Equatable, Sendable {
  var latitudes: ClosedRange<Double>
  /// One range, or two when the box crosses ±180°; each within -180...180.
  var longitudes: [ClosedRange<Double>]

  /// The box around a track, or nil for no coordinates.
  init?(enclosing coordinates: [RenderCache.Coordinate]) {
    guard let first = coordinates.first else { return nil }
    var latitudes = first.latitude...first.latitude
    var longitudes = first.longitude...first.longitude
    for coordinate in coordinates.dropFirst() {
      latitudes = min(latitudes.lowerBound, coordinate.latitude)...max(latitudes.upperBound, coordinate.latitude)
      longitudes = min(longitudes.lowerBound, coordinate.longitude)...max(longitudes.upperBound, coordinate.longitude)
    }
    self.init(latitudes: latitudes, longitudes: [longitudes])
  }

  init(latitudes: ClosedRange<Double>, longitudes: [ClosedRange<Double>]) {
    self.latitudes = latitudes
    self.longitudes = longitudes
  }
}

/// The box around one completed move's track (ARCHITECTURE §3 viewport query, D44): the overview
/// reads only the tracks that reach into the screen. Derived: deleted with its segment.
///
/// Values are WGS-84 degrees × 10⁷, as in raw points. A track across the antimeridian gets a box
/// spanning nearly all longitudes, which only makes it fetched more often.
nonisolated struct TrackBounds: Equatable, Sendable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "track_bounds"

  var segmentID: Int64
  var minLatitude: Int64
  var maxLatitude: Int64
  var minLongitude: Int64
  var maxLongitude: Int64

  enum Columns {
    static let segmentID = Column("segmentID")
    static let minLatitude = Column("minLatitude")
    static let maxLatitude = Column("maxLatitude")
    static let minLongitude = Column("minLongitude")
    static let maxLongitude = Column("maxLongitude")
  }

  /// The bounds of a track's finest level; coarser levels keep a subset of its points.
  init?(segmentID: Int64, finest coordinates: [RenderCache.Coordinate]) {
    guard let box = GeoBox(enclosing: coordinates), let longitudes = box.longitudes.first else { return nil }
    self.segmentID = segmentID
    minLatitude = RawPoint.scaled(box.latitudes.lowerBound)
    maxLatitude = RawPoint.scaled(box.latitudes.upperBound)
    minLongitude = RawPoint.scaled(longitudes.lowerBound)
    maxLongitude = RawPoint.scaled(longitudes.upperBound)
  }

  init(row: Row) throws {
    segmentID = row[Columns.segmentID]
    minLatitude = row[Columns.minLatitude]
    maxLatitude = row[Columns.maxLatitude]
    minLongitude = row[Columns.minLongitude]
    maxLongitude = row[Columns.maxLongitude]
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.segmentID] = segmentID
    container[Columns.minLatitude] = minLatitude
    container[Columns.maxLatitude] = maxLatitude
    container[Columns.minLongitude] = minLongitude
    container[Columns.maxLongitude] = maxLongitude
  }
}
