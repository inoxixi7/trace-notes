import CoreLocation
import CoreMotion
import Foundation
import Observation
import UIKit
import os

/// The recording engine (ARCHITECTURE §4): sessions, sampling, wake-ups, and writing every saved
/// point and every engine event to the raw layer. It does no track processing.
@Observable
final class RecordingEngine: NSObject, CLLocationManagerDelegate {
  private(set) var authorization: CLAuthorizationStatus
  private(set) var motionAuthorization = CMMotionActivityManager.authorizationStatus()
  /// From the service session's diagnostics: Location Services are off for the whole device.
  private(set) var locationServicesOff = false
  private(set) var state: EngineState
  private(set) var isRunning = false
  /// A spike's own recorder runs instead (Debug builds only; one engine at a time).
  private(set) var isYieldingToSpike = false
  /// The last write or state-store failure, shown nowhere yet but logged; kept for diagnostics.
  private(set) var lastStorageError: String?

  @ObservationIgnored private let database: AppDatabase
  @ObservationIgnored private let store: EngineStateStore
  @ObservationIgnored private let strategy: any SamplingStrategy
  @ObservationIgnored private let manager = CLLocationManager()
  @ObservationIgnored private let motionManager = CMMotionActivityManager()
  @ObservationIgnored private var core: RecordingCore
  @ObservationIgnored private let launchedAt: Date
  @ObservationIgnored private var serviceSession: CLServiceSession?
  /// Only while authorization is When In Use (D41): it keeps background updates allowed there, at
  /// the price of the blue status-bar pill. With Always, background updates need no session and
  /// the live-updates subscription brings the app back after a kill.
  @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
  @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
  /// Keeps a live-updates subscription open for as long as the process runs (D41).
  @ObservationIgnored private var liveUpdatesTask: Task<Void, Never>?
  @ObservationIgnored private var appliedConfiguration: LocationConfiguration?
  @ObservationIgnored private var launchClassified = false
  @ObservationIgnored private var motionUpdatesStarted = false
  @ObservationIgnored private var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
  @ObservationIgnored private let writes: AsyncStream<Write>.Continuation
  /// Fixes the heartbeat skipped during the current stay, newest last, at most one heartbeat
  /// interval old: the way out of the place is saved from them when the stay ends (D38).
  @ObservationIgnored private var skippedWhileStationary: [(location: CLLocation, flags: RawPoint.Flags)] = []

  private enum Write {
    case point(RawPoint)
    case event(RecorderEvent)
  }

  init(database: AppDatabase, store: EngineStateStore, strategy: any SamplingStrategy = TieredAccuracyStrategy(), now: Date = .now) {
    self.database = database
    self.store = store
    self.strategy = strategy
    launchedAt = now
    var snapshot: RecordingCore.Snapshot?
    var storeError: String?
    do {
      snapshot = try store.loadSnapshot()
    } catch {
      storeError = "engine state unreadable, starting as moving: \(error.localizedDescription)"
    }
    core = RecordingCore(launchedAt: now, restoring: snapshot)
    state = core.state
    authorization = manager.authorizationStatus
    let (stream, continuation) = AsyncStream.makeStream(of: Write.self)
    writes = continuation
    super.init()
    if let storeError { reportStorageError(storeError) }
    manager.delegate = self
    startWriter(stream)
    observeLowPowerMode()
  }

  // MARK: - Lifecycle

  /// Once per process, from `application(_:didFinishLaunchingWithOptions:)`.
  func handleLaunch() {
    if store.markProcessStarted() {
      // The previous process never reached `applicationWillTerminate`: it was killed.
      Task {
        do {
          let last = try await database.lastActivity()
          enqueue(.terminatedDetected, payload: "lastActivity=\(last.map { $0.formatted(.iso8601) } ?? "none")", at: launchedAt)
        } catch {
          reportStorageError("terminatedDetected not written: \(error.localizedDescription)")
        }
      }
    }
    if isLowPowerMode { enqueue(.lowPowerModeOn, at: launchedAt) }
    AppLog.recording.info("launch state=\(self.state.name, privacy: .public)")
  }

  func handleTermination() {
    store.markProcessEnded()
  }

