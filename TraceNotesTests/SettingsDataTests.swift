import Foundation
import GRDB
import Testing

/// VS10 · deleting all data (D55 ②③) and the diagnostic report (D55 ⑤).
struct SettingsDataTests {
  let processing = TrackProcessorTests()
  let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsDataTests-\(UUID().uuidString)")

  func openDatabase() throws -> (AppDatabase, URL) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "test.sqlite")
    return (try AppDatabase(url: url), url)
  }

  func first<Value>(_ observation: AsyncValueObservation<Value>) async throws -> Value {
    var iterator = observation.makeAsyncIterator()
    return try #require(try await iterator.next())
  }

  /// A processed day with a renamed place, a corrected mode, Fog of World and a MetricKit report.
  func filledDatabase() async throws -> (AppDatabase, URL, [RawPoint]) {
    let (database, url) = try openDatabase()
    let (points, events) = processing.day()
    try await database.append(points: points, events: events)
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)
    let segments = try await first(database.observeSegments(on: LocalDay(year: 2026, month: 11, day: 22)))
    let stay = try #require(segments.first { $0.kind == .stay })
    try await database.renamePlace(id: try #require(stay.placeID), to: "Secret Café")
    try await database.setTransportMode(.cycling, for: try #require(segments.first { $0.kind == .move }))
    let origin = FogOfWorldTests.origin
    try await database.replaceFogOfWorld(
      FogOfWorld.stored(FogOfWorldTests.blocks((0..<10).map { (x: origin.x + $0, y: origin.y) })), importedAt: .now)
    try await database.saveMetricReport(MetricReport(receivedAt: points.last!.timestamp, kind: .metrics, json: #"{"launches":3}"#))
    return (database, url, points)
  }

  @Test func deletingAllDataEmptiesEveryTableAndRecordingGoesOn() async throws {
    let (database, url, points) = try await filledDatabase()
    let before = try await first(database.observeDataSummary())
    #expect(before.days > 0 && before.metres > 0 && before.hasFogOfWorld)

    try await database.deleteAllData()

    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    try await queue.read { db in
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'")
      #expect(Set(["raw_points", "recorder_events", "segments", "places", "segment_overrides", "fog_blocks", "metric_reports"]).isSubset(of: tables))
      for table in tables {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") == 0, "\(table)")
      }
    }
    #expect(try await first(database.observeDataSummary()) == AppDatabase.DataSummary(days: 0, metres: 0, hasFogOfWorld: false))

    // Recording goes on (D55 ③): new points are processed, with IDs after the deleted ones.
    let later = points.map { point in
      var point = point
      point.timestamp.addTimeInterval(2 * 24 * 3600)
      return point
    }
    try await database.append(points: later, events: [])
    try await TrackProcessor(database: database).process(now: later.last!.timestamp)
    #expect(try await first(database.observeDataSummary()).days > 0)
    let firstNewID = try await queue.read { db in try Int64.fetchOne(db, sql: "SELECT MIN(id) FROM raw_points") }
    #expect(firstNewID ?? 0 > Int64(points.count))

    // The raw layer is append-only again.
    await #expect(throws: DatabaseError.self) {
      try await queue.write { db in try db.execute(sql: "DELETE FROM raw_points") }
    }
  }

  /// A processing run that read before the deletion stores nothing after it.
  @Test func aRunStartedBeforeTheDeletionIsRefused() async throws {
    let (database, url, points) = try await filledDatabase()
    let input = try await database.segmentationInput()
    #expect(input.lastComplete != nil)
    try await database.deleteAllData()
    var segmenter = Segmenter(seed: .fresh(start: nil))
    for point in points { segmenter.add(point) }
    let stale = segmenter.finish(at: points.last!.timestamp)
    #expect(!stale.isEmpty)
    #expect(try await !database.replaceOpenSegments(madeFrom: input, with: stale, renderLevels: [:]))
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    #expect(try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments") } == 0)
  }

  @Test func theReportHasNoCoordinatesOrPlaceNames() async throws {
    let (database, _, points) = try await filledDatabase()
    let input = try await database.diagnosticsInput(since: points[0].timestamp.addingTimeInterval(-3600))
    #expect(input.segments.contains { $0.centerLatitude != nil })
    let text = DiagnosticReport.text(
      device: DiagnosticReport.Device(
        appVersion: "1.0", build: "7", systemVersion: "26.1", model: "iPhone15,2", language: "zh-Hans-JP", timeZoneID: "Asia/Tokyo"),
      status: DiagnosticReport.Status(
        authorization: "always", locationServicesOff: false, lowPowerMode: true, isRecording: true,
        engineState: "stationary", lastStorageError: nil),
      input: input,
      logs: [DiagnosticReport.LogLine(date: points[0].timestamp, category: "storage", message: "write failed")],
      now: points.last!.timestamp)

    #expect(text.contains("App 1.0 (7)") && text.contains("Low Power Mode on"))
    #expect(text.contains("2026-11-22 | "))
    #expect(text.contains("visitDepart"))
    #expect(text.contains(#"{"launches":3}"#))
    #expect(text.contains("[storage] write failed"))
    #expect(!text.contains("Secret Café"))
    // No number with three or more decimals: coordinates would show as such.
    #expect(text.firstMatch(of: /\d+\.\d{3,}/) == nil)
    #expect(!text.contains("35.") && !text.contains("139."))
  }

  /// D56: the drain table files each interval under its first sample's day and recorder state and
  /// leaves out charging.
  @Test func batteryDrainIsSplitByDayAndState() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    // 2026-11-23 00:00 in Tokyo.
    let midnight = Date(timeIntervalSince1970: 1_795_359_600)
    func sample(_ hours: Double, _ level: Int, _ power: String, _ engine: String) -> RecorderEvent {
      RecorderEvent(
        id: nil, timestamp: midnight.addingTimeInterval(hours * 3600), kind: .battery,
        payload: "level=\(level) power=\(power) engine=\(engine)")
    }
    let events = [
      sample(0, 90, "unplugged", "stationary"),
      RecorderEvent(id: nil, timestamp: midnight.addingTimeInterval(1800), kind: .visitDepart, payload: "accuracy=20"),
      sample(4, 88, "unplugged", "moving.walking"),
      sample(5, 85, "unplugged", "stationary"),
      sample(6, 85, "charging", "stationary"),
      sample(7, 95, "unplugged", "stationary"),
      // A charge missed between two samples: the level rose, so the interval is left out.
      sample(24, 99, "unplugged", "stationary"),
      sample(26, 98, "unplugged", "stationary"),
    ]
    let lines = DiagnosticReport.batteryLines(events, timeZone: tokyo)
    #expect(lines == [
      "day | drop on battery | still: hours, drop, per hour | moving: hours, drop, per hour",
      "2026-11-23 | 5 % | 4.0 h, 2 %, 0.50 %/h | 1.0 h, 3 %, 3.00 %/h",
      "2026-11-24 | 1 % | 2.0 h, 1 %, 0.50 %/h | -",
    ])
    #expect(DiagnosticReport.batteryLines([sample(0, 90, "unplugged", "stationary")], timeZone: tokyo) == ["No battery samples yet."])
  }

  @Test func metricReportsAreKeptThirtyDays() async throws {
    let (database, _) = try openDatabase()
    let start = Date(timeIntervalSince1970: 1_795_305_600)
    try await database.saveMetricReport(MetricReport(receivedAt: start, kind: .diagnostics, json: "{}"))
    try await database.saveMetricReport(
      MetricReport(receivedAt: start.addingTimeInterval(MetricReport.retention + 60), kind: .metrics, json: "{}"))
    let reports = try await database.diagnosticsInput(since: .distantPast).metricReports
    #expect(reports.map(\.kind) == [.metrics])
  }
}
