import CoreLocation
import CoreMotion
import Foundation
import Observation
import UIKit

/// S3 spike: runs one sampling strategy at a time and records what it costs and what it captures.
///
/// Shared by all strategies (so that only the sampling differs between test days):
/// - `CLServiceSession(.always)` + `CLBackgroundActivitySession`, created on every launch while armed
///   (they cannot be created later in the background, S1).
/// - Significant-change and visit monitoring, as relaunch paths after the app was killed (F1).
/// - Core Motion activity updates and the `S3MotionStateMachine`.
/// - Pause = keep sampling, do not save (S1 strategy A, rule 3).
///
/// Nothing stores coordinates: points only feed counters, the in-memory state machine and the log
/// (accuracy and flags only).
@Observable
final class S3Recorder: NSObject, CLLocationManagerDelegate {
  static let shared = S3Recorder()

  private(set) var isArmed: Bool
  private(set) var isPaused: Bool
  private(set) var strategy: S3Strategy
  private(set) var state: S3MotionStateMachine.State = .moving(.unknown)
  private(set) var authorization: CLAuthorizationStatus
  private(set) var motionStatus = "not started"
  private(set) var samplingSummary = "idle"
  private(set) var stats: S3DayStats
  private(set) var lastAccuracy: Double?
  private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
  /// Bumped whenever a log line is written, so the log view reloads.
  private(set) var logVersion = 0

  @ObservationIgnored private var machine = S3MotionStateMachine()
  @ObservationIgnored private var tracker: S3StatsTracker
  @ObservationIgnored private var lastFix: S3MotionStateMachine.Fix?
  @ObservationIgnored private var pointsSinceSave = 0
  @ObservationIgnored private var lastHour: Int?

  @ObservationIgnored private var serviceSession: CLServiceSession?
  @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
  @ObservationIgnored private var diagnosticTasks: [Task<Void, Never>] = []
  /// Authorization, significant changes and visits.
  @ObservationIgnored private let wakeManager = CLLocationManager()
  /// Strategies B and C: the standard location service.
  @ObservationIgnored private let streamManager = CLLocationManager()
  @ObservationIgnored private var streamSettings: S3Strategy.ManagerSettings?
  /// Strategy A: the live-updates loop and its configuration.
  @ObservationIgnored private var liveTask: Task<Void, Never>?
  @ObservationIgnored private var liveConfiguration: CLLocationUpdate.LiveConfiguration?
  /// Strategy C: exit geofence around the current stay.
  @ObservationIgnored private var monitor: CLMonitor?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private let motionManager = CMMotionActivityManager()

  private static let stayConditionID = "stay"
  private static let monitorName = "s3stay"  // CLMonitor names must be alphanumeric
  /// Stats are written at notable events and at least every this many points.
  private static let pointsPerStatsSave = 120

  private enum Keys {
    static let armed = "s3.armed"
    static let paused = "s3.paused"
    static let strategy = "s3.strategy"
  }

  private override init() {
    let defaults = UserDefaults.standard
    isArmed = defaults.bool(forKey: Keys.armed)
    isPaused = defaults.bool(forKey: Keys.paused)
    strategy = defaults.string(forKey: Keys.strategy).flatMap(S3Strategy.init(rawValue:)) ?? .systemLive
    authorization = wakeManager.authorizationStatus
    let now = Date.now
    let saved = S3StatsFiles.load(day: S3DayStats.dayString(for: now))
    tracker = S3StatsTracker(today: saved, now: now)
    stats = tracker.today
    super.init()
    wakeManager.delegate = self
    streamManager.delegate = self
    streamManager.allowsBackgroundLocationUpdates = true
    streamManager.pausesLocationUpdatesAutomatically = false
    observeSystemNotifications()
  }

  // MARK: - Lifecycle

  /// Called once per process launch (user launch or background relaunch).
  func handleLaunch() {
    tracker.noteRelaunch(at: .now)
    tracker.noteLaunch()
    log(
      "app.launch",
      "state=\(Self.appState) armed=\(isArmed) paused=\(isPaused) strategy=\(strategy.rawValue) auth=\(authorizationName) lowPower=\(isLowPowerMode)"
    )
    startMonitorEvents()
    if isArmed {
      startRecording(trigger: "launch")
    }
    saveStats()
  }

  func handleScenePhase(_ phase: String) {
    log("scene.phase", phase)
    if phase == "background" { saveStats() }
    authorization = wakeManager.authorizationStatus
  }

