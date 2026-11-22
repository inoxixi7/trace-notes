import Foundation
import GRDB
import Testing

/// VS4 · TransportClassifier (pipeline step ④) and the transport-mode overrides (§2.2).
struct TransportClassifierTests {
  let helper = SegmenterTests()

  /// One point per second heading north at `metresPerSecond`, without a recorded speed.
  func travel(from start: TimeInterval, for duration: TimeInterval, metresPerSecond: Double, startingAt north: Double) -> [RawPoint] {
    stride(from: 0.0, to: duration, by: 1).map { helper.point(start + $0, north: north + $0 * metresPerSecond) }
  }

  func reading(_ seconds: TimeInterval, _ activity: TransportClassifier.ActivityReading.Activity) -> TransportClassifier.ActivityReading {
    .init(timestamp: helper.base.addingTimeInterval(seconds), activity: activity)
  }

  func summary(_ runs: [TransportClassifier.Run]) -> [String] {
    runs.map { "\($0.mode)@\(Int(helper.seconds($0.start)))" }
  }

  @Test func aWalkIsWalking() {
    let runs = TransportClassifier.runs(of: helper.walk(from: 0, for: 600), activities: [])
    #expect(summary(runs) == ["walking@0"])
    #expect(runs[0].confidence > 0.95)
  }

  @Test func walkDriveWalkSplitsIntoThreeBySpeedAlone() {
    let points = travel(from: 0, for: 360, metresPerSecond: 1.4, startingAt: 0)
      + travel(from: 360, for: 1200, metresPerSecond: 15, startingAt: 504)
      + travel(from: 1560, for: 360, metresPerSecond: 1.4, startingAt: 18_504)
    let runs = TransportClassifier.runs(of: points, activities: [])
    let modes = runs.map(\.mode)
    #expect(modes == [.walking, .car, .walking])
    // Boundaries within the median window of the real change.
    #expect(abs(helper.seconds(runs[1].start) - 360) <= 60)
    #expect(abs(helper.seconds(runs[2].start) - 1560) <= 60)
  }

  @Test func aRedLightStaysInsideTheDrive() {
    let points = travel(from: 0, for: 600, metresPerSecond: 15, startingAt: 0)
      + travel(from: 600, for: 120, metresPerSecond: 0, startingAt: 9000)
      + travel(from: 720, for: 600, metresPerSecond: 15, startingAt: 9000)
    #expect(summary(TransportClassifier.runs(of: points, activities: [])) == ["car@0"])
  }

  @Test func aShortWalkUnderFiveMinutesJoinsTheDrive() {
    let points = travel(from: 0, for: 900, metresPerSecond: 15, startingAt: 0)
      + travel(from: 900, for: 240, metresPerSecond: 1.4, startingAt: 13_500)
      + travel(from: 1140, for: 900, metresPerSecond: 15, startingAt: 13_836)
    #expect(TransportClassifier.runs(of: points, activities: []).map(\.mode) == [.car])
  }

  @Test func theSensorDecidesWhereSpeedCannot() {
    // A car at walking pace in a jam: the sensor says automotive.
    let jam = travel(from: 0, for: 600, metresPerSecond: 1.5, startingAt: 0)
    #expect(TransportClassifier.runs(of: jam, activities: [reading(-10, .automotive)]).map(\.mode) == [.car])
    // A run at 10 km/h: running only with the sensor, cycling by speed alone.
    let jog = travel(from: 0, for: 600, metresPerSecond: 2.8, startingAt: 0)
    #expect(TransportClassifier.runs(of: jog, activities: [reading(0, .running)]).map(\.mode) == [.running])
    #expect(TransportClassifier.runs(of: jog, activities: []).map(\.mode) == [.cycling])
    // Stationary readings say nothing about the mode; speed decides.
    #expect(TransportClassifier.runs(of: jog, activities: [reading(0, .stationary)]).map(\.mode) == [.cycling])
  }

  @Test func speedOverrulesAnImpossibleReading() {
    #expect(TransportClassifier.mode(kmh: 60, reading: .walking) == .car)
    #expect(TransportClassifier.mode(kmh: 250, reading: .automotive) == .train)
    #expect(TransportClassifier.mode(kmh: 500, reading: .automotive) == .airplane)
    #expect(TransportClassifier.mode(kmh: 20, reading: .cycling) == .cycling)
    #expect(TransportClassifier.mode(kmh: 6.9, reading: nil) == .walking)
    #expect(TransportClassifier.mode(kmh: 30, reading: nil) == .car)
  }

