import Foundation
import GRDB
import MapKit
import Testing

/// Overview (D44): track boxes stored with the render cache, the viewport query and the boxes the
/// map asks for.
struct OverviewTests {
  let modes = TransportClassifierTests()
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "OverviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  /// A straight track from (latitude, longitude) one step north-east per point, at every level.
  func levels(from latitude: Double, _ longitude: Double, steps: Int = 3, step: Double = 0.01) -> [[RenderCache.Coordinate]] {
    let track = (0...steps).map { (latitude + Double($0) * step, longitude + Double($0) * step) }
    return RenderCache.tolerances.map { _ in track }
  }

  /// Completed moves at the given starts (minutes), with these tracks.
  func store(_ tracks: [[[RenderCache.Coordinate]]], in database: AppDatabase) async throws {
    let segments = tracks.indices.map { modes.move(Double($0) * 600, Double($0) * 600 + 300) }
    try await database.replaceOpenSegments(
      with: segments, renderLevels: Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0, $1) }))
  }

  func first<Value>(_ observation: AsyncValueObservation<Value>) async throws -> Value {
    var iterator = observation.makeAsyncIterator()
    return try #require(try await iterator.next())
  }

  func box(_ latitudes: ClosedRange<Double>, _ longitudes: ClosedRange<Double>...) -> GeoBox {
    GeoBox(latitudes: latitudes, longitudes: longitudes)
  }

  @Test func onlyTracksMeetingTheBoxAreRead() async throws {
    let database = try AppDatabase(url: directory.appending(path: "test.sqlite"))
    #expect(try await first(database.observeOverviewBounds(includingFogOfWorld: false)) == nil)
    // Tokyo, Osaka, and a track crossing the antimeridian's east side (Fiji).
    try await store([levels(from: 35.6, 139.7), levels(from: 34.6, 135.4), levels(from: -17.8, 179.95, steps: 2, step: 0.02)], in: database)

    let bounds = try #require(try await first(database.observeOverviewBounds(includingFogOfWorld: false)))
    #expect(abs(bounds.latitudes.lowerBound - -17.8) < 1e-6 && abs(bounds.latitudes.upperBound - 35.63) < 1e-6)

    let tokyo = try await first(database.observeOverviewTracks(in: box(35.5...35.7, 139.6...139.8), level: 2))
    #expect(tokyo.count == 1)
    #expect(tokyo.values.first?.count == 4)
    let japan = try await first(database.observeOverviewTracks(in: box(30...40, 130...145), level: 0))
    #expect(japan.count == 2)
    // A box split at ±180° finds the Fiji track (it ends at 179.99°).
    let pacific = try await first(database.observeOverviewTracks(in: box(-20...(-15), 179.98...180, -180...(-179)), level: 4))
    #expect(pacific.count == 1)
    let nowhere = try await first(database.observeOverviewTracks(in: box(0...1, 0...1), level: 0))
    #expect(nowhere.isEmpty)
  }

  @Test func boxesGoWithTheirSegment() async throws {
    let database = try AppDatabase(url: directory.appending(path: "test.sqlite"))
    try await store([levels(from: 35.6, 139.7)], in: database)
    #expect(try await database.deleteSegments(otherThan: Segmenter.pipelineVersion + 1) == 1)
    #expect(try await first(database.observeOverviewBounds(includingFogOfWorld: false)) == nil)
  }

  /// v7 fills the boxes of moves stored before it, from their finest level.
  @Test func migrationFillsBoxesFromTheStoredCache() throws {
    let url = directory.appending(path: "old.sqlite")
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    try AppDatabase.migrator.migrate(queue, upTo: "v6")
    try queue.write { db in
      var segment = modes.move(0, 300)
      try segment.insert(db)
      let segmentID = try #require(segment.id)
      for (level, coordinates) in levels(from: 35.6, 139.7).enumerated() {
        try RenderCacheEntry(segmentID: segmentID, level: level, coordinates: coordinates).insert(db)
      }
    }
    try AppDatabase.migrator.migrate(queue)
    let bounds = try queue.read { db in try TrackBounds.fetchAll(db) }
    #expect(bounds.count == 1)
    #expect(bounds.first?.minLatitude == RawPoint.scaled(35.6) && bounds.first?.maxLongitude == RawPoint.scaled(139.73))
  }

  @Test func mapRectsSplitAtTheAntimeridian() {
    let world = MKMapRect.world
    let japan = MKMapRect(
      origin: MKMapPoint(CLLocationCoordinate2D(latitude: 40, longitude: 130)),
      size: MKMapSize(width: world.width / 36, height: world.width / 36))
    let plain = OverviewRequest.box(for: japan)
    #expect(plain.longitudes.count == 1)
    #expect(abs(plain.longitudes[0].lowerBound - 130) < 1e-9 && abs(plain.longitudes[0].upperBound - 140) < 1e-9)
    #expect(plain.latitudes.upperBound > plain.latitudes.lowerBound)

    // 170° E to 170° W: the map shows map points past the world's right edge.
    let pacific = MKMapRect(x: world.width * 350 / 360, y: world.midY, width: world.width * 20 / 360, height: 1000)
    let split = OverviewRequest.box(for: pacific).longitudes
    #expect(split.count == 2)
    #expect(abs(split[0].lowerBound - 170) < 1e-9 && split[0].upperBound == 180)
    #expect(split[1].lowerBound == -180 && abs(split[1].upperBound - -170) < 1e-9)

    #expect(OverviewRequest.box(for: world.insetBy(dx: -world.width, dy: 0)).longitudes == [-180...180])
  }

  @Test func aRequestCoversSmallMovesAtTheSameLevel() {
    let visible = MKMapRect(x: MKMapRect.world.midX, y: MKMapRect.world.midY, width: 10_000, height: 20_000)
    let request = OverviewRequest(visible: visible, level: 2)
    #expect(request.covers(visible.offsetBy(dx: 4_000, dy: -9_000), level: 2))
    #expect(!request.covers(visible, level: 1))
    #expect(!request.covers(visible.offsetBy(dx: 30_000, dy: 0), level: 2))
  }
}
