import Foundation

/// Douglas-Peucker line simplification (ARCHITECTURE §6.3) on WGS-84 coordinates: keeps the
/// fewest points such that no dropped point is farther than `tolerance` metres from the result.
/// The first and last points are always kept.
nonisolated enum DouglasPeucker {
  typealias Coordinate = (latitude: Double, longitude: Double)

  static func simplify(_ coordinates: [Coordinate], tolerance: Double) -> [Coordinate] {
    guard coordinates.count > 2 else { return coordinates }
    // Local equirectangular metres around the first point: exact enough for one track.
    let origin = coordinates[0]
    let metresPerDegreeLatitude = 111_195.0
    let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(origin.latitude * .pi / 180)
    let planar = coordinates.map {
      SIMD2(($0.longitude - origin.longitude) * metresPerDegreeLongitude, ($0.latitude - origin.latitude) * metresPerDegreeLatitude)
    }
    var keep = [Bool](repeating: false, count: coordinates.count)
    keep[0] = true
    keep[coordinates.count - 1] = true
    // Iterative, so a long day cannot overflow the stack.
    var ranges = [(0, coordinates.count - 1)]
    while let (first, last) = ranges.popLast() {
      guard last - first > 1 else { continue }
      var farthest = first
      var farthestDistance = 0.0
      for index in (first + 1)..<last {
        let distance = distanceFromSegment(planar[index], planar[first], planar[last])
        if distance > farthestDistance {
          farthestDistance = distance
          farthest = index
        }
      }
      if farthestDistance > tolerance {
        keep[farthest] = true
        ranges.append((first, farthest))
        ranges.append((farthest, last))
      }
    }
    return coordinates.indices.filter { keep[$0] }.map { coordinates[$0] }
  }

  private static func distanceFromSegment(_ point: SIMD2<Double>, _ start: SIMD2<Double>, _ end: SIMD2<Double>) -> Double {
    let segment = end - start
    let lengthSquared = (segment * segment).sum()
    guard lengthSquared > 0 else { return ((point - start) * (point - start)).sum().squareRoot() }
    let t = min(1, max(0, ((point - start) * segment).sum() / lengthSquared))
    let projection = start + t * segment
    return ((point - projection) * (point - projection)).sum().squareRoot()
  }
}
