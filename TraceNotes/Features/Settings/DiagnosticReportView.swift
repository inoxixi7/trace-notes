import SwiftUI
import os
import UIKit
import UniformTypeIdentifiers

/// D55 ⑥: the diagnostic report in full before it is shared; the user picks where it goes.
struct DiagnosticReportView: View {
  let database: AppDatabase
  let engine: RecordingEngine
  @State private var report: Result<[String], ReportFailure>?

  struct ReportFailure: Error {
    var message: String
  }

  var body: some View {
    Group {
      switch report {
      case nil:
        ProgressView()
      case .failure(let failure):
        ContentUnavailableView {
          Label { Text("The report couldn’t be made") } icon: { Image(systemName: "exclamationmark.triangle") }
        } description: {
          Text(verbatim: failure.message)
        }
      case .success(let lines):
        ScrollView {
          // Lazy, one line per row: a 30-day report can run to thousands of lines.
          LazyVStack(alignment: .leading, spacing: 0) {
            Label {
              Text("No coordinates or place names are included.")
            } icon: {
              Image(systemName: "lock.shield")
            }
            .padding(.bottom, 12)
            ForEach(lines.indices, id: \.self) { index in
              Text(verbatim: lines[index].isEmpty ? " " : lines[index])
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding()
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            ShareLink(
              item: DiagnosticFile(text: lines.joined(separator: "\n")),
              preview: SharePreview(Text(verbatim: DiagnosticReport.fileName(at: .now)))
            ) {
              Label { Text("Share") } icon: { Image(systemName: "square.and.arrow.up") }
            }
          }
        }
      }
    }
    .navigationTitle(Text("Diagnostic Report"))
    .navigationBarTitleDisplayMode(.inline)
    .task { await makeReport() }
  }

  private func makeReport() async {
    let now = Date.now
    do {
      let input = try await database.diagnosticsInput(since: now.addingTimeInterval(-DiagnosticReport.period))
      let logs = try await Task.detached(priority: .userInitiated) { try AppLogReader.warningsAndErrors() }.value
      let text = DiagnosticReport.text(device: Self.device(), status: status, input: input, logs: logs, now: now)
      report = .success(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    } catch {
      AppLog.storage.error("making the diagnostic report failed: \(error.localizedDescription, privacy: .public)")
      report = .failure(ReportFailure(message: error.localizedDescription))
    }
  }

  private var status: DiagnosticReport.Status {
    DiagnosticReport.Status(
      authorization: RecordingEngine.name(engine.authorization),
      locationServicesOff: engine.locationServicesOff,
      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      isRecording: engine.isRunning,
      engineState: engine.state.name,
      lastStorageError: engine.lastStorageError)
  }

  private static func device() -> DiagnosticReport.Device {
    var system = utsname()
    uname(&system)
    let model = withUnsafeBytes(of: system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    let info = Bundle.main.infoDictionary
    return DiagnosticReport.Device(
      appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
      build: info?["CFBundleVersion"] as? String ?? "?",
      systemVersion: UIDevice.current.systemVersion,
      model: model,
      language: Locale.preferredLanguages.first ?? Locale.current.identifier,
      timeZoneID: TimeZone.current.identifier)
  }
}

/// The report as a text file, written when the share sheet asks for it.
struct DiagnosticFile: Transferable {
  let text: String

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .plainText) { file in
      let url = FileManager.default.temporaryDirectory.appending(path: DiagnosticReport.fileName(at: .now))
      try Data(file.text.utf8).write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }
}
