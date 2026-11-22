import CoreLocation
import SwiftUI

/// S3 spike UI: recording control, strategy switch (Debug only), today's stats, MetricKit files
/// and the event log. Spike-only English text; nothing here is localized.
struct S3RootView: View {
  private let recorder = S3Recorder.shared
  private let metrics = S3MetricStore.shared
  @State private var clearError: String?

  var body: some View {
    NavigationStack {
      List {
        recordingSection
        todaySection
        hoursSection
        metricsSection
        filesSection
        logSection
      }
      .navigationTitle("S3 · Sampling")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  // MARK: Sections

  private var recordingSection: some View {
    Section("Recording") {
      LabeledContent("Authorization", value: recorder.authorizationName)
      LabeledContent("Motion", value: recorder.motionStatus)
      LabeledContent("State", value: recorder.state.name)
      LabeledContent("Sampling", value: recorder.samplingSummary)
      LabeledContent("Last accuracy", value: recorder.lastAccuracy.map { "\(Int($0.rounded())) m" } ?? "–")
      LabeledContent("Low Power Mode", value: recorder.isLowPowerMode ? "on" : "off")
      #if DEBUG
      Picker("Strategy", selection: Binding(get: { recorder.strategy }, set: { recorder.setStrategy($0) })) {
        ForEach(S3Strategy.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      #else
      LabeledContent("Strategy", value: recorder.strategy.title)
      #endif
      Toggle("Paused (keep sampling, don't save)", isOn: Binding(get: { recorder.isPaused }, set: { recorder.setPaused($0) }))
        .disabled(!recorder.isArmed)
      if recorder.isArmed {
        Button("Stop recording", role: .destructive) { recorder.disarm() }
      } else {
        Button("Start recording") { recorder.arm() }
      }
    }
  }

  private var todaySection: some View {
    let stats = recorder.stats
    return Section("Today (\(stats.day))") {
      LabeledContent("Stationary", value: Self.duration(stats.secondsByState["stationary"] ?? 0))
      LabeledContent("Moving", value: Self.duration(movingSeconds(stats)))
      LabeledContent("Paused", value: Self.duration(stats.pausedSeconds))
      LabeledContent("Points saved / skipped", value: "\(stats.savedPoints) / \(stats.skippedPoints)")
      LabeledContent("Longest moving gap", value: Self.gap(stats.longestMovingGap, at: stats.longestMovingGapEnd))
      LabeledContent("Longest silence", value: Self.gap(stats.longestSilence, at: stats.longestSilenceEnd))
      LabeledContent("Max stay drift", value: "\(Int(stats.maximumStayDrift.rounded())) m")
      LabeledContent("Transitions / launches", value: "\(stats.transitions) / \(stats.launches)")
      LabeledContent(
        "Accuracy",
        value: S3DayStats.accuracyBucketOrder.compactMap { bucket in
          stats.pointsByAccuracy[bucket].map { "\(bucket) \($0)" }
        }.joined(separator: " · ")
      )
      ForEach(stats.secondsByStrategy.sorted(by: { $0.key < $1.key }), id: \.key) { strategy, seconds in
        LabeledContent(strategy, value: Self.duration(seconds))
      }
    }
    .font(.footnote)
  }

  private var hoursSection: some View {
    Section("Saved points per hour") {
      let hours = recorder.stats.pointsByHour
      Text(
        hours.indices.filter { hours[$0] > 0 }.map { String(format: "%02d:%d", $0, hours[$0]) }
          .joined(separator: "  ")
      )
      .font(.caption.monospaced())
    }
  }

  private var metricsSection: some View {
    Section {
      if let error = metrics.lastError {
        Text(error).foregroundStyle(.red)
      }
      if metrics.summaries.isEmpty {
        Text("No MetricKit payload yet. iOS delivers about once a day.")
          .foregroundStyle(.secondary)
      }
      ForEach(metrics.summaries) { summary in
        VStack(alignment: .leading, spacing: 4) {
          Text("\(summary.begin.formatted(date: .abbreviated, time: .shortened)) – \(summary.end.formatted(date: .omitted, time: .shortened))")
            .font(.footnote.bold())
          Text(
            ["bestForNavigation", "best", "10m", "100m", "1km", "3km"].map {
              "\($0) \(Self.duration(summary.locationSeconds[$0] ?? 0))"
            }.joined(separator: " · ")
          )
          Text(
            "bg location \(Self.duration(summary.backgroundLocationSeconds)) · CPU \(Int(summary.cpuSeconds)) s · fg \(Self.duration(summary.foregroundSeconds)) · bg \(Self.duration(summary.backgroundSeconds))"
          )
        }
        .font(.caption)
      }
    } header: {
      Text("MetricKit")
    } footer: {
      Text("Diagnostic payloads stored: \(metrics.diagnosticFileCount)")
    }
  }

  private var filesSection: some View {
    Section("Share") {
      ShareLink("Event log", item: S3EventLog.shared.fileURL)
      switch Result(catching: { try S3StatsFiles.allFiles() + S3MetricStore.shared.fileURLs() }) {
      case .success(let urls):
        ForEach(urls, id: \.self) { url in
          ShareLink(url.lastPathComponent, item: url)
        }
      case .failure(let error):
        Text("Cannot list files: \(error.localizedDescription)").foregroundStyle(.red)
      }
    }
    .font(.footnote)
  }

  private var logSection: some View {
    Section {
      if let clearError {
        Text(clearError).foregroundStyle(.red)
      }
      let lines = Self.lines(version: recorder.logVersion)
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(line).font(.caption2.monospaced())
      }
    } header: {
      HStack {
        Text("Event log (newest first, last 300)")
        Spacer()
        Button("Clear") {
          do {
            try recorder.clearLog()
            clearError = nil
          } catch {
            clearError = "Clear failed: \(error.localizedDescription)"
          }
        }
      }
    }
  }

  // MARK: Helpers

  private func movingSeconds(_ stats: S3DayStats) -> Double {
    stats.secondsByState.filter { $0.key.hasPrefix("moving") }.values.reduce(0, +)
  }

  /// `version` makes SwiftUI re-read the file when the recorder writes a line.
  private static func lines(version: Int) -> [String] {
    do {
      return try S3EventLog.shared.recentLines(limit: 300)
    } catch {
      return ["Cannot read log: \(error.localizedDescription)"]
    }
  }

  private static func duration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
  }

  private static func gap(_ seconds: Double, at end: Date?) -> String {
    guard let end else { return "–" }
    return "\(Int(seconds.rounded())) s (ended \(end.formatted(date: .omitted, time: .shortened)))"
  }
}
