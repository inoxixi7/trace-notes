import Foundation
import GRDB
import MapKit
import Testing

/// F12 · Fog of World import (D54): the Sync format, the centre line, the overlap with Trace
/// Notes' own tracks, storage and drawing cells. All data here is made up.
struct FogOfWorldTests {
  let overview: OverviewTests
  let directory = FileManager.default.temporaryDirectory.appending(path: "FogOfWorldTests-\(UUID().uuidString)")

  init() throws {
    overview = try OverviewTests()
  }

  typealias Key = FogOfWorld.BlockKey

  func database() throws -> AppDatabase {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try AppDatabase(url: directory.appending(path: "test.sqlite"))
  }

  // MARK: - Making Sync files

  /// A Sync file name for a tile: four characters, the disguised tile number, two characters.
  static func fileName(tileX: Int, tileY: Int) -> String {
    let digits = Array("olhwjsktri")
    let number = String(tileY * FogOfWorld.tilesPerSide + tileX).map { digits[Int(String($0)) ?? 0] }
    return "a1b2" + String(number) + "zz"
  }

  /// A compressed tile file with these explored pixels, by block within the tile (0..<128).
  static func tileFile(_ pixels: [(blockX: Int, blockY: Int, x: Int, y: Int)]) -> Data {
    let grouped = Dictionary(grouping: pixels) { $0.blockY * FogOfWorld.blocksPerTile + $0.blockX }
    var header = Data(count: FogOfWorld.blocksPerTile * FogOfWorld.blocksPerTile * 2)
    var body = Data()
    for (number, index) in grouped.keys.sorted().enumerated() {
      header[index * 2] = UInt8((number + 1) & 0xFF)
      header[index * 2 + 1] = UInt8((number + 1) >> 8)
      var bitmap = Data(count: 512)
      for pixel in grouped[index] ?? [] {
        bitmap[pixel.y * 8 + pixel.x / 8] |= 0x80 >> UInt8(pixel.x % 8)
      }
      body.append(bitmap)
      body.append(contentsOf: [0, 0, 0])
    }
    return zlib(header + body)
  }

