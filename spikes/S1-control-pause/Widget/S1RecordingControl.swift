import AppIntents
import SwiftUI
import WidgetKit

/// S1 spike: Control Center toggle. "On" means recording, "off" means paused.
struct S1RecordingControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(
      kind: S1Shared.controlKind,
      provider: S1RecordingValueProvider()
    ) { isRecording in
      ControlWidgetToggle(
        "Trace Notes",
        isOn: isRecording,
        action: S1SetRecordingIntent()
      ) { isOn in
        Label(isOn ? "Recording" : "Paused", systemImage: isOn ? "location.fill" : "pause.fill")
      }
    }
    .displayName("Recording (S1)")
    .description("Pause or resume location recording.")
  }
}

struct S1RecordingValueProvider: ControlValueProvider {
  var previewValue: Bool { true }

  func currentValue() async throws -> Bool {
    let isPaused = S1Shared.isPaused
    S1EventLog.append("control.currentValue", "paused=\(isPaused)")
    return !isPaused
  }
}

/// Only compiled into the widget extension, so it runs there and does not launch the app
/// (`openAppWhenRun` stays at its default, false). The app learns about the change from the
/// shared flag (read on every sample) and from a Darwin notification.
struct S1SetRecordingIntent: SetValueIntent {
  static let title: LocalizedStringResource = "Set Trace Notes Recording"

  @Parameter(title: "Recording")
  var value: Bool

  func perform() async throws -> some IntentResult {
    S1Shared.isPaused = !value
    S1EventLog.append("intent.perform", "paused=\(!value)")
    S1Shared.postPauseChanged()
    return .result()
  }
}
