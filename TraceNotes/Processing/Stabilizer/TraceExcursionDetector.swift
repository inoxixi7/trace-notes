import CoreLocation
import Foundation

/// Pure geometry analysis for short-lived GPS excursions.
///
/// The detector only considers a bounded, weak-evidence run which leaves the
/// direction of the user's already-confirmed trace and returns to that local
/// corridor. It never removes a high-quality, speed-supported route (including
/// a genuine loop or U-turn), and it has no MapKit/road-network dependency.
nonisolated struct TraceExcursionAnalysis: Equatable, Sendable {
  let suppressedIndices: [Int]
  let excursionCount: Int
  let maximumLateralDeviationMeters: CLLocationDistance
  let pathLengthMeters: CLLocationDistance
  let netDisplacementMeters: CLLocationDistance

  var detected: Bool { !suppressedIndices.isEmpty }
}

nonisolated struct TraceExcursionDetector: Sendable {
  static func analyze(
    locations: [RawPoint],
    decisions: [TraceDecision],
    configuration: TraceStabilizerConfiguration,
    scanFrom: Int = 0
  ) -> TraceExcursionAnalysis {
    guard locations.count == decisions.count,
      locations.count >= configuration.minimumExcursionPoints + 2
    else {
      return TraceExcursionAnalysis(
        suppressedIndices: [],
        excursionCount: 0,
        maximumLateralDeviationMeters: 0,
        pathLengthMeters: 0,
        netDisplacementMeters: 0
      )
    }

    var suppressed = Set<Int>()
    var eventRanges: [(start: Int, end: Int)] = []
    var excursionCount = 0
    var maximumLateralDeviation = 0.0
    var totalSuppressedPath = 0.0
    var totalSuppressedNet = 0.0
    let firstAfter = max(1, min(scanFrom, locations.count - 1))

    for afterIndex in firstAfter..<locations.count {
      guard decisions[afterIndex] == .confirmed else { continue }
      let candidateEnd = afterIndex - 1
      guard candidateEnd > 0,
        isWeakEvidence(locations[candidateEnd], configuration: configuration)
      else { continue }

      var candidateStart = candidateEnd
      while candidateStart > 0,
        candidateEnd - candidateStart + 1 < configuration.maximumExcursionPoints,
        decisions[candidateStart - 1] != .suppressed,
        isWeakEvidence(
          locations[candidateStart - 1],
          configuration: configuration
        )
      {
        candidateStart -= 1
      }

      let candidateIndices = Array(candidateStart...candidateEnd)
      guard candidateIndices.count >= configuration.minimumExcursionPoints,
        let beforeIndex = precedingConfirmedIndex(
          before: candidateStart,
          decisions: decisions
        ),
        let beforeBeforeIndex = precedingConfirmedIndex(
          before: beforeIndex,
          decisions: decisions
        ),
        decisions[afterIndex] == .confirmed,
        validWindow(
          from: beforeBeforeIndex,
          through: afterIndex,
          locations: locations,
          configuration: configuration
        ),
        let beforeBefore = coordinate(locations[beforeBeforeIndex]),
        let before = coordinate(locations[beforeIndex]),
        let after = coordinate(locations[afterIndex])
      else { continue }

      let duration = afterTimestamp(locations, index: afterIndex)
        .timeIntervalSince(afterTimestamp(locations, index: beforeIndex))
      guard duration > 0,
        duration <= configuration.maximumExcursionDurationSeconds
      else { continue }

      let candidatePoints = candidateIndices.compactMap {
        coordinate(locations[$0])
      }
      guard candidatePoints.count == candidateIndices.count else { continue }

      let pathPoints = [before] + candidatePoints + [after]
      let pathLength = pathLength(pathPoints)
      let netDisplacement = distance(before, after)
      guard pathLength >= configuration.minimumExcursionPathMeters else { continue }

      let ratio =
        netDisplacement < 1
        ? .infinity
        : pathLength / netDisplacement
      guard ratio >= configuration.excursionPathToNetRatio else { continue }

      // A weak-accuracy stream can still be trustworthy when Core Location
      // reports a consistent course and speed for nearly every sample. Keep
      // that forward progression provisional/confirmable rather than
      // mistaking degraded precision for a returning excursion.
      let progressionEvidenceCount = candidateIndices.reduce(into: 0) {
        count,
        index in
        let sample = locations[index]
        let hasSpeed =
          sample.speed.map {
            $0.isFinite
              && $0 >= configuration.movementSpeedEvidenceMetersPerSecond
          } ?? false
        let hasCourse = sample.course.map { $0.isFinite } ?? false
        if hasSpeed && hasCourse { count += 1 }
      }
      if progressionEvidenceCount >= max(2, candidateIndices.count - 1) {
        let baselineBearing = bearing(from: before, to: after)
        let pathBearings = zip(pathPoints, pathPoints.dropFirst()).map {
          bearing(from: $0.0, to: $0.1)
        }
        let directionallyConsistent = candidateIndices.enumerated().allSatisfy {
          offset,
          index in
          guard let course = locations[index].course,
            course.isFinite,
            offset < pathBearings.count
          else { return false }
          let pathBearing = pathBearings[offset]
          return angleDifference(
            normalizedBearing(course),
            pathBearing
          ) <= 75
            && angleDifference(
              normalizedBearing(course),
              baselineBearing
            ) <= 75
        }
        if directionallyConsistent { continue }
      }

      let medianAccuracy = medianAccuracy(
        candidateIndices.map { locations[$0].horizontalAccuracy },
        fallback: configuration.goodAccuracyMeters
      )
      let corridorRadius = min(
        max(8, medianAccuracy * configuration.excursionCorridorRadiusMultiplier),
        configuration.excursionLateralDeviationMaximumMeters
      )
      let lateralDeviation =
        candidatePoints.map {
          distanceToInfiniteLine($0, from: beforeBefore, to: before)
        }.max() ?? 0
      let accuracyLateralLimit = max(
        configuration.excursionLateralDeviationMinimumMeters,
        medianAccuracy * configuration.excursionLateralDeviationMultiplier
      )
      guard
        lateralDeviation
          >= max(
            accuracyLateralLimit,
            corridorRadius
          )
      else { continue }

      let returnsToCorridor =
        distanceToInfiniteLine(
          after,
          from: beforeBefore,
          to: before
        ) <= corridorRadius
      guard returnsToCorridor else { continue }

      // A real loop/U-turn has strong, sustained speed and good accuracy.
      // Missing course alone is not enough to reject it; inferred leg speed is
      // reliable evidence when the samples are precise.
      let strongEvidenceCount = candidateIndices.reduce(into: 0) { count, index in
        let sample = locations[index]
        let hasGoodAccuracy =
          sample.horizontalAccuracy.isFinite
          && sample.horizontalAccuracy <= configuration.goodAccuracyMeters
        let hasSpeed =
          sample.speed.map {
            $0.isFinite && $0 >= configuration.movementSpeedEvidenceMetersPerSecond
          } ?? false
        if hasGoodAccuracy && hasSpeed { count += 1 }
      }
      guard strongEvidenceCount < max(2, candidateIndices.count - 1) else {
        continue
      }

      let range = (
        start: candidateIndices[0],
        end: candidateIndices[candidateIndices.count - 1]
      )
      let overlapsExisting = eventRanges.contains { existing in
        range.start <= existing.end + 1 && existing.start <= range.end + 1
      }
      if !overlapsExisting {
        eventRanges.append(range)
        excursionCount += 1
        totalSuppressedPath += pathLength
        totalSuppressedNet += netDisplacement
      } else {
        // A later confirmed point can extend the same excursion window. It
        // should expand suppression, but not count the same episode again.
        for index in eventRanges.indices
        where
          range.start <= eventRanges[index].end + 1
          && eventRanges[index].start <= range.end + 1
        {
          eventRanges[index] = (
            start: min(eventRanges[index].start, range.start),
            end: max(eventRanges[index].end, range.end)
          )
        }
      }
      for index in candidateIndices where decisions[index] != .suppressed {
        suppressed.insert(index)
      }
      maximumLateralDeviation = max(maximumLateralDeviation, lateralDeviation)
    }

    return TraceExcursionAnalysis(
      suppressedIndices: suppressed.sorted(),
      excursionCount: excursionCount,
      maximumLateralDeviationMeters: maximumLateralDeviation,
      pathLengthMeters: totalSuppressedPath,
      netDisplacementMeters: totalSuppressedNet
    )
  }

  private static func precedingConfirmedIndex(
    before index: Int,
    decisions: [TraceDecision]
  ) -> Int? {
    guard index > 0 else { return nil }
    for candidate in stride(from: index - 1, through: 0, by: -1) {
      if decisions[candidate] == .confirmed { return candidate }
      if decisions[candidate] == .suppressed { return nil }
    }
    return nil
  }

  private static func validWindow(
    from start: Int,
    through end: Int,
    locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> Bool {
    guard start >= 0, end < locations.count, start < end else { return false }
    for index in (start + 1)...end {
      let gap = locations[index].timestamp.timeIntervalSince(
        locations[index - 1].timestamp
      )
      guard gap > 0,
        gap <= configuration.maximumTimestampGapSeconds,
        gap.isFinite
      else { return false }
    }
    return true
  }

  private static func isWeakEvidence(
    _ location: RawPoint,
    configuration: TraceStabilizerConfiguration
  ) -> Bool {
    let poorAccuracy =
      !location.horizontalAccuracy.isFinite
      || location.horizontalAccuracy > configuration.goodAccuracyMeters
    let missingSpeedEvidence =
      location.speed == nil
      || !(location.speed?.isFinite ?? false)
      || (location.speed ?? 0) < configuration.movementSpeedEvidenceMetersPerSecond
    let missingCourseEvidence =
      location.course == nil
      || !(location.course?.isFinite ?? false)
    return poorAccuracy || missingSpeedEvidence || missingCourseEvidence
  }

  private static func coordinate(_ location: RawPoint) -> TraceCoordinate? {
    TraceCoordinate(
      validatingLatitude: location.latitude,
      longitude: location.longitude
    )
  }

  private static func afterTimestamp(
    _ locations: [RawPoint],
    index: Int
  ) -> Date {
    locations[index].timestamp
  }

  private static func medianAccuracy(
    _ values: [CLLocationAccuracy],
    fallback: CLLocationAccuracy
  ) -> CLLocationAccuracy {
    let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
    guard !sorted.isEmpty else { return fallback }
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  private static func pathLength(_ points: [TraceCoordinate]) -> CLLocationDistance {
    zip(points, points.dropFirst()).reduce(0) { partial, pair in
      partial + distance(pair.0, pair.1)
    }
  }

  private static func distance(
    _ lhs: TraceCoordinate,
    _ rhs: TraceCoordinate
  ) -> CLLocationDistance {
    CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
      .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
  }

  private static func bearing(
    from start: TraceCoordinate,
    to end: TraceCoordinate
  ) -> Double {
    let latitude = start.latitude * .pi / 180
    let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
    let y = sin(deltaLongitude) * cos(end.latitude * .pi / 180)
    let x =
      cos(latitude) * sin(end.latitude * .pi / 180)
      - sin(latitude) * cos(end.latitude * .pi / 180) * cos(deltaLongitude)
    return normalizedBearing(atan2(y, x) * 180 / .pi)
  }

  private static func normalizedBearing(_ bearing: Double) -> Double {
    let normalized = bearing.truncatingRemainder(dividingBy: 360)
    return normalized >= 0 ? normalized : normalized + 360
  }

  private static func angleDifference(_ lhs: Double, _ rhs: Double) -> Double {
    let difference = abs(normalizedBearing(lhs) - normalizedBearing(rhs))
    return min(difference, 360 - difference)
  }

  private static func distanceToInfiniteLine(
    _ point: TraceCoordinate,
    from start: TraceCoordinate,
    to end: TraceCoordinate
  ) -> CLLocationDistance {
    let eastScale = 111_320.0 * cos(start.latitude * .pi / 180)
    let northScale = 110_540.0
    let px = (point.longitude - start.longitude) * eastScale
    let py = (point.latitude - start.latitude) * northScale
    let ex = (end.longitude - start.longitude) * eastScale
    let ey = (end.latitude - start.latitude) * northScale
    let length = hypot(ex, ey)
    guard length > 0, length.isFinite else { return distance(point, start) }
    return abs(px * ey - py * ex) / length
  }
}
