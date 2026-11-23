import Foundation

/// Pipeline step ⑦ (ARCHITECTURE §5.1, §6.3): each move's track simplified at several zoom
/// levels, so the map never draws more points than the screen can show.
nonisolated enum RenderCache {
  typealias Coordinate = DouglasPeucker.Coordinate

  /// Douglas-Peucker tolerance of each level, in metres. The finest is below GPS precision; each
  /// next level is 4× coarser, which is two map zoom levels (the scale halves per zoom level).
  static let tolerances: [Double] = [0.5, 2, 8, 32, 128]

  /// A level may be shown while its tolerance stays under this many screen points, i.e. its
  /// simplification error is invisible (about one pixel on a 2× or 3× screen).
  static let maximumErrorPoints = 0.5

  /// The track drawn for a move (pipeline steps ② and ⑦'s input): usable points only (accuracy
  /// within the decision limit, not replayed), thinned to the density the stabilizer was tuned on,
  /// then stabilized (D34), keeping every point that is not suppressed. A completed move resolves its undecided points; the open move keeps them.
  ///
  /// `from` and `to` are the centres of the stays before and after the move: the line starts and
  /// ends at their markers, so the way into and out of a place has no gap (D38).
  static func track(
    ofMove points: [RawPoint], isComplete: Bool, from start: Coordinate? = nil, to end: Coordinate? = nil,
    maximumAccuracy: Double = Segmenter.Parameters().maximumDecisionAccuracy
  ) -> [Coordinate] {
    let usable = points.filter { isUsable($0, maximumAccuracy: maximumAccuracy) }
    let stabilized = TraceStabilizer.stabilize(TraceStabilizer.spaced(usable), finalize: isComplete)
      .drawableCoordinates.map { ($0.latitude, $0.longitude) }
    return [start].compactMap { $0 } + stabilized + [end].compactMap { $0 }
  }

  /// The track drawn for `move` between the segments either side of it (D38, D52): its own points,
  /// and the way out of the stay before and into the stay after, so the line follows the recorded
  /// path to the marker instead of cutting straight across. `points` must cover the move and those
  /// stays.
  ///
  /// The ways are only thinned, not stabilized: the segmenter has already decided the user was
  /// leaving or arriving there, and the stabilizer takes the slow steps of a doorway for a
  /// stationary cloud and drops them.
  static func track(
    of move: Segment, previous before: Segment?, next after: Segment?, points: [RawPoint],
    maximumAccuracy: Double = Segmenter.Parameters().maximumDecisionAccuracy
  ) -> [Coordinate] {
    let own = points.filter { $0.timestamp >= move.start && $0.timestamp <= move.end }
    let ways = [(before, true), (after, false)].map { stay, leaving in
      stay.map { TraceStabilizer.spaced(way(of: $0, leaving: leaving, points: points, maximumAccuracy: maximumAccuracy)) }?
        .map { ($0.latitude, $0.longitude) } ?? []
    }
    let moving = track(ofMove: own, isComplete: move.isComplete, maximumAccuracy: maximumAccuracy)
    return [before?.stayCenter].compactMap { $0 } + ways[0] + moving + ways[1] + [after?.stayCenter].compactMap { $0 }
  }

  /// A stay's points on the way out of it (`leaving`) or into it (D52): those after the last (before
  /// the first) point at the place. A point is at the place when it lies within the stay's typical
  /// spread (the median distance of its points from the centre) or within its own accuracy. Half
  /// the stay's points are within the median, so the way never takes over the stay. The stay's
  /// boundary point is left out: it is the move's own first or last point. Empty for a move or gap.
  static func way(of stay: Segment, leaving: Bool, points: [RawPoint], maximumAccuracy: Double) -> [RawPoint] {
    guard let center = stay.stayCenter else { return [] }
    let own = points.filter {
      $0.timestamp >= stay.start && $0.timestamp <= stay.end && isUsable($0, maximumAccuracy: maximumAccuracy)
    }
    let distances = own.map { MotionStateMachine.distance(from: ($0.latitude, $0.longitude), to: center) }
    guard !distances.isEmpty else { return [] }
    let spread = distances.sorted()[distances.count / 2]
    let atPlace = own.indices.filter { distances[$0] <= max(spread, own[$0].horizontalAccuracy) }
    if leaving {
      guard let last = atPlace.last else { return [] }
      return own[(last + 1)...].filter { $0.timestamp < stay.end }
    } else {
      guard let first = atPlace.first else { return [] }
      return own[..<first].filter { $0.timestamp > stay.start }
    }
  }

  private static func isUsable(_ point: RawPoint, maximumAccuracy: Double) -> Bool {
    !point.flags.contains(.replayed) && point.horizontalAccuracy >= 0 && point.horizontalAccuracy <= maximumAccuracy
  }

  /// Metres along a track.
  static func length(of track: [Coordinate]) -> Double {
    zip(track, track.dropFirst()).map { MotionStateMachine.distance(from: $0, to: $1) }.reduce(0, +)
  }

  /// Every level for one track, finest first. Each level simplifies the previous one, which makes
  /// coarse levels cheap; the errors add up to at most 4/3 of a level's tolerance.
  static func levels(of track: [Coordinate]) -> [[Coordinate]] {
    var result: [[Coordinate]] = []
    var current = track
    for tolerance in tolerances {
      current = DouglasPeucker.simplify(current, tolerance: tolerance)
      result.append(current)
    }
    return result
  }

  /// The coarsest level whose error is invisible at `metresPerPoint` (metres per screen point).
  static func level(forMetresPerPoint metresPerPoint: Double) -> Int {
    let allowed = metresPerPoint * maximumErrorPoints
    return tolerances.lastIndex { $0 <= allowed } ?? 0
  }
}
