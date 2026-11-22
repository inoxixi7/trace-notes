import CoreLocation

/// S3 spike: the candidate sampling strategies. Details and rationale: docs/spikes/S3-result.md §2.
nonisolated enum S3Strategy: String, CaseIterable, Codable, Sendable {
  /// A · `CLLocationUpdate.liveUpdates`, configuration chosen by activity; Core Location's own
  /// stationary detection pauses delivery when still.
  case systemLive = "A-systemLive"
  /// B · `CLLocationManager` continuous updates; GPS-grade accuracy while moving, 100 m
  /// (Wi-Fi / cell) accuracy while stationary. Never stops updates.
  case tieredAccuracy = "B-tieredAccuracy"
  /// C · like B while moving; while stationary, stops updates and waits for an exit geofence,
  /// a visit departure, a significant change or Core Motion to wake it.
  case geofenceSleep = "C-geofenceSleep"

  var title: String {
    switch self {
    case .systemLive: "A · System live updates"
    case .tieredAccuracy: "B · Tiered accuracy (always on)"
    case .geofenceSleep: "C · Geofence sleep"
    }
  }

  /// Strategy A: live-update configuration per state.
  static func liveConfiguration(for state: S3MotionStateMachine.State) -> CLLocationUpdate.LiveConfiguration {
    switch state {
    case .moving(.walking), .moving(.running), .moving(.cycling): .fitness
    // Trains count as automotive in Core Motion; .otherNavigation does not snap to roads.
    case .moving(.automotive): .otherNavigation
    case .moving(.unknown), .stationary: .default
    }
  }

  /// Strategies B and C: standard location service settings per state.
  struct ManagerSettings: Equatable, Sendable {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    let activityType: CLActivityType

    var summary: String {
      "acc=\(Self.accuracyName(desiredAccuracy)) filter=\(distanceFilter == kCLDistanceFilterNone ? "none" : "\(Int(distanceFilter))m") type=\(activityType.rawValue)"
    }

    private static func accuracyName(_ accuracy: CLLocationAccuracy) -> String {
      switch accuracy {
      case kCLLocationAccuracyBestForNavigation: "bestForNavigation"
      case kCLLocationAccuracyBest: "best"
      case kCLLocationAccuracyNearestTenMeters: "10m"
      case kCLLocationAccuracyHundredMeters: "100m"
      case kCLLocationAccuracyKilometer: "1km"
      case kCLLocationAccuracyThreeKilometers: "3km"
      default: "\(Int(accuracy))m"
      }
    }
  }

  /// While moving there is **no distance filter**: a still phone must keep delivering fixes, or the
  /// dwell rule (stay within 50 m for 3 min) can never fire without Core Motion. The cost is CPU
  /// wake-ups (~1 Hz) only while moving; the GPS is on either way.
  static func managerSettings(for state: S3MotionStateMachine.State) -> ManagerSettings {
    switch state {
    case .moving(.walking), .moving(.running), .moving(.cycling), .moving(.unknown):
      ManagerSettings(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: kCLDistanceFilterNone, activityType: .fitness)
    // Trains count as automotive in Core Motion; .otherNavigation does not snap to roads.
    case .moving(.automotive):
      ManagerSettings(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: kCLDistanceFilterNone, activityType: .otherNavigation)
    // Strategy B only: Wi-Fi / cell positioning, GPS off. The 25 m filter still records drift (F3).
    case .stationary:
      ManagerSettings(desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 25, activityType: .other)
    }
  }
}
