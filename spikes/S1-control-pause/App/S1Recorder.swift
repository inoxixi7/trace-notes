import CoreLocation
import Observation
import UIKit
import WidgetKit

/// S1 spike: minimal recorder used to observe pause/resume behaviour.
///
/// Nothing is persisted except counters and the event log; coordinates are never written.
@Observable
final class S1Recorder: NSObject, CLLocationManagerDelegate {
  static let shared = S1Recorder()

  private(set) var isArmed = S1Shared.isArmed
  private(set) var isPaused = S1Shared.isPaused
  private(set) var strategy = S1Shared.pauseStrategy
  private(set) var isReceivingUpdates = false
  private(set) var savedCount = 0
  private(set) var skippedCount = 0
  private(set) var authorization: CLAuthorizationStatus
  /// Bumped on every log line written by this process so the log view can reload.
  private(set) var logVersion = 0

  @ObservationIgnored private var serviceSession: CLServiceSession?
  @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
  @ObservationIgnored private var updatesTask: Task<Void, Never>?
  @ObservationIgnored private var diagnosticTasks: [Task<Void, Never>] = []
  /// Used for the Always authorization request and for the wake-up services
  /// (significant location changes and visits) that can relaunch a terminated app.
  @ObservationIgnored private let manager = CLLocationManager()

  private override init() {
    authorization = manager.authorizationStatus
    super.init()
    manager.delegate = self
    observePauseNotifications()
  }

  // MARK: - Lifecycle

  /// Called once per process launch, foreground or background relaunch.
  func handleLaunch() {
    log(
      "app.launch",
      "state=\(appState) armed=\(isArmed) paused=\(isPaused) strategy=\(strategy.rawValue) auth=\(authorizationName)"
    )
    if isArmed {
      startRecording(trigger: "launch")
    }
  }

  func handleTermination() {
    log("app.willTerminate", "state=\(appState)")
  }

  func handleScenePhase(_ phase: String) {
    log("scene.phase", phase)
    if phase == "active" {
      refreshFromSharedState()
    }
  }

  // MARK: - User actions

  func arm() {
    S1Shared.isArmed = true
    isArmed = true
    manager.requestAlwaysAuthorization()
    startRecording(trigger: "user")
  }

  func disarm() {
    S1Shared.isArmed = false
    isArmed = false
    stopUpdates()
    diagnosticTasks.forEach { $0.cancel() }
    diagnosticTasks = []
    backgroundSession?.invalidate()
    serviceSession?.invalidate()
    backgroundSession = nil
    serviceSession = nil
    manager.stopMonitoringSignificantLocationChanges()
    manager.stopMonitoringVisits()
    log("recording.disarm", "state=\(appState)")
  }

  func setPausedFromApp(_ paused: Bool) {
    S1Shared.isPaused = paused
    log("pause.set", "source=app paused=\(paused)")
    ControlCenter.shared.reloadControls(ofKind: S1Shared.controlKind)
    applyPauseState(trigger: "app")
  }

  func setStrategy(_ newStrategy: S1Shared.PauseStrategy) {
    S1Shared.pauseStrategy = newStrategy
    log("strategy.set", newStrategy.rawValue)
    applyPauseState(trigger: "strategy")
  }

  // MARK: - Recording

  private func startRecording(trigger: String) {
    startSessions(trigger: trigger)
    manager.startMonitoringSignificantLocationChanges()
    manager.startMonitoringVisits()
    applyPauseState(trigger: trigger)
  }

  private func startSessions(trigger: String) {
    guard serviceSession == nil else { return }
    let service = CLServiceSession(authorization: .always)
    let background = CLBackgroundActivitySession()
    serviceSession = service
    backgroundSession = background
    log("session.start", "trigger=\(trigger) state=\(appState)")

    diagnosticTasks = [
      Task {
        do {
          for try await diagnostic in service.diagnostics {
            log("session.service.diagnostic", Self.describe(diagnostic))
          }
        } catch {
          log("session.service.diagnostics.error", "\(error)")
        }
      },
      Task {
        do {
          for try await diagnostic in background.diagnostics {
            log("session.background.diagnostic", Self.describe(diagnostic))
          }
        } catch {
          log("session.background.diagnostics.error", "\(error)")
        }
      },
    ]
  }

  /// Sessions stay alive in every pause state: they can only be created in the foreground
  /// (or on a background relaunch), so destroying them would make a background resume impossible.
  private func applyPauseState(trigger: String) {
    isPaused = S1Shared.isPaused
    strategy = S1Shared.pauseStrategy
    guard isArmed else { return }
    let wantsUpdates = !isPaused || strategy == .keepUpdates
    if wantsUpdates {
      startUpdates()
    } else {
      stopUpdates()
    }
    log(
      "pause.apply",
      "trigger=\(trigger) paused=\(isPaused) strategy=\(strategy.rawValue) updates=\(wantsUpdates) state=\(appState)"
    )
  }

  private func startUpdates() {
    guard updatesTask == nil else { return }
    isReceivingUpdates = true
    log("updates.start", "state=\(appState)")
    updatesTask = Task {
      do {
        for try await update in CLLocationUpdate.liveUpdates(.default) {
          if Task.isCancelled { break }
          handle(update)
        }
        log("updates.end", "cancelled=\(Task.isCancelled) state=\(appState)")
      } catch {
        log("updates.error", "\(error)")
      }
    }
  }

