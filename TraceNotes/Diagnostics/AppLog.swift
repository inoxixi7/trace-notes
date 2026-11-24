import os

/// Unified logging. Never log coordinates (PRODUCT §5); accuracy, states and counts are fine.
nonisolated enum AppLog {
  static let subsystem = "com.inoxixi.tracenotes"
  static let recording = Logger(subsystem: subsystem, category: "recording")
  static let storage = Logger(subsystem: subsystem, category: "storage")
  static let processing = Logger(subsystem: subsystem, category: "processing")
  static let rendering = Logger(subsystem: subsystem, category: "rendering")
}
