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

  @Test func drawnTrackSkipsPoorAndReplayedFixes() {
    let helper = SegmenterTests()
    let points = [helper.point(0), helper.point(1, accuracy: 300), helper.point(2, flags: .replayed), helper.point(30, north: 40)]
    // Two points are not enough evidence to decide; the open move still draws them (D34 ④).
    #expect(RenderCache.track(ofMove: points, isComplete: false).count == 2)
  }

  /// D34: a GPS spike out and back in the middle of a walk is not drawn. The legacy rule removes a
  /// one-point jump when the walk returns to within 15 % of the jump's length of where it left.
  @Test func drawnTrackDropsAnIsolatedSpike() {
    let helper = SegmenterTests()
    var points = stride(from: 0.0, to: 120, by: 5).map { helper.point($0, north: $0 * 1.4) }
    let spikeIndex = points.count / 2
    points[spikeIndex] = helper.point(points[spikeIndex].timestamp.timeIntervalSince(helper.base), north: Double(spikeIndex) * 7, east: 150, accuracy: 40)
    let eastMetres = RenderCache.track(ofMove: points, isComplete: true).map { ($0.longitude - 139) / helper.metre * cos(35 * .pi / 180) }
    #expect(eastMetres.allSatisfy { abs($0) < 10 })
    #expect(eastMetres.count >= points.count / 2)
    // While the move is still open the spike is undecided, but the walk has passed it: not drawn
    // either (simulator finding).
    let openEast = RenderCache.track(ofMove: points, isComplete: false).map { ($0.longitude - 139) / helper.metre * cos(35 * .pi / 180) }
    #expect(openEast.allSatisfy { abs($0) < 10 })
  }

  // MARK: - Ways into and out of stays (D52)

  func stay(from start: TimeInterval, to end: TimeInterval, north: Double = 0, east: Double = 0) -> Segment {
    let helper = SegmenterTests()
    let center = helper.point(0, north: north, east: east)
    return Segment(
      id: nil, kind: .stay, start: helper.base.addingTimeInterval(start), end: helper.base.addingTimeInterval(end),
      timeZoneID: "Asia/Tokyo", localDay: LocalDay(year: 2026, month: 11, day: 22), isComplete: true,
      continuesNextDay: false, pointCount: 0, distance: 0, centerLatitude: center.latitude,
      centerLongitude: center.longitude, radius: nil, pipelineVersion: Segmenter.pipelineVersion)
  }

  func move(from start: TimeInterval, to end: TimeInterval) -> Segment {
    var move = stay(from: start, to: end)
    move.kind = .move
    move.centerLatitude = nil
    move.centerLongitude = nil
    return move
  }

  /// Fixes every 5 s at walking pace along straight legs through `corners` (north, east), from
  /// `start` on, as the recorder saves a walk. Each corner after the first is reached in turn.
  func walk(from start: TimeInterval, through corners: [(Double, Double)]) -> [RawPoint] {
    let helper = SegmenterTests()
    var result = [helper.point(start, north: corners[0].0, east: corners[0].1)]
    var time = start
    for (from, to) in zip(corners, corners.dropFirst()) {
      let length = hypot(to.0 - from.0, to.1 - from.1)
      let legs = Int((length / (Self.walkingSpeed * Self.fixInterval)).rounded(.up))
      for step in 1...legs {
        let share = Double(step) / Double(legs)
        time += length / Self.walkingSpeed / Double(legs)
        result.append(helper.point(time, north: from.0 + (to.0 - from.0) * share, east: from.1 + (to.1 - from.1) * share))
      }
    }
    return result
  }

  static let walkingSpeed = 1.4
  static let fixInterval = 5.0

  func metres(_ track: [RenderCache.Coordinate]) -> [(north: Double, east: Double)] {
    let helper = SegmenterTests()
    return track.map { (($0.latitude - 35) / helper.metre, ($0.longitude - 139) / helper.metre * cos(35 * .pi / 180)) }
  }

  /// Out of the door, 30 m east to the street, then south: the first 46 m are still inside the
  /// stay, yet the line follows them instead of cutting from the marker straight to the corner.
  @Test func trackFollowsTheWayOutOfAStay() throws {
    let helper = SegmenterTests()
    let still = stride(from: 0.0, to: 540, by: 10).map { helper.point($0, north: $0.truncatingRemainder(dividingBy: 20) == 0 ? 2 : -2) }
    let route = walk(from: 540, through: [(0, 0), (0, 30), (-130, 30)])
    // The stay ends at the last fix within the dwell radius.
    let departure = try #require(route.last { hypot($0.latitude - 35, ($0.longitude - 139) * cos(35 * .pi / 180)) / helper.metre <= 50 })
    let start = departure.timestamp.timeIntervalSince(helper.base)
    let track = RenderCache.track(
      of: move(from: start, to: route.last!.timestamp.timeIntervalSince(helper.base)), previous: stay(from: 0, to: start),
      next: nil, points: still + route, maximumAccuracy: Segmenter.Parameters().maximumDecisionAccuracy)
    let drawn = metres(track)
    #expect(drawn.first.map { abs($0.north) < 1 && abs($0.east) < 1 } == true)
    // Every drawn point is on the street east or the street south: no diagonal.
    #expect(drawn.allSatisfy { abs($0.north) < 4 || abs($0.east - 30) < 4 })
    #expect(RenderCache.length(of: track) > 140)
  }

  /// Walking into a place from the side: the line follows the recorded path to the marker.
  @Test func trackFollowsTheWayIntoAStay() throws {
    let helper = SegmenterTests()
    let route = walk(from: 0, through: [(130, -30), (40, -30), (40, 0), (0, 0)])
    let arrival = try #require(route.first { hypot($0.latitude - 35, ($0.longitude - 139) * cos(35 * .pi / 180)) / helper.metre <= 50 })
    let end = arrival.timestamp.timeIntervalSince(helper.base)
    let settled = route.last!.timestamp.timeIntervalSince(helper.base)
    let still = stride(from: settled + 10, to: settled + 600, by: 10).map {
      helper.point($0, east: $0.truncatingRemainder(dividingBy: 20) == 0 ? 2 : -2)
    }
    let track = RenderCache.track(
      of: move(from: 0, to: end), previous: nil, next: stay(from: end, to: settled + 600), points: route + still,
      maximumAccuracy: Segmenter.Parameters().maximumDecisionAccuracy)
    let drawn = metres(track)
    #expect(drawn.last.map { abs($0.north) < 1 && abs($0.east) < 1 } == true)
    #expect(drawn.allSatisfy { abs($0.east + 30) < 4 || abs($0.north - 40) < 4 || abs($0.east) < 4 })
    #expect(RenderCache.length(of: track) > 140)
  }

  /// Moving about inside a place before leaving is part of the stay: at most the points after the
  /// last one near the centre are drawn, never the whole stay.
  @Test func wayOutNeverTakesOverTheStay() {
    let helper = SegmenterTests()
    // Ten minutes pacing 0–15 m from the centre with 3 m fixes, then a last point 25 m out at the
    // door. Half the points are within 10 m, so only the last pacing step and the door are drawn.
    let pacing = stride(from: 0.0, to: 600, by: 10).map { helper.point($0, east: $0.truncatingRemainder(dividingBy: 40) / 2, accuracy: 3) }
    let door = helper.point(605, north: 25, accuracy: 3)
    let way = RenderCache.way(
      of: stay(from: 0, to: 610), leaving: true, points: pacing + [door, helper.point(610, north: 30, accuracy: 3)],
      maximumAccuracy: Segmenter.Parameters().maximumDecisionAccuracy)
    #expect(way.map(\.timestamp) == [helper.base.addingTimeInterval(590), door.timestamp])
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

  /// D38: a 90° street corner keeps straight legs and is rounded with a 10 m arc, not a point
  /// and not a wide swing across the block.
  @Test func sharpTurnIsRoundedWithASmallArc() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 100)]
    let elements = CatmullRom.elements(through: points, metresPerUnit: 1)
    if case .curve = elements[1] {} else { Issue.record("the span before the corner's neighbour should stay curved") }
    // Along the leg to the arc's entry (a curve with its controls on the leg).
    guard case .curve(let entry, let legControl1, let legControl2) = elements[2] else {
      Issue.record("span to the arc expected")
      return
    }
    #expect(abs(entry.x - 90) < 1e-9 && abs(entry.y) < 1e-9)
    #expect(abs(legControl1.y) < 1e-9 && abs(legControl2.y) < 1e-9)
    guard case .curve(let to, let control1, let control2) = elements[3] else {
      Issue.record("the corner should be an arc")
      return
    }
    #expect(abs(to.x - 100) < 1e-9 && abs(to.y - 10) < 1e-9)
    // Tangent to both legs: the controls lie on them.
    #expect(abs(control1.y) < 1e-9 && abs(control2.x - 100) < 1e-9)
    guard case .curve(let after, let afterControl1, _) = elements[4] else {
      Issue.record("span after the arc expected")
      return
    }
    #expect(after == CGPoint(x: 100, y: 50) && abs(afterControl1.x - 100) < 1e-9)
    // The arc passes ≈ 3.5 m inside the corner point: rounded, but still on the street.
    let flattened = CatmullRom.polyline(through: points, metresPerUnit: 1, tolerance: 0.01)
    let closest = flattened.map { hypot($0.x - 100, $0.y) }.min() ?? .infinity
    #expect(closest > 3 && closest < 4.5)
  }

  /// Device feedback (D39): no kinks at any zoom. At every joint of a jittery walk with sharp
  /// corners, the curve arrives and leaves in the same direction.
  @Test func curveHasNoKinks() {
    let points = [(0, 0), (30, 2), (60, -1), (62, 30), (61, 60), (90, 63), (95, 64), (120, 62), (121, 90)]
      .map { CGPoint(x: Double($0.0), y: Double($0.1)) }
    let elements = CatmullRom.elements(through: points, metresPerUnit: 1)
    var previousEnd = points[0]
    var incoming: CGPoint?
    for element in elements.dropFirst() {
      let (end, firstControl, lastControl): (CGPoint, CGPoint, CGPoint) =
        switch element {
        case .move(let to), .line(let to): (to, to, previousEnd)
        case .curve(let to, let control1, let control2): (to, control1, control2)
        }
      let outgoing = CGPoint(x: firstControl.x - previousEnd.x, y: firstControl.y - previousEnd.y)
      if let incoming, hypot(incoming.x, incoming.y) > 1e-9, hypot(outgoing.x, outgoing.y) > 1e-9 {
        let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
        let dot = incoming.x * outgoing.x + incoming.y * outgoing.y
        #expect(abs(atan2(cross, dot)) < 1e-6, "kink before \(end)")
      }
      incoming = CGPoint(x: end.x - lastControl.x, y: end.y - lastControl.y)
      previousEnd = end
    }
  }

  /// Short legs limit the arc to half their length, so neighbouring corners never overlap.
  @Test func shortLegsShrinkTheArc() {
    let points = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 12), CGPoint(x: 80, y: 12)]
    let elements = CatmullRom.elements(through: points, metresPerUnit: 1)
    guard case .curve(let firstEntry, let control1, let control2) = elements[1] else {
      Issue.record("span along the leg expected")
      return
    }
    #expect(firstEntry == CGPoint(x: 34, y: 0) && abs(control1.y) < 1e-9 && abs(control2.y) < 1e-9)
    guard case .curve(let firstExit, _, _) = elements[2] else {
      Issue.record("arc expected")
      return
    }
    #expect(firstExit == CGPoint(x: 40, y: 6))
    #expect(elements[3] == .line(to: CGPoint(x: 40, y: 6)))
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
