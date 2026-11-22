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

  /// The points drawn for a move: usable ones only (accuracy within the decision limit, not
  /// replayed). The stabilizer that also removes spikes is a later slice.
  static func drawablePoints(_ points: [RawPoint], maximumAccuracy: Double = Segmenter.Parameters().maximumDecisionAccuracy) -> [Coordinate] {
    points
      .filter { !$0.flags.contains(.replayed) && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maximumAccuracy }
      .map { ($0.latitude, $0.longitude) }
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
