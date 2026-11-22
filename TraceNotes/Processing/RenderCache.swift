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
  static func track(
    ofMove points: [RawPoint], isComplete: Bool,
    maximumAccuracy: Double = Segmenter.Parameters().maximumDecisionAccuracy
  ) -> [Coordinate] {
    let usable = points.filter {
      !$0.flags.contains(.replayed) && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maximumAccuracy
    }
    return TraceStabilizer.stabilize(TraceStabilizer.spaced(usable), finalize: isComplete).drawableCoordinates.map { ($0.latitude, $0.longitude) }
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
