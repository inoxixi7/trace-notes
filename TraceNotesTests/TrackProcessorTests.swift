import Foundation
import GRDB
import Testing

/// VS2 · TrackProcessor: incremental runs over the database match one batch run, survive a
/// restart, and rebuild segments of another pipeline version.
struct TrackProcessorTests {
  let helper = SegmenterTests()
  let directory = FileManager.default.temporaryDirectory.appending(path: "TrackProcessorTests-\(UUID().uuidString)")

  func openDatabase() throws -> AppDatabase {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try AppDatabase(url: directory.appending(path: "test.sqlite"))
  }

  /// A day: walk, stay over midnight, gap, walk, with a visit departure inside the stay.
  func day() -> (points: [RawPoint], events: [RecorderEvent]) {
    let evening = 14 * 3600.0
    let points = helper.walk(from: evening - 3600, for: 900)
      + helper.still(from: evening - 2700, for: 3 * 3600, at: 1260)
      + helper.walk(from: evening + 2.5 * 3600, for: 600, startingAt: 1400)
      + helper.walk(from: evening + 4 * 3600, for: 600, startingAt: 9000)
    return (points, [helper.event(evening + 2.5 * 3600, .visitDepart)])
  }

  func summary(_ database: AppDatabase) async throws -> [String] {
    var rows: [String] = []
    for day in [LocalDay(year: 2026, month: 11, day: 22), LocalDay(year: 2026, month: 11, day: 23)] {
      var iterator = database.observeSegments(on: day).makeAsyncIterator()
      let segments = try #require(try await iterator.next())
      rows += segments.map {
        "\($0.localDay) \($0.kind) \(Int(helper.seconds($0.start)))-\(Int(helper.seconds($0.end))) complete=\($0.isComplete) points=\($0.pointCount)"
      }
    }
    return rows
  }

  /// D39 (device finding): the run after a visit-started stay resumes at the arrival itself; the
  /// arrival still starts the stay instead of being dropped (which split it into a 0 m move and a
  /// later stay).
  @Test func visitArrivalAtTheResumeCursorKeepsTheStay() async throws {
    let points = helper.walk(from: 0, for: 300) + helper.still(from: 300, for: 900, at: 420, drift: 70)
    let database = try openDatabase()
    let early = points.filter { helper.seconds($0.timestamp) <= 700 }
    try await database.append(points: early, events: [helper.event(320, .visitArrive)])
    try await TrackProcessor(database: database).process(now: early.last!.timestamp)
    #expect(try await summary(database).map { $0.split(separator: " ")[1] } == ["move", "stay"])

    try await database.append(points: Array(points.dropFirst(early.count)), events: [])
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)
    let rows = try await summary(database)
    #expect(rows.map { $0.split(separator: " ")[1] } == ["move", "stay"])
    #expect(rows.last?.split(separator: " ")[2].hasPrefix("320-") == true)
  }

  /// VS6 (D42): a gap ridden underground becomes a subway ride with its cause kept underneath;
  /// the user's "None" survives a rebuild and shows the cause again.
  @Test func aSubwayGapKeepsItsCauseAndTheUsersChoice() async throws {
    // Walk 5 min, nothing for 20 min while riding 8 km, walk 5 min; the app relaunched meanwhile.
    let points = helper.walk(from: 0, for: 300) + helper.walk(from: 1500, for: 300, startingAt: 8_420)
    var riding = helper.event(600, .motionActivity)
    riding.payload = "activity=automotive confidence=high"
    let database = try openDatabase()
    try await database.append(points: points, events: [riding, helper.event(1490, .backgroundRelaunch)])
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)

    func gap() async throws -> Segment {
      var iterator = database.observeSegments(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
      let segments = try #require(try await iterator.next())
      return try #require(segments.first { $0.kind == .gap })
    }
    let subway = try await gap()
    #expect(subway.gapTravelMode == .subway)
    #expect(subway.gapReason == .notRunning)

    try await database.setTransportMode(.unknown, for: subway)
    _ = try await database.deleteSegments(otherThan: -1)
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)
    let corrected = try await gap()
    #expect(corrected.userTransportMode == .unknown)
    #expect(corrected.gapTravelMode == nil)
    #expect(corrected.gapReason == .notRunning)
  }

  @Test func incrementalRunsMatchOneBatchRun() async throws {
    let (points, events) = day()
    let now = points.last!.timestamp

    let batch = try openDatabase()
    try await batch.append(points: points, events: events)
    try await TrackProcessor(database: batch).process(now: now)
    let expected = try await summary(batch)
    #expect(expected.map { $0.split(separator: " ")[1] } == ["move", "stay", "stay", "move", "gap", "move"])

    // The same data arriving in chunks of 97 points, a new processor (as after a kill) every
    // seventh run.
    let incremental = try AppDatabase(url: directory.appending(path: "incremental.sqlite"))
    var processor = TrackProcessor(database: incremental)
    var pendingEvents = events
    for (run, chunk) in stride(from: 0, to: points.count, by: 97).map({ points[$0..<min($0 + 97, points.count)] }).enumerated() {
      let chunkEnd = chunk.last!.timestamp
      let due = pendingEvents.filter { $0.timestamp <= chunkEnd }
      pendingEvents.removeAll { $0.timestamp <= chunkEnd }
      try await incremental.append(points: Array(chunk), events: due)
      if run.isMultiple(of: 7) { processor = TrackProcessor(database: incremental) }
      try await processor.process(now: chunkEnd)
    }
    #expect(try await summary(incremental) == expected)
  }

  @Test func segmentsOfAnotherVersionAreRebuilt() async throws {
    let database = try openDatabase()
    let (points, events) = day()
    try await database.append(points: points, events: events)
    let stale = Segment(
      id: nil, kind: .gap, start: helper.base, end: helper.base.addingTimeInterval(86_400), timeZoneID: "Asia/Tokyo",
      localDay: LocalDay(year: 2026, month: 11, day: 22), isComplete: true, continuesNextDay: false, pointCount: 0,
      distance: 0, centerLatitude: nil, centerLongitude: nil, radius: nil, pipelineVersion: Segmenter.pipelineVersion - 1)
    try await database.replaceOpenSegments(with: [stale])
    #expect(try await database.deleteSegments(otherThan: Segmenter.pipelineVersion) == 1)
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)
    #expect(try await summary(database).count == 6)
  }

  /// The timeline's distance is the length of the drawn track, not of the raw points: ±3 m noise on
  /// a 1 Hz walk would nearly triple the raw length (VS5 simulator finding).
  @Test func moveDistanceIgnoresGPSNoise() async throws {
    var generator = SystemRandomNumberGenerator()
    let walk = (0..<640).map { second -> RawPoint in
      let noise = { Double.random(in: -3...3, using: &generator) }
      return helper.point(Double(second), north: Double(second) * 1.4 + noise(), east: noise())
    }
    let points = walk + helper.still(from: 640, for: 900, at: 896)
    let raw = zip(walk, walk.dropFirst())
      .map { MotionStateMachine.distance(from: ($0.latitude, $0.longitude), to: ($1.latitude, $1.longitude)) }
      .reduce(0, +)
    #expect(raw > 1400)

    let database = try openDatabase()
    try await database.append(points: points, events: [])
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)
    var iterator = database.observeSegments(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
    let move = try #require(try await iterator.next()?.first { $0.kind == .move })
    // The walk covers 896 m; the move ends where the stay begins, a little before.
    #expect(move.distance > 750 && move.distance < 1000, "\(move.distance)")
  }
}
