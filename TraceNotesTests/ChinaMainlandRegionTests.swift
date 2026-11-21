import CoreLocation
import Foundation
import Testing

struct ChinaMainlandRegionTests {
  struct Place: Sendable, CustomTestStringConvertible {
    let name: String
    let latitude: Double
    let longitude: Double
    let inMainland: Bool
    var testDescription: String { name }
  }

  /// Border pairs are a few hundred metres to ~1.5 km from the boundary (see S2-result.md).
  static let places: [Place] = [
    Place(name: "Beijing", latitude: 39.9042, longitude: 116.4074, inMainland: true),
    Place(name: "Shanghai", latitude: 31.2304, longitude: 121.4737, inMainland: true),
    Place(name: "Shenzhen Luohu", latitude: 22.5390, longitude: 114.1180, inMainland: true),
    Place(name: "Hong Kong Lo Wu", latitude: 22.5280, longitude: 114.1130, inMainland: false),
    Place(name: "Zhuhai Gongbei", latitude: 22.2180, longitude: 113.5490, inMainland: true),
    Place(name: "Macau Portas do Cerco", latitude: 22.2140, longitude: 113.5500, inMainland: false),
    Place(name: "Xiamen", latitude: 24.4798, longitude: 118.0894, inMainland: true),
    Place(name: "Kinmen", latitude: 24.4320, longitude: 118.3170, inMainland: false),
    Place(name: "Dandong", latitude: 40.1290, longitude: 124.3940, inMainland: true),
    Place(name: "Sinuiju", latitude: 40.1000, longitude: 124.3980, inMainland: false),
    Place(name: "Taipei", latitude: 25.0330, longitude: 121.5654, inMainland: false),
    Place(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, inMainland: false),
    Place(name: "Seoul", latitude: 37.5665, longitude: 126.9780, inMainland: false),
    Place(name: "New York", latitude: 40.7128, longitude: -74.0060, inMainland: false),
  ]

  @Test(arguments: places)
  func classifies(_ place: Place) throws {
    let region = try ChinaMainlandRegion.bundled()
    #expect(region.contains(latitude: place.latitude, longitude: place.longitude) == place.inMainland)
  }

  @Test func rejectsNonFiniteCoordinates() throws {
    let region = try ChinaMainlandRegion.bundled()
    #expect(!region.contains(latitude: .nan, longitude: 116.4))
    #expect(!region.contains(latitude: 39.9, longitude: .infinity))
  }

  @Test func loadsSquareFromData() throws {
    let region = try ChinaMainlandRegion(data: TestRegionFile.square())
    #expect(region.contains(latitude: 0.5, longitude: 0.5))
    #expect(!region.contains(latitude: 1.5, longitude: 0.5))
  }

  @Test func holeIsOutside() throws {
    let region = try ChinaMainlandRegion(data: TestRegionFile.square(withHole: true))
    #expect(!region.contains(latitude: 0.5, longitude: 0.5))
    #expect(region.contains(latitude: 0.1, longitude: 0.1))
  }

  @Test func rejectsBadMagic() {
    var data = TestRegionFile.square()
    data[0] = UInt8(ascii: "X")
    #expect(throws: ChinaMainlandRegion.LoadError.badMagic) { try ChinaMainlandRegion(data: data) }
  }

  @Test func rejectsUnknownVersion() {
    #expect(throws: ChinaMainlandRegion.LoadError.unsupportedVersion(2)) {
      try ChinaMainlandRegion(data: TestRegionFile.square(version: 2))
    }
  }

  @Test func rejectsTruncatedData() {
    let data = TestRegionFile.square().dropLast(3)
    #expect(throws: ChinaMainlandRegion.LoadError.truncated) { try ChinaMainlandRegion(data: data) }
  }

  @Test func rejectsEmptyRegion() {
    var data = Data("TNCB".utf8)
    TestRegionFile.append(UInt32(1), to: &data)
    TestRegionFile.append(UInt32(0), to: &data)
    #expect(throws: ChinaMainlandRegion.LoadError.empty) { try ChinaMainlandRegion(data: data) }
  }
}

/// Builds small files in the china-mainland.bin format.
enum TestRegionFile {
  static func square(version: UInt32 = 1, withHole: Bool = false) -> Data {
    let outer: [(Double, Double)] = [(0, 0), (0, 1), (1, 1), (1, 0)]
    let hole: [(Double, Double)] = [(0.4, 0.4), (0.4, 0.6), (0.6, 0.6), (0.6, 0.4)]
    let rings = withHole ? [outer, hole] : [outer]
    var data = Data("TNCB".utf8)
    append(version, to: &data)
    append(UInt32(1), to: &data)
    append(UInt32(rings.count), to: &data)
    for ring in rings {
      append(UInt32(ring.count), to: &data)
      for (latitude, longitude) in ring {
        append(UInt32(bitPattern: Int32((latitude * 1e6).rounded())), to: &data)
        append(UInt32(bitPattern: Int32((longitude * 1e6).rounded())), to: &data)
      }
    }
    return data
  }

  static func append(_ value: UInt32, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
}
