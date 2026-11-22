import SwiftUI

@main
struct TraceNotesApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      switch appDelegate.startup {
      case .ready(let database, let engine):
        RootView(database: database, engine: engine)
          .onChange(of: scenePhase, initial: true) { _, phase in
            // Covers a user launch that gets no fix (e.g. location denied).
            if phase != .background { engine.handleSceneBecameVisible() }
          }
      case .failed(let message):
        StartupFailureView(message: message)
      }
    }
  }
}

/// Onboarding until it is done, then Today.
struct RootView: View {
  let database: AppDatabase
  let engine: RecordingEngine
  @AppStorage(Onboarding.completedKey) private var onboardingCompleted = false

  var body: some View {
    if onboardingCompleted {
      TodayView(database: database, engine: engine)
    } else {
      OnboardingView(engine: engine) { onboardingCompleted = true }
    }
  }
}

struct StartupFailureView: View {
  let message: String

  var body: some View {
    ContentUnavailableView {
      Label("Trace Notes can’t open its data", systemImage: "exclamationmark.triangle")
    } description: {
      Text("Restart the app. If this keeps happening, restart your iPhone.\n\(message)")
    }
  }
}
