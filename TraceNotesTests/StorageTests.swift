import Foundation
import GRDB
import Testing

/// VS1 · Storage (TraceNotes/Storage).
struct StorageTests {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "StorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func openDatabase() throws -> (AppDatabase, URL) {
    let url = directory.appending(path: "test.sqlite")
    return (try AppDatabase(url: url), url)
  }

  func point(_ timestamp: Date, latitude: Double = 35.681236, longitude: Double = 139.767125, zone: String = "Asia/Tokyo") -> RawPoint {
    RawPoint(
      id: nil, timestamp: timestamp, latitude: latitude, longitude: longitude, horizontalAccuracy: 5,
      altitude: 40, verticalAccuracy: 3, speed: 1.4, course: 90, timeZoneID: zone, source: .recorded,
      importBatchID: nil, flags: [.lowAccuracy])
  }

  @Test func migratesEmptyDatabaseToLatest() throws {
    let (_, url) = try openDatabase()
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    try queue.read { db in
      #expect(try AppDatabase.migrator.completedMigrations(db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"])
      #expect(try db.tableExists("segments") && db.tableExists("render_cache"))
      #expect(try db.tableExists("raw_points"))
      #expect(try db.tableExists("recorder_events"))
      #expect(try db.indexes(on: "raw_points").contains { $0.columns == ["timestamp"] })
      let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
      #expect(triggers.count == 4)  // raw layer only; segments are derived and replaceable
    }
  }

  @Test func pointRoundTripKeepsMillisecondsAndCentimetres() async throws {
    let (database, url) = try openDatabase()
    let time = Date(timeIntervalSince1970: 1_795_000_000.123)
    let written = point(time, latitude: 35.681_236_789, longitude: -122.009_012_345)
    try await database.append(points: [written], events: [])

    let read = try #require(try await database.points(in: time.addingTimeInterval(-1)..<time.addingTimeInterval(1)).first)
    #expect(RawPoint.milliseconds(read.timestamp) == RawPoint.milliseconds(time))
    let metresPerDegree = 111_195.0
    #expect(abs(read.latitude - written.latitude) * metresPerDegree < 0.02)
    #expect(abs(read.longitude - written.longitude) * metresPerDegree < 0.02)
    #expect(read.timeZoneID == "Asia/Tokyo" && read.source == .recorded && read.flags == [.lowAccuracy])
    #expect(read.altitude == 40 && read.speed == 1.4)

    // Stored as integers, not text or real (D26).
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    let types = try await queue.read { db in
      try String.fetchAll(db, sql: "SELECT typeof(timestamp) || ',' || typeof(latitude) || ',' || typeof(longitude) FROM raw_points")
    }
    #expect(types == ["integer,integer,integer"])
  }

  @Test func rawLayerIsAppendOnly() async throws {
    let (database, url) = try openDatabase()
    try await database.append(points: [point(.now)], events: [RecorderEvent(id: nil, timestamp: .now, kind: .launch, payload: nil)])
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    #expect(throws: DatabaseError.self) {
      try queue.write { db in try db.execute(sql: "UPDATE raw_points SET flags = 0") }
    }
    #expect(throws: DatabaseError.self) {
      try queue.write { db in try db.execute(sql: "DELETE FROM recorder_events") }
    }
  }

  /// F8: each point belongs to the local date of the zone it was recorded in.
  @Test func localDayFollowsEachPointsTimeZone() {
    // 2026-11-22 15:00 UTC = 00:00 on the 23rd in Tokyo, 23:00 on the 22nd in Shanghai.
    let instant = Date(timeIntervalSince1970: 1_795_359_600)
    #expect(LocalDay(instant, timeZoneID: "Asia/Tokyo") == LocalDay(year: 2026, month: 11, day: 23))
    #expect(LocalDay(instant, timeZoneID: "Asia/Shanghai") == LocalDay(year: 2026, month: 11, day: 22))
    // 23:30 local in both cities is the same local date, one hour apart in UTC.
    let tokyo2330 = Date(timeIntervalSince1970: 1_795_357_800)  // 14:30 UTC
    let shanghai2330 = Date(timeIntervalSince1970: 1_795_361_400)  // 15:30 UTC
    #expect(LocalDay(tokyo2330, timeZoneID: "Asia/Tokyo") == LocalDay(year: 2026, month: 11, day: 22))
    #expect(LocalDay(shanghai2330, timeZoneID: "Asia/Shanghai") == LocalDay(year: 2026, month: 11, day: 22))
  }

  @Test func observingADayFiltersByEachPointsZone() async throws {
    let (database, _) = try openDatabase()
    let tokyoMidnight = Date(timeIntervalSince1970: 1_795_359_600)  // 23rd 00:00 Tokyo
    let shanghai2300 = tokyoMidnight  // same instant, 22nd 23:00 Shanghai
    let tokyo2330 = Date(timeIntervalSince1970: 1_795_357_800)  // 22nd 23:30 Tokyo
    try await database.append(
      points: [point(tokyo2330), point(tokyoMidnight), point(shanghai2300, zone: "Asia/Shanghai")], events: [])

    var iterator = database.observePoints(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
    let day22 = try #require(try await iterator.next())
    #expect(day22.map(\.timeZoneID) == ["Asia/Tokyo", "Asia/Shanghai"])
    #expect(day22.map(\.timestamp) == [tokyo2330, shanghai2300])
  }
}