  func handleTermination() {
    log("app.willTerminate", "state=\(Self.appState)")
    saveStats()
  }

  // MARK: - User actions

  func arm() {
    isArmed = true
    UserDefaults.standard.set(true, forKey: Keys.armed)
    wakeManager.requestAlwaysAuthorization()
    startRecording(trigger: "user")
  }

  func disarm() {
    isArmed = false
    UserDefaults.standard.set(false, forKey: Keys.armed)
    stopSampling()
    motionManager.stopActivityUpdates()
    wakeManager.stopMonitoringSignificantLocationChanges()
    wakeManager.stopMonitoringVisits()
    diagnosticTasks.forEach { $0.cancel() }
    diagnosticTasks = []
    backgroundSession?.invalidate()
    serviceSession?.invalidate()
    backgroundSession = nil
    serviceSession = nil
    samplingSummary = "idle"
    log("recording.disarm")
    tracker.breakContinuity()
    saveStats()
  }

  func setPaused(_ paused: Bool) {
    noteEvent()
    isPaused = paused
    UserDefaults.standard.set(paused, forKey: Keys.paused)
    log("pause.set", "paused=\(paused) state=\(state.name)")
    saveStats()
  }

  func setStrategy(_ newStrategy: S3Strategy) {
    guard newStrategy != strategy else { return }
    noteEvent()
    stopSampling()
    strategy = newStrategy
    UserDefaults.standard.set(newStrategy.rawValue, forKey: Keys.strategy)
    log("strategy.set", newStrategy.rawValue)
    if isArmed { applySampling(trigger: "strategy") }
    saveStats()
  }

  func clearLog() throws {
    try S3EventLog.shared.clear()
    logVersion += 1
  }

  // MARK: - Recording

  private func startRecording(trigger: String) {
    startSessions(trigger: trigger)
    wakeManager.startMonitoringSignificantLocationChanges()
    wakeManager.startMonitoringVisits()
    startMotion()
    applySampling(trigger: trigger)
  }

  private func startSessions(trigger: String) {
    guard serviceSession == nil else { return }
    let service = CLServiceSession(authorization: .always)
    let background = CLBackgroundActivitySession()
    serviceSession = service
    backgroundSession = background
    log("session.start", "trigger=\(trigger) state=\(Self.appState)")
    diagnosticTasks = [
      Task {
        do {
          for try await diagnostic in service.diagnostics where diagnostic.hasIssue {
            log("session.service.diagnostic", diagnostic.flagSummary)
          }
        } catch {
          log("session.service.diagnostics.error", "\(error)")
        }
      },
      Task {
        do {
          for try await diagnostic in background.diagnostics where diagnostic.hasIssue {
            log("session.background.diagnostic", diagnostic.flagSummary)
          }
        } catch {
          log("session.background.diagnostics.error", "\(error)")
        }
      },
    ]
  }

  private func startMotion() {
    guard CMMotionActivityManager.isActivityAvailable() else {
      motionStatus = "unavailable (speed only)"
      log("motion.unavailable")
      return
    }
    switch CMMotionActivityManager.authorizationStatus() {
    case .denied, .restricted:
      motionStatus = "denied (speed only)"
      log("motion.denied")
      return
    case .notDetermined, .authorized:
      break
    @unknown default:
      break
    }
    motionStatus = "running"
    motionManager.startActivityUpdates(to: .main) { [weak self] activity in
      guard let activity else { return }
      let reading = Self.reading(from: activity)
      let summary = Self.describe(activity)
      let time = activity.startDate
      MainActor.assumeIsolated {
        self?.handleMotion(reading, summary: summary, at: time)
      }
    }
  }

  /// Starts the current strategy for the current state.
  private func applySampling(trigger: String) {
    switch strategy {
    case .systemLive:
      setLiveConfiguration(S3Strategy.liveConfiguration(for: state))
      removeStayGeofence()
    case .tieredAccuracy:
      setStream(S3Strategy.managerSettings(for: state))
      removeStayGeofence()
    case .geofenceSleep:
      if state == .stationary, let anchor = machine.anchor {
        setStream(nil)
        addStayGeofence(around: anchor)
      } else {
        setStream(S3Strategy.managerSettings(for: state.isMoving ? state : .moving(.unknown)))
        removeStayGeofence()
      }
    }
    log("sampling.apply", "trigger=\(trigger) strategy=\(strategy.rawValue) state=\(state.name) \(samplingSummary)")
  }

