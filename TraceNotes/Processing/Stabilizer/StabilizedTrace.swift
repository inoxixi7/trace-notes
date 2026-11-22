import CoreLocation
import Foundation

/// A finite geographic coordinate used by the stabilizer.
nonisolated struct TraceCoordinate: Equatable, Hashable, Sendable {
  let latitude: CLLocationDegrees
  let longitude: CLLocationDegrees

  init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
    precondition(
      latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
        && (-180...180).contains(longitude),
      "TraceCoordinate must contain a finite geographic coordinate"
    )
    self.latitude = latitude
    self.longitude = longitude
  }

  /// A non-trapping entry point for values that may be invalid (raw GPS, averages).
  init?(validatingLatitude latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
    guard latitude.isFinite, longitude.isFinite,
      (-90...90).contains(latitude), (-180...180).contains(longitude)
    else { return nil }
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// The derived decision for one raw point of a move.
nonisolated struct TracePointUpdate: Equatable, Sendable {
  let recordedAt: Date
  let decision: TraceDecision
  /// The smoothed position for confirmed points, the raw one for provisional points, nil when
  /// suppressed.
  let displayCoordinate: TraceCoordinate?
}

/// The result of stabilizing one move: a decision for every input point plus diagnostics.
nonisolated struct StabilizedTrace: Equatable, Sendable {
  let state: MotionState
  /// One per input point, in the same order.
  let points: [TracePointUpdate]
  let stationaryAnchor: TraceCoordinate?
  let confirmedDistanceMeters: CLLocationDistance
  let rawDistanceMeters: CLLocationDistance
  let provisionalDistanceDiscardedMeters: CLLocationDistance
  let multiPointExcursionCount: Int
  let excursionSuppressedPointCount: Int
  let excursionSuppressedDistanceMeters: CLLocationDistance
  let maximumLateralDeviationMeters: CLLocationDistance

  var confirmedCoordinates: [TraceCoordinate] {
    points.compactMap { $0.decision == .confirmed ? $0.displayCoordinate : nil }
  }

  var provisionalCoordinates: [TraceCoordinate] {
    points.compactMap { $0.decision == .provisional ? $0.displayCoordinate : nil }
  }

  /// What the map draws (D34 ④): confirmed points, plus the undecided tail after the last confirmed
  /// one, so the open move's line keeps up with the newest fix. An undecided point that later
  /// confirmed points have passed (a spike awaiting the move's end) is left out, as finishing the
  /// move would suppress it.
  var drawableCoordinates: [TraceCoordinate] {
    let tailStart = (points.lastIndex { $0.decision == .confirmed } ?? -1) + 1
    return points.indices.compactMap { index in
      switch points[index].decision {
      case .confirmed: points[index].displayCoordinate
      case .provisional: index >= tailStart ? points[index].displayCoordinate : nil
      case .suppressed: nil
      }
    }
  }
}
