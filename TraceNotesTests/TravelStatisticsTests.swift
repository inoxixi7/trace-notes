import Foundation
import GRDB
import Testing

/// VS7.6 · overview statistics (D50): what counts towards distance, countries, days and hours, the
/// year filter, and the region lookup for places named before the slice.
struct TravelStatisticsTests {
  let helper = SegmenterTests()
  let directory = FileManager.default.temporaryDirectory.appending(path: "TravelStatisticsTests-\(UUID().uuidString)")

  /// 2026-11-22 00:00 in Tokyo.
  let midnight = Date(timeIntervalSince1970: 1_795_273_200)

  func segment(
    _ kind: Segment.Kind, from start: TimeInterval, to end: TimeInterval, day: LocalDay = LocalDay(year: 2026, month: 11, day: 22),
    zone: String = "Asia/Tokyo", distance: Double = 0, mode: TransportMode? = nil, id: Int64? = nil, place: Int64? = nil
  ) -> Segment {
    Segment(
      id: id, kind: kind, start: midnight.addingTimeInterval(start), end: midnight.addingTimeInterval(end),
      timeZoneID: zone, localDay: day, isComplete: true, continuesNextDay: false, pointCount: 0, distance: distance,
      centerLatitude: nil, centerLongitude: nil, radius: nil, pipelineVersion: Segmenter.pipelineVersion,
      transportMode: mode, placeID: place)
  }

  func input(_ segments: [Segment], countries: [Int64: String] = [:], gaps: [Int64: Double] = [:]) -> TravelStatistics.Input {
    TravelStatistics.Input(segments: segments, countryOfPlace: countries, gapDistances: gaps, placesAwaitingCountry: 0)
  }

  // MARK: - Computing

