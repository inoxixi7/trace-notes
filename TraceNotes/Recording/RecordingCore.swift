import Foundation

/// The recording engine's decisions, without Core Location (pure, unit-tested):
/// which state the engine is in, which fixes are saved (D28 heartbeat) and with which flags.
nonisolated struct RecordingCore: Sendable {
  /// D28: one point per interval while stationary. Default 5 min (PRODUCT F1).
  static let defaultHeartbeatInterval: TimeInterval = 300

  struct Decision: Sendable, Equatable {
    var save: Bool
    var flags: RawPoint.Flags
    var transition: MotionStateMachine.Transition?
    /// Set when this fix starts a new clock hour after an hour with skipped points (D28: one
    /// recorder event per hour).
    var skippedReport: SkippedReport?
  }

  struct SkippedReport: Sendable, Equatable {
    var hourStart: Date
    var count: Int
  }

  /// What survives a process kill (ARCHITECTURE §4.3), kept in the App Group.
  struct Snapshot: Codable, Sendable, Equatable {
    var machine: MotionStateMachine.Snapshot
    var lastSavedAt: Date?
  }

  private(set) var machine: MotionStateMachine
  let heartbeatInterval: TimeInterval
  /// Fixes timestamped before this (the process launch) are cached replays (S3 finding).
  let launchedAt: Date
  private(set) var lastSavedAt: Date?
  /// While stationary: the newest usable fix within the dwell radius of the stay centre. When the
  /// stay ends, the skipped fixes from here on are the way out of the place and are saved after
  /// all (D38), so the track reaches the stay instead of starting 150 m away.
  private(set) var lastAtPlace: Date?
  private var skipped: SkippedReport?
  private let calendar: Calendar

  init(
    launchedAt: Date,
    restoring snapshot: Snapshot? = nil,
    parameters: MotionStateMachine.Parameters = .init(),
    heartbeatInterval: TimeInterval = defaultHeartbeatInterval,
    calendar: Calendar = .current
  ) {
    self.launchedAt = launchedAt
    self.calendar = calendar
    self.heartbeatInterval = heartbeatInterval
    machine = MotionStateMachine(parameters: parameters, restoring: snapshot?.machine)
    lastSavedAt = snapshot?.lastSavedAt
  }

  var state: EngineState { machine.state }
  var snapshot: Snapshot { Snapshot(machine: machine.snapshot, lastSavedAt: lastSavedAt) }

  /// - Replayed fixes are saved and flagged, and never reach the state machine.
  /// - Moving: every fix is saved.
  /// - Stationary: a fix is saved when the heartbeat is due, or when it is credibly outside the
  ///   stay (it then also ends the stay).
  mutating func handle(_ fix: LocationFix) -> Decision {
    var flags: RawPoint.Flags = machine.isUsable(fix) ? [] : .lowAccuracy
    guard fix.timestamp >= launchedAt else {
      flags.insert(.replayed)
      return Decision(save: true, flags: flags, transition: nil, skippedReport: nil)
    }
    let report = finishSkippedHour(before: fix.timestamp)
    let wasStationary = machine.state == .stationary
    if wasStationary, machine.isUsable(fix), let centre = machine.stayCentre,
      MotionStateMachine.distance(from: centre, to: (fix.latitude, fix.longitude)) <= machine.parameters.dwellRadius
    {
      lastAtPlace = fix.timestamp
    }
    let transition = machine.ingest(fix)
    if transition?.to == .stationary { lastAtPlace = machine.isUsable(fix) ? fix.timestamp : nil }
    let save: Bool
    if wasStationary, machine.state == .stationary {
      save = lastSavedAt.map { fix.timestamp.timeIntervalSince($0) >= heartbeatInterval } ?? true
    } else {
      save = true
    }
    if save {
      lastSavedAt = fix.timestamp
    } else {
      countSkipped(at: fix.timestamp)
    }
    return Decision(save: save, flags: flags, transition: transition, skippedReport: report)
  }

  mutating func handle(_ motion: MotionStateMachine.Motion, at time: Date) -> MotionStateMachine.Transition? {
    let transition = machine.ingest(motion, at: time)
    if transition?.to == .stationary { lastAtPlace = nil }
    return transition
  }

  mutating func handleVisitDeparture() -> MotionStateMachine.Transition? {
    machine.ingestVisitDeparture()
  }

  /// Ends the skipped-points count of an earlier hour, if any.
  private mutating func finishSkippedHour(before time: Date) -> SkippedReport? {
    guard let skipped, let hour = calendar.dateInterval(of: .hour, for: time), skipped.hourStart < hour.start else {
      return nil
    }
    self.skipped = nil
    return skipped
  }

  private mutating func countSkipped(at time: Date) {
    guard let hourStart = calendar.dateInterval(of: .hour, for: time)?.start else { return }
    let count = skipped?.hourStart == hourStart ? (skipped?.count ?? 0) + 1 : 1
    skipped = SkippedReport(hourStart: hourStart, count: count)
  }
}
