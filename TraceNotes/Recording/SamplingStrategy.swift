import CoreLocation

/// Standard location service settings for one engine state.
nonisolated struct LocationConfiguration: Equatable, Sendable {
  var desiredAccuracy: CLLocationAccuracy
  var distanceFilter: CLLocationDistance
  var activityType: CLActivityType
}

/// The replaceable sampling part of the engine (ARCHITECTURE §4.3): state in, configuration out.
/// Release builds contain only the strategy finally chosen by S3 (P1: nothing for the user to
/// pick).
nonisolated protocol SamplingStrategy: Sendable {
  func configuration(for state: EngineState) -> LocationConfiguration
}

/// S3 strategy B, the current baseline (S3-result §2.3, §5): GPS-grade accuracy with no distance
/// filter while moving, Wi-Fi / cell accuracy while stationary. Updates never stop, because a
/// stopped app gets suspended and cannot restart updates from the background (S1).
nonisolated struct TieredAccuracyStrategy: SamplingStrategy {
  func configuration(for state: EngineState) -> LocationConfiguration {
    switch state {
    // No distance filter while moving: a phone that stops must keep producing fixes, or the
    // dwell rule cannot fire without Core Motion (S3 finding).
    case .moving(.automotive):
      // Trains count as automotive in Core Motion; .otherNavigation does not snap to roads.
      LocationConfiguration(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: kCLDistanceFilterNone, activityType: .otherNavigation)
    case .moving:
      LocationConfiguration(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: kCLDistanceFilterNone, activityType: .fitness)
    case .stationary:
      // GPS off. The filter still lets drift and departures through (F3).
      LocationConfiguration(desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 25, activityType: .other)
    }
  }
}
