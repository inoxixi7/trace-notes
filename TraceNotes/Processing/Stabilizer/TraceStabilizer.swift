import CoreLocation
import Foundation

/// Removes GPS drift, spikes and short excursions from one move before it is drawn (D34,
/// ARCHITECTURE §5.1 ②). Migrated from the legacy `TraceStabilizer` (LEGACY_INVENTORY §3) with
/// its tuned values and decision rules unchanged.
///
/// The legacy type was a live state machine that held the whole recording session and copied it on
/// every sample (LEGACY_INVENTORY §4.2). Here it is one pass over a single move segment, the way the
/// track processor re-derives segments (§5.2): the working set is that move, never the day, and there
/// is no per-sample path left. The pass is linear (10 800 points in 0.18 s, Debug build, simulator).
nonisolated enum TraceStabilizer {
  private struct DerivedPoint: Equatable, Sendable {
    var decision: TraceDecision
    var displayCoordinate: TraceCoordinate?
  }

  private struct Derivation: Sendable {
    let points: [DerivedPoint]
    let state: MotionState
    let stationaryAnchor: TraceCoordinate?
    let stationaryIndices: [Int]
    let candidateRun: [Int]
    let pendingPromotion: [Int]
    let resumeRun: [Int]
    let confirmedDistanceMeters: CLLocationDistance
    let rawDistanceMeters: CLLocationDistance
    let provisionalDistanceDiscardedMeters: CLLocationDistance
    let multiPointExcursionCount: Int
    let excursionSuppressedPointCount: Int
    let excursionSuppressedDistanceMeters: CLLocationDistance
    let maximumLateralDeviationMeters: CLLocationDistance
  }

  private struct StationaryCluster: Sendable {
    let indices: [Int]
    let anchor: TraceCoordinate
  }

  /// The points the stabilizer was tuned on: each at least `minimumInputSpacingMeters` from the
  /// previous one kept, as the legacy app's location delivery did. Raw points are not changed.
  static func spaced(_ locations: [RawPoint], configuration: TraceStabilizerConfiguration = .default) -> [RawPoint] {
    var kept: [RawPoint] = []
    var last: CLLocation?
    for location in locations {
      let here = CLLocation(latitude: location.latitude, longitude: location.longitude)
      if let last, here.distance(from: last) < configuration.minimumInputSpacingMeters { continue }
      kept.append(location)
      last = here
    }
    return kept
  }

  /// One pass over a move's points, oldest first. `finalize` is true for a completed move (D34 ③):
  /// points still undecided are then resolved, as the legacy session end did; while the move is
  /// open they stay provisional and are drawn (D34 ④).
  static func stabilize(
    _ locations: [RawPoint],
    finalize: Bool,
    configuration: TraceStabilizerConfiguration = .default
  ) -> StabilizedTrace {
    let derivation = derive(locations, configuration: configuration, finalize: finalize)
    return StabilizedTrace(
      state: derivation.state,
      points: zip(locations, derivation.points).map { location, point in
        TracePointUpdate(recordedAt: location.timestamp, decision: point.decision, displayCoordinate: point.displayCoordinate)
      },
      stationaryAnchor: derivation.stationaryAnchor,
      confirmedDistanceMeters: derivation.confirmedDistanceMeters,
      rawDistanceMeters: derivation.rawDistanceMeters,
      provisionalDistanceDiscardedMeters: derivation.provisionalDistanceDiscardedMeters,
      multiPointExcursionCount: derivation.multiPointExcursionCount,
      excursionSuppressedPointCount: derivation.excursionSuppressedPointCount,
      excursionSuppressedDistanceMeters: derivation.excursionSuppressedDistanceMeters,
      maximumLateralDeviationMeters: derivation.maximumLateralDeviationMeters)
  }

  // MARK: - Derivation

  private static func derive(
    _ locations: [RawPoint],
    configuration: TraceStabilizerConfiguration,
    finalize: Bool
  ) -> Derivation {
    guard !locations.isEmpty else {
      return Derivation(
        points: [],
        state: .uncertain,
        stationaryAnchor: nil,
        stationaryIndices: [],
        candidateRun: [],
        pendingPromotion: [],
        resumeRun: [],
        confirmedDistanceMeters: 0,
        rawDistanceMeters: 0,
        provisionalDistanceDiscardedMeters: 0,
        multiPointExcursionCount: 0,
        excursionSuppressedPointCount: 0,
        excursionSuppressedDistanceMeters: 0,
        maximumLateralDeviationMeters: 0
      )
    }

    var points: [DerivedPoint]
    var motionState: MotionState
    var stationaryAnchor: TraceCoordinate?
    var stationaryIndices: [Int]
    var candidateRun: [Int]
    var pendingPromotion: [Int]
    var resumeRun: [Int]
    var multiPointExcursionCount: Int
    var excursionSuppressedPointCount: Int
    var excursionSuppressedDistanceMeters: CLLocationDistance
    var maximumLateralDeviationMeters: CLLocationDistance

    points = locations.map { location in
      DerivedPoint(
        decision: .provisional,
        displayCoordinate: validCoordinate(for: location)
      )
    }
    motionState = .uncertain
    stationaryAnchor = nil
    stationaryIndices = []
    candidateRun = []
    pendingPromotion = []
    resumeRun = []
    multiPointExcursionCount = 0
    excursionSuppressedPointCount = 0
    excursionSuppressedDistanceMeters = 0
    maximumLateralDeviationMeters = 0

    for index in locations.indices {
      guard validCoordinate(for: locations[index]) != nil,
        locations[index].timestamp.timeIntervalSince1970.isFinite,
        locations[index].horizontalAccuracy.isFinite,
        locations[index].horizontalAccuracy >= 0
      else {
        points[index] = DerivedPoint(decision: .suppressed, displayCoordinate: nil)
        motionState = .uncertain
        stationaryIndices.removeAll(keepingCapacity: true)
        candidateRun.removeAll(keepingCapacity: true)
        pendingPromotion.removeAll(keepingCapacity: true)
        resumeRun.removeAll(keepingCapacity: true)
        continue
      }

      if index == 0 {
        candidateRun = [index]
        continue
      }

      let interval = locations[index].timestamp.timeIntervalSince(
        locations[index - 1].timestamp
      )
      guard interval > 0, interval.isFinite else {
        points[index] = DerivedPoint(decision: .suppressed, displayCoordinate: nil)
        motionState = .uncertain
        stationaryIndices.removeAll(keepingCapacity: true)
        candidateRun.removeAll(keepingCapacity: true)
        pendingPromotion.removeAll(keepingCapacity: true)
        resumeRun.removeAll(keepingCapacity: true)
        continue
      }

      // A large gap is a hard continuity boundary.  It is still a canonical
      // sample, but no display segment or movement confirmation may cross it.
      if interval > configuration.maximumTimestampGapSeconds {
        motionState = .uncertain
        stationaryIndices.removeAll(keepingCapacity: true)
        candidateRun = [index]
        pendingPromotion.removeAll(keepingCapacity: true)
        resumeRun.removeAll(keepingCapacity: true)
        points[index] = DerivedPoint(
          decision: .provisional,
          displayCoordinate: validCoordinate(for: locations[index])
        )
        continue
      }

      let cluster = stationaryClusterEnding(
        at: index,
        in: locations,
        configuration: configuration
      )

      if motionState == .stationary, let currentAnchor = stationaryAnchor {
        if progressesFromStationary(
          index: index,
          anchor: currentAnchor,
          previousResumeIndices: resumeRun,
          locations: locations,
          configuration: configuration
        ) {
          resumeRun.append(index)
          points[index] = DerivedPoint(decision: .suppressed, displayCoordinate: nil)
          if resumeRun.count >= configuration.movementConfirmationCount {
            motionState = .moving
            stationaryAnchor = nil
            candidateRun = resumeRun
            pendingPromotion.removeAll(keepingCapacity: true)
            for promotedIndex in resumeRun {
              points[promotedIndex] = DerivedPoint(
                decision: .confirmed,
                displayCoordinate: validCoordinate(for: locations[promotedIndex])
              )
            }
            resumeRun.removeAll(keepingCapacity: true)
            stationaryIndices.removeAll(keepingCapacity: true)
          }
        } else {
          resumeRun.removeAll(keepingCapacity: true)
          if let cluster {
            stationaryIndices = cluster.indices
          }
          points[index] = DerivedPoint(decision: .suppressed, displayCoordinate: nil)
        }
        continue
      }

      // Detect a stationary cloud before treating its individual chords as a
      // route.  The cluster helper returns only a suffix, preserving the
      // confirmed route leading into a stop.
      if let cluster {
        motionState = .stationary
        stationaryAnchor = cluster.anchor
        stationaryIndices = cluster.indices
        candidateRun.removeAll(keepingCapacity: true)
        pendingPromotion.removeAll(keepingCapacity: true)
        resumeRun.removeAll(keepingCapacity: true)
        for clusterIndex in cluster.indices {
          points[clusterIndex] = DerivedPoint(
            decision: .suppressed,
            displayCoordinate: nil
          )
        }
        continue
      }

      // A three-point reversal is an isolated GPS jump rather than a route.
      // This is intentionally stricter than a normal corner: a real turn is
      // retained when both legs have a positive forward projection, while an
      // out-and-back leg reverses its projection and is suppressed.
      if isIsolatedReversal(
        at: index,
        in: locations,
        configuration: configuration
      ) {
        let jumpedIndex = index - 1
        let hasStrongRealTurnEvidence = {
          let accuracy = locations[jumpedIndex].horizontalAccuracy
          let hasGoodAccuracy =
            accuracy.isFinite
            && accuracy <= configuration.goodAccuracyMeters
          let hasSpeed =
            locations[jumpedIndex].speed.map {
              $0.isFinite
                && $0 >= configuration.movementSpeedEvidenceMetersPerSecond
            } ?? false
          let hasCourse =
            locations[jumpedIndex].course.map { $0.isFinite }
            ?? false
          return hasGoodAccuracy && hasSpeed && hasCourse
        }()

        if hasStrongRealTurnEvidence {
          if motionState == .uncertain {
            // The normal movement hysteresis has not filled yet, but a
            // precise point with coherent speed/course is enough to preserve
            // the incoming leg of a genuine U-turn. The reverse leg remains
            // provisional until subsequent samples confirm it.
            motionState = .moving
            for candidateIndex in candidateRun {
              points[candidateIndex] = DerivedPoint(
                decision: .confirmed,
                displayCoordinate: validCoordinate(for: locations[candidateIndex])
              )
            }
          }
          pendingPromotion = [index]
        }

        // Keep the rejection provisional until the session boundary.  This
        // lets persistence observe the final suppression as a normal
        // retroactive decision change while still guaranteeing that the
        // isolated jump never reaches confirmed geometry.
        // Never demote an already confirmed vertex. A real walk can make a
        // U-turn; retaining the confirmed incoming leg lets the following
        // coherent samples prove that the reversal was genuine. Only an
        // unresolved incoming point remains provisional and can be discarded
        // when the excursion returns to its baseline.
        if points[jumpedIndex].decision != .confirmed {
          points[jumpedIndex] = DerivedPoint(
            decision: .provisional,
            displayCoordinate: validCoordinate(for: locations[jumpedIndex])
          )
        }
        points[index] = DerivedPoint(
          decision: .provisional,
          displayCoordinate: validCoordinate(for: locations[index])
        )
        candidateRun = [index]
        if !hasStrongRealTurnEvidence {
          pendingPromotion.removeAll(keepingCapacity: true)
        }
        resumeRun.removeAll(keepingCapacity: true)
        if motionState == .moving && !hasStrongRealTurnEvidence {
          // A single contradictory chord should not erase previously
          // confirmed geometry, but the conflicting pair is not confirmed.
          motionState = .uncertain
        }
        continue
      }

      let movementStep = isMovementStep(
        from: index - 1,
        to: index,
        in: locations,
        configuration: configuration
      )

      if movementStep {
        if candidateRun.isEmpty || candidateRun.last != index - 1 {
          candidateRun = [index - 1]
        }
        candidateRun.append(index)
        if candidateRun.count > configuration.maximumWindowPoints {
          candidateRun.removeFirst(
            candidateRun.count - configuration.maximumWindowPoints
          )
        }
      } else {
        candidateRun = [index]
      }

      let coherent = coherentMovement(
        candidateRun,
        in: locations,
        configuration: configuration
      )

      switch motionState {
      case .uncertain:
        guard coherent else {
          points[index] = DerivedPoint(
            decision: .provisional,
            displayCoordinate: validCoordinate(for: locations[index])
          )
          continue
        }

        if candidateRun.count >= configuration.movementConfirmationCount {
          motionState = .moving
          pendingPromotion.removeAll(keepingCapacity: true)
          for promotedIndex in candidateRun {
            points[promotedIndex] = DerivedPoint(
              decision: .confirmed,
              displayCoordinate: validCoordinate(for: locations[promotedIndex])
            )
          }
        } else {
          points[index] = DerivedPoint(
            decision: .provisional,
            displayCoordinate: validCoordinate(for: locations[index])
          )
        }

      case .moving:
        guard coherent else {
          points[index] = DerivedPoint(
            decision: .provisional,
            displayCoordinate: validCoordinate(for: locations[index])
          )
          if pendingPromotion.isEmpty {
            pendingPromotion = [index]
          } else {
            pendingPromotion.append(index)
          }
          if pendingPromotion.count > configuration.maximumWindowPoints {
            pendingPromotion.removeFirst(
              pendingPromotion.count - configuration.maximumWindowPoints
            )
          }
          continue
        }

        let accuracy = locations[index].horizontalAccuracy
        let degraded = !accuracy.isFinite || accuracy > configuration.goodAccuracyMeters
        if degraded {
          points[index] = DerivedPoint(
            decision: .provisional,
            displayCoordinate: validCoordinate(for: locations[index])
          )
          if pendingPromotion.isEmpty {
            pendingPromotion = [index]
          } else {
            pendingPromotion.append(index)
          }
          if pendingPromotion.count > configuration.maximumWindowPoints {
            pendingPromotion.removeFirst(
              pendingPromotion.count - configuration.maximumWindowPoints
            )
          }
        } else if pendingPromotion.isEmpty {
          points[index] = DerivedPoint(
            decision: .confirmed,
            displayCoordinate: validCoordinate(for: locations[index])
          )
        } else {
          pendingPromotion.append(index)
        }

        if pendingPromotion.count >= configuration.movementConfirmationCount {
          for promotedIndex in pendingPromotion {
            points[promotedIndex] = DerivedPoint(
              decision: .confirmed,
              displayCoordinate: validCoordinate(for: locations[promotedIndex])
            )
          }
          pendingPromotion.removeAll(keepingCapacity: true)
        }

      case .stationary:
        // The stationary case is handled above, but retaining this branch
        // keeps the state machine exhaustive if its ordering changes later.
        points[index] = DerivedPoint(decision: .suppressed, displayCoordinate: nil)
      }
    }

    // A short weak-evidence block can leave the local confirmed corridor for
    // several samples and then return before the stationary window fills. Run
    // the pure excursion analysis after normal motion classification so it can
    // retroactively retract that block without touching canonical GPS data.
    let excursion = TraceExcursionDetector.analyze(
      locations: locations,
      decisions: points.map { $0.decision },
      configuration: configuration,
      scanFrom: 0
    )
    if excursion.detected {
      // Count only points not already suppressed by motion classification.
      let newlySuppressed = excursion.suppressedIndices.filter {
        points[$0].decision != .suppressed
      }
      if !newlySuppressed.isEmpty {
        multiPointExcursionCount += excursion.excursionCount
        excursionSuppressedPointCount += newlySuppressed.count
        excursionSuppressedDistanceMeters += excursion.pathLengthMeters
        maximumLateralDeviationMeters = max(
          maximumLateralDeviationMeters,
          excursion.maximumLateralDeviationMeters
        )
      }
      for index in excursion.suppressedIndices {
        points[index] = DerivedPoint(decision: .suppressed, displayCoordinate: nil)
      }
      pendingPromotion.removeAll { excursion.suppressedIndices.contains($0) }
      candidateRun.removeAll { excursion.suppressedIndices.contains($0) }
      resumeRun.removeAll { excursion.suppressedIndices.contains($0) }
    }

    if finalize, motionState == .uncertain,
      candidateRun.count >= 2,
      coherentMovement(
        candidateRun,
        in: locations,
        configuration: configuration
      )
    {
      // A short recording can legitimately end before the normal movement
      // hysteresis window fills. Promote only a coherent forward run; the
      // reversal/out-and-back guard above keeps an isolated GPS excursion
      // suppressed at the session boundary.
      motionState = .moving
      for index in candidateRun {
        points[index] = DerivedPoint(
          decision: .confirmed,
          displayCoordinate: validCoordinate(for: locations[index])
        )
      }
    }

    if finalize {
      for index in points.indices where points[index].decision == .provisional {
        points[index] = DerivedPoint(decision: .suppressed, displayCoordinate: nil)
      }
    }

    // Recompute local display coordinates only after decisions have settled so
    // retroactive promotion/rejection and smoothing remain deterministic.
    smoothConfirmedPoints(&points, locations: locations, configuration: configuration, affectedStartIndex: 0)

    let confirmedDistance = distance(of: confirmedRuns(from: points, locations: locations, configuration: configuration))
    let rawDistance = Self.rawDistance(in: locations, configuration: configuration)
    let provisionalDiscardedDistance = provisionalDistanceContribution(
      in: points, locations: locations, configuration: configuration, from: 0)

    return Derivation(
      points: points,
      state: motionState,
      stationaryAnchor: stationaryAnchor,
      stationaryIndices: stationaryIndices,
      candidateRun: candidateRun,
      pendingPromotion: pendingPromotion,
      resumeRun: resumeRun,
      confirmedDistanceMeters: confirmedDistance,
      rawDistanceMeters: rawDistance,
      provisionalDistanceDiscardedMeters: provisionalDiscardedDistance,
      multiPointExcursionCount: multiPointExcursionCount,
      excursionSuppressedPointCount: excursionSuppressedPointCount,
      excursionSuppressedDistanceMeters: excursionSuppressedDistanceMeters,
      maximumLateralDeviationMeters: maximumLateralDeviationMeters
    )
  }

  // MARK: - Stationary detection

  private static func stationaryClusterEnding(
    at end: Int,
    in locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> StationaryCluster? {
    guard end >= 0 else { return nil }
    let earliest = max(0, end - configuration.maximumWindowPoints + 1)
    guard earliest <= end else { return nil }

    for start in earliest...end {
      let indices = Array(start...end)
      guard indices.count >= configuration.minimumWindowPoints else { continue }
      guard let first = locations[safe: start],
        let last = locations[safe: end]
      else { continue }
      let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
      guard elapsed >= configuration.minimumWindowDurationSeconds,
        elapsed <= configuration.maximumWindowDurationSeconds
      else { continue }

      var contiguous = true
      for pair in zip(indices, indices.dropFirst()) {
        let interval = locations[pair.1].timestamp.timeIntervalSince(
          locations[pair.0].timestamp
        )
        if interval <= 0 || interval > configuration.maximumTimestampGapSeconds {
          contiguous = false
          break
        }
      }
      guard contiguous else { continue }

      // A reported walking/transit speed is positive movement evidence.  Do
      // not let a preceding moving sample be absorbed into the stationary
      // suffix merely because its coordinate happens to be close to the
      // eventual anchor.
      let containsSustainedSpeed = indices.contains { pointIndex in
        guard let speed = locations[pointIndex].speed else { return false }
        return speed.isFinite && speed >= configuration.movementSpeedEvidenceMetersPerSecond
      }
      guard !containsSustainedSpeed else { continue }

      guard
        let anchor = accuracyWeightedAnchor(
          indices: indices,
          locations: locations
        )
      else { continue }

      let representativeAccuracy = medianAccuracy(
        indices: indices,
        locations: locations,
        fallback: configuration.goodAccuracyMeters
      )
      let radius = configuration.stationaryRadius(for: representativeAccuracy)
      guard
        indices.allSatisfy({ pointIndex in
          guard let coordinate = validCoordinate(for: locations[pointIndex])
          else { return false }
          return distance(anchor, coordinate) <= radius
        })
      else { continue }

      guard let firstCoordinate = validCoordinate(for: first),
        let lastCoordinate = validCoordinate(for: last)
      else { continue }
      let netDisplacement = distance(firstCoordinate, lastCoordinate)
      let netLimit = configuration.stationaryNetDisplacement(
        for: representativeAccuracy
      )
      guard netDisplacement <= netLimit else { continue }

      var path = 0.0
      for pair in zip(indices, indices.dropFirst()) {
        guard let from = validCoordinate(for: locations[pair.0]),
          let to = validCoordinate(for: locations[pair.1])
        else {
          path = .infinity
          break
        }
        path += distance(from, to)
      }
      let ratio: Double
      if netDisplacement < 1 {
        ratio = path > 0 ? .infinity : 1
      } else {
        ratio = path / netDisplacement
      }
      // A perfectly still device can produce repeated identical coordinates,
      // for which path/net is 0/0 rather than a useful jitter ratio.  The
      // bounded-cluster and low-net checks are already sufficient evidence in
      // that case; require the ratio only when the window has material path.
      let hasJitterPath = path > max(1, netLimit * 0.25)
      guard !hasJitterPath || ratio >= configuration.jitterPathToNetRatio
      else { continue }

      return StationaryCluster(indices: indices, anchor: anchor)
    }
    return nil
  }

  private static func medianAccuracy(
    indices: [Int],
    locations: [RawPoint],
    fallback: CLLocationAccuracy
  ) -> CLLocationAccuracy {
    let values =
      indices
      .map { locations[$0].horizontalAccuracy }
      .filter { $0.isFinite && $0 >= 0 }
      .sorted()
    guard !values.isEmpty else { return fallback }
    let middle = values.count / 2
    if values.count.isMultiple(of: 2) {
      return (values[middle - 1] + values[middle]) / 2
    }
    return values[middle]
  }

  private static func accuracyWeightedAnchor(
    indices: [Int],
    locations: [RawPoint]
  ) -> TraceCoordinate? {
    guard !indices.isEmpty else { return nil }
    var bestIndex = indices[0]
    var bestScore = Double.infinity
    for candidateIndex in indices {
      guard let candidate = validCoordinate(for: locations[candidateIndex])
      else { continue }
      var score = 0.0
      for otherIndex in indices where otherIndex != candidateIndex {
        guard let other = validCoordinate(for: locations[otherIndex]) else {
          score = .infinity
          break
        }
        let accuracy = locations[otherIndex].horizontalAccuracy
        let finiteAccuracy = accuracy.isFinite ? max(1, accuracy) : 100
        let weight = 1 / (finiteAccuracy * finiteAccuracy)
        score += distance(candidate, other) * weight
      }
      if score < bestScore {
        bestScore = score
        bestIndex = candidateIndex
      }
    }
    return validCoordinate(for: locations[bestIndex])
  }

  private static func progressesFromStationary(
    index: Int,
    anchor: TraceCoordinate,
    previousResumeIndices: [Int],
    locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> Bool {
    guard index > 0,
      let current = validCoordinate(for: locations[index]),
      let previous = validCoordinate(for: locations[index - 1])
    else { return false }
    let interval = locations[index].timestamp.timeIntervalSince(
      locations[index - 1].timestamp
    )
    guard interval > 0, interval <= configuration.maximumTimestampGapSeconds
    else { return false }

    let fromAnchor = distance(anchor, current)
    let adaptiveLimit = max(
      8,
      configuration.stationaryNetDisplacement(for: locations[index].horizontalAccuracy)
    )
    guard fromAnchor > adaptiveLimit else { return false }

    let step = distance(previous, current)
    guard
      step
        >= movementDistanceThreshold(
          for: locations[index],
          configuration: configuration
        )
    else { return false }

    let inferredSpeed = step / interval
    let speedEvidence =
      locations[index].speed.flatMap { speed in
        speed.isFinite && speed >= 0 ? speed : nil
      } ?? inferredSpeed
    guard speedEvidence >= configuration.movementSpeedEvidenceMetersPerSecond
    else { return false }

    if let lastResume = previousResumeIndices.last,
      let lastCoordinate = validCoordinate(for: locations[lastResume])
    {
      let previousDistance = distance(anchor, lastCoordinate)
      let requiredProgress = max(2, adaptiveLimit * 0.35)
      guard fromAnchor >= previousDistance + requiredProgress else {
        return false
      }
      if previousResumeIndices.count >= 2,
        let beforeLast = previousResumeIndices.dropLast().last,
        let beforeCoordinate = validCoordinate(for: locations[beforeLast])
      {
        let incoming = bearing(from: beforeCoordinate, to: lastCoordinate)
        let outgoing = bearing(from: lastCoordinate, to: current)
        let course = locations[index].course
        let directionDifference = angleDifference(incoming, outgoing)
        let courseDifference = course.map {
          angleDifference(outgoing, normalizedBearing($0))
        }
        guard directionDifference <= 75 || (courseDifference ?? 180) <= 75
        else { return false }
      }
    }

    return true
  }

  // MARK: - Movement/rejection

  private static func isMovementStep(
    from firstIndex: Int,
    to secondIndex: Int,
    in locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> Bool {
    guard firstIndex >= 0, secondIndex < locations.count,
      let first = validCoordinate(for: locations[firstIndex]),
      let second = validCoordinate(for: locations[secondIndex])
    else { return false }
    let interval = locations[secondIndex].timestamp.timeIntervalSince(
      locations[firstIndex].timestamp
    )
    guard interval > 0, interval <= configuration.maximumTimestampGapSeconds
    else { return false }
    let step = distance(first, second)
    let threshold = max(
      movementDistanceThreshold(
        for: locations[firstIndex],
        configuration: configuration
      ),
      movementDistanceThreshold(
        for: locations[secondIndex],
        configuration: configuration
      )
    )
    guard step >= threshold else { return false }

    let inferredSpeed = step / interval
    let suppliedSpeed = locations[secondIndex].speed.flatMap { speed in
      speed.isFinite && speed >= 0 ? speed : nil
    }
    return max(inferredSpeed, suppliedSpeed ?? 0)
      >= configuration.movementSpeedEvidenceMetersPerSecond
  }

  private static func movementDistanceThreshold(
    for location: RawPoint,
    configuration: TraceStabilizerConfiguration
  ) -> CLLocationDistance {
    let accuracy =
      location.horizontalAccuracy.isFinite
      ? max(1, location.horizontalAccuracy)
      : configuration.goodAccuracyMeters
    // GPS movement below a few metres is not useful as a route vertex, while
    // degraded accuracy should not make genuine transit impossible to confirm.
    return max(3, min(12, accuracy * 0.5))
  }

  private static func coherentMovement(
    _ indices: [Int],
    in locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> Bool {
    guard indices.count >= 2,
      let firstIndex = indices.first,
      let lastIndex = indices.last,
      let first = validCoordinate(for: locations[firstIndex]),
      let last = validCoordinate(for: locations[lastIndex])
    else { return false }

    let net = distance(first, last)
    let strongEvidence = indices.dropFirst().allSatisfy { locationIndex in
      let sample = locations[locationIndex]
      let accuracyIsGood =
        sample.horizontalAccuracy.isFinite
        && sample.horizontalAccuracy <= configuration.goodAccuracyMeters
      let speedIsCredible =
        sample.speed.map {
          $0.isFinite
            && $0 >= configuration.movementSpeedEvidenceMetersPerSecond
        } ?? false
      return accuracyIsGood && speedIsCredible
    }
    let minimumNet = max(
      8,
      min(
        25,
        configuration.goodAccuracyMeters * 0.5
      )
    )
    guard net >= minimumNet || strongEvidence else { return false }

    var path = 0.0
    var legBearings: [Double] = []
    for pair in zip(indices, indices.dropFirst()) {
      guard let from = validCoordinate(for: locations[pair.0]),
        let to = validCoordinate(for: locations[pair.1])
      else { return false }
      let leg = distance(from, to)
      path += leg
      guard leg > 0 else { return false }
      legBearings.append(bearing(from: from, to: to))
    }
    guard path > 0 else { return false }

    let pathToNetRatio = net > 0 ? path / net : .infinity
    if pathToNetRatio > configuration.jitterPathToNetRatio {
      // A high-quality, speed-backed sequence can legitimately close a loop
      // or make a U-turn.  The path/net ratio is therefore only a jitter
      // signal when evidence is weak; it must never be a stand-alone reason
      // to reject a real excursion.  Keep the geometric heading guard below
      // so a precise sequence with a genuine reversal still goes through the
      // dedicated U-turn handling above.
      guard strongEvidence else { return false }
    }

    let overallBearing = net > 0 ? bearing(from: first, to: last) : nil
    for (offset, legBearing) in legBearings.enumerated() {
      let locationIndex = indices[offset + 1]
      if let course = locations[locationIndex].course,
        course.isFinite
      {
        // Core Location courses are degrees clockwise from north.
        guard angleDifference(legBearing, normalizedBearing(course)) <= 80
        else { return false }
      } else {
        // A gradual/90-degree turn remains forward progress.  A reversal is
        // rejected separately and cannot pass this projection check.
        if !strongEvidence {
          guard let overallBearing,
            angleDifference(legBearing, overallBearing) <= 105
          else { return false }
        }
      }
    }

    for pair in zip(legBearings, legBearings.dropFirst()) {
      guard angleDifference(pair.0, pair.1) < 135 else { return false }
    }
    return true
  }

  private static func isIsolatedReversal(
    at index: Int,
    in locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> Bool {
    guard index >= 2,
      isMovementStep(
        from: index - 2,
        to: index - 1,
        in: locations,
        configuration: configuration
      ),
      isMovementStep(
        from: index - 1,
        to: index,
        in: locations,
        configuration: configuration
      ),
      let before = validCoordinate(for: locations[index - 2]),
      let jumped = validCoordinate(for: locations[index - 1]),
      let after = validCoordinate(for: locations[index])
    else { return false }

    let incoming = bearing(from: before, to: jumped)
    let outgoing = bearing(from: jumped, to: after)
    let reversal = angleDifference(incoming, outgoing)
    guard reversal >= 135 else { return false }

    let baselineReturn = distance(before, after)
    let jump = distance(before, jumped)
    return baselineReturn <= max(5, jump * 0.15)
  }

  // MARK: - Display and metrics

  private static func smoothConfirmedPoints(
    _ points: inout [DerivedPoint],
    locations: [RawPoint],
    configuration: TraceStabilizerConfiguration,
    affectedStartIndex: Int = 0
  ) {
    guard points.count >= 3 else { return }
    let firstIndex = max(1, affectedStartIndex)
    let lastIndex = points.count - 2
    guard firstIndex <= lastIndex else { return }
    for index in firstIndex...lastIndex {
      guard points[index - 1].decision == .confirmed,
        points[index].decision == .confirmed,
        points[index + 1].decision == .confirmed,
        // Always smooth from canonical coordinates, never from the previous
        // derived display values. Live updates revisit a bounded suffix on
        // every callback; using already-smoothed neighbors would compound the
        // filter over time and make incremental processing diverge from a
        // deterministic full replay.
        let previous = validCoordinate(for: locations[index - 1]),
        let current = validCoordinate(for: locations[index]),
        let next = validCoordinate(for: locations[index + 1])
      else { continue }

      let incoming = distance(previous, current)
      let outgoing = distance(current, next)
      guard incoming > 0, outgoing > 0 else { continue }
      let incomingBearing = bearing(from: previous, to: current)
      let outgoingBearing = bearing(from: current, to: next)
      var headingChange = angleDifference(incomingBearing, outgoingBearing)
      // Raw GPS vertices can oscillate around a straight walking course.  A
      // supplied Core Location course is stronger evidence of the traveller's
      // heading than that lateral noise; use it to distinguish such a run
      // from a genuine corner.  At a real turn the adjacent course values
      // still differ, so the vertex remains untouched.
      if let previousCourse = locations[index].course,
        let nextCourse = locations[index + 1].course,
        previousCourse.isFinite,
        nextCourse.isFinite
      {
        headingChange = min(
          headingChange,
          angleDifference(
            normalizedBearing(previousCourse),
            normalizedBearing(nextCourse)
          )
        )
      }
      let currentAccuracy = locations[index].horizontalAccuracy
      let currentAccuracyIsDegraded =
        !currentAccuracy.isFinite
        || currentAccuracy > configuration.goodAccuracyMeters
      if incoming >= configuration.turnLegMinimumMeters,
        outgoing >= configuration.turnLegMinimumMeters,
        headingChange >= configuration.turnAngleThresholdDegrees,
        !currentAccuracyIsDegraded
      {
        continue
      }

      let temporalWeights = [
        configuration.smoothingPreviousWeight,
        configuration.smoothingCurrentWeight,
        configuration.smoothingNextWeight,
      ]
      let coordinates = [previous, current, next]
      let accuracies = [
        locations[index - 1].horizontalAccuracy,
        locations[index].horizontalAccuracy,
        locations[index + 1].horizontalAccuracy,
      ]
      var latitude = 0.0
      var longitude = 0.0
      var totalWeight = 0.0
      for offset in 0..<3 {
        let accuracy =
          accuracies[offset].isFinite
          ? max(1, accuracies[offset])
          : 100
        let weight = temporalWeights[offset] / (accuracy * accuracy)
        guard weight.isFinite else { continue }
        latitude += coordinates[offset].latitude * weight
        longitude += coordinates[offset].longitude * weight
        totalWeight += weight
      }
      guard totalWeight > 0,
        let smoothed = TraceCoordinate(
          validatingLatitude: latitude / totalWeight,
          longitude: longitude / totalWeight
        )
      else { continue }
      points[index].displayCoordinate = smoothed
    }
  }

  /// Runs of consecutive confirmed points, split at suppressed points and timestamp gaps, for the
  /// confirmed distance.
  private static func confirmedRuns(
    from points: [DerivedPoint],
    locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> [[TraceCoordinate]] {
    var runs: [[TraceCoordinate]] = []
    var run: [TraceCoordinate] = []
    for index in points.indices {
      guard points[index].decision == .confirmed, let coordinate = points[index].displayCoordinate else {
        if run.count >= 2 { runs.append(run) }
        run.removeAll(keepingCapacity: true)
        continue
      }
      let interval = index > 0 ? locations[index].timestamp.timeIntervalSince(locations[index - 1].timestamp) : 0
      let connected = index > 0 && points[index - 1].decision == .confirmed && interval > 0
        && interval <= configuration.maximumTimestampGapSeconds
      if !connected {
        if run.count >= 2 { runs.append(run) }
        run.removeAll(keepingCapacity: true)
      }
      run.append(coordinate)
    }
    if run.count >= 2 { runs.append(run) }
    return runs
  }

  private static func distance(of segments: [[TraceCoordinate]]) -> Double {
    var total = 0.0
    for segment in segments {
      for pair in zip(segment, segment.dropFirst()) {
        total += distance(pair.0, pair.1)
      }
    }
    return total.isFinite ? total : 0
  }

  /// Distance contribution of a decision suffix. A live append can only
  /// revise this bounded region; the confirmed prefix is already represented
  /// by the prior accumulator value.
  private static func rawDistance(
    in locations: [RawPoint],
    configuration: TraceStabilizerConfiguration
  ) -> CLLocationDistance {
    guard locations.count >= 2 else { return 0 }
    var total = 0.0
    for index in locations.indices.dropFirst() {
      guard let previous = validCoordinate(for: locations[index - 1]),
        let current = validCoordinate(for: locations[index])
      else { continue }
      let interval = locations[index].timestamp.timeIntervalSince(
        locations[index - 1].timestamp
      )
      guard interval > 0, interval.isFinite else { continue }
      // Raw diagnostics retain the chord even over a gap; only display and
      // confirmed metrics enforce the continuity boundary.
      total += distance(previous, current)
    }
    return total.isFinite ? total : 0
  }

  private static func provisionalDistanceContribution(
    in points: [DerivedPoint],
    locations: [RawPoint],
    configuration: TraceStabilizerConfiguration,
    from startIndex: Int
  ) -> CLLocationDistance {
    guard locations.count >= 2, points.count == locations.count else { return 0 }
    var total = 0.0
    let firstIndex = max(1, startIndex)
    guard firstIndex < locations.count else { return 0 }
    for index in firstIndex..<locations.count {
      guard let previous = validCoordinate(for: locations[index - 1]),
        let current = validCoordinate(for: locations[index]),
        points[index - 1].decision != .confirmed || points[index].decision != .confirmed
      else { continue }
      let interval = locations[index].timestamp.timeIntervalSince(
        locations[index - 1].timestamp
      )
      guard interval > 0, interval <= configuration.maximumTimestampGapSeconds
      else { continue }
      total += distance(previous, current)
    }
    return total.isFinite ? total : 0
  }

  // MARK: - Geographic helpers

  private static func validCoordinate(
    for location: RawPoint
  ) -> TraceCoordinate? {
    TraceCoordinate(
      validatingLatitude: location.latitude,
      longitude: location.longitude
    )
  }

  private static func distance(
    _ lhs: TraceCoordinate,
    _ rhs: TraceCoordinate
  ) -> CLLocationDistance {
    CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
      .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
  }

  private static func bearing(
    from lhs: TraceCoordinate,
    to rhs: TraceCoordinate
  ) -> Double {
    let lat1 = lhs.latitude * .pi / 180
    let lat2 = rhs.latitude * .pi / 180
    let deltaLongitude = (rhs.longitude - lhs.longitude) * .pi / 180
    let y = sin(deltaLongitude) * cos(lat2)
    let x =
      cos(lat1) * sin(lat2)
      - sin(lat1) * cos(lat2) * cos(deltaLongitude)
    return normalizedBearing(atan2(y, x) * 180 / .pi)
  }

  private static func normalizedBearing(_ bearing: Double) -> Double {
    let result = bearing.truncatingRemainder(dividingBy: 360)
    return result >= 0 ? result : result + 360
  }

  private static func angleDifference(_ lhs: Double, _ rhs: Double) -> Double {
    let difference = abs((lhs - rhs).truncatingRemainder(dividingBy: 360))
    return min(difference, 360 - difference)
  }
}

extension Array {
  nonisolated fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
