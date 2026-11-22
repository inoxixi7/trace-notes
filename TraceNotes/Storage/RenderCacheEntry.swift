import Foundation
import GRDB

/// One simplification level of one completed move (ARCHITECTURE §2.3 RenderCache). Derived:
/// deleted with its segment and rebuilt with it.
///
/// Coordinates are WGS-84 degrees × 10⁷ (as in raw points), packed as little-endian Int32 pairs.
nonisolated struct RenderCacheEntry: Equatable, Sendable {
  var segmentID: Int64
  var level: Int
  var coordinates: [RenderCache.Coordinate]

  static func == (lhs: RenderCacheEntry, rhs: RenderCacheEntry) -> Bool {
    lhs.segmentID == rhs.segmentID && lhs.level == rhs.level && lhs.coordinates.elementsEqual(rhs.coordinates) {
      $0.latitude == $1.latitude && $0.longitude == $1.longitude
    }
  }
}

nonisolated extension RenderCacheEntry: FetchableRecord, PersistableRecord {
  static let databaseTableName = "render_cache"

  enum Columns {
    static let segmentID = Column("segmentID")
    static let level = Column("level")
    static let coordinates = Column("coordinates")
  }

  init(row: Row) throws {
    segmentID = row[Columns.segmentID]
    level = row[Columns.level]
    let data: Data = row[Columns.coordinates]
    guard data.count.isMultiple(of: 8) else {
      throw DatabaseError(message: "render_cache.coordinates has \(data.count) bytes, not a multiple of 8")
    }
    coordinates = data.withUnsafeBytes { buffer in
      stride(from: 0, to: buffer.count, by: 8).map { offset in
        let latitude = Int32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: Int32.self))
        let longitude = Int32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: Int32.self))
        return (Double(latitude) / RawPoint.coordinateScale, Double(longitude) / RawPoint.coordinateScale)
      }
    }
  }

  func encode(to container: inout PersistenceContainer) throws {
    container[Columns.segmentID] = segmentID
    container[Columns.level] = level
    var data = Data(capacity: coordinates.count * 8)
    for coordinate in coordinates {
      // |degrees| × 10⁷ ≤ 1.8 × 10⁹ fits in Int32.
      for value in [coordinate.latitude, coordinate.longitude] {
        withUnsafeBytes(of: Int32(RawPoint.scaled(value)).littleEndian) { data.append(contentsOf: $0) }
      }
    }
    container[Columns.coordinates] = data
  }
}
