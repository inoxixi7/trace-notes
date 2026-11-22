import CoreGraphics
import Foundation
import GRDB
import Testing

/// VS3 · Geo (Douglas-Peucker, Catmull-Rom) and pipeline step ⑦ (render cache).
struct GeoTests {
  let metre = 1.0 / 111_195

  // MARK: - Douglas-Peucker

  @Test func straightLineKeepsOnlyItsEnds() {
    let line = (0...100).map { (35 + Double($0) * metre, 139.0) }
    let simplified = DouglasPeucker.simplify(line, tolerance: 0.5)
    #expect(simplified.count == 2)
    #expect(simplified.first! == line.first! && simplified.last! == line.last!)
  }

  @Test func cornerSurvivesAndErrorStaysWithinTolerance() {
    // 100 m north with 0.3 m zigzag, then 100 m east.
    let north = (0...100).map { (35 + Double($0) * metre, 139 + ($0.isMultiple(of: 2) ? 0.3 : -0.3) * metre) }
    let east = (1...100).map { (35 + 100 * metre, 139 + Double($0) * metre / cos(35 * .pi / 180)) }
    let simplified = DouglasPeucker.simplify(north + east, tolerance: 2)
    #expect(simplified.count == 3)
    #expect(abs((simplified[1].0 - 35) / metre - 100) < 1)
  }

  @Test func levelsGetCoarserAndKeepTheEnds() {
    let wiggle = (0...2000).map { index -> (Double, Double) in
      let t = Double(index)
      return (35 + t * metre, 139 + sin(t / 40) * 60 * metre)
    }
    let levels = RenderCache.levels(of: wiggle)
    #expect(levels.count == RenderCache.tolerances.count)
    let counts = levels.map(\.count)
    #expect(counts == counts.sorted(by: >))
    #expect(counts.last! < counts.first!)
    #expect(levels.allSatisfy { $0.first! == wiggle.first! && $0.last! == wiggle.last! })
  }

  /// A level is used while its error stays under half a screen point.
  @Test func levelFollowsTheZoom() {
    #expect(RenderCache.level(forMetresPerPoint: 0.1) == 0)  // street level: finest
    #expect(RenderCache.level(forMetresPerPoint: 4) == 1)  // 2 m ≤ 2 m
    #expect(RenderCache.level(forMetresPerPoint: 20) == 2)
    #expect(RenderCache.level(forMetresPerPoint: 1000) == 4)  // country: coarsest
  }

  @Test func drawablePointsSkipPoorAndReplayedFixes() {
    let helper = SegmenterTests()
    let points = [helper.point(0), helper.point(1, accuracy: 300), helper.point(2, flags: .replayed), helper.point(3, north: 5)]
    #expect(RenderCache.drawablePoints(points).count == 2)
  }

  // MARK: - Catmull-Rom

  @Test func curvePassesThroughEveryPoint() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 3), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 4)]
    let elements = CatmullRom.elements(through: points, metresPerUnit: 1)
    #expect(elements.first == .move(to: points[0]))
    let ends = elements.dropFirst().map { element -> CGPoint in
      switch element {
      case .move(let to), .line(let to), .curve(let to, _, _): to
      }
    }
    #expect(ends == Array(points.dropFirst()))
    #expect(elements.dropFirst().allSatisfy { if case .curve = $0 { true } else { false } })
  }

  /// A straight run stays straight: control points lie on the line.
  @Test func collinearPointsGiveAStraightCurve() {
    let points = (0..<4).map { CGPoint(x: Double($0) * 10, y: 0) }
    for element in CatmullRom.elements(through: points, metresPerUnit: 1) {
      if case .curve(_, let control1, let control2) = element {
        #expect(abs(control1.y) < 1e-9 && abs(control2.y) < 1e-9)
      }
    }
  }

  /// D22 / §6.2: a 90° street corner is not rounded off; both spans touching it are straight.
  @Test func sharpTurnIsDrawnAsACorner() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 100)]
    let elements = CatmullRom.elements(through: points, metresPerUnit: 1)
    #expect(elements[2] == .line(to: CGPoint(x: 100, y: 0)))
    #expect(elements[3] == .line(to: CGPoint(x: 100, y: 50)))
    if case .curve = elements[1] {} else { Issue.record("the span before the corner's neighbour should stay curved") }
  }

  /// Short legs (GPS jitter) are not corners even when the angle is sharp.
  @Test func jitterIsNotACorner() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 3), CGPoint(x: 6, y: 3)]
    #expect(CatmullRom.elements(through: points, metresPerUnit: 1).dropFirst().allSatisfy {
      if case .curve = $0 { true } else { false }
    })
  }

  /// The map draws the curve as a polyline (MapKit draws only polylines as vectors); it keeps
  /// every track point and stays within the tolerance of the true curve.
  @Test func flattenedCurveStaysWithinTolerance() {
    let points = stride(from: 0.0, through: 90, by: 30).map { degrees in
      CGPoint(x: 100 * cos(degrees * .pi / 180), y: 100 * sin(degrees * .pi / 180))
    }
    let coarse = CatmullRom.polyline(through: points, metresPerUnit: 1, tolerance: 0.5)
    let exact = CatmullRom.polyline(through: points, metresPerUnit: 1, tolerance: 0.001)
    #expect(points.allSatisfy { point in coarse.contains { hypot($0.x - point.x, $0.y - point.y) < 1e-9 } })
    #expect(coarse.count < exact.count)
    let worst = exact.map { point in
      zip(coarse, coarse.dropFirst()).map { distance(from: point, toSegment: $0, $1) }.min() ?? .infinity
    }.max() ?? .infinity
    #expect(worst <= 0.5)
  }

  private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    let t = lengthSquared > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
  }

  // MARK: - Render cache storage

  @Test func completedMovesGetCachedLevelsThatGoWithTheirSegment() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "GeoTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase(url: directory.appending(path: "test.sqlite"))
    let processorTests = TrackProcessorTests()
    let (points, events) = processorTests.day()
    try await database.append(points: points, events: events)
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)

    var iterator = database.observeRenderCache(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
    let cache = try #require(try await iterator.next())
    // Day 22 has one completed move (the evening walk); its levels are stored, finest first.
    #expect(cache.count == 1)
    let levels = try #require(cache.values.first)
    #expect(levels.count == RenderCache.tolerances.count)
    #expect(levels[0].count >= levels[4].count && levels[4].count >= 2)

    // Stored as integers like raw points: within 1 cm.
    let walkStart = try #require(points.first)
    #expect(abs(levels[0][0].latitude - walkStart.latitude) < 1e-7)

    // A pipeline-version rebuild removes the cache with its segments.
    try await database.replaceOpenSegments(with: [])
    #expect(try await database.deleteSegments(otherThan: Segmenter.pipelineVersion + 1) > 0)
    var after = database.observeRenderCache(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
    #expect(try #require(try await after.next()).isEmpty)
  }
}
