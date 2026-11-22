import Foundation
import GRDB
import Testing

/// VS5 · places: matching stays to places, the lookup queue with retries, and user names (D37).
struct PlaceTests {
  let helper = SegmenterTests()
  let directory = FileManager.default.temporaryDirectory.appending(path: "PlaceTests-\(UUID().uuidString)")

  func openDatabase() throws -> AppDatabase {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try AppDatabase(url: directory.appending(path: "test.sqlite"))
  }

  func place(north: Double, status: Place.Status = .pending) -> Place {
    Place(
      id: nil, latitude: 35 + north * helper.metre, longitude: 139, name: nil, address: nil, status: status, attempts: 0,
      lastAttemptAt: nil, nextAttemptAt: nil, userName: nil, createdAt: helper.base)
  }

  /// Stay at home, walk 1.2 km, stay at a shop, walk back, stay at home again.
  func dayWithTwoVisitsHome() -> [RawPoint] {
    helper.still(from: 0, for: 900, at: 0, drift: 10)
      + helper.walk(from: 900, for: 857, startingAt: 0)
      + helper.still(from: 1757, for: 900, at: 1200, drift: 10)
      + helper.walk(from: 2657, for: 857, startingAt: 1200).map { point in
        // Back south along the same street.
        var back = point
        back.latitude = 35 + (2400 - (point.latitude - 35) / helper.metre) * helper.metre
        return back
      }
      + helper.still(from: 3514, for: 900, at: 0, drift: 10)
  }

  func segments(_ database: AppDatabase) async throws -> [Segment] {
    var iterator = database.observeSegments(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
    return try #require(try await iterator.next())
  }

  func places(_ database: AppDatabase) async throws -> [Int64: Place] {
    var iterator = database.observePlaces(on: LocalDay(year: 2026, month: 11, day: 22)).makeAsyncIterator()
    return try #require(try await iterator.next())
  }

  // MARK: - Matching

  @Test func nearestPlaceWithinTheMatchRadius() {
    var near = place(north: 30)
    near.id = 1
    var far = place(north: 80)
    far.id = 2
    #expect(Place.nearest(to: 35, 139, in: [far, near])?.id == 1)
    #expect(Place.nearest(to: 35, 139, in: [far]) == nil)
  }

  @Test func staysAtTheSameSpotShareOnePlace() async throws {
    let database = try openDatabase()
    let points = dayWithTwoVisitsHome()
    try await database.append(points: points, events: [])
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)
    let stays = try await segments(database).filter { $0.kind == .stay }
    #expect(stays.count == 3)
    #expect(stays[0].placeID != nil && stays[0].placeID == stays[2].placeID)
    #expect(stays[1].placeID != stays[0].placeID)
    #expect(try await places(database).count == 2)
  }

  // MARK: - Lookup queue

  @Test func resolverNamesNewPlaces() async throws {
    let database = try openDatabase()
    let points = dayWithTwoVisitsHome()
    try await database.append(points: points, events: [])
    try await TrackProcessor(database: database).process(now: points.last!.timestamp)
    let resolver = PlaceResolver(database: database) { latitude, _ in
      latitude > 35.005 ? .init(name: "FamilyMart", address: "Shimanouchi 1") : .init(name: nil, address: "Kitahorie 2")
    }
    try await resolver.resolveDue(at: points.last!.timestamp)
    let names = try await places(database).values.map(\.displayName).sorted { ($0 ?? "") < ($1 ?? "") }
    #expect(names == ["FamilyMart", "Kitahorie 2"])
    #expect(try await database.placesToResolve(at: .distantFuture, limit: 10).isEmpty)
  }

  @Test func failedLookupIsRetriedOnlyWhenDue() async throws {
    struct Offline: Error {}
    let database = try openDatabase()
    try await database.append(points: helper.still(from: 0, for: 900, at: 0, drift: 10), events: [])
    try await TrackProcessor(database: database).process(now: helper.base.addingTimeInterval(900))
    let now = helper.base.addingTimeInterval(900)

    try await PlaceResolver(database: database) { _, _ in throw Offline() }.resolveDue(at: now)
    let failed = try #require(try await places(database).values.first)
    #expect(failed.status == .failed && failed.attempts == 1)
    #expect(failed.nextAttemptAt == now.addingTimeInterval(Place.retryDelays[0]))
    #expect(try await database.placesToResolve(at: now.addingTimeInterval(59), limit: 10).isEmpty)

    let later = now.addingTimeInterval(Place.retryDelays[0])
    try await PlaceResolver(database: database) { _, _ in .init(name: "Home", address: nil) }.resolveDue(at: later)
    let resolved = try #require(try await places(database).values.first)
    #expect(resolved.status == .resolved && resolved.displayName == "Home" && resolved.nextAttemptAt == nil)
  }

  @Test func retryDelaysGrowAndThenRepeat() {
    var place = place(north: 0)
    var delays: [TimeInterval] = []
    for _ in 0..<7 {
      place.recordFailure(at: helper.base)
      delays.append(place.nextAttemptAt!.timeIntervalSince(helper.base))
    }
    #expect(delays == Place.retryDelays + [Place.retryDelays.last!, Place.retryDelays.last!])
  }

  // MARK: - User names

  @Test func userNameWinsAndSurvivesLookupAndRecomputation() async throws {
    let database = try openDatabase()
    let points = dayWithTwoVisitsHome()
    let now = points.last!.timestamp
    try await database.append(points: points, events: [])
    try await TrackProcessor(database: database).process(now: now)
    let home = try #require(try await segments(database).first?.placeID)

    try await database.renamePlace(id: home, to: "  Home ")
    try await PlaceResolver(database: database) { _, _ in .init(name: "Some shop", address: "Kitahorie 2") }.resolveDue(at: now)
    #expect(try await places(database)[home]?.displayName == "Home")

    // A new pipeline version rebuilds the segments; the place and its name stay.
    try await database.deleteSegments(otherThan: -1)
    try await TrackProcessor(database: database).process(now: now)
    let rebuilt = try await segments(database).filter { $0.kind == .stay }
    #expect(rebuilt.first?.placeID == home && rebuilt.last?.placeID == home)
    #expect(try await places(database)[home]?.displayName == "Home")

    // A blank name goes back to the looked-up one.
    try await database.renamePlace(id: home, to: " ")
    #expect(try await places(database)[home]?.displayName == "Some shop")
  }
}