  private func stopSampling() {
    setLiveConfiguration(nil)
    setStream(nil)
    removeStayGeofence()
  }

  // MARK: Strategy A

  private func setLiveConfiguration(_ configuration: CLLocationUpdate.LiveConfiguration?) {
    guard configuration != liveConfiguration || (configuration != nil && liveTask == nil) else { return }
    liveTask?.cancel()
    liveTask = nil
    liveConfiguration = configuration
    guard let configuration else { return }
    samplingSummary = "live=\(Self.name(configuration))"
    liveTask = Task {
      do {
        for try await update in CLLocationUpdate.liveUpdates(configuration) {
          if Task.isCancelled { break }
          handleLiveUpdate(update)
        }
      } catch {
        log("live.error", "\(error)")
      }
    }
  }

  private func handleLiveUpdate(_ update: CLLocationUpdate) {
    if let location = update.location {
      handleLocation(location, source: "live", flags: update.flagSummary)
    } else {
      noteEvent()
      log("live.noLocation", update.flagSummary)
    }
    if update.stationary {
      apply(machine.ingestSystemStationary(at: .now, lastFix: lastFix))
    }
  }

  // MARK: Strategies B and C

  private func setStream(_ settings: S3Strategy.ManagerSettings?) {
    guard settings != streamSettings else { return }
    streamSettings = settings
    guard let settings else {
      streamManager.stopUpdatingLocation()
      samplingSummary = "stream=off"
      return
    }
    streamManager.desiredAccuracy = settings.desiredAccuracy
    streamManager.distanceFilter = settings.distanceFilter
    streamManager.activityType = settings.activityType
    streamManager.startUpdatingLocation()
    samplingSummary = "stream \(settings.summary)"
  }

  // MARK: Strategy C geofence

  private func startMonitorEvents() {
    guard monitorTask == nil else { return }
    monitorTask = Task {
      let monitor = await CLMonitor(Self.monitorName)
      self.monitor = monitor
      do {
        for try await event in await monitor.events {
          handleMonitorEvent(identifier: event.identifier, state: event.state, at: event.date)
        }
      } catch {
        log("monitor.error", "\(error)")
      }
    }
  }

