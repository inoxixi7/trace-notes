import CoreLocation
import Foundation
import Testing

/// Reference values come from the published test suites of eviltransform (BSD-2-Clause) and the
/// coordtransform README (MIT); see docs/THIRD_PARTY_NOTICES.md.
struct GCJ02Tests {
  struct Vector: Sendable, CustomTestStringConvertible {
    let name: String
    let wgs: CLLocationCoordinate2D
    let gcj: CLLocationCoordinate2D
    var testDescription: String { name }
  }

  static let vectors: [Vector] = [
    Vector(
      name: "Beijing (eviltransform)",
      wgs: .init(latitude: 39.911954, longitude: 116.377817),
      gcj: .init(latitude: 39.91334545536069, longitude: 116.38404722455657)),
    Vector(
      name: "Beijing (coordtransform)",
      wgs: .init(latitude: 39.915, longitude: 116.404),
      gcj: .init(latitude: 39.91640428150164, longitude: 116.41024449916938)),
    Vector(
      name: "Shanghai (eviltransform)",
      wgs: .init(latitude: 31.1774276, longitude: 121.5272106),
      gcj: .init(latitude: 31.17530398364597, longitude: 121.531541859215)),
    Vector(
      name: "Shenzhen (eviltransform)",
      wgs: .init(latitude: 22.543847, longitude: 113.912316),
      gcj: .init(latitude: 22.540796131694766, longitude: 113.9171764808363)),
  ]

  /// Required accuracy of the display transform against the reference implementations.
  static let toleranceMeters = 1.0

  @Test(arguments: vectors)
  func matchesReference(_ vector: Vector) {
    let converted = GCJ02.fromWGS84(vector.wgs)
    let error = TestGeo.distanceMeters(converted, vector.gcj)
    #expect(error < Self.toleranceMeters, "error \(error) m")
  }

  @Test func shiftIsHundredsOfMetresInBeijing() {
    let wgs = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
    let shift = TestGeo.distanceMeters(wgs, GCJ02.fromWGS84(wgs))
    #expect(shift > 300 && shift < 800, "shift \(shift) m")
  }
}

enum TestGeo {
  static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
      .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
  }
}