  @Test func distanceCountsMovesAndTravelledGapsOnly() {
    var userCar = segment(.gap, from: 7200, to: 7800, id: 3)
    userCar.userTransportMode = .car
    var unexplained = segment(.gap, from: 9000, to: 9600, id: 4)
    unexplained.gapReason = .unknown
    let statistics = TravelStatistics(
      input([
        segment(.move, from: 0, to: 600, distance: 800, mode: .walking),
        segment(.move, from: 600, to: 1200, distance: 5000, mode: .car),
        segment(.gap, from: 3600, to: 4200, mode: .subway, id: 2),
        userCar,
        unexplained,
      ], gaps: [2: 6000, 3: 1500, 4: 9999]),
      year: nil)
    #expect(statistics.distance == 13_300)
    #expect(statistics.distanceByMode == [
      .init(mode: .car, metres: 6500), .init(mode: .subway, metres: 6000), .init(mode: .walking, metres: 800),
    ])
  }

  @Test func countriesInTheOrderFirstVisited() {
    let statistics = TravelStatistics(
      input(
        [
          segment(.stay, from: 0, to: 600, place: 1),
          segment(.stay, from: 1200, to: 1800, place: 2),
          segment(.stay, from: 2400, to: 3000, place: 3),
          segment(.stay, from: 3600, to: 4200, place: 4),
        ],
        countries: [1: "KR", 2: "JP", 3: "KR"]),
      year: nil)
    #expect(statistics.countries == ["KR", "JP"])
  }

  @Test func yearFilterUsesTheLocalDay() {
    let segments = [
      segment(.stay, from: 0, to: 600, day: LocalDay(year: 2025, month: 12, day: 31), place: 1),
      segment(.move, from: 600, to: 1200, day: LocalDay(year: 2025, month: 12, day: 31), distance: 100, mode: .walking),
      segment(.move, from: 90_000, to: 90_600, day: LocalDay(year: 2026, month: 1, day: 1), distance: 300, mode: .cycling),
    ]
    let all = TravelStatistics(input(segments, countries: [1: "JP"]), year: nil)
    let last = TravelStatistics(input(segments, countries: [1: "JP"]), year: 2025)
    #expect(input(segments).years == [2026, 2025])
    #expect(all.distance == 400 && all.recordedDays == 2 && all.firstDay == LocalDay(year: 2025, month: 12, day: 31))
    #expect(last.distance == 100 && last.recordedDays == 1 && last.countries == ["JP"])
  }

  @Test func minutesAreSpreadOverLocalHours() {
    // 08:40–09:10 in Tokyo, and the same instant in UTC (23:40–00:10).
    let tokyo = segment(.move, from: 8 * 3600 + 2400, to: 9 * 3600 + 600, distance: 1, mode: .walking)
    let utc = segment(.move, from: 8 * 3600 + 2400, to: 9 * 3600 + 600, zone: "UTC", distance: 1, mode: .walking)
    let statistics = TravelStatistics(input([tokyo, utc]), year: nil)
    #expect(statistics.minutesByHour[8] == 20 && statistics.minutesByHour[9] == 10)
    #expect(statistics.minutesByHour[23] == 20 && statistics.minutesByHour[0] == 10)
    #expect(statistics.minutesByHour.reduce(0, +) == 60)
  }

  // MARK: - Database

  @Test func gapDistanceIsTheStraightLineBetweenItsSides() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase(url: directory.appending(path: "test.sqlite"))
    try await database.append(
      points: [helper.point(0), helper.point(600, north: 3000), helper.point(601, north: 9000, flags: .replayed)],
      events: [])
    let gap = Segment(
      id: nil, kind: .gap, start: helper.base, end: helper.base.addingTimeInterval(600), timeZoneID: "Asia/Tokyo",
      localDay: LocalDay(year: 2026, month: 11, day: 22), isComplete: true, continuesNextDay: false, pointCount: 0,
      distance: 0, centerLatitude: nil, centerLongitude: nil, radius: nil, pipelineVersion: Segmenter.pipelineVersion,
      transportMode: .subway)
    try await database.replaceOpenSegments(with: [gap])
    var iterator = database.observeStatisticsInput().makeAsyncIterator()
    let input = try #require(try await iterator.next())
    let metres = try #require(input.gapDistances.values.first)
    #expect(abs(metres - 3000) < 1)
  }

  /// A place named before v8 is looked up again for its region alone and keeps its name.
  @Test func placesNamedEarlierGetOnlyTheirRegion() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "test.sqlite")
    do {
      let pool = try DatabasePool(path: url.path(percentEncoded: false))
      try AppDatabase.migrator.migrate(pool, upTo: "v7")
      try await pool.write { db in
        try db.execute(
          sql: """
            INSERT INTO places (latitude, longitude, name, status, attempts, createdAt)
            VALUES (350000000, 1390000000, 'Home', 'resolved', 1, 0)
            """)
      }
    }
    let database = try AppDatabase(url: url)
    let now = helper.base
    struct Offline: Error {}
    try await PlaceResolver(database: database) { _, _ in throw Offline() }.resolveDue(at: now)
    let place = try #require(try await database.placesToResolve(at: .distantFuture, limit: 10).first)
    #expect(place.status == .resolved && place.countryStatus == .failed && place.name == "Home")
    #expect(try await database.placesToResolve(at: now, limit: 10).isEmpty)

    try await PlaceResolver(database: database) { _, _ in .init(name: "Elsewhere", address: nil, countryCode: "JP") }
      .resolveDue(at: .distantFuture)
    #expect(try await database.placesToResolve(at: .distantFuture, limit: 10).isEmpty)
    var iterator = database.observeStatisticsInput().makeAsyncIterator()
    let input = try #require(try await iterator.next())
    #expect(Array(input.countryOfPlace.values) == ["JP"] && input.placesAwaitingCountry == 0)
    let stored = try await DatabasePool(path: url.path(percentEncoded: false)).read { db in try Place.fetchOne(db) }
    #expect(stored?.name == "Home" && stored?.countryCode == "JP")
  }
}