  /// zlib: header, raw deflate, Adler-32.
  static func zlib(_ data: Data) -> Data {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
      a = (a + UInt32(byte)) % 65521
      b = (b + a) % 65521
    }
    let adler = b << 16 | a
    let deflated = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()
    return Data([0x78, 0x9C]) + deflated + Data([UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
  }

  /// A zip archive with these entries, stored (method 0) or deflated (8). CRCs are not checked by
  /// the reader, so they are left at zero.
  static func zip(_ entries: [(path: String, data: Data, deflate: Bool)]) -> Data {
    var archive = Data()
    var directory = Data()
    func append(_ data: inout Data, _ fields: [(value: Int, bytes: Int)]) {
      for field in fields {
        for byte in 0..<field.bytes { data.append(UInt8(field.value >> (byte * 8) & 0xFF)) }
      }
    }
    for entry in entries {
      let name = Data(entry.path.utf8)
      let stored = entry.deflate ? ((try? (entry.data as NSData).compressed(using: .zlib) as Data) ?? Data()) : entry.data
      let method = entry.deflate ? 8 : 0
      let offset = archive.count
      append(&archive, [(0x0403_4B50, 4), (20, 2), (0, 2), (method, 2), (0, 4), (0, 4)])
      append(&archive, [(stored.count, 4), (entry.data.count, 4), (name.count, 2), (0, 2)])
      archive.append(name)
      archive.append(stored)
      append(&directory, [(0x0201_4B50, 4), (20, 2), (20, 2), (0, 2), (method, 2), (0, 4), (0, 4)])
      append(&directory, [(stored.count, 4), (entry.data.count, 4), (name.count, 2), (0, 2), (0, 2), (0, 2), (0, 2)])
      append(&directory, [(0, 4), (offset, 4)])
      directory.append(name)
    }
    let directoryOffset = archive.count
    archive.append(directory)
    append(&archive, [(0x0605_4B50, 4), (0, 2), (0, 2), (entries.count, 2), (entries.count, 2)])
    append(&archive, [(directory.count, 4), (directoryOffset, 4), (0, 2)])
    return archive
  }

  /// Blocks with these pixels set, by global pixel coordinates.
  static func blocks(_ pixels: [(x: Int, y: Int)]) -> [Key: FogOfWorld.Rows] {
    var blocks: [Key: FogOfWorld.Rows] = [:]
    for pixel in pixels {
      let key = Key(x: Int32(pixel.x >> 6), y: Int32(pixel.y >> 6))
      blocks[key, default: FogOfWorld.Rows(repeating: 0, count: 64)][pixel.y & 63] |= 1 << UInt64(pixel.x & 63)
    }
    return blocks
  }

  /// Somewhere near Tokyo on the pixel grid, away from any block edge.
  static let origin = (x: 3_726_000, y: 1_651_000)

  // MARK: - Format

  @Test func tileNamesStandForTheirNumber() throws {
    let tile = try #require(FogOfWorld.tile(fileName: Self.fileName(tileX: 455, tileY: 201)))
    #expect(tile.x == 455 && tile.y == 201)
    #expect(FogOfWorld.tile(fileName: "a1b2xxxxzz") == nil)
    #expect(FogOfWorld.tile(fileName: "short") == nil)
    // Past the last tile.
    #expect(FogOfWorld.tile(fileName: "a1b2" + String(repeating: "i", count: 6) + "zz") == nil)
  }

  /// The leftmost pixel is a byte's highest bit, and block numbers place blocks in the tile.
  @Test func tilePixelsLandWhereTheyBelong() throws {
    let file = Self.tileFile([(blockX: 2, blockY: 3, x: 1, y: 0), (blockX: 2, blockY: 3, x: 63, y: 63), (blockX: 127, blockY: 0, x: 8, y: 5)])
    let blocks = try FogOfWorld.blocks(ofTile: file, x: 10, y: 20)
    #expect(blocks.count == 2)
    let first = try #require(blocks[Key(x: 10 * 128 + 2, y: 20 * 128 + 3)])
    #expect(first[0] == 1 << 1 && first[63] == 1 << 63)
    let second = try #require(blocks[Key(x: 10 * 128 + 127, y: 20 * 128)])
    #expect(second[5] == 1 << 8)
  }

  /// Only tiles in a Sync folder count; other archives and damaged tiles are refused.
  @Test func readsSyncFoldersOnly() throws {
    let tile = Self.tileFile((0..<10).map { (blockX: 5, blockY: 5, x: $0, y: 7) })
    let name = Self.fileName(tileX: 455, tileY: 201)
    let archive = Self.zip([
      ("Fog of World/Sync/\(name)", tile, true),
      ("Fog of World/Sync/.DS_Store", Data([1, 2, 3]), false),
      ("Fog of World/Model/*/\(Self.fileName(tileX: 1, tileY: 1))", tile, false),
    ])
    let imported = try FogOfWorld.read(archive: archive)
    #expect(imported.tiles == 1)
    #expect(imported.blocks.count == 1 && imported.blocks.first?.pixelCount == 10)

    #expect(throws: FogOfWorld.Failure.notArchive) { try FogOfWorld.read(archive: Data("not a zip".utf8)) }
    #expect(throws: FogOfWorld.Failure.noTiles) {
      try FogOfWorld.read(archive: Self.zip([("Model/*/\(name)", tile, false)]))
    }
    #expect(throws: FogOfWorld.Failure.damagedTile) {
      try FogOfWorld.read(archive: Self.zip([("Sync/\(name)", Data([0x78, 0x9C, 1, 2, 3]), false)]))
    }
  }

  // MARK: - Centre line

  /// A band three pixels wide counts once, along its middle, across block edges.
  @Test func wideBandCountsAsOneLine() {
    let length = 200
    let band = (0..<length).flatMap { x in (0..<3).map { (x: Self.origin.x + x, y: Self.origin.y + $0) } }
    let line = FogOfWorld.thinned(Self.blocks(band))
    let pixels = line.values.flatMap { $0 }.map(\.nonzeroBitCount).reduce(0, +)
    #expect(pixels >= length - 4 && pixels <= length)
    let metres = FogOfWorld.centreLineLengths(of: line).values.reduce(0, +)
    let perPixel = FogOfWorld.metresPerPixel(atY: Double(Self.origin.y))
    // A line of n pixels is n - 1 steps long; thinning shortens the band's ends by a pixel or two.
    #expect(abs(metres / perPixel - Double(length - 1)) <= 4)
    // About 7.8 m a pixel at Tokyo's latitude.
    #expect(perPixel > 7.5 && perPixel < 8)
  }

  /// A diagonal step counts √2 pixels; a corner already joined along the sides is not counted
  /// again.
  @Test func diagonalsCountTheirLength() {
    let diagonal = (0..<100).map { (x: Self.origin.x + $0, y: Self.origin.y + $0) }
    let metres = FogOfWorld.centreLineLengths(of: Self.blocks(diagonal)).values.reduce(0, +)
    let perPixel = FogOfWorld.metresPerPixel(atY: Double(Self.origin.y + 50))
    #expect(abs(metres / perPixel - 99 * 2.squareRoot()) < 0.5)

    let corner = [(x: Self.origin.x, y: Self.origin.y), (x: Self.origin.x + 1, y: Self.origin.y), (x: Self.origin.x + 1, y: Self.origin.y + 1)]
    let cornerMetres = FogOfWorld.centreLineLengths(of: Self.blocks(corner)).values.reduce(0, +)
    #expect(abs(cornerMetres / FogOfWorld.metresPerPixel(atY: Double(Self.origin.y)) - 2) < 0.01)
  }

  /// Cells are drawn as lines between neighbours; a lone cell as a dot.
  @Test func cellsBecomeLines() {
    let cell = { (x: Int32, y: Int32) in FogOfWorld.Cell(x: x, y: y) }
    let links = FogOfWorld.links(of: [cell(0, 0), cell(1, 0), cell(2, 1), cell(10, 10)])
    #expect(links.count == 3)
    #expect(links.contains { $0.from == cell(1, 0) && $0.to == cell(2, 1) })
    #expect(links.contains { $0.from == cell(10, 10) && $0.to == cell(10, 10) })
  }

  /// A slope of one-cell steps is drawn as one straight line, not a staircase.
  @Test func stepsAreSmoothedAway() throws {
    let cell = { (x: Int32, y: Int32) in FogOfWorld.Cell(x: x, y: y) }
    // Two cells a row, one row down every two cells: centres up to 0.22 cells off the slope.
    let steps = Set((0..<20).flatMap { [cell(2 * $0, $0), cell(2 * $0 + 1, $0)] })
    let lines = FogOfWorld.lines(of: steps)
    #expect(lines.count == 1)
    let line = try #require(lines.first)
    // The cells' centres follow y = x / 2, each 0.22 cells off it; the smoothed line keeps to it
    // except near its ends, which stay at their cells' centres.
    let offset = { (point: FogOfWorld.LinePoint) in abs(point.y - point.x / 2) / 1.25.squareRoot() }
    let inner = line.dropFirst(FogOfWorld.smoothingPasses).dropLast(FogOfWorld.smoothingPasses)
    #expect(inner.count > 20 && inner.allSatisfy { offset($0) < 0.05 })
    let (start, end) = (try #require(line.first), try #require(line.last))
    // The ends stay at cells' centres.
    #expect([start, end].allSatisfy { $0.x.truncatingRemainder(dividingBy: 1) == 0.5 && $0.y.truncatingRemainder(dividingBy: 1) == 0.5 })
  }

  /// A band several cells wide is drawn along its middle, as one line.
  @Test func bandsAreThinned() throws {
    let cell = { (x: Int32, y: Int32) in FogOfWorld.Cell(x: x, y: y) }
    let band = Set((0..<30).flatMap { x in (0..<5).map { cell(x, 100 + $0) } })
    let lines = FogOfWorld.lines(of: band)
    #expect(lines.count == 1)
    let line = try #require(lines.first)
    #expect(line.allSatisfy { abs($0.y - 102.5) < 0.5 })
    #expect((line.map(\.x).max() ?? 0) - (line.map(\.x).min() ?? 0) > 20)
  }

  /// Chains meet at junctions, short spurs go, loops close, and a lone cell is a dot.
  @Test func junctionsSpursLoopsAndDots() throws {
    let cell = { (x: Int32, y: Int32) in FogOfWorld.Cell(x: x, y: y) }
    let across = (-6...6).map { cell(10 + $0, 10) }
    // A T: arms of six cells from (10, 10).
    let tee = Set(across + (1...6).map { cell(10, 10 + $0) })
    let arms = FogOfWorld.lines(of: tee)
    #expect(arms.count == 3)
    let junction = FogOfWorld.LinePoint(x: 10.5, y: 10.5)
    #expect(arms.allSatisfy { $0.first == junction || $0.last == junction })

    // A stub of `spurLength` cells is dropped, leaving one line across.
    let stub = Set(across + (1...FogOfWorld.spurLength).map { cell(10, 10 + Int32($0)) })
    #expect(FogOfWorld.lines(of: stub).count == 1)

    // A ring round a square.
    let ring = Set((0..<8).flatMap { [cell($0, 0), cell($0 + 1, 8), cell(0, $0 + 1), cell(8, $0)] })
    let loops = FogOfWorld.lines(of: ring)
    #expect(loops.count == 1)
    #expect(loops.first.map { $0.count > 8 && $0.first == $0.last } == true)

    #expect(FogOfWorld.lines(of: [cell(3, 3)]) == [[FogOfWorld.LinePoint(x: 3.5, y: 3.5)]])
  }

  /// The grid gets coarser as the map zooms out, so each cell stays within the line's width.
  @Test func cellSizeFollowsTheZoom() {
    let mapPointsPerPixel = MKMapRect.world.width / Double(FogOfWorld.pixelsPerSide)
    // Zoomed in: one pixel (10 points) is wider than half the line.
    #expect(OverviewRequest.fogShift(pointsPerMapPoint: 10 / mapPointsPerPixel, lineWidth: 5) == 0)
    // One point a pixel: cells of 2 pixels, 2 points.
    #expect(OverviewRequest.fogShift(pointsPerMapPoint: 1 / mapPointsPerPixel, lineWidth: 5) == 1)
    // A pixel a tenth of a point across: cells of 16 pixels, 1.6 points.
    #expect(OverviewRequest.fogShift(pointsPerMapPoint: 0.1 / mapPointsPerPixel, lineWidth: 5) == 4)
    #expect(OverviewRequest.fogShift(pointsPerMapPoint: 1e-12, lineWidth: 5) == 22)
  }

  // MARK: - Storage

  @Test func importReplacesAndRemoves() async throws {
    let database = try database()
    #expect(try await overview.first(database.observeFogOfWorld()) == nil)
    let first = FogOfWorld.stored(Self.blocks((0..<10).map { (x: Self.origin.x + $0, y: Self.origin.y) }))
    try await database.replaceFogOfWorld(first, importedAt: Date(timeIntervalSince1970: 1000))
    let second = FogOfWorld.stored(Self.blocks((0..<4).map { (x: Self.origin.x + $0, y: Self.origin.y + 500) }))
    try await database.replaceFogOfWorld(second, importedAt: Date(timeIntervalSince1970: 2000))
    let summary = try #require(try await overview.first(database.observeFogOfWorld()))
    #expect(summary.pixelCount == 4 && summary.importedAt == Date(timeIntervalSince1970: 2000))
    try await database.removeFogOfWorld()
    #expect(try await overview.first(database.observeFogOfWorld()) == nil)
    #expect(try await overview.first(database.observeFogOfWorldDistance(tolerance: 50)) == nil)
  }

  /// Cells come from the box only, at the grid asked for; the overview frames them too.
  @Test func cellsInABox() async throws {
    let database = try database()
    let line = (0..<130).map { (x: Self.origin.x + $0, y: Self.origin.y) }
    let far = (x: Self.origin.x + 100_000, y: Self.origin.y)
    try await database.replaceFogOfWorld(FogOfWorld.stored(Self.blocks(line + [far])), importedAt: .now)

    let west = FogOfWorld.coordinate(x: Double(Self.origin.x - 10), y: Double(Self.origin.y - 10))
    let east = FogOfWorld.coordinate(x: Double(Self.origin.x + 200), y: Double(Self.origin.y + 10))
    let box = GeoBox(latitudes: east.latitude...west.latitude, longitudes: [west.longitude...east.longitude])
    let pixels = try await overview.first(database.observeFogOfWorldCells(in: box, shift: 0))
    #expect(pixels.count == 130)
    let eights = try await overview.first(database.observeFogOfWorldCells(in: box, shift: 3))
    #expect(eights.count >= 17 && eights.count <= 18)
    let blocks = try await overview.first(database.observeFogOfWorldCells(in: box, shift: 6))
    #expect(blocks.count >= 3 && blocks.count <= 4)

    #expect(try await overview.first(database.observeOverviewBounds(includingFogOfWorld: false)) == nil)
    let bounds = try #require(try await overview.first(database.observeOverviewBounds(includingFogOfWorld: true)))
    let farEast = FogOfWorld.coordinate(x: Double(far.x), y: Double(far.y)).longitude
    #expect(bounds.longitudes.first.map { $0.contains(west.longitude) && $0.contains(farEast) } == true)
  }

  /// D54 ⑤: where Trace Notes recorded the same way, the explored line is not counted again.
  @Test func distanceLeavesOutOwnTracks() async throws {
    let database = try database()
    let length = 500
    let line = (0..<length).map { (x: Self.origin.x + $0, y: Self.origin.y) }
    try await database.replaceFogOfWorld(FogOfWorld.stored(Self.blocks(line)), importedAt: .now)
    let perPixel = FogOfWorld.metresPerPixel(atY: Double(Self.origin.y))
    let full = try #require(try await overview.first(database.observeFogOfWorldDistance(tolerance: 50)))
    #expect(abs(full / perPixel - Double(length - 1)) < 1)

    // Trace Notes walked the first half, two pixels north of the explored line.
    let start = FogOfWorld.coordinate(x: Double(Self.origin.x), y: Double(Self.origin.y) - 2)
    let middle = FogOfWorld.coordinate(x: Double(Self.origin.x + length / 2), y: Double(Self.origin.y) - 2)
    try await overview.store([RenderCache.tolerances.map { _ in [start, middle] }], in: database)
    let rest = try #require(try await overview.first(database.observeFogOfWorldDistance(tolerance: 50)))
    // Half the line is left, give or take the tolerance at the walk's end (a few pixels).
    #expect(abs(rest / full - 0.5) < 0.05)
  }

  @Test func statisticsCountTheEstimateForAllRecordsOnly() {
    let input = TravelStatistics.Input(segments: [], countryOfPlace: [:], gapDistances: [:], placesAwaitingCountry: 0)
    let all = TravelStatistics(input, year: nil, fogOfWorld: 12_000)
    #expect(all.distance == 12_000 && all.fogOfWorldDistance == 12_000)
    let year = TravelStatistics(input, year: 2026, fogOfWorld: 12_000)
    #expect(year.distance == 0 && year.fogOfWorldDistance == nil)
  }
}
