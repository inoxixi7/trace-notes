import CoreLocation
import Foundation
import Testing

struct MapDatumPolicyTests {
  let policy: MapDatumPolicy

  init() throws {
    policy = MapDatumPolicy(mainland: try ChinaMainlandRegion.bundled(), chinaBaseMapServed: true)
  }

  /// D26: without the China base map, mainland points are drawn as stored too.
  @Test func mainlandPointIsUnchangedWithoutChinaBaseMap() throws {
    let policy = MapDatumPolicy(mainland: try ChinaMainlandRegion.bundled(), chinaBaseMapServed: false)
    let beijing = CLLocationCoordinate2D(latitude: 39.911954, longitude: 116.377817)
    #expect(policy.datum(at: beijing) == .wgs84)
    let display = policy.displayCoordinate(for: beijing)
    #expect(display.latitude == beijing.latitude && display.longitude == beijing.longitude)
  }

  @Test func mainlandPointIsConverted() {
    let beijing = CLLocationCoordinate2D(latitude: 39.911954, longitude: 116.377817)
    #expect(policy.datum(at: beijing) == .gcj02)
    let display = policy.displayCoordinate(for: beijing)
    #expect(TestGeo.distanceMeters(display, GCJ02.fromWGS84(beijing)) == 0)
  }

  @Test(arguments: [
    (22.3193, 114.1694),  // Hong Kong
    (22.1987, 113.5439),  // Macau
    (25.0330, 121.5654),  // Taipei
    (35.6762, 139.6503),  // Tokyo
  ])
  func nonMainlandPointIsUnchanged(latitude: Double, longitude: Double) {
    let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    #expect(policy.datum(at: point) == .wgs84)
    let display = policy.displayCoordinate(for: point)
    #expect(display.latitude == point.latitude && display.longitude == point.longitude)
  }

  /// A track crossing at Lo Wu: only the Shenzhen side is shifted.
  @Test func crossingTrackIsConvertedPerPoint() {
    let track = [
      CLLocationCoordinate2D(latitude: 22.5390, longitude: 114.1180),  // Shenzhen Luohu
      CLLocationCoordinate2D(latitude: 22.5280, longitude: 114.1130),  // Hong Kong Lo Wu
    ]
    let display = policy.displayCoordinates(for: track)
    #expect(display.count == track.count)
    #expect(TestGeo.distanceMeters(display[0], track[0]) > 100)
    #expect(TestGeo.distanceMeters(display[1], track[1]) == 0)
  }

}
