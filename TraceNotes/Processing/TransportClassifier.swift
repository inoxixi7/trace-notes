import Foundation

/// Pipeline step ④ (ARCHITECTURE §5.1), VS4: decides the transport mode of a move and splits it
/// where the mode changes for long enough. Pure and deterministic.
///
/// Rules (PRODUCT F4, D36):
/// - Each usable point gets a mode from the newest Motion & Fitness reading at or before it when
///   that reading is a movement, otherwise from the median speed of the points within
///   `speedWindow` of it. Speed alone: below 7 km/h walking, below 30 km/h cycling, else car.
///   Running is only ever reported by the sensor.
/// - Speed overrules the sensor where they cannot both be right: above 200 km/h is a train, above
///   300 km/h a plane, and a walking, running or cycling reading above 30 km/h is ignored.
/// - A car and a train look the same to the sensor (both "automotive"): the car is assumed and the
///   user corrects it (D36). The subway is never chosen automatically.
/// - Runs of one mode shorter than `minimumRun` join their longer neighbour, so a red light or a
///   few steps from the car park stay inside the trip.
nonisolated enum TransportClassifier {
  struct Parameters: Sendable {
    /// Shortest change of mode that becomes its own row in the timeline (D36).
    var minimumRun: TimeInterval = 300
    /// Half-width of the window whose median speed labels a point.
    var speedWindow: TimeInterval = 60
    /// km/h boundaries (D36).
    var walkingBelow: Double = 7
    var cyclingBelow: Double = 30
    var trainAbove: Double = 200
    var airplaneAbove: Double = 300
    /// Same decision limit as the segmenter: worse points decide nothing.
    var maximumDecisionAccuracy: Double = 100
  }

  /// A Motion & Fitness reading from a `motionActivity` recorder event.
  struct ActivityReading: Equatable, Sendable {
    enum Activity: String, Sendable {
      case walking, running, cycling, automotive, stationary, unknown
    }

    let timestamp: Date
    let activity: Activity

    /// Reads `activity=<name> …`; low-confidence readings were already recorded as `unknown`.
    init?(_ event: RecorderEvent) {
      guard event.kind == .motionActivity, let payload = event.payload else { return nil }
      let value = payload.split(separator: " ").lazy
        .compactMap { pair -> Substring? in
          let parts = pair.split(separator: "=", maxSplits: 1)
          return parts.count == 2 && parts[0] == "activity" ? parts[1] : nil
        }
        .first
      guard let value, let activity = Activity(rawValue: String(value)) else { return nil }
      timestamp = event.timestamp
      self.activity = activity
    }

    init(timestamp: Date, activity: Activity) {
      self.timestamp = timestamp
      self.activity = activity
    }
  }

  /// One stretch of a move with a single mode.
  struct Run: Equatable, Sendable {
    var start: Date
    var mode: TransportMode
    /// Share of the run's time whose points voted for `mode`.
    var confidence: Double
  }

  /// The runs of one move. `points` are the move's points in time order, `activities` the readings
  /// in time order, including the newest one before the move. Always returns at least one run,
  /// starting at the first point (`unknown` when no point is usable).
  static func runs(of points: [RawPoint], activities: [ActivityReading], parameters: Parameters = Parameters()) -> [Run] {
    let usable = points.filter {
      !$0.flags.contains(.replayed) && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= parameters.maximumDecisionAccuracy
    }
    guard usable.count > 1 else {
      return [Run(start: points.first?.timestamp ?? .distantPast, mode: .unknown, confidence: 0)]
    }
    let labels = label(usable, activities: activities, parameters: parameters)
    // Each point stands for the time until the next one.
    let weights = zip(usable, usable.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) } + [0]

    struct Draft {
      var first: Int
      var last: Int
      var mode: TransportMode
      var duration: TimeInterval
    }
    var drafts: [Draft] = []
    for index in usable.indices {
      if var current = drafts.last, current.mode == labels[index] {
        current.last = index
        current.duration += weights[index]
        drafts[drafts.count - 1] = current
      } else {
        drafts.append(Draft(first: index, last: index, mode: labels[index], duration: weights[index]))
      }
    }
    // The shortest run under the minimum joins its longer neighbour, until none is left.
    while drafts.count > 1,
      let shortest = drafts.indices.filter({ drafts[$0].duration < parameters.minimumRun })
        .min(by: { drafts[$0].duration < drafts[$1].duration })
    {
      let previous = shortest > 0 ? shortest - 1 : nil
      let next = shortest < drafts.count - 1 ? shortest + 1 : nil
      let target: Int
      switch (previous, next) {
      case (let p?, let n?): target = drafts[p].duration >= drafts[n].duration ? p : n
      case (let p?, nil): target = p
      case (nil, let n?): target = n
      case (nil, nil): target = shortest
      }
      let low = min(shortest, target)
      let merged = Draft(
        first: drafts[low].first, last: drafts[low + 1].last, mode: drafts[target].mode,
        duration: drafts[low].duration + drafts[low + 1].duration)
      drafts.replaceSubrange(low...(low + 1), with: [merged])
      // Neighbours that now share a mode become one run.
      if low > 0, drafts[low - 1].mode == drafts[low].mode {
        let joined = Draft(
          first: drafts[low - 1].first, last: drafts[low].last, mode: drafts[low].mode,
          duration: drafts[low - 1].duration + drafts[low].duration)
        drafts.replaceSubrange((low - 1)...low, with: [joined])
      }
      if low < drafts.count - 1, drafts[low].mode == drafts[low + 1].mode {
        let joined = Draft(
          first: drafts[low].first, last: drafts[low + 1].last, mode: drafts[low].mode,
          duration: drafts[low].duration + drafts[low + 1].duration)
        drafts.replaceSubrange(low...(low + 1), with: [joined])
      }
    }
    return drafts.enumerated().map { position, draft in
      let agreeing = (draft.first...draft.last).filter { labels[$0] == draft.mode }.map { weights[$0] }.reduce(0, +)
      return Run(
        // The first run covers the move from its first point, usable or not.
        start: position == 0 ? (points.first?.timestamp ?? usable[draft.first].timestamp) : usable[draft.first].timestamp,
        mode: draft.mode,
        confidence: draft.duration > 0 ? agreeing / draft.duration : 1)
    }
  }

  /// The move cut into one segment per run, each with its mode (distance is left to the processor).
  /// `points` are the raw points of the move's range. Pieces share their boundary point (as segments do); only the last piece keeps
  /// `continuesNextDay`.
  static func split(_ move: Segment, points: [RawPoint], activities: [ActivityReading], parameters: Parameters = Parameters()) -> [Segment] {
    let own = points.filter { !$0.flags.contains(.replayed) && $0.timestamp >= move.start && $0.timestamp <= move.end }
    let runs = runs(of: own, activities: activities, parameters: parameters)
    return runs.indices.map { index in
      let start = index == 0 ? move.start : runs[index].start
      let end = index + 1 < runs.count ? runs[index + 1].start : move.end
      let piecePoints = own.filter { $0.timestamp >= start && $0.timestamp <= end }
      var piece = move
      piece.start = start
      piece.end = end
      piece.continuesNextDay = move.continuesNextDay && index == runs.count - 1
      piece.pointCount = piecePoints.count
      piece.transportMode = runs[index].mode
      piece.modeConfidence = runs[index].confidence
      return piece
    }
  }

  // MARK: - Labels

  private static func label(_ points: [RawPoint], activities: [ActivityReading], parameters: Parameters) -> [TransportMode] {
    let speeds = pointSpeeds(points)
    var readingIndex = -1
    var windowStart = 0
    var windowEnd = 0
    return points.indices.map { index in
      let time = points[index].timestamp
      while readingIndex + 1 < activities.count, activities[readingIndex + 1].timestamp <= time { readingIndex += 1 }
      while points[windowStart].timestamp < time.addingTimeInterval(-parameters.speedWindow) { windowStart += 1 }
      while windowEnd + 1 < points.count, points[windowEnd + 1].timestamp <= time.addingTimeInterval(parameters.speedWindow) {
        windowEnd += 1
      }
      let kmh = median(speeds[windowStart...windowEnd]) * 3.6
      let reading = readingIndex >= 0 ? activities[readingIndex].activity : nil
      return mode(kmh: kmh, reading: reading, parameters: parameters)
    }
  }

  static func mode(kmh: Double, reading: ActivityReading.Activity?, parameters: Parameters = Parameters()) -> TransportMode {
    if kmh > parameters.airplaneAbove { return .airplane }
    if kmh > parameters.trainAbove { return .train }
    let bySpeed: TransportMode = kmh < parameters.walkingBelow ? .walking : kmh < parameters.cyclingBelow ? .cycling : .car
    switch reading {
    case .automotive: return .car
    case .walking: return kmh < parameters.cyclingBelow ? .walking : bySpeed
    case .running: return kmh < parameters.cyclingBelow ? .running : bySpeed
    case .cycling: return kmh < parameters.cyclingBelow ? .cycling : bySpeed
    case .stationary, .unknown, nil: return bySpeed
    }
  }

  /// m/s per point: the recorded Doppler speed when valid, otherwise from the previous point.
  private static func pointSpeeds(_ points: [RawPoint]) -> [Double] {
    points.indices.map { index in
      if let speed = points[index].speed, speed >= 0 { return speed }
      guard index > 0 else {
        return points.count > 1 ? derivedSpeed(points[0], points[1]) : 0
      }
      return derivedSpeed(points[index - 1], points[index])
    }
  }

  private static func derivedSpeed(_ a: RawPoint, _ b: RawPoint) -> Double {
    let seconds = b.timestamp.timeIntervalSince(a.timestamp)
    guard seconds > 0 else { return 0 }
    return MotionStateMachine.distance(from: (a.latitude, a.longitude), to: (b.latitude, b.longitude)) / seconds
  }

  private static func median(_ values: ArraySlice<Double>) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
}
