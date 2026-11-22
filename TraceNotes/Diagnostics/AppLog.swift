import os

/// Unified logging. Never log coordinates (PRODUCT §5); accuracy, states and counts are fine.
nonisolated enum AppLog {
  static let recording = Logger(subsystem: "com.inoxixi.tracenotes", category: "recording")
  static let storage = Logger(subsystem: "com.inoxixi.tracenotes", category: "storage")
}
