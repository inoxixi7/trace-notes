import CoreGraphics
import Foundation

/// Smooth track curves for the display layer (F7, D22, ARCHITECTURE §6.2): a centripetal
/// Catmull-Rom spline (α = 0.5, no cusps or self-intersections within a span) expressed as cubic
/// Bézier spans, so a renderer can hand them straight to Core Graphics.
///
/// At a sharp turn the spline would round the corner off and cut across buildings; there the
/// spans on both sides of the corner are drawn straight instead.
nonisolated enum CatmullRom {
  enum Element: Equatable {
    case move(to: CGPoint)
    case line(to: CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
  }

  /// A heading change of at least this much, with both legs at least `cornerLegMinimum` long, is a
  /// real corner. Field-tuned values from the legacy stabilizer (`turnAngleThresholdDegrees`,
  /// `turnLegMinimumMeters`, LEGACY_INVENTORY §3).
  static let cornerAngleDegrees = 45.0
  static let cornerLegMinimumMetres = 8.0

  /// Path elements through `points` (screen or map units). `metresPerUnit` converts their units to
  /// metres for the corner test.
  static func elements(through points: [CGPoint], metresPerUnit: Double) -> [Element] {
    guard let first = points.first else { return [] }
    var elements: [Element] = [.move(to: first)]
    guard points.count > 1 else { return elements }
    let corners = Set(points.indices.dropFirst().dropLast().filter { isCorner(at: $0, in: points, metresPerUnit: metresPerUnit) })
    for index in 0..<(points.count - 1) {
      let p1 = points[index]
      let p2 = points[index + 1]
      if corners.contains(index) || corners.contains(index + 1) {
        elements.append(.line(to: p2))
        continue
      }
      // The ends are extended by repeating the first and last points.
      let p0 = index > 0 ? points[index - 1] : p1
      let p3 = index + 2 < points.count ? points[index + 2] : p2
      elements.append(bezierSpan(p0, p1, p2, p3))
    }
    return elements
  }

  /// The same curve as `elements(through:metresPerUnit:)` as a polyline, for renderers that only
  /// draw polylines. Each Bézier span is cut into the fewest equal steps that keep it within
  /// `tolerance` (in the points' units) by Wang's formula: n = ⌈√(¾ · M / tolerance)⌉, where M is
  /// the largest second difference of the control points.
  static func polyline(through points: [CGPoint], metresPerUnit: Double, tolerance: Double) -> [CGPoint] {
    var result: [CGPoint] = []
    var current = CGPoint.zero
    for element in elements(through: points, metresPerUnit: metresPerUnit) {
      switch element {
      case .move(let to), .line(let to):
        result.append(to)
        current = to
      case .curve(let to, let c1, let c2):
        let m = max((current - c1 * 2 + c2).length, (c1 - c2 * 2 + to).length)
        let steps = max(1, Int((0.75 * m / max(tolerance, .leastNonzeroMagnitude)).squareRoot().rounded(.up)))
        for step in 1...steps {
          let t = Double(step) / Double(steps)
          let u = 1 - t
          result.append(current * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + to * (t * t * t))
        }
        current = to
      }
    }
    return result
  }

  /// Centripetal Catmull-Rom span p1→p2 as a cubic Bézier (Yuksel, Schaefer & Keyser 2011).
  static func bezierSpan(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> Element {
    let d1 = distance(p0, p1).squareRoot()  // |p1 − p0|^α with α = 0.5
    let d2 = distance(p1, p2).squareRoot()
    let d3 = distance(p2, p3).squareRoot()
    guard d2 > 0 else { return .line(to: p2) }
    var control1 = p1
    if d1 > 0 {
      let a = d1 * d1
      let b = d2 * d2
      let denominator = 3 * d1 * (d1 + d2)
      control1 = (p2 * a - p0 * b + p1 * (2 * a + 3 * d1 * d2 + b)) / denominator
    } else {
      control1 = p1 + (p2 - p1) / 3
    }
    var control2 = p2
    if d3 > 0 {
      let a = d3 * d3
      let b = d2 * d2
      let denominator = 3 * d3 * (d3 + d2)
      control2 = (p1 * a - p3 * b + p2 * (2 * a + 3 * d3 * d2 + b)) / denominator
    } else {
      control2 = p2 + (p1 - p2) / 3
    }
    return .curve(to: p2, control1: control1, control2: control2)
  }

  private static func isCorner(at index: Int, in points: [CGPoint], metresPerUnit: Double) -> Bool {
    let incoming = points[index] - points[index - 1]
    let outgoing = points[index + 1] - points[index]
    let incomingLength = incoming.length
    let outgoingLength = outgoing.length
    guard incomingLength * metresPerUnit >= cornerLegMinimumMetres, outgoingLength * metresPerUnit >= cornerLegMinimumMetres
    else { return false }
    let cosine = (incoming.x * outgoing.x + incoming.y * outgoing.y) / (incomingLength * outgoingLength)
    let turn = acos(min(1, max(-1, cosine))) * 180 / .pi
    return turn >= cornerAngleDegrees
  }

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    (b - a).length
  }
}

nonisolated private extension CGPoint {
  var length: Double { (x * x + y * y).squareRoot() }
  static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
  static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
  static func * (lhs: CGPoint, rhs: Double) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
  static func / (lhs: CGPoint, rhs: Double) -> CGPoint { CGPoint(x: lhs.x / rhs, y: lhs.y / rhs) }
}