  private func addStayGeofence(around anchor: S3MotionStateMachine.Fix) {
    let center = CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude)
    let radius = machine.configuration.exitRadius
    samplingSummary = "stream=off geofence=\(Int(radius))m"
    Task {
      guard let monitor else {
        log("monitor.unavailable", "geofence not added")
        return
      }
      await monitor.add(
        CLMonitor.CircularGeographicCondition(center: center, radius: radius),
        identifier: Self.stayConditionID,
        assuming: .satisfied
      )
      log("geofence.add", "radius=\(Int(radius))m")
    }
  }

  private func removeStayGeofence() {
    Task {
      guard let monitor, await monitor.identifiers.contains(Self.stayConditionID) else { return }
      await monitor.remove(Self.stayConditionID)
      log("geofence.remove")
    }
  }

  private func handleMonitorEvent(identifier: String, state: CLMonitor.Event.State, at time: Date) {
    noteEvent()
    log("geofence.event", "id=\(identifier) state=\(Self.name(state)) appState=\(Self.appState)")
    guard identifier == Self.stayConditionID, state == .unsatisfied else { return }
    apply(machine.ingestExit(reason: "geofence.exit", at: time))
  }

  // MARK: - Event handling

  private func handleLocation(_ location: CLLocation, source: String, flags: String = "") {
    noteEvent()
    let fix = S3MotionStateMachine.Fix(
      time: location.timestamp,
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      horizontalAccuracy: location.horizontalAccuracy,
      speed: location.speed
    )
    let saved = !isPaused
    let replayed = tracker.isReplay(fix.time)
    let wasStationary = state == .stationary
    let distanceFromAnchor = machine.anchor.map { S3MotionStateMachine.distance($0, fix) }
    lastAccuracy = fix.horizontalAccuracy
    if !replayed, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= machine.configuration.maximumDecisionAccuracy {
      lastFix = fix
    }
    let poor = fix.horizontalAccuracy < 0 || fix.horizontalAccuracy > machine.configuration.maximumDecisionAccuracy
    log(
      "pt",
      "src=\(source) acc=\(Int(fix.horizontalAccuracy.rounded()))m bucket=\(S3DayStats.accuracyBucket(fix.horizontalAccuracy)) saved=\(saved) poor=\(poor) state=\(state.name) app=\(Self.appState)\(replayed ? " replayed=true" : "")\(flags.isEmpty ? "" : " flags=\(flags)")",
      at: fix.time
    )
    // A cached fix with an old timestamp would fake a long dwell; it is saved but not decided on.
    if !replayed { apply(machine.ingest(fix)) }
    // Drift (F3) counts only points that kept the stay; the point that ended it is not drift.
    let drift = wasStationary && state == .stationary ? distanceFromAnchor : nil
    tracker.notePoint(at: fix.time, accuracy: fix.horizontalAccuracy, saved: saved, moving: state.isMoving, stayDrift: drift)
    pointsSinceSave += 1
    if pointsSinceSave >= Self.pointsPerStatsSave { saveStats() }
  }

  private func handleMotion(_ reading: S3MotionStateMachine.MotionReading, summary: String, at time: Date) {
    noteEvent()
    log("motion", summary)
    apply(machine.ingest(reading, at: time))
  }

  private func apply(_ transition: S3MotionStateMachine.Transition?) {
    guard let transition else { return }
    state = transition.to
    tracker.noteTransition()
    log("state", "\(transition.from.name) -> \(transition.to.name) reason=\(transition.reason) app=\(Self.appState)")
    if isArmed { applySampling(trigger: "transition") }
    saveStats()
  }

  /// Accrues time and handles day and hour boundaries. Called before handling any event.
  private func noteEvent(at time: Date = .now) {
    if let finished = tracker.rollOver(at: time) {
      S3StatsFiles.save(finished)
      log("day.rollover", "finished=\(finished.day)")
    }
    let hour = Calendar.current.component(.hour, from: time)
    if let lastHour, lastHour != hour {
      let points = tracker.today.pointsByHour[lastHour]
      log("hour.summary", "hour=\(lastHour) points=\(points) state=\(state.name)")
    }
    lastHour = hour
    tracker.noteEvent(at: time, state: state.name, strategy: strategy.rawValue, paused: isPaused)
    stats = tracker.today
  }

  private func saveStats() {
    // Stamp the current state, so that a later process accrues the time after a kill to the state
    // that really held (right after a transition, the last event still carries the old state).
    if isArmed { noteEvent() }
    pointsSinceSave = 0
    stats = tracker.today
    S3StatsFiles.save(tracker.today)
  }

  // MARK: - CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard manager === wakeManager else { return }
    authorization = manager.authorizationStatus
    log("auth.change", "auth=\(authorizationName)")
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    if manager === streamManager {
      locations.forEach { handleLocation($0, source: "stream") }
      return
    }
    // Significant-change monitoring.
    guard let location = locations.last else { return }
    handleLocation(location, source: "slc")
    if state == .stationary, let anchor = machine.anchor {
      let fix = S3MotionStateMachine.Fix(
        time: location.timestamp, latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude, horizontalAccuracy: location.horizontalAccuracy,
        speed: location.speed)
      if S3MotionStateMachine.distance(anchor, fix) - location.horizontalAccuracy > machine.configuration.exitRadius {
        apply(machine.ingestExit(reason: "slc.far", at: location.timestamp))
      }
    }
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    noteEvent()
    let departure = visit.departureDate != .distantFuture
    log("visit", "\(departure ? "departure" : "arrival") acc=\(Int(visit.horizontalAccuracy.rounded()))m app=\(Self.appState)")
    if departure {
      apply(machine.ingestExit(reason: "visit.departure", at: visit.departureDate))
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    log("manager.error", "\(manager === streamManager ? "stream" : "wake") \(error.localizedDescription)")
  }

  // MARK: - System notifications

  private func observeSystemNotifications() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(powerStateChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
  }

  @objc private nonisolated func powerStateChanged() {
    let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    Task { @MainActor in
      self.isLowPowerMode = enabled
      self.log("power.lowPowerMode", "enabled=\(enabled)")
    }
  }

  // MARK: - Helpers

  private func log(_ event: String, _ details: String = "", at time: Date = .now) {
    S3EventLog.shared.append(event, details, at: time)
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

  private static var appState: String {
    switch UIApplication.shared.applicationState {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
  }

  nonisolated private static func reading(from activity: CMMotionActivity) -> S3MotionStateMachine.MotionReading {
    guard activity.confidence != .low else { return .unknown }
    // Vehicle wins over stationary: a car at a red light or a train at a station is still travelling.
    if activity.automotive { return .moving(.automotive) }
    if activity.cycling { return .moving(.cycling) }
    if activity.running { return .moving(.running) }
    if activity.walking { return .moving(.walking) }
    if activity.stationary { return .stationary }
    return .unknown
  }

  nonisolated private static func describe(_ activity: CMMotionActivity) -> String {
    let kinds = [
      ("stationary", activity.stationary), ("walking", activity.walking), ("running", activity.running),
      ("cycling", activity.cycling), ("automotive", activity.automotive), ("unknown", activity.unknown),
    ].filter(\.1).map(\.0).joined(separator: ",")
    let confidence = switch activity.confidence {
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    @unknown default: "?"
    }
    return "activity=\(kinds.isEmpty ? "none" : kinds) confidence=\(confidence)"
  }

  private static func name(_ configuration: CLLocationUpdate.LiveConfiguration) -> String {
    switch configuration {
    case .default: "default"
    case .automotiveNavigation: "automotiveNavigation"
    case .otherNavigation: "otherNavigation"
    case .fitness: "fitness"
    case .airborne: "airborne"
    default: "other"
    }
  }

  private static func name(_ state: CLMonitor.Event.State) -> String {
    switch state {
    case .satisfied: "satisfied"
    case .unsatisfied: "unsatisfied"
    case .unknown: "unknown"
    case .unmonitored: "unmonitored"
    @unknown default: "?"
    }
  }
}

// MARK: - Flag summaries (no coordinates)

private extension CLLocationUpdate {
  var flagSummary: String {
    [
      ("stationary", stationary), ("locationUnavailable", locationUnavailable),
      ("accuracyLimited", accuracyLimited), ("authorizationDenied", authorizationDenied),
      ("authorizationDeniedGlobally", authorizationDeniedGlobally),
      ("authorizationRestricted", authorizationRestricted),
      ("insufficientlyInUse", insufficientlyInUse), ("serviceSessionRequired", serviceSessionRequired),
    ].filter(\.1).map(\.0).joined(separator: ",")
  }
}

private extension CLServiceSession.Diagnostic {
  var flagSummary: String {
    [
      ("authorizationDenied", authorizationDenied), ("authorizationDeniedGlobally", authorizationDeniedGlobally),
      ("authorizationRestricted", authorizationRestricted), ("insufficientlyInUse", insufficientlyInUse),
      ("serviceSessionRequired", serviceSessionRequired), ("fullAccuracyDenied", fullAccuracyDenied),
      ("alwaysAuthorizationDenied", alwaysAuthorizationDenied),
      ("authorizationRequestInProgress", authorizationRequestInProgress),
    ].filter(\.1).map(\.0).joined(separator: ",")
  }

  var hasIssue: Bool { !flagSummary.isEmpty }
}

private extension CLBackgroundActivitySession.Diagnostic {
  var flagSummary: String {
    [
      ("authorizationDenied", authorizationDenied), ("authorizationDeniedGlobally", authorizationDeniedGlobally),
      ("authorizationRestricted", authorizationRestricted), ("insufficientlyInUse", insufficientlyInUse),
      ("serviceSessionRequired", serviceSessionRequired),
      ("authorizationRequestInProgress", authorizationRequestInProgress),
    ].filter(\.1).map(\.0).joined(separator: ",")
  }

  var hasIssue: Bool { !flagSummary.isEmpty }
}

/// Day stats files in Documents/stats (JSON, no coordinates).
enum S3StatsFiles {
  static let directory = URL.documentsDirectory.appending(path: "stats", directoryHint: .isDirectory)

  static func url(day: String) -> URL { directory.appending(path: "\(day).json") }

  static func load(day: String) -> S3DayStats? {
    let url = url(day: day)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(S3DayStats.self, from: Data(contentsOf: url))
    } catch {
      S3EventLog.shared.append("stats.loadError", "day=\(day) \(error.localizedDescription)")
      return nil
    }
  }

  static func save(_ stats: S3DayStats) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(stats).write(to: url(day: stats.day), options: .atomic)
    } catch {
      S3EventLog.shared.append("stats.saveError", "day=\(stats.day) \(error.localizedDescription)")
    }
  }

  static func allFiles() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
}
