#if DEBUG
import SwiftUI

/// Debug builds only: the single entry to the spike pages. Never compiled into Release.
struct DeveloperMenu: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          NavigationLink {
            S1SpikeView()
          } label: {
            Text(verbatim: "S1 · Control Center pause")
          }
          NavigationLink {
            MapDatumDebugView()
          } label: {
            Text(verbatim: "S2 · Map datum")
          }
        } footer: {
          Text(
            verbatim:
              "Starting the S1 recorder pauses the Trace Notes engine until S1 is stopped (one engine at a time). S1's Control Center widget is no longer in the bundle. S3 is its own app (scheme TraceNotesS3)."
          )
        }
      }
      .navigationTitle(Text(verbatim: "Developer"))
      .toolbar {
        Button {
          dismiss()
        } label: {
          Text(verbatim: "Done")
        }
      }
    }
  }
}

/// One location engine at a time (VS1): while the S1 spike recorder is armed, the Trace Notes
/// engine yields.
enum SpikeEngineGuard {
  static func start(engine: RecordingEngine) {
    // S1 no longer starts by itself at launch; an "armed" flag left by an older build is stale.
    if S1Shared.isArmed {
      S1Recorder.shared.disarm()
    }
    Task {
      for await armed in Observations({ S1Recorder.shared.isArmed }) {
        engine.setYieldingToSpike(armed)
      }
    }
  }
}
#endif
