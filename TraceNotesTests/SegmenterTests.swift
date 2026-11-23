import Foundation
import Testing

/// VS2 · Segmenter (TraceNotes/Processing): stays, moves, gaps, visits, midnight cuts.
struct SegmenterTests {
  /// 2026-11-22 09:00 in Tokyo (00:00 UTC).
  let base = Date(timeIntervalSince1970: 1_795_305_600)
  let metre = 1.0 / 111_195

  func point(
    _ seconds: TimeInterval, north: Double = 0, east: Double = 0, accuracy: Double = 10, zone: String = "Asia/Tokyo",
    flags: RawPoint.Flags = []
  ) -> RawPoint {
    RawPoint(
      id: nil, timestamp: base.addingTimeInterval(seconds), latitude: 35 + north * metre,
      longitude: 139 + east * metre / cos(35 * .pi / 180), horizontalAccuracy: accuracy, altitude: nil,
      verticalAccuracy: nil, speed: nil, course: nil, timeZoneID: zone, source: .recorded, importBatchID: nil,
      flags: flags)
  }

  func event(_ seconds: TimeInterval, _ kind: RecorderEvent.Kind) -> RecorderEvent {
    RecorderEvent(id: nil, timestamp: base.addingTimeInterval(seconds), kind: kind, payload: nil)
  }

  /// Walking north at 1.4 m/s, one point per second, from `start` for `duration` seconds.
  func walk(from start: TimeInterval, for duration: TimeInterval, startingAt north: Double = 0) -> [RawPoint] {
    stride(from: 0.0, to: duration, by: 1).map { point(start + $0, north: north + $0 * 1.4) }
  }

  /// Drifting within ±`drift` metres of `north` every 10 s (a phone lying still indoors).
  func still(from start: TimeInterval, for duration: TimeInterval, at north: Double, drift: Double = 20) -> [RawPoint] {
    stride(from: 0.0, to: duration, by: 10).enumerated().map { index, offset in
      let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
      return point(start + offset, north: north + sign * drift, east: sign * drift / 2)
    }
  }

  func segment(_ points: [RawPoint], events: [RecorderEvent] = [], seed: Segmenter.Seed = .fresh(start: nil), now: TimeInterval? = nil) -> [Segment] {
    var segmenter = Segmenter(seed: seed)
    let items: [(Date, Either)] = points.map { ($0.timestamp, .point($0)) } + events.map { ($0.timestamp, .event($0)) }
    for (_, item) in items.sorted(by: { $0.0 < $1.0 }) {
      switch item {
      case .point(let point): segmenter.add(point)
      case .event(let event): segmenter.add(event)
      }
    }
    let end = now.map(base.addingTimeInterval) ?? (points.last?.timestamp ?? base)
    return segmenter.finish(at: end)
  }

  enum Either {
    case point(RawPoint)
    case event(RecorderEvent)
  }

  func seconds(_ date: Date) -> TimeInterval { date.timeIntervalSince(base) }

  func expectContiguous(_ segments: [Segment], sourceLocation: SourceLocation = #_sourceLocation) {
    for (a, b) in zip(segments, segments.dropFirst()) {
      #expect(a.end == b.start, "\(a.kind) ends \(seconds(a.end)), \(b.kind) starts \(seconds(b.start))", sourceLocation: sourceLocation)
    }
    #expect(segments.dropLast().filter { !$0.isComplete }.isEmpty, sourceLocation: sourceLocation)
    #expect(segments.last?.isComplete == false, sourceLocation: sourceLocation)
  }

  // MARK: - Stays and moves

  /// F3: 20 minutes of indoor drift between two walks is one stay, not a scribble.
  @Test func walkStayWalk() throws {
    let arrival = 600.0
    let points = walk(from: 0, for: 600) + still(from: arrival, for: 1200, at: 840)
      + walk(from: 1800, for: 600, startingAt: 840)
    let segments = segment(points)
    #expect(segments.map(\.kind) == [.move, .stay, .move])
    expectContiguous(segments)
    let stay = segments[1]
    // The stay begins where the walk slows into the 50 m dwell window (within ~20 s of arrival)
    // and ends at its last point within the 50 m dwell radius on the way out (D38): the walk
    // leaves the centre at 1.4 m/s from 1800 s, so about 36 s later.
    #expect(abs(seconds(stay.start) - arrival) <= 30)
    #expect(seconds(stay.end) > 1800 && seconds(stay.end) < 1845)
    // The way out (50 m to 150 m) is part of the move, so it is drawn.
    #expect(segments[2].pointCount > 100)
    let center = try #require(stay.centerLatitude)
    #expect(abs((center - 35) / metre - 840) < 15)
  }

