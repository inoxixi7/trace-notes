import CoreLocation
import CoreMotion

/// What the top capsule on Today says (PRODUCT F1 state table). Pause arrives with VS9.
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
}
