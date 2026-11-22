import CoreLocation
import Foundation

/// Tuning values for `TraceStabilizer`: the legacy field-tuned values, unchanged except the gap
/// (D34 ②, ⑤). Changing any of them changes derived tracks, so bump `Segmenter.pipelineVersion`.
nonisolated struct TraceStabilizerConfiguration: Equatable, Sendable {
  let maximumWindowPoints: Int
  let maximumWindowDurationSeconds: TimeInterval
  let maximumTimestampGapSeconds: TimeInterval
  let minimumWindowPoints: Int
  let minimumWindowDurationSeconds: TimeInterval
  let goodAccuracyMeters: CLLocationAccuracy
  let stationaryRadiusMultiplier: Double
  let stationaryRadiusMinimumMeters: CLLocationDistance
  let stationaryRadiusMaximumMeters: CLLocationDistance
  let stationaryNetDisplacementMultiplier: Double
  let stationaryNetDisplacementMinimumMeters: CLLocationDistance
  let stationaryNetDisplacementMaximumMeters: CLLocationDistance
  let jitterPathToNetRatio: Double
  let movementConfirmationCount: Int
  let movementSpeedEvidenceMetersPerSecond: CLLocationSpeed
  let smoothingPreviousWeight: Double
  let smoothingCurrentWeight: Double
  let smoothingNextWeight: Double
  let turnLegMinimumMeters: CLLocationDistance
  let turnAngleThresholdDegrees: Double
  let maximumExcursionPoints: Int
  let maximumExcursionDurationSeconds: TimeInterval
  let minimumExcursionPoints: Int
  let minimumExcursionPathMeters: CLLocationDistance
  let excursionPathToNetRatio: Double
  let excursionLateralDeviationMultiplier: Double
  let excursionLateralDeviationMinimumMeters: CLLocationDistance
  let excursionLateralDeviationMaximumMeters: CLLocationDistance
  let excursionCorridorRadiusMultiplier: Double
  /// The legacy app delivered a fix only once it was this far from the previous one
  /// (`CoreLocationClient.minimumDeliveryDistanceMeters`), and every value above was tuned on that
  /// density. Trace Notes stores every fix (F1), so the input is thinned the same way first;
  /// unthinned 1 Hz walking steps of 1.4 m never count as movement and the walk is suppressed.
  let minimumInputSpacingMeters: CLLocationDistance = 10

  init(
    maximumWindowPoints: Int = 8,
    maximumWindowDurationSeconds: TimeInterval = 30,
    // D34 ⑤: the timeline's gap (D32), was 180 s in the legacy app.
    maximumTimestampGapSeconds: TimeInterval = 300,
    minimumWindowPoints: Int = 5,
    minimumWindowDurationSeconds: TimeInterval = 20,
    goodAccuracyMeters: CLLocationAccuracy = 20,
    stationaryRadiusMultiplier: Double = 1.5,
    stationaryRadiusMinimumMeters: CLLocationDistance = 12,
    stationaryRadiusMaximumMeters: CLLocationDistance = 45,
    stationaryNetDisplacementMultiplier: Double = 0.75,
    stationaryNetDisplacementMinimumMeters: CLLocationDistance = 8,
    stationaryNetDisplacementMaximumMeters: CLLocationDistance = 25,
    jitterPathToNetRatio: Double = 2.5,
    movementConfirmationCount: Int = 3,
    movementSpeedEvidenceMetersPerSecond: CLLocationSpeed = 1.2,
    smoothingPreviousWeight: Double = 0.25,
    smoothingCurrentWeight: Double = 0.5,
    smoothingNextWeight: Double = 0.25,
    turnLegMinimumMeters: CLLocationDistance = 8,
    turnAngleThresholdDegrees: Double = 45,
    maximumExcursionPoints: Int = 8,
    maximumExcursionDurationSeconds: TimeInterval = 45,
    minimumExcursionPoints: Int = 2,
    minimumExcursionPathMeters: CLLocationDistance = 45,
    excursionPathToNetRatio: Double = 2.5,
    excursionLateralDeviationMultiplier: Double = 1.5,
    excursionLateralDeviationMinimumMeters: CLLocationDistance = 20,
    excursionLateralDeviationMaximumMeters: CLLocationDistance = 80,
    excursionCorridorRadiusMultiplier: Double = 1.0
  ) {
    self.maximumWindowPoints = max(1, maximumWindowPoints)
    self.maximumWindowDurationSeconds = max(0, maximumWindowDurationSeconds)
    self.maximumTimestampGapSeconds = max(0, maximumTimestampGapSeconds)
    self.minimumWindowPoints = max(1, minimumWindowPoints)
    self.minimumWindowDurationSeconds = max(0, minimumWindowDurationSeconds)
    self.goodAccuracyMeters = max(0, goodAccuracyMeters)
    self.stationaryRadiusMultiplier = max(0, stationaryRadiusMultiplier)
    self.stationaryRadiusMinimumMeters = max(0, stationaryRadiusMinimumMeters)
    self.stationaryRadiusMaximumMeters = max(
      self.stationaryRadiusMinimumMeters,
      stationaryRadiusMaximumMeters
    )
    self.stationaryNetDisplacementMultiplier = max(
      0,
      stationaryNetDisplacementMultiplier
    )
    self.stationaryNetDisplacementMinimumMeters = max(
      0,
      stationaryNetDisplacementMinimumMeters
    )
    self.stationaryNetDisplacementMaximumMeters = max(
      self.stationaryNetDisplacementMinimumMeters,
      stationaryNetDisplacementMaximumMeters
    )
    self.jitterPathToNetRatio = max(1, jitterPathToNetRatio)
    self.movementConfirmationCount = max(1, movementConfirmationCount)
    self.movementSpeedEvidenceMetersPerSecond = max(
      0,
      movementSpeedEvidenceMetersPerSecond
    )
    self.smoothingPreviousWeight = max(0, smoothingPreviousWeight)
    self.smoothingCurrentWeight = max(0, smoothingCurrentWeight)
    self.smoothingNextWeight = max(0, smoothingNextWeight)
    self.turnLegMinimumMeters = max(0, turnLegMinimumMeters)
    self.turnAngleThresholdDegrees = max(0, turnAngleThresholdDegrees)
    self.maximumExcursionPoints = max(2, maximumExcursionPoints)
    self.maximumExcursionDurationSeconds = max(
      1,
      maximumExcursionDurationSeconds
    )
    self.minimumExcursionPoints = max(
      2,
      min(minimumExcursionPoints, self.maximumExcursionPoints)
    )
    self.minimumExcursionPathMeters = max(0, minimumExcursionPathMeters)
    self.excursionPathToNetRatio = max(1, excursionPathToNetRatio)
    self.excursionLateralDeviationMultiplier = max(
      0,
      excursionLateralDeviationMultiplier
    )
    self.excursionLateralDeviationMinimumMeters = max(
      0,
      excursionLateralDeviationMinimumMeters
    )
    self.excursionLateralDeviationMaximumMeters = max(
      self.excursionLateralDeviationMinimumMeters,
      excursionLateralDeviationMaximumMeters
    )
    self.excursionCorridorRadiusMultiplier = max(
      0,
      excursionCorridorRadiusMultiplier
    )
  }

  static let `default` = TraceStabilizerConfiguration()
  func stationaryRadius(for accuracy: CLLocationAccuracy) -> CLLocationDistance {
    let finiteAccuracy = accuracy.isFinite ? max(1, accuracy) : goodAccuracyMeters
    return min(
      max(
        finiteAccuracy * stationaryRadiusMultiplier,
        stationaryRadiusMinimumMeters
      ),
      stationaryRadiusMaximumMeters
    )
  }

  func stationaryNetDisplacement(for accuracy: CLLocationAccuracy)
    -> CLLocationDistance
  {
    let finiteAccuracy = accuracy.isFinite ? max(1, accuracy) : goodAccuracyMeters
    return min(
      max(
        finiteAccuracy * stationaryNetDisplacementMultiplier,
        stationaryNetDisplacementMinimumMeters
      ),
      stationaryNetDisplacementMaximumMeters
    )
  }
}