  /// A walk around home at 1 m/s, one point every 2 s, between two still periods there: out
  /// `radius` metres north (100 s from 900 s), round half a circle at that distance (300 s), and
  /// straight back (100 s).
  func strollNearHome(radius: Double = 100) -> [RawPoint] {
    let out = stride(from: 0.0, to: 100, by: 2).map { point(900 + $0, north: radius * $0 / 100) }
    let around = stride(from: 0.0, to: 300, by: 2).map { offset in
      let angle = Double.pi * offset / 300
      return point(1000 + offset, north: radius * cos(angle), east: radius * sin(angle))
    }
    let back = stride(from: 0.0, to: 100, by: 2).map { point(1300 + $0, north: -radius * (1 - $0 / 100)) }
    return still(from: 0, for: 900, at: 0, drift: 10) + out + around + back + still(from: 1400, for: 900, at: 0, drift: 10)
  }

  func activity(_ seconds: TimeInterval, _ name: String) -> RecorderEvent {
    var reading = event(seconds, .motionActivity)
    reading.payload = "activity=\(name) confidence=high"
    return reading
  }

  /// D51 (device, 2026-11-23): a 20-minute walk that stayed within the 150 m stay radius was lost
  /// in the stay at home. Walking for 2 minutes lets the stay end at the 50 m dwell radius.
  @Test func walkWithinTheStayRadiusIsAMove() {
    let readings = [
      activity(905, "walking"), activity(1000, "unknown"), activity(1100, "walking"), activity(1300, "walking"),
      activity(1410, "stationary"),
    ]
    let segments = segment(strollNearHome(), events: readings)
    #expect(segments.map(\.kind) == [.stay, .move, .stay])
    expectContiguous(segments)
    // Left at the last point within 50 m of the stay's centre (about 950 s, once the walk had
    // reached 60 m at 1060 s, 2 minutes after the first walking reading); home again about 1350 s.
    #expect(abs(seconds(segments[1].start) - 950) < 20)
    #expect(abs(seconds(segments[2].start) - 1350) < 20)
  }

  /// Without Motion & Fitness, or while it says the phone is still, the 150 m rule alone decides.
  @Test func driftOrNoMotionDataKeepsTheStay() {
    #expect(segment(strollNearHome()).map(\.kind) == [.stay])
    let still = [activity(905, "stationary"), activity(1300, "stationary")]
    #expect(segment(strollNearHome(), events: still).map(\.kind) == [.stay])
    // Walking around inside, within the dwell radius, is still the stay.
    let pacing = [activity(905, "walking"), activity(1300, "walking"), activity(1410, "stationary")]
    #expect(segment(strollNearHome(radius: 35), events: pacing).map(\.kind) == [.stay])
  }

  /// Walking that began before the stay (the way in) does not count towards leaving it.
  @Test func walkingIntoAStayDoesNotEndIt() {
    let points = walk(from: 0, for: 300) + still(from: 300, for: 1200, at: 420, drift: 30)
    let readings = [activity(10, "walking"), activity(400, "unknown")]
    #expect(segment(points, events: readings).map(\.kind) == [.move, .stay])
  }

  /// VS2 decision: a pause shorter than 5 minutes stays part of the move.
  @Test func shortStopStaysInTheMove() {
    let points = walk(from: 0, for: 300) + still(from: 300, for: 180, at: 420, drift: 5)
      + walk(from: 480, for: 300, startingAt: 420)
    #expect(segment(points).map(\.kind) == [.move])
  }

  /// D28: while stationary the recorder saves few points; long silences in one place are a stay.
  @Test func silentHeartbeatIsAStayNotAGap() {
    let points = walk(from: 0, for: 300) + stride(from: 900.0, through: 4500, by: 900).map { point($0, north: 420 + 10) }
    let segments = segment(points, now: 4600)
    #expect(segments.map(\.kind) == [.move, .stay])
    #expect(seconds(segments[1].start) == 299)
    #expect(seconds(segments[1].end) == 4600)  // open stay lasts until now
    expectContiguous(segments)
  }

  /// Simulator finding (VS2): the recorder saves every point for its own 3-minute dwell, then only
  /// a heartbeat every 5 minutes (D28). The stay starts where the dwell began, not at the last
  /// dense point before the first heartbeat.
  @Test func stayStartsAtTheDwellWhenHeartbeatsFollow() {
    let points = walk(from: 0, for: 300) + still(from: 300, for: 180, at: 420, drift: 20)
      + [point(480 + 301, north: 425), point(480 + 602, north: 415)]
    let segments = segment(points, now: 1200)
    #expect(segments.map(\.kind) == [.move, .stay])
    #expect(seconds(segments[1].start) <= 300)
  }

  /// VS2 decision: more than 5 minutes without points *and* elsewhere afterwards is a gap.
  @Test func silenceWithDisplacementIsAGap() {
    let points = walk(from: 0, for: 300) + walk(from: 1500, for: 120, startingAt: 2420)
    let segments = segment(points)
    #expect(segments.map(\.kind) == [.move, .gap, .move])
    #expect(seconds(segments[1].start) == 299)
    #expect(seconds(segments[1].end) == 1500)
    expectContiguous(segments)
  }

  @Test func poorFixDoesNotEndAStay() {
    var points = walk(from: 0, for: 300) + still(from: 300, for: 1200, at: 420)
    points.insert(point(900, north: 1400, accuracy: 1500), at: points.firstIndex { seconds($0.timestamp) > 900 } ?? 0)
    #expect(segment(points).map(\.kind) == [.move, .stay])
  }

