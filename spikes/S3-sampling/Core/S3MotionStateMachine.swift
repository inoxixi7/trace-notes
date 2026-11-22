import Foundation

/// S3 spike: decides "stationary" vs "moving (activity)" from location fixes, Core Motion
/// activity and wake-up events. Pure logic shared by every sampling strategy; the strategies only
/// differ in what they do with the state (see `S3Strategy`).
///
/// Bias (D13 / P3): when in doubt, stay **moving**. Missing a short walk inside a stay is
/// acceptable; losing track while travelling is not.
nonisolated struct S3MotionStateMachine: Sendable {
  enum Activity: String, Sendable, CaseIterable {
    case walking, running, cycling, automotive, unknown
  }

  enum State: Equatable, Sendable {
    case stationary
    case moving(Activity)

    var name: String {
      switch self {
      case .stationary: "stationary"
      case .moving(let activity): "moving.\(activity.rawValue)"
      }
    }

    var isMoving: Bool { self != .stationary }
  }

  /// What Core Motion reported, reduced to what the state machine needs.
  enum MotionReading: Equatable, Sendable {
    case stationary
    case moving(Activity)
    case unknown
  }

  struct Fix: Sendable {
    let time: Date
    let latitude: Double
    let longitude: Double
    /// Metres; negative means invalid.
    let horizontalAccuracy: Double
    /// Metres per second; negative means invalid.
    let speed: Double
  }

  struct Transition: Equatable, Sendable {
    let from: State
    let to: State
    let reason: String
  }

  struct Configuration: Sendable {
    /// Leaving a stay: the device must be this far from the stay anchor (beyond its accuracy).
    /// About a city block; also the radius of strategy C's exit geofence.
    var exitRadius: Double = 150
    /// Entering a stay: all usable fixes stay within this radius of the first one…
    var dwellRadius: Double = 50
    /// …for at least this long. Longer than a typical red light or train stop.
    var dwellDuration: TimeInterval = 180
    /// Fixes worse than this are kept (F1) but not used for decisions.
    var maximumDecisionAccuracy: Double = 100
    /// Speed-based activity when Core Motion is unavailable (m/s): ≥ walking threshold is moving.
    var walkingSpeed: Double = 0.6
    var cyclingSpeed: Double = 2.8
    var automotiveSpeed: Double = 7
    /// A speed-based activity change needs this many consecutive fixes, so GPS speed noise
    /// around a threshold does not flap the configuration.
    var activityConfirmationFixes = 5
  }

  let configuration: Configuration
  /// Start as moving: right after launch we do not know, and moving is the safe side.
  private(set) var state: State = .moving(.unknown)
  /// Centre of the current stay (stationary) or of the dwell candidate (moving).
  private(set) var anchor: Fix?
  private var dwellStart: Date?
  private var motion: (reading: MotionReading, time: Date)?
  private var motionStationarySince: Date?
  private var pendingActivity: (activity: Activity, count: Int)?

  init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// Usable fix → may leave a stay (displacement) or enter one (dwell).
  mutating func ingest(_ fix: Fix) -> Transition? {
    guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= configuration.maximumDecisionAccuracy
    else { return nil }

    switch state {
    case .stationary:
      if let anchor, Self.distance(anchor, fix) - fix.horizontalAccuracy > configuration.exitRadius {
        return move(to: .moving(activity(for: fix)), reason: "displacement", at: fix.time, anchor: fix)
      }
      return nil
    case .moving(let current):
      if let candidate = anchor, Self.distance(candidate, fix) <= configuration.dwellRadius,
        let dwellStart
      {
        if fix.time.timeIntervalSince(dwellStart) >= configuration.dwellDuration,
          !motionSaysMoving(at: fix.time)
        {
          return move(to: .stationary, reason: "dwell", at: fix.time, anchor: candidate)
        }
      } else {
        anchor = fix
        dwellStart = fix.time
      }
      let next = activity(for: fix)
      guard next != current, next != .unknown else {
        pendingActivity = nil
        return nil
      }
      let count = pendingActivity?.activity == next ? (pendingActivity?.count ?? 0) + 1 : 1
      pendingActivity = (next, count)
      guard count >= configuration.activityConfirmationFixes else { return nil }
      return move(to: .moving(next), reason: "activity", at: fix.time, anchor: anchor)
    }
  }

  /// Core Motion update.
  mutating func ingest(_ reading: MotionReading, at time: Date) -> Transition? {
    motion = (reading, time)
    if reading == .stationary {
      if motionStationarySince == nil { motionStationarySince = time }
    } else {
      motionStationarySince = nil
    }

    switch (state, reading) {
    case (.stationary, .moving(let activity)):
      return move(to: .moving(activity), reason: "motion", at: time, anchor: nil)
    case (.moving(let current), .moving(let activity)) where activity != current:
      return move(to: .moving(activity), reason: "motion.activity", at: time, anchor: anchor)
    case (.moving, .stationary):
      // Indoors there may be no usable fix at all; Core Motion alone may end the movement,
      // but only after the same dwell time.
      if let since = motionStationarySince,
        time.timeIntervalSince(since) >= configuration.dwellDuration
      {
        return move(to: .stationary, reason: "motion.dwell", at: time, anchor: anchor)
      }
      return nil
    default:
      return nil
    }
  }

  /// The location service itself reported that the device is stationary
  /// (`CLLocationUpdate.stationary`, strategy A).
  mutating func ingestSystemStationary(at time: Date, lastFix: Fix?) -> Transition? {
    guard state.isMoving, !motionSaysMoving(at: time) else { return nil }
    return move(to: .stationary, reason: "system.stationary", at: time, anchor: lastFix ?? anchor)
  }

  /// A wake-up source says the device left its stay (geofence exit, visit departure,
  /// a distant significant-change fix).
  mutating func ingestExit(reason: String, at time: Date) -> Transition? {
    guard state == .stationary else { return nil }
    return move(to: .moving(.unknown), reason: reason, at: time, anchor: nil)
  }

  // MARK: - Helpers

  private mutating func move(to next: State, reason: String, at time: Date, anchor newAnchor: Fix?)
    -> Transition
  {
    let transition = Transition(from: state, to: next, reason: reason)
    state = next
    pendingActivity = nil
    anchor = newAnchor
    dwellStart = newAnchor == nil ? nil : time
    return transition
  }

  /// Core Motion reports only when the activity changes, so the latest reading holds until the
  /// next one (a long train ride is a single "automotive" reading).
  private func motionSaysMoving(at time: Date) -> Bool {
    guard let motion, motion.time <= time else { return false }
    if case .moving = motion.reading { return true }
    return false
  }

  /// The current Core Motion activity wins; otherwise classify by GPS speed.
  private func activity(for fix: Fix) -> Activity {
    if let motion, motion.time <= fix.time, case .moving(let activity) = motion.reading {
      return activity
    }
    guard fix.speed >= 0 else { return .unknown }
    switch fix.speed {
    case ..<configuration.walkingSpeed: return .unknown
    case ..<configuration.cyclingSpeed: return .walking
    case ..<configuration.automotiveSpeed: return .cycling
    default: return .automotive
    }
  }

  /// Equirectangular approximation; exact enough for distances below a few kilometres.
  static func distance(_ a: Fix, _ b: Fix) -> Double {
    let earthRadius = 6_371_000.0
    let meanLatitude = (a.latitude + b.latitude) / 2 * .pi / 180
    let dx = (b.longitude - a.longitude) * .pi / 180 * cos(meanLatitude)
    let dy = (b.latitude - a.latitude) * .pi / 180
    return (dx * dx + dy * dy).squareRoot() * earthRadius
  }
}