  @Test func recordedSpeedIsPreferredOverJitteryPositions() {
    // Positions jump back and forth, but the Doppler speed says a steady walk.
    let points = (0..<600).map { second -> RawPoint in
      var point = helper.point(Double(second), north: Double(second) * 1.4 + (second.isMultiple(of: 2) ? 15 : -15))
      point.speed = 1.4
      return point
    }
    #expect(TransportClassifier.runs(of: points, activities: []).map(\.mode) == [.walking])
  }

  @Test func readsTheRecordedPayload() {
    let event = RecorderEvent(id: nil, timestamp: helper.base, kind: .motionActivity, payload: "activity=automotive confidence=high")
    #expect(TransportClassifier.ActivityReading(event)?.activity == .automotive)
    let other = RecorderEvent(id: nil, timestamp: helper.base, kind: .launch, payload: "activity=automotive")
    #expect(TransportClassifier.ActivityReading(other) == nil)
  }

  @Test func splitPiecesShareBoundariesAndKeepTheirDistance() throws {
    let points = travel(from: 0, for: 360, metresPerSecond: 1.4, startingAt: 0)
      + travel(from: 360, for: 1200, metresPerSecond: 15, startingAt: 504)
    let move = try #require(helper.segment(points).first)
    let pieces = TransportClassifier.split(move, points: points, activities: [])
    #expect(pieces.map(\.transportMode) == [.walking, .car])
    #expect(pieces.first?.start == move.start && pieces.last?.end == move.end)
    #expect(pieces[0].end == pieces[1].start)
    #expect(abs(pieces.map(\.distance).reduce(0, +) - move.distance) < 30)
  }

  // MARK: - Overrides

  func override(_ start: TimeInterval, _ end: TimeInterval, _ mode: TransportMode, createdAt: TimeInterval = 0) -> SegmentOverride {
    SegmentOverride(
      id: nil, startTime: helper.base.addingTimeInterval(start), endTime: helper.base.addingTimeInterval(end),
      field: .transportMode, value: mode.rawValue, createdAt: helper.base.addingTimeInterval(createdAt))
  }

  func move(_ start: TimeInterval, _ end: TimeInterval) -> Segment {
    Segment(
      id: nil, kind: .move, start: helper.base.addingTimeInterval(start), end: helper.base.addingTimeInterval(end),
      timeZoneID: "Asia/Tokyo", localDay: LocalDay(year: 2026, month: 11, day: 22), isComplete: true,
      continuesNextDay: false, pointCount: 0, distance: 0, centerLatitude: nil, centerLongitude: nil, radius: nil,
      pipelineVersion: Segmenter.pipelineVersion, transportMode: .car)
  }

  @Test func overrideGoesToTheMoveItOverlapsMost() {
    var segments = [move(0, 600), move(600, 1800)]
    let unmatched = SegmentOverride.applyTransportModes([override(500, 1700, .train)], to: &segments)
    #expect(unmatched == 0)
    #expect(segments.map(\.displayedTransportMode) == [.car, .train])
  }

  @Test func overrideUnderHalfOverlapIsNotApplied() {
    var segments = [move(0, 400), move(1000, 1400)]
    let unmatched = SegmentOverride.applyTransportModes([override(0, 1000, .train)], to: &segments)
    #expect(unmatched == 1)
    #expect(segments.allSatisfy { $0.userTransportMode == nil })
  }

  @Test func newestOverrideWins() {
    var segments = [move(0, 600)]
    _ = SegmentOverride.applyTransportModes(
      [override(0, 600, .cycling, createdAt: 20), override(0, 600, .train, createdAt: 10)], to: &segments)
    #expect(segments[0].userTransportMode == .cycling)
  }

  @Test func overrideSurvivesRecomputation() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TransportClassifierTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase(url: directory.appending(path: "test.sqlite"))
    let points = travel(from: 0, for: 360, metresPerSecond: 1.4, startingAt: 0)
      + travel(from: 360, for: 1200, metresPerSecond: 15, startingAt: 504)
      + helper.still(from: 1560, for: 900, at: 18_504)
    try await database.append(points: points, events: [])
    let now = points.last!.timestamp
    try await TrackProcessor(database: database).process(now: now)

    let day = LocalDay(year: 2026, month: 11, day: 22)
    func segments() async throws -> [Segment] {
      var iterator = database.observeSegments(on: day).makeAsyncIterator()
      return try #require(try await iterator.next())
    }
    let drive = try #require(try await segments().first { $0.transportMode == .car })
    try await database.setTransportMode(.train, for: drive)
    #expect(try await segments().first { $0.start == drive.start }?.displayedTransportMode == .train)

    // A new pipeline version rebuilds every segment from the raw layer.
    try await database.deleteSegments(otherThan: -1)
    try await TrackProcessor(database: database).process(now: now)
    let rebuilt = try await segments()
    #expect(rebuilt.map { $0.displayedTransportMode } == [.walking, .train, nil])
  }
}
