import Foundation
import MetricKit
import Observation

/// S3 spike: keeps every MetricKit payload on the device (Documents/metrics) and a small summary
/// for the in-app list. MetricKit payloads contain no location data. Nothing leaves the device
/// unless the user shares a file.
@Observable
final class S3MetricStore: NSObject, MXMetricManagerSubscriber {
  static let shared = S3MetricStore()

  struct Summary: Codable, Identifiable, Sendable {
    var id: String { fileName }
    let fileName: String
    let begin: Date
    let end: Date
    /// Seconds of location activity per requested accuracy level.
    let locationSeconds: [String: Double]
    let backgroundLocationSeconds: Double
    let foregroundSeconds: Double
    let backgroundSeconds: Double
    let cpuSeconds: Double
  }

  private(set) var summaries: [Summary] = []
  private(set) var diagnosticFileCount = 0
  private(set) var lastError: String?

  let directory = URL.documentsDirectory.appending(path: "metrics", directoryHint: .isDirectory)
  private var summariesURL: URL { directory.appending(path: "summaries.json") }

  func start() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: summariesURL.path) {
        summaries = try JSONDecoder().decode([Summary].self, from: Data(contentsOf: summariesURL))
      }
      diagnosticFileCount = try fileURLs().filter { $0.lastPathComponent.hasPrefix("diagnostic-") }.count
    } catch {
      lastError = "Loading metrics failed: \(error.localizedDescription)"
    }
    let manager = MXMetricManager.shared
    manager.add(self)
    store(manager.pastPayloads)
    store(manager.pastDiagnosticPayloads)
  }

  func fileURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" && $0.lastPathComponent != "summaries.json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  // MARK: MXMetricManagerSubscriber (called on a MetricKit queue)

  nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
    let items = payloads.map { (Self.summarize($0), $0.jsonRepresentation()) }
    Task { @MainActor in self.store(items) }
  }

  nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
    let items = payloads.map { ($0.timeStampBegin, $0.jsonRepresentation()) }
    Task { @MainActor in self.storeDiagnostics(items) }
  }

  // MARK: Storage

  private func store(_ payloads: [MXMetricPayload]) {
    store(payloads.map { (Self.summarize($0), $0.jsonRepresentation()) })
  }

  private func store(_ payloads: [MXDiagnosticPayload]) {
    storeDiagnostics(payloads.map { ($0.timeStampBegin, $0.jsonRepresentation()) })
  }

  private func store(_ items: [(Summary, Data)]) {
    guard !items.isEmpty else { return }
    do {
      for (summary, json) in items where !summaries.contains(where: { $0.fileName == summary.fileName }) {
        try json.write(to: directory.appending(path: summary.fileName), options: .atomic)
        summaries.append(summary)
      }
      summaries.sort { $0.begin > $1.begin }
      try JSONEncoder().encode(summaries).write(to: summariesURL, options: .atomic)
      S3EventLog.shared.append("metrickit.metrics", "payloads=\(items.count)")
    } catch {
      lastError = "Saving metrics failed: \(error.localizedDescription)"
      S3EventLog.shared.append("metrickit.error", error.localizedDescription)
    }
  }

  private func storeDiagnostics(_ items: [(Date, Data)]) {
    guard !items.isEmpty else { return }
    do {
      for (begin, json) in items {
        let name = "diagnostic-\(Self.fileStamp(begin))-\(UUID().uuidString.prefix(8)).json"
        try json.write(to: directory.appending(path: name), options: .atomic)
        diagnosticFileCount += 1
      }
      S3EventLog.shared.append("metrickit.diagnostics", "payloads=\(items.count)")
    } catch {
      lastError = "Saving diagnostics failed: \(error.localizedDescription)"
      S3EventLog.shared.append("metrickit.error", error.localizedDescription)
    }
  }

  nonisolated private static func summarize(_ payload: MXMetricPayload) -> Summary {
    var location: [String: Double] = [:]
    if let metric = payload.locationActivityMetrics {
      location = [
        "bestForNavigation": metric.cumulativeBestAccuracyForNavigationTime,
        "best": metric.cumulativeBestAccuracyTime,
        "10m": metric.cumulativeNearestTenMetersAccuracyTime,
        "100m": metric.cumulativeHundredMetersAccuracyTime,
        "1km": metric.cumulativeKilometerAccuracyTime,
        "3km": metric.cumulativeThreeKilometersAccuracyTime,
      ].mapValues { $0.converted(to: .seconds).value }
    }
    let time = payload.applicationTimeMetrics
    return Summary(
      fileName: "metrics-\(fileStamp(payload.timeStampBegin))-\(fileStamp(payload.timeStampEnd)).json",
      begin: payload.timeStampBegin,
      end: payload.timeStampEnd,
      locationSeconds: location,
      backgroundLocationSeconds: time?.cumulativeBackgroundLocationTime.converted(to: .seconds).value ?? 0,
      foregroundSeconds: time?.cumulativeForegroundTime.converted(to: .seconds).value ?? 0,
      backgroundSeconds: time?.cumulativeBackgroundTime.converted(to: .seconds).value ?? 0,
      cpuSeconds: payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value ?? 0
    )
  }

  nonisolated private static func fileStamp(_ date: Date) -> String {
    date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
      .dateSeparator(.omitted).timeSeparator(.omitted))
  }
}
