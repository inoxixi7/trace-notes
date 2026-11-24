import Foundation

/// Reads the entries of a zip archive (PKWARE APPNOTE), stored or deflated, from its central
/// directory. Enough for the archives Files and Finder make of a folder (D54 ①); ZIP64 archives,
/// encryption and other methods are refused.
nonisolated enum ZipArchive {
  struct Entry: Sendable {
    var path: String
    var method: UInt16
    var compressedSize: Int
    var size: Int
    var localHeaderOffset: Int
  }

  enum Failure: Error, Equatable {
    case notZip
    case unsupported
    case damaged
  }

  private static let endSignature: UInt32 = 0x0605_4B50
  private static let centralSignature: UInt32 = 0x0201_4B50
  private static let localSignature: UInt32 = 0x0403_4B50
  private static let endRecordSize = 22
  private static let centralHeaderSize = 46
  private static let localHeaderSize = 30
  /// The end record may be followed by a comment of up to 65 535 bytes.
  private static let maximumCommentSize = 0xFFFF
  private static let stored: UInt16 = 0
  private static let deflated: UInt16 = 8
  private static let encryptedFlag: UInt16 = 1

  /// The files in the archive (folders left out), in central-directory order.
  static func entries(of archive: Data) throws(Failure) -> [Entry] {
    let bytes = Bytes(archive)
    guard archive.count >= endRecordSize else { throw .notZip }
    let lowest = max(0, archive.count - endRecordSize - maximumCommentSize)
    guard
      let end = stride(from: archive.count - endRecordSize, through: lowest, by: -1).first(where: {
        bytes.uint32($0) == endSignature
      })
    else { throw .notZip }
    let count = Int(bytes.uint16(end + 10))
    let directoryOffset = Int(bytes.uint32(end + 16))
    if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF { throw .unsupported }
    var entries: [Entry] = []
    var offset = directoryOffset
    for _ in 0..<count {
      guard offset + centralHeaderSize <= archive.count, bytes.uint32(offset) == centralSignature else { throw .damaged }
      let flags = bytes.uint16(offset + 8)
      let method = bytes.uint16(offset + 10)
      let compressedSize = Int(bytes.uint32(offset + 20))
      let size = Int(bytes.uint32(offset + 24))
      let nameLength = Int(bytes.uint16(offset + 28))
      let extraLength = Int(bytes.uint16(offset + 30))
      let commentLength = Int(bytes.uint16(offset + 32))
      let localHeaderOffset = Int(bytes.uint32(offset + 42))
      let nameStart = offset + centralHeaderSize
      guard nameStart + nameLength <= archive.count else { throw .damaged }
      let path = String(decoding: archive[archive.startIndex + nameStart..<archive.startIndex + nameStart + nameLength], as: UTF8.self)
      offset = nameStart + nameLength + extraLength + commentLength
      guard !path.hasSuffix("/") else { continue }
      if flags & encryptedFlag != 0 || compressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
        throw .unsupported
      }
      entries.append(Entry(path: path, method: method, compressedSize: compressedSize, size: size, localHeaderOffset: localHeaderOffset))
    }
    return entries
  }

  /// An entry's uncompressed bytes.
  static func contents(of entry: Entry, in archive: Data) throws(Failure) -> Data {
    let bytes = Bytes(archive)
    let offset = entry.localHeaderOffset
    guard offset + localHeaderSize <= archive.count, bytes.uint32(offset) == localSignature else { throw .damaged }
    let start = offset + localHeaderSize + Int(bytes.uint16(offset + 26)) + Int(bytes.uint16(offset + 28))
    guard start + entry.compressedSize <= archive.count else { throw .damaged }
    let data = archive[archive.startIndex + start..<archive.startIndex + start + entry.compressedSize]
    switch entry.method {
    case stored:
      return Data(data)
    case deflated:
      // Foundation's `.zlib` is raw deflate (RFC 1951), which is what zip stores.
      let inflated: Data
      do {
        inflated = try (Data(data) as NSData).decompressed(using: .zlib) as Data
      } catch {
        throw .damaged
      }
      guard inflated.count == entry.size else { throw .damaged }
      return inflated
    default:
      throw .unsupported
    }
  }

  /// Little-endian reads at offsets from the data's start.
  private struct Bytes {
    let data: Data

    init(_ data: Data) {
      self.data = data
    }

    func uint16(_ offset: Int) -> UInt16 {
      let index = data.startIndex + offset
      return UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    func uint32(_ offset: Int) -> UInt32 {
      UInt32(uint16(offset)) | UInt32(uint16(offset + 2)) << 16
    }
  }
}
