import CoreLocation
import Foundation

/// WGS-84 → GCJ-02 conversion for drawing on mainland-China base maps.
///
/// GCJ-02 is the obfuscated datum required for maps published in mainland China. This is the
/// widely published approximation of it (Krasovsky 1940 ellipsoid constants), the same formula as
/// eviltransform (BSD-2-Clause, © 2015 Googol Lee and contributors) and coordtransform
/// (MIT, © 2015 记忆的残骸 / wandergis); re-implemented here. See docs/THIRD_PARTY_NOTICES.md.
///
/// The offset is applied unconditionally. Deciding *whether* a point should be shifted is
/// `MapDatumPolicy`'s job. Results are for display only and must never be stored (D16).
nonisolated enum GCJ02 {
  /// Krasovsky 1940 semi-major axis in metres, as used by the GCJ-02 formula.
  private static let semiMajorAxis = 6_378_245.0
  /// Krasovsky 1940 first eccentricity squared, as used by the GCJ-02 formula.
  private static let eccentricitySquared = 0.00669342162296594323
  /// The formula is expressed relative to this origin (degrees).
  private static let originLongitude = 105.0
  private static let originLatitude = 35.0

  static func fromWGS84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
    let converted = fromWGS84(latitude: coordinate.latitude, longitude: coordinate.longitude)
    return CLLocationCoordinate2D(latitude: converted.latitude, longitude: converted.longitude)
  }

  static func fromWGS84(
    latitude: CLLocationDegrees,
    longitude: CLLocationDegrees
  ) -> (latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
    let x = longitude - originLongitude
    let y = latitude - originLatitude
    let radianLatitude = latitude / 180 * .pi
    let sinLatitude = sin(radianLatitude)
    let magic = 1 - eccentricitySquared * sinLatitude * sinLatitude
    let sqrtMagic = magic.squareRoot()

    let deltaLatitude =
      (latitudeOffset(x: x, y: y) * 180)
      / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
    let deltaLongitude =
      (longitudeOffset(x: x, y: y) * 180)
      / (semiMajorAxis / sqrtMagic * cos(radianLatitude) * .pi)
    return (latitude + deltaLatitude, longitude + deltaLongitude)
  }

  private static func latitudeOffset(x: Double, y: Double) -> Double {
    var result = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
    result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
    result += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
    result += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
    return result
  }

  private static func longitudeOffset(x: Double, y: Double) -> Double {
    var result = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
    result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
    result += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
    result += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
    return result
  }
}
