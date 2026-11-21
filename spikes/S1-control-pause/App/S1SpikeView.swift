import SwiftUI

/// S1 spike: status, controls and the shared event log.
///
/// Strings are verbatim on purpose so spike text does not leak into the product String Catalog.
struct S1SpikeView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var lines: [String] = []
  @State private var errorMessage: String?
  private let recorder = S1Recorder.shared
  private let maximumLines = 500

  var body: some View {
    NavigationStack {
      List {
        statusSection
        logSection
      }
      .navigationTitle(Text(verbatim: "S1 · Control pause"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: reload) {
            Label { Text(verbatim: "Reload") } icon: { Image(systemName: "arrow.clockwise") }
          }
        }
      }
    }
    .onAppear(perform: reload)
    .onChange(of: recorder.logVersion) { reload() }
    .onChange(of: scenePhase) { _, phase in
      recorder.handleScenePhase(String(describing: phase))
      reload()
    }
  }

  private var statusSection: some View {
    Section {
      row("Authorization", recorder.authorizationName)
      row("Recording armed", recorder.isArmed ? "yes" : "no")
      row("Receiving live updates", recorder.isReceivingUpdates ? "yes" : "no")
      row("Saved / skipped (this process)", "\(recorder.savedCount) / \(recorder.skippedCount)")
      Toggle(isOn: Binding(get: { recorder.isPaused }, set: { recorder.setPausedFromApp($0) })) {
        Text(verbatim: "Paused")
      }
      Picker(
        selection: Binding(get: { recorder.strategy }, set: { recorder.setStrategy($0) })
      ) {
        Text(verbatim: "Keep updates, skip saving").tag(S1Shared.PauseStrategy.keepUpdates)
        Text(verbatim: "Stop updates, keep sessions").tag(S1Shared.PauseStrategy.stopUpdates)
      } label: {
        Text(verbatim: "Pause strategy")
      }
      if recorder.isArmed {
        Button(role: .destructive, action: recorder.disarm) {
          Text(verbatim: "Stop recording (invalidate sessions)")
        }
      } else {
        Button(action: recorder.arm) {
          Text(verbatim: "Start recording")
        }
      }
    } header: {
      Text(verbatim: "Status")
    }
  }

  private var logSection: some View {
    Section {
      if let errorMessage {
        Text(verbatim: errorMessage).foregroundStyle(.red)
      }
      if lines.isEmpty {
        Text(verbatim: "No events yet").foregroundStyle(.secondary)
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(verbatim: line)
          .font(.caption2.monospaced())
          .textSelection(.enabled)
      }
    } header: {
      HStack {
        Text(verbatim: "Event log (newest first, last \(maximumLines))")
        Spacer()
        if let url = S1EventLog.fileURL {
          ShareLink(item: url) { Text(verbatim: "Share") }
        }
        Button(action: clear) { Text(verbatim: "Clear") }
      }
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    LabeledContent {
      Text(verbatim: value)
    } label: {
      Text(verbatim: title)
    }
  }

  private func reload() {
    do {
      lines = try S1EventLog.recentLines(limit: maximumLines)
      errorMessage = nil
    } catch {
      errorMessage = "Cannot read log: \(error)"
    }
  }

  private func clear() {
    do {
      try S1EventLog.clear()
      lines = []
      errorMessage = nil
    } catch {
      errorMessage = "Cannot clear log: \(error)"
    }
  }
}
