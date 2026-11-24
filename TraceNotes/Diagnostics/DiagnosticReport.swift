import Foundation

/// The diagnostic report the user may share (F10, D55 ⑤): plain text about the app, the device and
/// how recording went over the last 30 days. It holds no coordinates, place names or GPX content:
/// segments contribute only their day, kind, point count, gap reason and time zone, and events only
/// their time, kind and payload, which never has coordinates (`RecorderEvent`).
nonisolated enum DiagnosticReport {
  /// How far back the report goes.
  static let period: TimeInterval = 30 * 24 * 3600

  struct Device: Sendable {
    var appVersion: String
    var build: String
    var systemVersion: String
    /// The hardware identifier, e.g. `iPhone15,2`.
    var model: String
    var language: String
    var timeZoneID: String
  }

  /// The recorder as it is now.
  struct Status: Sendable {
    var authorization: String
    var locationServicesOff: Bool
    var lowPowerMode: Bool
    var isRecording: Bool
    var engineState: String
    var lastStorageError: String?
  }

  /// A warning or error the app logged since it started (`AppLogReader`).
  struct LogLine: Sendable {
    var date: Date
    var category: String
    var message: String
  }

  static func text(
    device: Device, status: Status, input: AppDatabase.DiagnosticsInput, logs: [LogLine], now: Date
  ) -> String {
    var lines = [
      "Trace Notes diagnostic report",
      "Created \(timestamp(now))",
      "This report has no coordinates, place names or GPX content.",
      "",
      "## App and device",
      "App \(device.appVersion) (\(device.build))",
      "iOS \(device.systemVersion)",
      "Model \(device.model)",
      "Language \(device.language)",
      "Time zone \(device.timeZoneID)",
      "",
      "## Now",
      "Location permission \(status.authorization)",
      "Location services \(status.locationServicesOff ? "off" : "on")",
      "Low Power Mode \(status.lowPowerMode ? "on" : "off")",
      "Recording \(status.isRecording ? "running" : "stopped"), state \(status.engineState)",
    ]
    if let error = status.lastStorageError { lines.append("Last storage error \(error)") }

    lines += ["", "## Days (last 30 days)", "day | points | stays | moves | gaps (reasons) | time zones"]
    let days = Dictionary(grouping: input.segments, by: \.localDay)
    for day in days.keys.sorted() {
      lines.append(summary(of: day, days[day] ?? []))
    }

    lines += ["", "## Recorder events (last 30 days)"]
    lines += input.events.map { event in
      [timestamp(event.timestamp), event.kind.rawValue, event.payload].compactMap { $0 }.joined(separator: " ")
    }

    lines += ["", "## MetricKit reports (last 30 days)"]
    for report in input.metricReports {
      lines += ["### \(report.kind.rawValue), received \(timestamp(report.receivedAt))", report.json]
    }

    lines += ["", "## Warnings and errors since the app started"]
    lines += logs.map { "\(timestamp($0.date)) [\($0.category)] \($0.message)" }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func summary(of day: LocalDay, _ segments: [Segment]) -> String {
    let recorded = segments.filter { $0.kind != .gap }
    let gaps = segments.filter { $0.kind == .gap }
    var reasons: [String: Int] = [:]
    for gap in gaps {
      let reason = gap.gapTravelMode.map { "by \($0.rawValue)" } ?? gap.gapReason?.rawValue ?? "none"
      reasons[reason, default: 0] += 1
    }
    let reasonList = reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    let zones = Set(segments.map(\.timeZoneID)).sorted().joined(separator: ", ")
    return [
      "\(day)",
      "\(recorded.map(\.pointCount).reduce(0, +))",
      "\(segments.count { $0.kind == .stay })",
      "\(segments.count { $0.kind == .move })",
      gaps.isEmpty ? "0" : "\(gaps.count) (\(reasonList))",
      zones,
    ].joined(separator: " | ")
  }

  private static func timestamp(_ date: Date) -> String {
    date.formatted(.iso8601)
  }

  /// The file name the report is shared under.
  static func fileName(at date: Date) -> String {
    "Trace Notes Diagnostics \(LocalDay(date, in: .current)).txt"
  }
}
