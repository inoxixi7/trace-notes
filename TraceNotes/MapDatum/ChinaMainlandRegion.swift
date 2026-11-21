import CoreLocation
import Foundation

/// Point-in-region test for "mainland China" as used by the map display layer:
/// mainland China excluding Hong Kong, Macau and Taiwan-controlled islands, extended ~10 km
/// out to sea so coastal tracks do not flip at a coarse coastline.
///
/// Data: `china-mainland.bin`, built by `Tools/geodata/build_boundary.py` from Natural Earth
/// (public domain) and OpenStreetMap (© OpenStreetMap contributors, ODbL 1.0). ~74 KB.
nonisolated struct ChinaMainlandRegion: Sendable {
  enum LoadError: Error, Equatable {
    case resourceMissing
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated
    case empty
  }

  /// One polygon edge in degrees.
  private struct Edge: Sendable {
    let latitude1: Double
    let longitude1: Double
    let latitude2: Double
    let longitude2: Double
  }

  /// Height of the latitude bands used to index edges, in degrees (~2 km). Smaller bands mean
  /// fewer edges to test per lookup at the cost of a larger index.
  private static let bandHeight = 0.02
  private static let formatVersion: UInt32 = 1
  private static let coordinateScale = 1e6

  private let edges: [Edge]
  /// For each latitude band, the indices of edges whose latitude span overlaps it.
  private let bands: [[Int32]]
  private let minimumLatitude: Double
  private let maximumLatitude: Double
  private let minimumLongitude: Double
  private let maximumLongitude: Double

  /// Loads the region shipped in the app bundle.
  static func bundled() throws -> ChinaMainlandRegion {
    guard
      let url = Bundle(for: BundleToken.self).url(
        forResource: "china-mainland",
        withExtension: "bin"
      )
    else { throw LoadError.resourceMissing }
    return try ChinaMainlandRegion(data: Data(contentsOf: url))
  }

  init(data: Data) throws {
    var reader = Reader(data: data)
    guard try reader.bytes(4) == Array("TNCB".utf8) else { throw LoadError.badMagic }
    let version = try reader.uint32()
    guard version == Self.formatVersion else { throw LoadError.unsupportedVersion(version) }

    var edges: [Edge] = []
    let polygonCount = try reader.uint32()
    for _ in 0..<polygonCount {
      let ringCount = try reader.uint32()
      for _ in 0..<ringCount {
        let pointCount = Int(try reader.uint32())
        var ring: [(Double, Double)] = []
        ring.reserveCapacity(pointCount)
        for _ in 0..<pointCount {
          let latitude = Double(try reader.int32()) / Self.coordinateScale
          let longitude = Double(try reader.int32()) / Self.coordinateScale
          ring.append((latitude, longitude))
        }
        guard ring.count >= 3 else { continue }
        for index in ring.indices {
          let start = ring[index]
          let end = ring[(index + 1) % ring.count]
          edges.append(Edge(latitude1: start.0, longitude1: start.1, latitude2: end.0, longitude2: end.1))
        }
      }
    }
    guard !edges.isEmpty else { throw LoadError.empty }

    let latitudes = edges.flatMap { [$0.latitude1, $0.latitude2] }
    let longitudes = edges.flatMap { [$0.longitude1, $0.longitude2] }
    let minimumLatitude = latitudes.min() ?? 0
    let maximumLatitude = latitudes.max() ?? 0
    self.minimumLatitude = minimumLatitude
    self.maximumLatitude = maximumLatitude
    self.minimumLongitude = longitudes.min() ?? 0
    self.maximumLongitude = longitudes.max() ?? 0

    let bandCount = Int(((maximumLatitude - minimumLatitude) / Self.bandHeight).rounded(.up)) + 1
    var bands = [[Int32]](repeating: [], count: bandCount)
    for (index, edge) in edges.enumerated() {
      let low = min(edge.latitude1, edge.latitude2)
      let high = max(edge.latitude1, edge.latitude2)
      let first = Int((low - minimumLatitude) / Self.bandHeight)
      let last = Int((high - minimumLatitude) / Self.bandHeight)
      for band in first...last {
        bands[band].append(Int32(index))
      }
    }
    self.edges = edges
    self.bands = bands
  }

  func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
    contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
  }

  /// Even-odd ray casting (towards increasing longitude) over the edges in the point's band.
  func contains(latitude: CLLocationDegrees, longitude: CLLocationDegrees) -> Bool {
    guard latitude.isFinite, longitude.isFinite,
      latitude >= minimumLatitude, latitude <= maximumLatitude,
      longitude >= minimumLongitude, longitude <= maximumLongitude
    else { return false }

    let band = Int((latitude - minimumLatitude) / Self.bandHeight)
    var inside = false
    for index in bands[band] {
      let edge = edges[Int(index)]
      // Half-open rule: an edge counts when the point's latitude is in [low, high).
      guard (edge.latitude1 > latitude) != (edge.latitude2 > latitude) else { continue }
      let crossingLongitude =
        edge.longitude1
        + (latitude - edge.latitude1) * (edge.longitude2 - edge.longitude1)
        / (edge.latitude2 - edge.latitude1)
      if longitude < crossingLongitude {
        inside.toggle()
      }
    }
    return inside
  }
}

/// Anchor for locating this module's bundle (the app in production, the host app under tests).
nonisolated private final class BundleToken {}

/// Sequential little-endian reader for the region file.
nonisolated private struct Reader {
  let data: Data
  var offset = 0

  mutating func bytes(_ count: Int) throws -> [UInt8] {
    guard offset + count <= data.count else { throw ChinaMainlandRegion.LoadError.truncated }
    defer { offset += count }
    return Array(data[data.startIndex + offset..<data.startIndex + offset + count])
  }

  mutating func uint32() throws -> UInt32 {
    let raw = try bytes(4)
    return raw.reversed().reduce(0) { $0 << 8 | UInt32($1) }
  }

  mutating func int32() throws -> Int32 {
    Int32(bitPattern: try uint32())
  }
}
