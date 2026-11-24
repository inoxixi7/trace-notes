import Foundation
import MetricKit

/// Receives MetricKit's daily metrics and its crash and hang diagnostics, and keeps them in the
/// database for the diagnostic report (D14, D55 ⑤). Nothing leaves the phone unless the user shares
/// the report.
final class MetricReceiver: NSObject, MXMetricManagerSubscriber {
  private let database: AppDatabase

  init(database: AppDatabase) {
    self.database = database
  }

  /// Once per process; MetricKit then delivers waiting reports.
  func start() {
    MXMetricManager.shared.add(self)
  }

  nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
    save(payloads.map { (.metrics, $0.jsonRepresentation()) })
  }

  nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
    save(payloads.map { (.diagnostics, $0.jsonRepresentation()) })
  }

  private nonisolated func save(_ reports: [(MetricReport.Kind, Data)]) {
    let database = database
    let receivedAt = Date.now
    Task {
      for (kind, json) in reports {
        do {
          try await database.saveMetricReport(
            MetricReport(receivedAt: receivedAt, kind: kind, json: String(decoding: json, as: UTF8.self)))
        } catch {
          AppLog.storage.error("saving a MetricKit report failed: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
  }
}