  private func stopUpdates() {
    guard let updatesTask else { return }
    updatesTask.cancel()
    self.updatesTask = nil
    isReceivingUpdates = false
    log("updates.stop", "state=\(appState)")
  }

  private func handle(_ update: CLLocationUpdate) {
    let flags = Self.describe(update)
    guard let location = update.location else {
      log("update.noLocation", flags)
      return
    }
    // The shared flag is read on every sample, so a pause from Control Center takes effect
    // on the next sample even if the Darwin notification was missed.
    let paused = S1Shared.isPaused
    if paused != isPaused {
      isPaused = paused
    }
    if paused {
      skippedCount += 1
    } else {
      savedCount += 1
    }
    let accuracy = Int(location.horizontalAccuracy.rounded())
    log(
      "location",
      "acc=\(accuracy)m saved=\(!paused) state=\(appState)\(flags.isEmpty ? "" : " flags=\(flags)")"
    )
  }

  private func refreshFromSharedState() {
    let paused = S1Shared.isPaused
    let sharedStrategy = S1Shared.pauseStrategy
    if paused != isPaused || sharedStrategy != strategy {
      applyPauseState(trigger: "foreground-sync")
    }
    authorization = manager.authorizationStatus
  }

  // MARK: - Pause notifications from the widget extension

  private func observePauseNotifications() {
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      nil,
      { _, _, _, _, _ in
        Task { @MainActor in
          S1Recorder.shared.pauseChangedExternally()
        }
      },
      S1Shared.pauseChangedNotification as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func pauseChangedExternally() {
    log("pause.observed", "source=darwin paused=\(S1Shared.isPaused) state=\(appState)")
    applyPauseState(trigger: "darwin")
  }

  // MARK: - CLLocationManagerDelegate (authorization and wake-up services)

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorization = manager.authorizationStatus
    log("auth.change", "auth=\(authorizationName) state=\(appState)")
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Only significant-change monitoring delivers here; live updates use the async sequence.
    let accuracy = locations.last.map { "\(Int($0.horizontalAccuracy.rounded()))m" } ?? "n/a"
    log("slc.update", "count=\(locations.count) acc=\(accuracy) state=\(appState)")
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    let isDeparture = visit.departureDate != .distantFuture
    log("visit", "\(isDeparture ? "departure" : "arrival") acc=\(Int(visit.horizontalAccuracy.rounded()))m state=\(appState)")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    log("manager.error", "\(error)")
  }

  // MARK: - Helpers

  private func log(_ event: String, _ details: String = "") {
    S1EventLog.append(event, details)
    logVersion += 1
  }

  var authorizationName: String {
    switch authorization {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorizedAlways: "always"
    case .authorizedWhenInUse: "whenInUse"
    @unknown default: "unknown(\(authorization.rawValue))"
    }
  }

  private var appState: String {
    switch UIApplication.shared.applicationState {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
  }

  private static func describe(_ update: CLLocationUpdate) -> String {
    [
      ("stationary", update.stationary),
      ("locationUnavailable", update.locationUnavailable),
      ("accuracyLimited", update.accuracyLimited),
      ("authorizationDenied", update.authorizationDenied),
      ("authorizationDeniedGlobally", update.authorizationDeniedGlobally),
      ("authorizationRestricted", update.authorizationRestricted),
      ("authorizationRequestInProgress", update.authorizationRequestInProgress),
      ("insufficientlyInUse", update.insufficientlyInUse),
      ("serviceSessionRequired", update.serviceSessionRequired),
    ].filter(\.1).map(\.0).joined(separator: ",")
  }

  private static func describe(_ diagnostic: CLServiceSession.Diagnostic) -> String {
    [
      ("authorizationDenied", diagnostic.authorizationDenied),
      ("authorizationDeniedGlobally", diagnostic.authorizationDeniedGlobally),
      ("authorizationRestricted", diagnostic.authorizationRestricted),
      ("authorizationRequestInProgress", diagnostic.authorizationRequestInProgress),
      ("insufficientlyInUse", diagnostic.insufficientlyInUse),
      ("serviceSessionRequired", diagnostic.serviceSessionRequired),
      ("fullAccuracyDenied", diagnostic.fullAccuracyDenied),
      ("alwaysAuthorizationDenied", diagnostic.alwaysAuthorizationDenied),
    ].filter(\.1).map(\.0).joined(separator: ",")
  }

  private static func describe(_ diagnostic: CLBackgroundActivitySession.Diagnostic) -> String {
    [
      ("authorizationDenied", diagnostic.authorizationDenied),
      ("authorizationDeniedGlobally", diagnostic.authorizationDeniedGlobally),
      ("authorizationRestricted", diagnostic.authorizationRestricted),
      ("authorizationRequestInProgress", diagnostic.authorizationRequestInProgress),
      ("insufficientlyInUse", diagnostic.insufficientlyInUse),
      ("serviceSessionRequired", diagnostic.serviceSessionRequired),
    ].filter(\.1).map(\.0).joined(separator: ",")
  }
}