  /// A scene reached the foreground: the user opened the app.
  func handleSceneBecameVisible() {
    classifyLaunch(.launch)
  }

  /// Starts sessions, wake-ups, motion and sampling. The first call must happen in the
  /// foreground (S1: sessions can only be created there or on a system relaunch); later
  /// processes call it on every launch to rejoin.
  func start() {
    guard !isRunning else { return }
    isRunning = true
    let service = CLServiceSession(authorization: .always)
    serviceSession = service
    updateBackgroundSession()
    keepLiveUpdatesOpen()
    observeDiagnostics(of: service)
    if authorization == .notDetermined { manager.requestAlwaysAuthorization() }
    manager.allowsBackgroundLocationUpdates = true
    // No blue status-bar pill while recording with Always (D41; this is also the default).
    manager.showsBackgroundLocationIndicator = false
    manager.pausesLocationUpdatesAutomatically = false
    manager.startMonitoringSignificantLocationChanges()
    manager.startMonitoringVisits()
    // Onboarding asks for Motion & Fitness after location (F1); see `requestMotionAccess()`.
    if motionAuthorization == .authorized { startMotionUpdates() }
    applySampling()
  }

  /// Debug builds: a spike recorder (S1) takes over location; ours stops sampling meanwhile.
  func setYieldingToSpike(_ yielding: Bool) {
    guard yielding != isYieldingToSpike else { return }
    isYieldingToSpike = yielding
    AppLog.recording.notice("yielding to spike engine: \(yielding)")
    if yielding {
      manager.stopUpdatingLocation()
      appliedConfiguration = nil
    } else if isRunning {
      applySampling()
    }
  }

  // MARK: - Sampling

  private func applySampling() {
    guard isRunning, !isYieldingToSpike else { return }
    let configuration = strategy.configuration(for: core.state)
    guard configuration != appliedConfiguration else { return }
    manager.desiredAccuracy = configuration.desiredAccuracy
    manager.distanceFilter = configuration.distanceFilter
    manager.activityType = configuration.activityType
    if appliedConfiguration == nil { manager.startUpdatingLocation() }
    appliedConfiguration = configuration
    AppLog.recording.info(
      "sampling state=\(self.core.state.name, privacy: .public) accuracy=\(configuration.desiredAccuracy) filter=\(configuration.distanceFilter)")
  }

  private func apply(_ transition: MotionStateMachine.Transition?) {
    guard let transition else { return }
    if transition.from == .stationary {
      // The way out: skipped fixes since the last one at the place (D38).
      let since = core.lastAtPlace ?? .distantPast
      for skipped in skippedWhileStationary where skipped.location.timestamp >= since {
        writes.yield(.point(Self.rawPoint(from: skipped.location, flags: skipped.flags)))
      }
    }
    skippedWhileStationary.removeAll()
    state = transition.to
    AppLog.recording.info(
      "state \(transition.from.name, privacy: .public) -> \(transition.to.name, privacy: .public) reason=\(transition.reason.rawValue, privacy: .public)")
    persistSnapshot()
    applySampling()
  }

  private func persistSnapshot() {
    do {
      try store.save(core.snapshot)
    } catch {
      reportStorageError("engine state not saved: \(error.localizedDescription)")
    }
  }

  // MARK: - Locations

