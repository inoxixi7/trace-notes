import CoreLocation
import CoreMotion
import SwiftUI
import UIKit

/// What the status button and card on Today say (PRODUCT F1 state table). Pause arrives with VS9.
enum RecordingStatus: Equatable {
  case recording
  /// Authorization not answered yet.
  case waitingForPermission
  /// "While Using": records only while the app is open.
  case backgroundUnavailable
  /// Denied or restricted for this app.
  case notRecording
  /// Location Services are off for the whole device.
  case locationServicesOff
  /// Debug builds: a spike recorder runs instead of the engine.
  case yieldingToSpike

  init(engine: RecordingEngine) {
    if engine.locationServicesOff {
      self = .locationServicesOff
      return
    }
    switch engine.authorization {
    case .notDetermined: self = .waitingForPermission
    case .denied, .restricted: self = .notRecording
    case .authorizedWhenInUse: self = .backgroundUnavailable
    case .authorizedAlways: self = engine.isYieldingToSpike ? .yieldingToSpike : .recording
    @unknown default: self = .notRecording
    }
  }

  /// Motion & Fitness denied: recording continues, activity comes from speed only (F1).
  static func motionDenied(_ engine: RecordingEngine) -> Bool {
    engine.motionAuthorization == .denied || engine.motionAuthorization == .restricted
  }

  var needsSettings: Bool {
    switch self {
    case .backgroundUnavailable, .notRecording, .locationServicesOff: true
    case .recording, .waitingForPermission, .yieldingToSpike: false
    }
  }

  var isProblem: Bool {
    self != .recording
  }

  var title: Text {
    switch self {
    case .recording: Text("Recording")
    case .waitingForPermission: Text("Waiting for location access")
    case .backgroundUnavailable: Text("Can’t record in the background")
    case .notRecording: Text("Not recording")
    case .locationServicesOff: Text("Location Services are off")
    // Debug builds only; not localized.
    case .yieldingToSpike: Text(verbatim: "Paused: the S1 spike recorder is running")
    }
  }

  var detail: Text? {
    switch self {
    case .recording, .waitingForPermission, .yieldingToSpike: nil
    case .backgroundUnavailable: Text("Location access is set to “While Using the App”. Choose “Always” to keep recording when the app is closed.")
    case .notRecording: Text("Location access is off for Trace Notes. Your saved history is still here.")
    case .locationServicesOff: Text("Turn on Location Services in Settings to record.")
    }
  }

  var symbol: String {
    switch self {
    case .recording: "record.circle"
    case .waitingForPermission: "location"
    case .backgroundUnavailable, .notRecording, .locationServicesOff: "location.slash"
    case .yieldingToSpike: "pause.circle"
    }
  }

  /// The status button's colour, so the state reads at a glance (D49).
  var color: Color {
    switch self {
    case .recording: .green
    case .waitingForPermission: .yellow
    case .backgroundUnavailable: .orange
    case .notRecording, .locationServicesOff: .red
    case .yieldingToSpike: .gray
    }
  }

  static let motionDeniedNote = Text("Motion & Fitness is off, so transport is judged by speed only.")

  @MainActor static func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}
