import Foundation
import os

/// S3 spike: append-only text log in Documents. Lines hold time, event and details only;
/// **never coordinates**. The file handle stays open so per-point lines cost one write each.
final class S3EventLog {
  static let shared = S3EventLog()
  static let logger = Logger(subsystem: "com.inoxixi.tracenotes.s3", category: "S3")

  let fileURL = URL.documentsDirectory.appending(path: "s3-events.log")
  private var handle: FileHandle?
  private let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

  private init() {}

  func append(_ event: String, _ details: String = "", at time: Date = .now) {
    let line = "\(time.formatted(timestampStyle)) \(event)\(details.isEmpty ? "" : " \(details)")\n"
    do {
      try openHandleIfNeeded().write(contentsOf: Data(line.utf8))
    } catch {
      handle = nil
      Self.logger.error("S3 log write failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Newest lines first.
  func recentLines(limit: Int) throws -> [String] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let text = try String(contentsOf: fileURL, encoding: .utf8)
    return text.split(separator: "\n").suffix(limit).reversed().map(String.init)
  }

  func clear() throws {
    try handle?.close()
    handle = nil
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }

  private func openHandleIfNeeded() throws -> FileHandle {
    if let handle { return handle }
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    let opened = try FileHandle(forWritingTo: fileURL)
    try opened.seekToEnd()
    handle = opened
    return opened
  }
}