  /// `nil` while no scene is connected yet.
  private static var sceneInForeground: Bool? {
    let scenes = UIApplication.shared.connectedScenes
    guard !scenes.isEmpty else { return nil }
    return scenes.contains { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
  }

  private func handle(_ location: CLLocation) {
    // UIKit connects a scene on both kinds of launch, after `didFinishLaunching`; a user launch
    // moves it to the foreground in the same main-thread transaction, a system relaunch leaves
    // it in the background (simulator probe, VS1). A fix that arrives before any scene is
    // connected cannot tell them apart, so it does not decide.
    if !launchClassified, let inForeground = Self.sceneInForeground {
      classifyLaunch(inForeground ? .launch : .backgroundRelaunch)
    }
    guard !isYieldingToSpike else { return }
    let fix = LocationFix(
      timestamp: location.timestamp,
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      horizontalAccuracy: location.horizontalAccuracy,
      speed: location.speed)
    let wasStationary = core.state == .stationary
    let decision = core.handle(fix)
    if let report = decision.skippedReport {
      enqueue(.heartbeatSkipped, payload: "hourStart=\(report.hourStart.formatted(.iso8601)) count=\(report.count)", at: fix.timestamp)
    }
    if decision.save {
      writes.yield(.point(Self.rawPoint(from: location, flags: decision.flags)))
      // While stationary the heartbeat time must survive a kill too.
      if wasStationary, decision.transition == nil { persistSnapshot() }
    } else {
      skippedWhileStationary.append((location, decision.flags))
      let oldest = location.timestamp.addingTimeInterval(-core.heartbeatInterval)
      skippedWhileStationary.removeAll { $0.location.timestamp < oldest }
    }
    apply(decision.transition)
  }

  private static func rawPoint(from location: CLLocation, flags: RawPoint.Flags) -> RawPoint {
    RawPoint(
      id: nil,
      timestamp: location.timestamp,
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      horizontalAccuracy: location.horizontalAccuracy,
      altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
      verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
      speed: location.speed >= 0 ? location.speed : nil,
      course: location.course >= 0 ? location.course : nil,
      timeZoneID: TimeZone.current.identifier,
      source: .recorded,
      importBatchID: nil,
      flags: flags)
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    locations.forEach(handle)
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    let departed = visit.departureDate != .distantFuture
    if departed {
      enqueue(.visitDepart, payload: "accuracy=\(Int(visit.horizontalAccuracy.rounded()))", at: visit.departureDate)
      guard !isYieldingToSpike else { return }
      apply(core.handleVisitDeparture())
    } else {
      enqueue(.visitArrive, payload: "accuracy=\(Int(visit.horizontalAccuracy.rounded()))", at: visit.arrivalDate)
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard manager.authorizationStatus != authorization else { return }
    authorization = manager.authorizationStatus
    enqueue(.authorizationChanged, payload: "status=\(Self.name(authorization))", at: .now)
    if isRunning { updateBackgroundSession() }
  }

  /// D41: an open live-updates subscription is what gets the app relaunched in the background
  /// after the system kills it (simulator: 3 of 3 kills, relaunched within seconds; without it and
  /// without a background activity session, not within 3 minutes). Its fixes are not used: the
  /// points still come from the location manager and its sampling strategy (S3).
  private func keepLiveUpdatesOpen() {
    liveUpdatesTask = Task {
      do {
        for try await _ in CLLocationUpdate.liveUpdates() {}
        AppLog.recording.error("live updates finished: relaunch after a kill is no longer armed")
      } catch {
        AppLog.recording.error("live updates failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// D41: a background activity session only for When In Use, where background updates need one
  /// (and iOS shows the blue pill whatever the app does). With Always, background updates come from
  /// `allowsBackgroundLocationUpdates` with the indicator off, like other always-on trackers.
  /// A session for When In Use must be created (or, after a relaunch, resumed) right away; it only
  /// becomes active in the foreground, which is where the user grants that authorization.
  private func updateBackgroundSession() {
    switch authorization {
    case .authorizedWhenInUse where backgroundSession == nil:
      backgroundSession = CLBackgroundActivitySession()
      AppLog.recording.notice("background activity session started (when in use)")
    case .authorizedAlways, .denied, .restricted:
      guard let session = backgroundSession else { return }
      session.invalidate()
      backgroundSession = nil
      AppLog.recording.notice("background activity session ended (\(Self.name(self.authorization), privacy: .public))")
    default:
      break
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // kCLErrorLocationUnknown is transient (the manager keeps trying); denial arrives through
    // the authorization callback. Both are logged for diagnostics.
    AppLog.recording.error("location error: \(error.localizedDescription, privacy: .public)")
  }

  // MARK: - Motion

  private func startMotionUpdates() {
    guard !motionUpdatesStarted else { return }
    guard CMMotionActivityManager.isActivityAvailable() else {
      AppLog.recording.notice("motion unavailable; activity from speed only")
      return
    }
    motionUpdatesStarted = true
    motionManager.startActivityUpdates(to: .main) { [weak self] activity in
      guard let activity else { return }
      MainActor.assumeIsolated {
        self?.handle(activity)
      }
    }
  }

  private func handle(_ activity: CMMotionActivity) {
    motionAuthorization = CMMotionActivityManager.authorizationStatus()
    let reading = Self.reading(from: activity)
    enqueue(.motionActivity, payload: "activity=\(Self.name(reading)) confidence=\(Self.name(activity.confidence))", at: activity.startDate)
    guard !isYieldingToSpike else { return }
    apply(core.handle(reading, at: activity.startDate))
  }

  /// Shows the Motion & Fitness prompt if it was never answered, then starts activity updates
  /// when allowed. Without it, activity comes from GPS speed (F1).
  func requestMotionAccess() async {
    if CMMotionActivityManager.isActivityAvailable(), motionAuthorization == .notDetermined {
      await withCheckedContinuation { continuation in
        // A one-minute query is the documented way to trigger the prompt. Its result and error
        // are not needed: the authorization status read below is the answer.
        motionManager.queryActivityStarting(from: .now.addingTimeInterval(-60), to: .now, to: .main) { _, _ in
          continuation.resume()
        }
      }
    }
    motionAuthorization = CMMotionActivityManager.authorizationStatus()
    if motionAuthorization == .authorized, isRunning { startMotionUpdates() }
  }

  private static func reading(from activity: CMMotionActivity) -> MotionStateMachine.Motion {
    guard activity.confidence != .low else { return .unknown }
    // A vehicle wins over stationary: a car at a light or a train at a station is still travelling.
    if activity.automotive { return .moving(.automotive) }
    if activity.cycling { return .moving(.cycling) }
    if activity.running { return .moving(.running) }
    if activity.walking { return .moving(.walking) }
    if activity.stationary { return .stationary }
    return .unknown
  }

  // MARK: - Diagnostics and system state

  private func observeDiagnostics(of session: CLServiceSession) {
    diagnosticsTask = Task { [weak self] in
      do {
        for try await diagnostic in session.diagnostics {
          self?.handle(diagnostic)
        }
      } catch {
        AppLog.recording.error("service session diagnostics ended: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func handle(_ diagnostic: CLServiceSession.Diagnostic) {
    let off = diagnostic.authorizationDeniedGlobally
    guard off != locationServicesOff else { return }
    locationServicesOff = off
    if off { enqueue(.locationServicesOff, at: .now) }
  }

  private func observeLowPowerMode() {
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
        self?.lowPowerModeChanged()
      }
    }
  }

  private func lowPowerModeChanged() {
    let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    guard enabled != isLowPowerMode else { return }
    isLowPowerMode = enabled
    enqueue(enabled ? .lowPowerModeOn : .lowPowerModeOff, at: .now)
  }

  // MARK: - Writing

  private func classifyLaunch(_ kind: RecorderEvent.Kind) {
    guard !launchClassified else { return }
    launchClassified = true
    enqueue(kind, payload: "auth=\(Self.name(authorization))", at: launchedAt)
  }

  private func enqueue(_ kind: RecorderEvent.Kind, payload: String? = nil, at time: Date) {
    writes.yield(.event(RecorderEvent(id: nil, timestamp: time, kind: kind, payload: payload)))
  }

  /// One consumer writes in arrival order, each point in its own transaction right away (P3).
  private func startWriter(_ stream: AsyncStream<Write>) {
    let database = database
    Task { [weak self] in
      for await write in stream {
        do {
          switch write {
          case .point(let point): try await database.append(points: [point], events: [])
          case .event(let event): try await database.append(points: [], events: [event])
          }
        } catch {
          self?.reportStorageError("write failed: \(error.localizedDescription)")
        }
      }
    }
  }

  private func reportStorageError(_ message: String) {
    lastStorageError = message
    AppLog.storage.error("\(message, privacy: .public)")
  }

  // MARK: - Names

  static func name(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorizedAlways: "always"
    case .authorizedWhenInUse: "whenInUse"
    @unknown default: "unknown"
    }
  }

  private static func name(_ motion: MotionStateMachine.Motion) -> String {
    switch motion {
    case .stationary: "stationary"
    case .moving(let activity): activity.rawValue
    case .unknown: "unknown"
    }
  }

  private static func name(_ confidence: CMMotionActivityConfidence) -> String {
    switch confidence {
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    @unknown default: "unknown"
    }
  }
}
