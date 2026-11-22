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
}
