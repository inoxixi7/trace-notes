import CoreLocation
import SwiftUI

/// First launch (F1): one screen of explanation → location "Always" → Motion & Fitness → Today.
struct OnboardingView: View {
  let engine: RecordingEngine
  let onFinish: () -> Void
  @State private var step = Step.intro

  private enum Step {
    case intro, location, motion
  }

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
        .font(.system(size: 64))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("Your footprints, kept as a diary")
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)
      Text("No settings. Trace Notes records all day in the background, even when the app is closed. Everything stays on this iPhone.")
        .multilineTextAlignment(.center)
      Text("Next, allow location access “Always” and Motion & Fitness.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Spacer()
      Button(action: begin) {
        Text("Start Recording")
          .font(.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
      }
      .buttonStyle(.glassProminent)
      .disabled(step != .intro)
    }
    .padding(32)
    .onChange(of: engine.authorization) { _, _ in
      continueAfterLocation()
    }
  }

  private func begin() {
    step = .location
    // Creating the sessions in the foreground is what lets them run later (S1); it also shows
    // the location prompt.
    engine.start()
    continueAfterLocation()
  }

  /// Location answered (any answer) → ask for Motion & Fitness → done. A denied location still
  /// finishes onboarding; Today then explains the state (F1).
  private func continueAfterLocation() {
    guard step == .location, engine.authorization != .notDetermined else { return }
    step = .motion
    Task {
      await engine.requestMotionAccess()
      onFinish()
    }
  }
}
