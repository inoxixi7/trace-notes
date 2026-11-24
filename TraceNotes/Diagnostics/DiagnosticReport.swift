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
    device: Device, status: Status, input: AppDatabase.DiagnosticsInput, logs: [LogLine], now: Date,
    timeZone: TimeZone = .current
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

    lines += ["", "## Battery (whole phone, D56)"] + batteryLines(input.events, timeZone: timeZone)

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

  /// One sample read from a `battery` event's payload.
  private struct BatterySample {
    var date: Date
    var percent: Int
    var unplugged: Bool
    var moving: Bool
  }

  /// The battery's drop per day on battery power, split by what the recorder was doing.
  ///
  /// Each pair of neighbouring samples is one interval, filed under the day and the recorder
  /// state of its first sample. An interval counts only when the phone was on battery at both
  /// ends and the level did not rise; any other one (charging, or a charge missed between two
  /// samples) is left out. The level is the whole phone's, so screen use shows here too: hours
  /// with the phone untouched (nights) come closest to Trace Notes' own cost.
  static func batteryLines(_ events: [RecorderEvent], timeZone: TimeZone) -> [String] {
    let samples = events.compactMap(batterySample)
    guard samples.count >= 2 else { return ["No battery samples yet."] }
    struct Totals {
      var stillSeconds = 0.0, stillDrop = 0
      var movingSeconds = 0.0, movingDrop = 0
    }
    var days: [LocalDay: Totals] = [:]
    for (start, end) in zip(samples, samples.dropFirst()) where start.unplugged && end.unplugged && end.percent <= start.percent {
      let seconds = end.date.timeIntervalSince(start.date)
      let drop = start.percent - end.percent
      let day = LocalDay(start.date, in: timeZone)
      if start.moving {
        days[day, default: Totals()].movingSeconds += seconds
        days[day, default: Totals()].movingDrop += drop
      } else {
        days[day, default: Totals()].stillSeconds += seconds
        days[day, default: Totals()].stillDrop += drop
      }
    }
    var lines = ["day | drop on battery | still: hours, drop, per hour | moving: hours, drop, per hour"]
    for day in days.keys.sorted() {
      let totals = days[day] ?? Totals()
      lines.append([
        "\(day)",
        "\(totals.stillDrop + totals.movingDrop) %",
        rate(seconds: totals.stillSeconds, drop: totals.stillDrop),
        rate(seconds: totals.movingSeconds, drop: totals.movingDrop),
      ].joined(separator: " | "))
    }
    return lines
  }

  private static func batterySample(_ event: RecorderEvent) -> BatterySample? {
    guard event.kind == .battery, let payload = event.payload else { return nil }
    var fields: [Substring: Substring] = [:]
    for pair in payload.split(separator: " ") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    guard let level = fields["level"].flatMap({ Int($0) }), let power = fields["power"], let engine = fields["engine"] else {
      return nil
    }
    return BatterySample(date: event.timestamp, percent: level, unplugged: power == "unplugged", moving: engine.hasPrefix("moving"))
  }

  private static func rate(seconds: Double, drop: Int) -> String {
    let hours = seconds / 3600
    guard hours > 0 else { return "-" }
    // Not localized: the report reads the same in every language.
    return String(format: "%.1f h, %d %%, %.2f %%/h", hours, drop, Double(drop) / hours)
  }

  private static func timestamp(_ date: Date) -> String {
    date.formatted(.iso8601)
  }

  /// The file name the report is shared under.
  static func fileName(at date: Date) -> String {
    "Trace Notes Diagnostics \(LocalDay(date, in: .current)).txt"
  }
}
