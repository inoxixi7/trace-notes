import Foundation
import GRDB
import Testing

/// VS8 · GPX import and export (F9, D53).
struct GPXTests {
  let helper = SegmenterTests()
  let directory = FileManager.default.temporaryDirectory.appending(path: "GPXTests-\(UUID().uuidString)")

  func database() throws -> AppDatabase {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try AppDatabase(url: directory.appending(path: "test.sqlite"))
  }

  func imported(_ point: RawPoint) -> RawPoint {
    var point = point
    point.source = .gpxImport
    return point
  }

  // MARK: - Writing and reading

  /// What is written reads back the same: time to the millisecond, position to 1e-7°, accuracy,
  /// altitude, speed, course and the point's own time zone.
  @Test func exportReadsBackTheSame() throws {
    var point = helper.point(0.123, north: 12.3, east: 45.6, accuracy: 7.5, zone: "Europe/Paris")
    point.altitude = 41.2
    point.speed = 1.25
    point.course = 270
    let data = GPXWriter.document(of: [point, helper.point(10, north: 20)], gapInterval: 300)
    let read = try GPXReader.read(data, timeZoneID: "Asia/Tokyo")
    #expect(read.skipped == 0 && read.points.count == 2)
    let first = try #require(read.points.first)
    #expect(RawPoint.milliseconds(first.timestamp) == RawPoint.milliseconds(point.timestamp))
    #expect(RawPoint.scaled(first.latitude) == RawPoint.scaled(point.latitude))
    #expect(RawPoint.scaled(first.longitude) == RawPoint.scaled(point.longitude))
    #expect(first.horizontalAccuracy == 7.5 && first.altitude == 41.2 && first.speed == 1.25 && first.course == 270)
    #expect(first.timeZoneID == "Europe/Paris" && first.source == .gpxImport)
    #expect(read.points[1].timeZoneID == "Asia/Tokyo")
  }

  /// D53 ②: one track per local day of each point's own zone, a new segment after a silence
  /// longer than the gap interval.
  @Test func tracksPerDayAndSegmentsAtGaps() throws {
    // helper.base is 2026-11-22 00:00 UTC, 09:00 in Tokyo.
    let points = [
      helper.point(0), helper.point(60), helper.point(60 + 301),
      helper.point(16 * 3600),  // 01:00 the next day in Tokyo
    ]
    let xml = String(decoding: GPXWriter.document(of: points, gapInterval: 300), as: UTF8.self)
    #expect(xml.components(separatedBy: "<trk>").count - 1 == 2)
    #expect(xml.components(separatedBy: "<trkseg>").count - 1 == 3)
    #expect(xml.contains("<name>2026-11-22</name>") && xml.contains("<name>2026-11-23</name>"))
  }

  /// Files from other apps: route points count too, waypoints do not, points without a time or a
  /// valid position are counted and left out, and missing accuracy means exact.
  @Test func readsTracksAndRoutesFromOtherApps() throws {
    let xml = """
      <?xml version="1.0"?>
      <gpx version="1.1" creator="Other" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><time>2020-01-01T00:00:00Z</time></metadata>
        <wpt lat="35" lon="139"><time>2026-11-22T00:00:00Z</time></wpt>
        <trk><trkseg>
          <trkpt lat="35.0001" lon="139.0001"><ele>12</ele><time>2026-11-22T01:00:00Z</time></trkpt>
          <trkpt lat="35.0002" lon="139.0002"></trkpt>
          <trkpt lat="95" lon="139"><time>2026-11-22T01:00:05Z</time></trkpt>
        </trkseg></trk>
        <rte><rtept lat="35.0003" lon="139.0003"><time>2026-11-22T00:59:00+09:00</time></rtept></rte>
      </gpx>
      """
    let read = try GPXReader.read(Data(xml.utf8), timeZoneID: "Asia/Tokyo")
    #expect(read.points.count == 2 && read.skipped == 2)
    // Oldest first: the route point is at 2026-11-21 15:59 UTC.
    #expect(read.points.map(\.latitude) == [35.0003, 35.0001])
    #expect(read.points.allSatisfy { $0.horizontalAccuracy == 0 })
    #expect(read.points[1].altitude == 12)
  }