  @Test func replayedFixesAreSkipped() {
    let replayed = (0..<30).map { point(Double($0) * 20, north: 5000, flags: .replayed) }
    let segments = segment(replayed + walk(from: 600, for: 120))
    #expect(segments.map(\.kind) == [.move])
    #expect(seconds(segments[0].start) == 600)
  }

  // MARK: - Visits

  @Test func visitDepartureEndsTheStay() {
    // Wandering within 100 m (no displacement beyond the stay radius), then the system reports
    // the departure at t = 1500.
    let points = walk(from: 0, for: 300) + still(from: 300, for: 1200, at: 420)
      + stride(from: 1500.0, to: 1800, by: 10).map { point($0, north: 420 + ($0 - 1500) / 3) }
    let segments = segment(points, events: [event(1500, .visitDepart)])
    #expect(segments.map(\.kind) == [.move, .stay, .move])
    #expect(seconds(segments[1].end) == 1500)
    expectContiguous(segments)
  }

  /// F3 "prefer CLVisit": an arrival starts the stay even when points spread more than the dwell
  /// radius, once it has lasted 5 minutes.
  @Test func visitArrivalStartsAStay() {
    let points = walk(from: 0, for: 300) + still(from: 300, for: 900, at: 420, drift: 70)
    let withoutVisit = segment(points)
    #expect(withoutVisit.map(\.kind) == [.move])
    let segments = segment(points, events: [event(320, .visitArrive)])
    #expect(segments.map(\.kind) == [.move, .stay])
    #expect(seconds(segments[1].start) == 320)
  }

  /// D39 (device finding): indoors the stationary heartbeat saved fixes that drifted 55 m away.
  /// The stay still lasts until the last of them, and no second stay follows at the same place.
  @Test func heartbeatDriftDoesNotEndTheStayEarly() {
    let points = walk(from: 0, for: 300) + still(from: 300, for: 600, at: 420, drift: 10)
      + [point(1260, north: 475), point(1620, north: 475)]
      + walk(from: 1650, for: 300, startingAt: 475)
    let segments = segment(points)
    #expect(segments.map(\.kind) == [.move, .stay, .move])
    #expect(seconds(segments[1].end) == 1620)
    expectContiguous(segments)
  }

  @Test func visitArrivalShorterThanMinimumIsIgnored() {
    let points = walk(from: 0, for: 300) + still(from: 300, for: 120, at: 420, drift: 70)
      + walk(from: 420, for: 300, startingAt: 420)
    #expect(segment(points, events: [event(300, .visitArrive)]).map(\.kind) == [.move])
  }

  // MARK: - Days

  /// D30 / F8: a stay over midnight is cut at local midnight; the next run continues it.
  @Test func stayIsCutAtLocalMidnightAndContinues() throws {
    // 23:00 Tokyo = base + 14 h.
    let evening = 14 * 3600.0
    let points = walk(from: evening, for: 300) + still(from: evening + 300, for: 3600 * 2, at: 420)
    let segments = segment(points)
    #expect(segments.map(\.kind) == [.move, .stay, .stay])
    let first = segments[1]
    let second = segments[2]
    #expect(first.localDay == LocalDay(year: 2026, month: 11, day: 22))
    #expect(second.localDay == LocalDay(year: 2026, month: 11, day: 23))
    #expect(first.continuesNextDay && first.isComplete)
    #expect(seconds(first.end) == 15 * 3600)  // 00:00 Tokyo
    expectContiguous(segments)

    // Resuming from the cut, as the processor does, gives the same open stay.
    let midnight = first.end
    let pointBefore = points.last { $0.timestamp < midnight }
    let resumed = segment(points.filter { $0.timestamp >= midnight }, seed: .continuing(first, pointBefore: pointBefore))
    #expect(resumed.map(\.kind) == [.stay])
    #expect(resumed.first?.start == second.start && resumed.first?.end == second.end)
  }

  /// F8: the cut follows the segment's own zone (Shanghai midnight is 01:00 in Tokyo).
  @Test func cutFollowsTheSegmentsTimeZone() {
    let evening = 14 * 3600.0
    let points = (walk(from: evening, for: 300) + still(from: evening + 300, for: 3600 * 2, at: 420))
      .map { point(seconds($0.timestamp), north: ($0.latitude - 35) / metre, zone: "Asia/Shanghai") }
    let segments = segment(points)
    #expect(segments.map(\.kind) == [.move, .stay, .stay])
    #expect(seconds(segments[1].end) == 16 * 3600)
    #expect(segments[1].localDay == LocalDay(year: 2026, month: 11, day: 22))
  }

  @Test func gapIsCutAtMidnightToo() {
    let evening = 14 * 3600.0
    let points = walk(from: evening, for: 300) + walk(from: evening + 3 * 3600, for: 60, startingAt: 5000)
    let segments = segment(points)
    #expect(segments.map(\.kind) == [.move, .gap, .gap, .move])
    #expect(seconds(segments[1].end) == 15 * 3600)
    #expect(segments[2].localDay == LocalDay(year: 2026, month: 11, day: 23))
  }
}
