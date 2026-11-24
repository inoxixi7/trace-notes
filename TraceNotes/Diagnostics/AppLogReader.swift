import Foundation
import OSLog

/// The app's own warnings and errors for the diagnostic report (D55 ⑤). An app can read only its
/// current process's log, so earlier launches are covered by the recorder events instead.
nonisolated enum AppLogReader {
  static func warningsAndErrors() throws -> [DiagnosticReport.LogLine] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    return try store.getEntries(matching: NSPredicate(format: "subsystem == %@", AppLog.subsystem))
      .compactMap { $0 as? OSLogEntryLog }
      .filter { $0.level == .error || $0.level == .fault }
      .map { DiagnosticReport.LogLine(date: $0.date, category: $0.category, message: $0.composedMessage) }
  }
}
