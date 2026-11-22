import CoreLocation
import Foundation

/// Pipeline step ⑥ (ARCHITECTURE §5.1, F6): why a gap has no points, from what the recorder wrote
/// about itself, and whether it looks like a subway ride (D19, D42).
///
/// Only one cause is shown. In order: location access or Location Services turned off, a subway
/// ride, the phone off or the app not running, Low Power Mode, unknown (D42). A pause would come
/// first, but the recorder writes no pause events until VS9.
nonisolated enum GapExplainer {
  struct Parameters: Sendable {
    /// A subway ride covers at least this straight-line distance, in metres...
    var subwayMinimumDistance: Double = 1_000
    /// ...at an average straight-line speed in this range, in km/h (D42).
    var subwayMinimumSpeed: Double = 15
    var subwayMaximumSpeed: Double = 100
  }

  struct Explanation: Equatable, Sendable {
    /// The cause from the recorder's events; never `nil` (unknown when nothing explains it).
    var reason: GapReason
    /// Set when the gap looks like a subway ride and no stronger cause applies.
    var isSubway: Bool
  }

  /// `events` are the recorder events in time order that may matter: those inside the gap and the
  /// first motion reading after it. `lowPowerBefore` is the newest Low Power Mode event before the
  /// gap, `activityBefore` the newest motion reading at or before its start. `entry` and `exit` are
  /// the WGS-84 positions on either side of it.
  static func explain(
    start: Date, end: Date, events: [RecorderEvent], lowPowerBefore: RecorderEvent?,
    activityBefore: TransportClassifier.ActivityReading?,
    entry: CLLocationCoordinate2D?, exit: CLLocationCoordinate2D?,
    parameters: Parameters = Parameters()
  ) -> Explanation {
    let inside = events.filter { $0.timestamp >= start && $0.timestamp <= end }
    if let cause = accessCause(in: inside) {
      return Explanation(reason: cause, isSubway: false)
    }
    let subway = looksLikeSubway(
      start: start, end: end, events: events, activityBefore: activityBefore, entry: entry, exit: exit, parameters: parameters)
    let reason: GapReason
    if inside.contains(where: { [.launch, .backgroundRelaunch, .terminatedDetected].contains($0.kind) }) {
      reason = .notRunning
    } else if lowPowerBefore?.kind == .lowPowerModeOn || inside.contains(where: { $0.kind == .lowPowerModeOn }) {
      reason = .lowPower
    } else {
      reason = .unknown
    }
    return Explanation(reason: reason, isSubway: subway)
  }

  /// Location Services off, or access no longer allowing location. Every launch writes the current
  /// status, so only statuses that stop recording count.
  private static func accessCause(in events: [RecorderEvent]) -> GapReason? {
    if events.contains(where: { $0.kind == .locationServicesOff }) { return .locationOff }
    let stopping: Set<String> = ["status=denied", "status=restricted", "status=notDetermined"]
    if events.contains(where: { $0.kind == .authorizationChanged && stopping.contains($0.payload ?? "") }) {
      return .permissionChanged
    }
    return nil
  }

  /// Motion & Fitness says riding (in the newest reading before the gap and the first after it, or
  /// anywhere inside it), and the straight line between the two sides fits a train (D42).
  private static func looksLikeSubway(
    start: Date, end: Date, events: [RecorderEvent], activityBefore: TransportClassifier.ActivityReading?,
    entry: CLLocationCoordinate2D?, exit: CLLocationCoordinate2D?, parameters: Parameters
  ) -> Bool {
    guard let entry, let exit else { return false }
    let readings = events.compactMap(TransportClassifier.ActivityReading.init)
    let inside = readings.filter { $0.timestamp > start && $0.timestamp < end }
    let after = readings.first { $0.timestamp >= end }
    let riding = inside.contains { $0.activity == .automotive }
      || (activityBefore?.activity == .automotive && after?.activity == .automotive)
    guard riding else { return false }
    let metres = CLLocation(latitude: entry.latitude, longitude: entry.longitude)
      .distance(from: CLLocation(latitude: exit.latitude, longitude: exit.longitude))
    let hours = end.timeIntervalSince(start) / 3_600
    guard metres >= parameters.subwayMinimumDistance, hours > 0 else { return false }
    let speed = metres / 1_000 / hours
    return speed >= parameters.subwayMinimumSpeed && speed <= parameters.subwayMaximumSpeed
  }
}