  @Test func refusesWhatItCannotUse() {
    #expect(throws: GPXReader.Failure.notGPX) { try GPXReader.read(Data("not xml".utf8), timeZoneID: "UTC") }
    #expect(throws: GPXReader.Failure.notGPX) { try GPXReader.read(Data("<kml></kml>".utf8), timeZoneID: "UTC") }
    #expect(throws: GPXReader.Failure.noPoints) { try GPXReader.read(Data("<gpx version=\"1.1\"></gpx>".utf8), timeZoneID: "UTC") }
    #expect(throws: GPXReader.Failure.noUsablePoints) {
      try GPXReader.read(Data("<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"2\"/></trkseg></trk></gpx>".utf8), timeZoneID: "UTC")
    }
    #expect(throws: GPXReader.Failure.notGPX) { try GPXReader.read(Data(), timeZoneID: "UTC") }
  }

  // MARK: - Database

  /// F9: importing the same file again adds nothing; each import that adds points is its own
  /// batch.
  @Test func reimportingAddsNoDuplicates() async throws {
    let database = try database()
    let points = (0..<5).map { imported(helper.point(Double($0) * 10, north: Double($0) * 10)) }
    let first = try await database.importGPX(points)
    let again = try await database.importGPX(points)
    #expect(first == .init(added: 5, duplicates: 0))
    #expect(again == .init(added: 0, duplicates: 5))
    let more = try await database.importGPX(points + [imported(helper.point(60, north: 60))])
    #expect(more == .init(added: 1, duplicates: 5))
    let batches = try await DatabasePool(path: directory.appending(path: "test.sqlite").path(percentEncoded: false)).read { db in
      try Int64.fetchAll(db, sql: "SELECT DISTINCT importBatchID FROM raw_points ORDER BY 1")
    }
    // The import that added nothing left no batch behind.
    #expect(batches == [1, 2])
  }

  /// D53 ③: an imported point within five minutes of a recorded one is kept but not used; one
  /// further away is.
  @Test func recordingWinsWhereTheyOverlap() async throws {
    let database = try database()
    try await database.append(points: [helper.point(1000), helper.point(1200)], events: [])
    _ = try await database.importGPX([
      imported(helper.point(500, north: 100)),  // 500 s before the first recorded point
      imported(helper.point(800, north: 100)),  // 200 s before it
      imported(helper.point(1100, north: 100)),
      imported(helper.point(1600, north: 100)),  // 400 s after the last
    ])
    let points = try await database.points(in: helper.base..<helper.base.addingTimeInterval(2000))
    #expect(points.map { $0.timestamp.timeIntervalSince(helper.base) } == [500, 1000, 1200, 1600])
    let exported = try await database.exportPoints(on: LocalDay(year: 2026, month: 11, day: 22)...LocalDay(year: 2026, month: 11, day: 22))
    #expect(exported.count == 4)
  }

  /// Importing into the past drops the segments from there on, so the processor recomputes them
  /// with the imported points (ARCHITECTURE §5.4).
  @Test func importRecomputesFromTheEarliestNewPoint() async throws {
    let database = try database()
    let processor = TrackProcessor(database: database)
    // Recorded: a stay, then from 4000 s a stay 3 km north.
    let recorded = stride(from: 0.0, through: 1200, by: 60).map { helper.point($0) }
      + stride(from: 4000.0, through: 5200, by: 60).map { helper.point($0, north: 3000) }
    try await database.append(points: recorded, events: [])
    try await processor.process(now: helper.base.addingTimeInterval(5300))
    let before = try await segments(database)
    #expect(before.map(\.kind) == [.stay, .gap, .stay])

    // The import fills the hole with a walk north.
    let walk = stride(from: 1600.0, through: 3600, by: 20).map { imported(helper.point($0, north: ($0 - 1600) * 1.4)) }
    _ = try await database.importGPX(walk)
    try await processor.process(now: helper.base.addingTimeInterval(5300))
    let after = try await segments(database)
    #expect(after.contains { $0.kind == .move && $0.distance > 2000 })
    #expect(after.first?.kind == .stay && after.first?.start == helper.base)
  }

  /// Poor and replayed fixes are left out of the file (D53 ②).
  @Test func exportLeavesOutPoorAndReplayedFixes() async throws {
    let database = try database()
    try await database.append(
      points: [helper.point(0), helper.point(10, accuracy: 300), helper.point(20, flags: .replayed), helper.point(30)], events: [])
    let day = LocalDay(year: 2026, month: 11, day: 22)
    let exported = try await database.exportPoints(on: day...day)
    #expect(exported.map { $0.timestamp.timeIntervalSince(helper.base) } == [0, 30])
    #expect(try await database.pointDays() == day...day)
  }

  private func segments(_ database: AppDatabase) async throws -> [Segment] {
    var iterator = database.observeSegments(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
    return try #require(try await iterator.next())
  }
}
