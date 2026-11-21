import Foundation
import os

/// S1 spike: append-only text log in the App Group container, written by both processes.
///
/// Lines never contain coordinates: only time, process, event name, accuracy and state.
nonisolated enum S1EventLog {
  enum LogError: Error {
    case containerUnavailable
  }

  static var fileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: S1Shared.appGroupID)?
      .appending(path: "s1-events.log")
  }

  static func append(_ event: String, _ details: String = "") {
    let timestamp = Date.now.formatted(
      Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)
    )
    let process = ProcessInfo.processInfo.processName
    let line = "\(timestamp) [\(process)] \(event)\(details.isEmpty ? "" : " \(details)")\n"

    guard let url = fileURL else {
      S1Shared.logger.error("App Group container unavailable; dropped event \(event, privacy: .public)")
      return
    }
    // O_APPEND keeps short writes from the app and the extension from interleaving.
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else {
      S1Shared.logger.error("Cannot open S1 log (errno \(errno)); dropped event \(event, privacy: .public)")
      return
    }
    defer { close(descriptor) }
    let bytes = Array(line.utf8)
    let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    if written != bytes.count {
      S1Shared.logger.error("Short write to S1 log (errno \(errno)) for event \(event, privacy: .public)")
    }
  }

  /// Newest lines first.
  static func recentLines(limit: Int) throws -> [String] {
    guard let url = fileURL else { throw LogError.containerUnavailable }
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n").suffix(limit).reversed().map(String.init)
  }

  static func clear() throws {
    guard let url = fileURL else { throw LogError.containerUnavailable }
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}
