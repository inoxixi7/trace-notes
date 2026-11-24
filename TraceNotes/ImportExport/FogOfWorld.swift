import Foundation

/// F12 · Fog of World import (D54). Fog of World keeps the explored world as a grid of pixels on
/// the Web Mercator square, 2²² pixels a side (about 10 m at the equator), with no times. Its Sync
/// folder holds one zlib-compressed file per explored 512-grid tile; each tile has 128 × 128 blocks
/// of 64 × 64 pixels, and only explored blocks are stored.
///
/// A tile file is a 32 KiB header of 16-bit little-endian block numbers (row-major, 0 = not
/// explored, n = the n-th stored block), then the blocks, each a 512-byte bitmap (row-major, eight
/// bytes a row, the leftmost pixel in a byte's highest bit) and three bytes Trace Notes does not
/// use. The file name is the tile number in disguise: characters 5 to 10 stand for its decimal
/// digits.
///
/// Imported blocks are not raw points (P5): they keep no time and never enter the timeline.
nonisolated enum FogOfWorld {
  static let tilesPerSide = 512
  static let blocksPerTile = 128
  static let pixelsPerBlock = 64
  static let blocksPerSide = tilesPerSide * blocksPerTile
  static let pixelsPerSide = blocksPerSide * pixelsPerBlock
  /// log₂ of `pixelsPerBlock`: a pixel's block is its coordinate shifted right by this.
  static let blockShift = 6

  private static let headerSize = blocksPerTile * blocksPerTile * 2
  private static let bitmapSize = pixelsPerBlock * pixelsPerBlock / 8
  private static let blockRecordSize = bitmapSize + 3
  /// The characters that stand for the digits 0–9 in a tile file's name.
  private static let fileNameDigits = Dictionary(uniqueKeysWithValues: "olhwjsktri".enumerated().map { ($1, $0) })
  /// The folder Fog of World keeps its tiles in.
  static let syncFolderName = "Sync"
  /// Web Mercator's sphere radius, in metres.
  private static let earthRadius = 6_378_137.0

  struct BlockKey: Hashable, Comparable, Sendable {
    /// 0 ..< `blocksPerSide`, west to east and north to south.
    var x: Int32
    var y: Int32

    static func < (lhs: BlockKey, rhs: BlockKey) -> Bool { (lhs.y, lhs.x) < (rhs.y, rhs.x) }
  }

  /// A block's explored pixels: 64 rows, north first; bit x of a row is the pixel x from the west.
  typealias Rows = [UInt64]

  /// A cell of the pixel grid coarsened by a power of two (`Cell(…, shift: 0)` is a pixel).
  struct Cell: Hashable, Sendable {
    var x: Int32
    var y: Int32
  }

  enum Failure: Error, Equatable {
    /// Not a zip archive, or one this reader cannot open.
    case notArchive
    /// No tile files in a Sync folder.
    case noTiles
    /// A tile file that does not decode.
    case damagedTile
  }

  /// What is stored for one block (`AppDatabase.replaceFogOfWorld`).
  struct StoredBlock: Equatable, Sendable {
    var key: BlockKey
    /// The explored pixels as `pixelIndex` values, ascending, 16-bit little-endian.
    var pixels: Data
    var pixelCount: Int
    /// The block's share of the explored area's centre line, in metres (D54 ⑤).
    var length: Double
  }

  struct Import: Sendable {
    var blocks: [StoredBlock]
    var tiles: Int
  }

  // MARK: - Reading

  /// The tiles of every `Sync` folder in a zip archive (a zipped Sync folder, or the zip Files makes
  /// of a picked folder), with their centre lines measured. Other entries are ignored.
  static func read(archive: Data) throws(Failure) -> Import {
    let entries: [ZipArchive.Entry]
    do {
      entries = try ZipArchive.entries(of: archive)
    } catch {
      throw .notArchive
    }
    var blocks: [BlockKey: Rows] = [:]
    var tiles = 0
    for entry in entries {
      let components = entry.path.split(separator: "/")
      guard components.count >= 2, components[components.count - 2] == syncFolderName,
        let tile = tile(fileName: String(components[components.count - 1]))
      else { continue }
      let data: Data
      do {
        data = try ZipArchive.contents(of: entry, in: archive)
      } catch {
        throw .notArchive
      }
      for (key, rows) in try self.blocks(ofTile: data, x: tile.x, y: tile.y) { blocks[key] = rows }
      tiles += 1
    }
    guard tiles > 0 else { throw .noTiles }
    return Import(blocks: stored(blocks), tiles: tiles)
  }

  /// The tile a Sync file name stands for, or nil for any other name.
  static func tile(fileName: String) -> (x: Int, y: Int)? {
    let characters = Array(fileName)
    guard characters.count > 6 else { return nil }
    var number = 0
    for character in characters[4..<(characters.count - 2)] {
      guard let digit = fileNameDigits[character] else { return nil }
      number = number * 10 + digit
    }
    guard number < tilesPerSide * tilesPerSide else { return nil }
    return (number % tilesPerSide, number / tilesPerSide)
  }

  /// The explored blocks of one compressed tile file.
  static func blocks(ofTile compressed: Data, x tileX: Int, y tileY: Int) throws(Failure) -> [BlockKey: Rows] {
    let data = try inflated(compressed)
    guard data.count >= headerSize else { throw .damagedTile }
    var blocks: [BlockKey: Rows] = [:]
    for index in 0..<(blocksPerTile * blocksPerTile) {
      let number = Int(data[data.startIndex + index * 2]) | Int(data[data.startIndex + index * 2 + 1]) << 8
      guard number > 0 else { continue }
      let start = data.startIndex + headerSize + (number - 1) * blockRecordSize
      guard start + bitmapSize <= data.endIndex else { throw .damagedTile }
      var rows = Rows(repeating: 0, count: pixelsPerBlock)
      for row in 0..<pixelsPerBlock {
        var value: UInt64 = 0
        for byte in 0..<(pixelsPerBlock / 8) {
          value |= UInt64(reversedBits[Int(data[start + row * 8 + byte])]) << (byte * 8)
        }
        rows[row] = value
      }
      guard rows.contains(where: { $0 != 0 }) else { continue }
      let key = BlockKey(
        x: Int32(tileX * blocksPerTile + index % blocksPerTile), y: Int32(tileY * blocksPerTile + index / blocksPerTile))
      blocks[key] = rows
    }
    return blocks
  }

  /// zlib (RFC 1950): a two-byte header, then raw deflate, which is what Foundation's `.zlib` reads.
  private static func inflated(_ compressed: Data) throws(Failure) -> Data {
    guard compressed.count > 2, compressed[compressed.startIndex] & 0x0F == 8 else { throw .damagedTile }
    do {
      return try (compressed.dropFirst(2) as NSData).decompressed(using: .zlib) as Data
    } catch {
      throw .damagedTile
    }
  }

  /// Each byte with its bits in reverse order: Fog of World's leftmost pixel is a byte's highest bit.
  private static let reversedBits: [UInt8] = (0...255).map { value in
    (0..<8).reduce(UInt8(0)) { result, bit in result | (UInt8(value) >> bit & 1) << (7 - bit) }
  }

  // MARK: - Storing

  /// Blocks as stored: their pixels, and their part of the centre line's length.
  static func stored(_ blocks: [BlockKey: Rows]) -> [StoredBlock] {
    let lengths = centreLineLengths(of: thinned(blocks))
    return blocks.keys.sorted().map { key in
      let rows = blocks[key] ?? []
      var pixels = Data()
      var count = 0
      for (y, row) in rows.enumerated() {
        var remaining = row
        while remaining != 0 {
          let index = UInt16(y * pixelsPerBlock + remaining.trailingZeroBitCount)
          pixels.append(UInt8(index & 0xFF))
          pixels.append(UInt8(index >> 8))
          remaining &= remaining - 1
          count += 1
        }
      }
      return StoredBlock(key: key, pixels: pixels, pixelCount: count, length: lengths[key] ?? 0)
    }
  }

  /// The pixel indices (y × 64 + x) of a stored block's `pixels`.
  static func pixelIndices(_ pixels: Data) -> [Int] {
    stride(from: pixels.startIndex, to: pixels.endIndex - 1, by: 2).map { Int(pixels[$0]) | Int(pixels[$0 + 1]) << 8 }
  }

  // MARK: - Centre line (D54 ⑤)

  /// Thins explored areas to lines one pixel wide that keep their shape and connections (Zhang and
  /// Suen, 1984). Fog of World's paths are mostly a pixel wide already; wider areas shrink to their
  /// centre line, so an area is not counted as many parallel paths.
  static func thinned(_ blocks: [BlockKey: Rows]) -> [BlockKey: Rows] {
    var current = blocks
    var active = Set(blocks.keys)
    while !active.isEmpty {
      var changed = Set<BlockKey>()
      for firstPass in [true, false] {
        var removals: [BlockKey: Rows] = [:]
        for key in active {
          guard let rows = current[key] else { continue }
          let around = Neighbourhood(current, key)
          var removal = Rows(repeating: 0, count: pixelsPerBlock)
          var removes = false
          for y in 0..<pixelsPerBlock {
            var remaining = rows[y]
            while remaining != 0 {
              let x = remaining.trailingZeroBitCount
              remaining &= remaining - 1
              if around.isRemovable(x: x, y: y, firstPass: firstPass) {
                removal[y] |= 1 << UInt64(x)
                removes = true
              }
            }
          }
          if removes { removals[key] = removal }
        }
        for (key, removal) in removals {
          guard let rows = current[key] else { continue }
          current[key] = zip(rows, removal).map { $0 & ~$1 }
          changed.insert(key)
        }
      }
      // A removal can make pixels in the neighbouring blocks removable next time.
      active = Set(changed.flatMap { key in
        (-1...1).flatMap { dy in (-1...1).map { dx in BlockKey(x: key.x + Int32(dx), y: key.y + Int32(dy)) } }
      }.filter { current[$0] != nil })
    }
    return current
  }

  /// The length of each block's part of a one-pixel-wide line, in metres: a step to a side
  /// neighbour counts one pixel, a step to a corner neighbour √2 pixels unless a side neighbour
  /// already links the two. Each step counts once, for the pixel it starts from.
  static func centreLineLengths(of lines: [BlockKey: Rows]) -> [BlockKey: Double] {
    var lengths: [BlockKey: Double] = [:]
    for (key, rows) in lines {
      let around = Neighbourhood(lines, key)
      var straight = 0
      var diagonal = 0
      for y in 0..<pixelsPerBlock {
        var remaining = rows[y]
        while remaining != 0 {
          let x = remaining.trailingZeroBitCount
          remaining &= remaining - 1
          let east = around.bit(x + 1, y)
          let south = around.bit(x, y + 1)
          let west = around.bit(x - 1, y)
          if east { straight += 1 }
          if south { straight += 1 }
          if around.bit(x + 1, y + 1), !east, !south { diagonal += 1 }
          if around.bit(x - 1, y + 1), !west, !south { diagonal += 1 }
        }
      }
      let centre = (Double(key.y) + 0.5) * Double(pixelsPerBlock)
      lengths[key] = (Double(straight) + Double(diagonal) * 2.squareRoot()) * metresPerPixel(atY: centre)
    }
    return lengths
  }

  /// A block with its eight neighbours, for looking one pixel past its edges.
  private struct Neighbourhood {
    /// Row-major from the north-west; nil where nothing is explored.
    private let blocks: [Rows?]

    init(_ all: [BlockKey: Rows], _ key: BlockKey) {
      blocks = (-1...1).flatMap { dy in (-1...1).map { dx in all[BlockKey(x: key.x + Int32(dx), y: key.y + Int32(dy))] } }
    }

    /// Whether the pixel at (x, y) relative to the middle block, -1...64 on both axes, is set.
    func bit(_ x: Int, _ y: Int) -> Bool {
      let column = x < 0 ? 0 : x >= pixelsPerBlock ? 2 : 1
      let row = y < 0 ? 0 : y >= pixelsPerBlock ? 2 : 1
      guard let rows = blocks[row * 3 + column] else { return false }
      let localX = (x + pixelsPerBlock) % pixelsPerBlock
      let localY = (y + pixelsPerBlock) % pixelsPerBlock
      return rows[localY] >> UInt64(localX) & 1 == 1
    }

    /// The eight neighbours clockwise from the north (Zhang–Suen's p2…p9).
    private static let clockwise: [(dx: Int, dy: Int)] = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]

    /// Zhang–Suen's test for a set pixel.
    func isRemovable(x: Int, y: Int, firstPass: Bool) -> Bool {
      // Bit i is p(i + 2): north, north-east, east, … , north-west.
      let offsets = Self.clockwise
      var mask: UInt8 = 0
      for index in 0..<8 where bit(x + offsets[index].dx, y + offsets[index].dy) { mask |= 1 << UInt8(index) }
      guard (2...6).contains(mask.nonzeroBitCount) else { return false }
      // Unset-to-set steps going round once: bit i of `next` is neighbour i + 1.
      let next = mask >> 1 | mask << 7
      guard (~mask & next).nonzeroBitCount == 1 else { return false }
      let north = mask & 0b0000_0001 != 0
      let east = mask & 0b0000_0100 != 0
      let south = mask & 0b0001_0000 != 0
      let west = mask & 0b0100_0000 != 0
      return firstPass
        ? !(north && east && south) && !(east && south && west)
        : !(north && east && west) && !(north && south && west)
    }
  }

  // MARK: - Geometry

  /// Metres across one pixel at a pixel row (fractional rows allowed).
  static func metresPerPixel(atY y: Double) -> Double {
    2 * .pi * earthRadius * cos(latitude(atY: y) * .pi / 180) / Double(pixelsPerSide)
  }

  /// WGS-84 degrees at a position on the pixel grid (fractional pixels allowed).
  static func coordinate(x: Double, y: Double) -> (latitude: Double, longitude: Double) {
    (latitude(atY: y), x / Double(pixelsPerSide) * 360 - 180)
  }

  private static func latitude(atY y: Double) -> Double {
    atan(sinh(.pi * (1 - 2 * y / Double(pixelsPerSide)))) * 180 / .pi
  }

  /// The position on the pixel grid of WGS-84 degrees (fractional; latitudes past Web Mercator's
  /// ±85.05° come out past the grid's edge).
  static func pixel(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
    let radians = latitude * .pi / 180
    let x = (longitude + 180) / 360 * Double(pixelsPerSide)
    let y = (1 - asinh(tan(radians)) / .pi) / 2 * Double(pixelsPerSide)
    return (x, y)
  }

  /// The links that draw a set of cells as lines (D54 ④): every pair of side neighbours, and every
  /// pair of corner neighbours not already joined through a side neighbour; a cell with no
  /// neighbour at all is its own one-point link, drawn as a dot.
  static func links(of cells: Set<Cell>) -> [(from: Cell, to: Cell)] {
    var links: [(from: Cell, to: Cell)] = []
    for cell in cells {
      let neighbour = { (dx: Int32, dy: Int32) in cells.contains(Cell(x: cell.x + dx, y: cell.y + dy)) }
      let east = neighbour(1, 0)
      let south = neighbour(0, 1)
      let west = neighbour(-1, 0)
      if east { links.append((cell, Cell(x: cell.x + 1, y: cell.y))) }
      if south { links.append((cell, Cell(x: cell.x, y: cell.y + 1))) }
      if neighbour(1, 1), !east, !south { links.append((cell, Cell(x: cell.x + 1, y: cell.y + 1))) }
      if neighbour(-1, 1), !west, !south { links.append((cell, Cell(x: cell.x - 1, y: cell.y + 1))) }
      let isolated = !east && !south && !west && !neighbour(0, -1)
        && !neighbour(1, 1) && !neighbour(-1, 1) && !neighbour(1, -1) && !neighbour(-1, -1)
      if isolated { links.append((cell, cell)) }
    }
    return links
  }

  /// A point on the cell grid, in cells; a cell's centre is at its index plus a half.
  struct LinePoint: Hashable {
    var x: Double
    var y: Double
  }

  /// The lines that draw a set of cells (D54 ④). The stored pixels are the explored bands, so the
  /// cells are first thinned to centre lines and stripped of short spurs; `links` are then joined
  /// into chains between ends and junctions and smoothed, so a diagonal path's one-cell steps do
  /// not show as a staircase (device finding). Junctions and ends keep their place, so chains still
  /// meet; a closed loop is smoothed all round; an isolated cell is a one-point line, drawn as a dot.
  static func lines(of cells: Set<Cell>) -> [[LinePoint]] {
    let skeleton = centreLines(of: cells)
    var neighbours = Dictionary(uniqueKeysWithValues: skeleton.map { ($0, [Cell]()) })
    for link in links(of: skeleton) where link.from != link.to {
      neighbours[link.from, default: []].append(link.to)
      neighbours[link.to, default: []].append(link.from)
    }
    removeSpurs(from: &neighbours)
    var walked = Set<Step>()
    var lines: [[LinePoint]] = []
    func walk(from start: Cell, to first: Cell) -> (cells: [Cell], isClosed: Bool) {
      var chain = [start]
      var previous = start
      var current = first
      walked.insert(Step(previous, current))
      while current != start, let next = neighbours[current], next.count == 2 {
        chain.append(current)
        let following = next[0] == previous ? next[1] : next[0]
        previous = current
        current = following
        walked.insert(Step(previous, current))
      }
      chain.append(current)
      return (chain, current == start)
    }
    for (cell, next) in neighbours {
      if next.isEmpty { lines.append([centre(of: cell)]) }
      guard next.count != 2 else { continue }
      for neighbour in next where !walked.contains(Step(cell, neighbour)) {
        lines.append(smoothed(walk(from: cell, to: neighbour).cells.map(centre), isClosed: false))
      }
    }
    // What is left are loops with no end or junction.
    for (cell, next) in neighbours where next.count == 2 && !walked.contains(Step(cell, next[0])) {
      lines.append(smoothed(walk(from: cell, to: next[0]).cells.map(centre), isClosed: true))
    }
    return lines
  }

  /// Branches of at most this many cells that end in nothing are dropped. Thinning a band leaves a
  /// spur a cell or two long at each bump of its edge; at the overview's grid that is under the
  /// line's width (`fogShift`), so only noise goes, while a real side trip is longer.
  static let spurLength = 3

  /// The cells thinned to lines one cell wide, with the same thinning as the distance estimate.
  private static func centreLines(of cells: Set<Cell>) -> Set<Cell> {
    var blocks: [BlockKey: Rows] = [:]
    let inBlock = Int32(pixelsPerBlock - 1)
    for cell in cells {
      let key = BlockKey(x: cell.x >> blockShift, y: cell.y >> blockShift)
      blocks[key, default: Rows(repeating: 0, count: pixelsPerBlock)][Int(cell.y & inBlock)] |= 1 << UInt64(cell.x & inBlock)
    }
    var skeleton = Set<Cell>()
    for (key, rows) in thinned(blocks) {
      for (y, row) in rows.enumerated() {
        var bits = row
        while bits != 0 {
          let x = bits.trailingZeroBitCount
          bits &= bits - 1
          skeleton.insert(Cell(x: key.x << blockShift + Int32(x), y: key.y << blockShift + Int32(y)))
        }
      }
    }
    return skeleton
  }

  /// Drops each branch of at most `spurLength` cells that runs from an end to a junction.
  private static func removeSpurs(from neighbours: inout [Cell: [Cell]]) {
    for end in Array(neighbours.keys) {
      guard let first = neighbours[end], first.count == 1 else { continue }
      var spur = [end]
      var previous = end
      var current = first[0]
      while spur.count <= spurLength, let next = neighbours[current], next.count == 2 {
        spur.append(current)
        (previous, current) = (current, next[0] == previous ? next[1] : next[0])
      }
      guard spur.count <= spurLength, let next = neighbours[current], next.count >= 3 else { continue }
      for cell in spur { neighbours[cell] = nil }
      neighbours[current] = next.filter { $0 != previous }
    }
  }

  /// Passes of the [1 2 1] / 4 filter over a chain. Three passes weigh each point over three cells
  /// either side (about a Gaussian 1.2 cells wide): enough to even out one-cell steps, while a bend
  /// a few cells round moves by under a cell, which is at most half the line's width (`fogShift`).
  static let smoothingPasses = 3

  private static func centre(of cell: Cell) -> LinePoint {
    LinePoint(x: Double(cell.x) + 0.5, y: Double(cell.y) + 0.5)
  }

  /// A closed chain repeats its first point at the end.
  private static func smoothed(_ chain: [LinePoint], isClosed: Bool) -> [LinePoint] {
    var points = isClosed ? Array(chain.dropLast()) : chain
    guard points.count >= 3 else { return chain }
    let count = points.count
    for _ in 0..<smoothingPasses {
      let before = points
      for index in (isClosed ? 0..<count : 1..<(count - 1)) {
        let previous = before[(index + count - 1) % count]
        let next = before[(index + 1) % count]
        points[index] = LinePoint(
          x: (previous.x + 2 * before[index].x + next.x) / 4, y: (previous.y + 2 * before[index].y + next.y) / 4)
      }
    }
    return isClosed ? points + [points[0]] : points
  }

  /// A link walked in either direction.
  private struct Step: Hashable {
    let a: Cell
    let b: Cell
    init(_ one: Cell, _ other: Cell) {
      (a, b) = (one.y, one.x) < (other.y, other.x) ? (one, other) : (other, one)
    }
  }

  // MARK: - Overlap with Trace Notes' own tracks (D54 ⑤)

  /// The places Trace Notes' own tracks pass, on a grid whose cells are about `tolerance` across at
  /// each latitude. An explored pixel in the same cell as a track, or a neighbouring one, is taken
  /// as the same way (within `tolerance` to about 2.8 × `tolerance`).
  struct OwnTracks {
    let tolerance: Double
    /// Cells by their grid's shift (cells are 2^shift pixels across).
    private(set) var cells: [Int: Set<Cell>] = [:]

    init(tracks: [[DouglasPeucker.Coordinate]], tolerance: Double) {
      self.tolerance = tolerance
      for track in tracks {
        let pixels = track.map { FogOfWorld.pixel(latitude: $0.latitude, longitude: $0.longitude) }
        for (from, to) in zip(pixels, pixels.dropFirst()) { mark(from: from, to: to) }
        if pixels.count == 1, let only = pixels.first { mark(from: only, to: only) }
      }
    }

    /// The grid's shift at a pixel row: the largest cells no wider than `tolerance`, at least a pixel.
    func shift(atY y: Double) -> Int {
      max(0, Int((tolerance / FogOfWorld.metresPerPixel(atY: y)).rounded(.down)).bitWidthLog2)
    }

    /// Marks the cells along a line, in steps of at most half a cell.
    private mutating func mark(from: (x: Double, y: Double), to: (x: Double, y: Double)) {
      let shift = self.shift(atY: (from.y + to.y) / 2)
      let size = Double(1 << shift)
      let steps = max(1, Int((hypot(to.x - from.x, to.y - from.y) / (size / 2)).rounded(.up)))
      for step in 0...steps {
        let share = Double(step) / Double(steps)
        let x = from.x + (to.x - from.x) * share
        let y = from.y + (to.y - from.y) * share
        cells[shift, default: []].insert(Cell(x: Int32((x / size).rounded(.down)), y: Int32((y / size).rounded(.down))))
      }
    }

    /// Whether a pixel lies in or next to a cell a track passes.
    func covers(pixelX x: Int, y: Int) -> Bool {
      let shift = self.shift(atY: Double(y) + 0.5)
      guard let marked = cells[shift] else { return false }
      let cellX = Int32(x >> shift)
      let cellY = Int32(y >> shift)
      for dy in Int32(-1)...1 {
        for dx in Int32(-1)...1 where marked.contains(Cell(x: cellX + dx, y: cellY + dy)) { return true }
      }
      return false
    }

    /// The blocks that may hold pixels `covers` accepts.
    var reachableBlocks: Set<BlockKey> {
      var blocks = Set<BlockKey>()
      for (shift, cells) in cells {
        for cell in cells {
          // The cell and its neighbours, in pixels, then in blocks.
          let low = (Int(cell.x) - 1) << shift
          let high = ((Int(cell.x) + 2) << shift) - 1
          let top = (Int(cell.y) - 1) << shift
          let bottom = ((Int(cell.y) + 2) << shift) - 1
          for blockY in (top >> FogOfWorld.blockShift)...(bottom >> FogOfWorld.blockShift) {
            for blockX in (low >> FogOfWorld.blockShift)...(high >> FogOfWorld.blockShift) {
              blocks.insert(BlockKey(x: Int32(blockX), y: Int32(blockY)))
            }
          }
        }
      }
      return blocks
    }
  }
}

nonisolated extension Int {
  /// ⌊log₂ self⌋ for a positive value, 0 otherwise.
  fileprivate var bitWidthLog2: Int {
    self > 0 ? Int.bitWidth - 1 - leadingZeroBitCount : 0
  }
}
