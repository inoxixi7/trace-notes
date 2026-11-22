import Foundation

/// How the person is moving, as far as the engine needs it for sampling. Not the transport-mode
/// recognition of F4.
nonisolated enum Activity: String, Codable, Sendable {
  case walking, running, cycling, automotive, unknown
}

nonisolated enum EngineState: Codable, Sendable, Equatable {
  case stationary
  case moving(Activity)

  var isMoving: Bool {
    if case .moving = self { true } else { false }
  }

  var name: String {
    switch self {
    case .stationary: "stationary"
    case .moving(let activity): "moving.\(activity.rawValue)"
    }
  }
}

/// A fix as the engine sees it. Coordinates are WGS-84 degrees.
nonisolated struct LocationFix: Sendable, Equatable {
  var timestamp: Date
  var latitude: Double
  var longitude: Double
  /// Metres; negative means invalid.
  var horizontalAccuracy: Double
  /// m/s; negative means unknown.
  var speed: Double
}

/// Decides between "stationary" and "moving" (ARCHITECTURE §4.3, strategy B of S3). Pure logic.
///
/// - moving → stationary: every usable fix stays within `dwellRadius` for `dwellDuration` while
///   Core Motion does not say moving ("dwell"); or Core Motion says stationary for
///   `dwellDuration` ("motionDwell", works indoors without fixes).
/// - stationary → moving: a usable fix farther than `stayRadius` (plus its accuracy) from the
///   stay centre ("displacement"); Core Motion says moving ("motion"); a visit departure.
/// - It starts as `moving(unknown)`: when unsure, record (D13 reliability first).
nonisolated struct MotionStateMachine: Sendable {
  /// Values carried over from S3 (S3-result §2.1); to be tuned with the device results.
  struct Parameters: Sendable {
    /// Leaving the stay: a fix beyond this distance (plus its accuracy) from the centre. Also the
    /// heartbeat's stay radius (D28).
    var stayRadius: Double = 150
    /// Entering a stay: fixes must stay this close to the first one of the dwell window.
    var dwellRadius: Double = 50
    var dwellDuration: TimeInterval = 180
    /// Fixes worse than this never drive a decision (they are still saved, F1).
    var maximumDecisionAccuracy: Double = 100
    /// GPS speed thresholds when Core Motion is unavailable or denied (F1).
    var walkingSpeed: Double = 0.6
    var cyclingSpeed: Double = 2.8
    var automotiveSpeed: Double = 7
    /// Consecutive fixes needed before a speed-based activity change (no flapping).
    var activityConfirmationFixes = 5
  }

  /// A Core Motion reading. Automotive-and-stationary (a train at a station) arrives as
  /// `.moving(.automotive)`.
  enum Motion: Sendable, Equatable {
    case stationary
    case moving(Activity)
    case unknown
  }

  enum Reason: String, Sendable {
    case dwell, motionDwell, displacement, motion, activity, visitDeparture
  }

  struct Transition: Sendable, Equatable {
    var from: EngineState
    var to: EngineState
    var reason: Reason
  }

  /// The part that survives a process kill (ARCHITECTURE §4.3).
  struct Snapshot: Codable, Sendable, Equatable {
    var state: EngineState
    var stayLatitude: Double?
    var stayLongitude: Double?
    var stayEnteredAt: Date?
  }

  let parameters: Parameters
  private(set) var state: EngineState = .moving(.unknown)
  /// Centre of the current stay; nil when moving, or when the stay began without a usable fix.
  private(set) var stayCentre: (latitude: Double, longitude: Double)?
  private(set) var stayEnteredAt: Date?
  private var dwellAnchor: LocationFix?
  private var lastUsableFix: LocationFix?
  /// Core Motion reports changes only, so the latest reading holds until the next one.
  private var motion: Motion = .unknown
  private var motionStationarySince: Date?
  private var pendingActivity: (activity: Activity, count: Int)?

  init(parameters: Parameters = Parameters(), restoring snapshot: Snapshot? = nil) {
    self.parameters = parameters
    guard let snapshot else { return }
    state = snapshot.state
    stayEnteredAt = snapshot.stayEnteredAt
    if let latitude = snapshot.stayLatitude, let longitude = snapshot.stayLongitude {
      stayCentre = (latitude, longitude)
    }
  }

  var snapshot: Snapshot {
    Snapshot(state: state, stayLatitude: stayCentre?.latitude, stayLongitude: stayCentre?.longitude, stayEnteredAt: stayEnteredAt)
  }

  func isUsable(_ fix: LocationFix) -> Bool {
    fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= parameters.maximumDecisionAccuracy
  }

  /// True when `fix` is credibly outside the stay (D28: such a point is saved at once).
  func isOutsideStay(_ fix: LocationFix) -> Bool {
    guard isUsable(fix), let stayCentre else { return false }
    let distance = Self.distance(from: stayCentre, to: (fix.latitude, fix.longitude))
    return distance > parameters.stayRadius + fix.horizontalAccuracy
  }

  // MARK: - Inputs

  mutating func ingest(_ fix: LocationFix) -> Transition? {
    guard isUsable(fix) else { return nil }
    lastUsableFix = fix
    switch state {
    case .stationary:
      if stayCentre == nil {
        // The stay began from Core Motion alone; the first usable fix becomes its centre.
        stayCentre = (fix.latitude, fix.longitude)
        return nil
      }
      guard isOutsideStay(fix) else { return nil }
      return move(to: movingActivity(speed: fix.speed), reason: .displacement)
    case .moving(let current):
      if let transition = updateActivity(current: current, speed: fix.speed) { return transition }
      return checkDwell(with: fix)
    }
  }

  mutating func ingest(_ reading: Motion, at time: Date) -> Transition? {
    motion = reading
    switch reading {
    case .moving(let activity):
      motionStationarySince = nil
      pendingActivity = nil
      switch state {
      case .stationary: return move(to: activity, reason: .motion)
      case .moving(let current) where current != activity: return move(to: activity, reason: .activity)
      case .moving: return nil
      }
    case .stationary:
      if motionStationarySince == nil { motionStationarySince = time }
      return checkMotionDwell(at: time)
    case .unknown:
      motionStationarySince = nil
      return nil
    }
  }

  /// A visit departure (CLVisit) ends a stay.
  mutating func ingestVisitDeparture() -> Transition? {
    guard state == .stationary else { return nil }
    return move(to: .unknown, reason: .visitDeparture)
  }

  // MARK: - Rules

  private mutating func checkDwell(with fix: LocationFix) -> Transition? {
    guard let anchor = dwellAnchor,
      Self.distance(from: (anchor.latitude, anchor.longitude), to: (fix.latitude, fix.longitude)) <= parameters.dwellRadius
    else {
      dwellAnchor = fix
      return nil
    }
    guard !motionSaysMoving, fix.timestamp.timeIntervalSince(anchor.timestamp) >= parameters.dwellDuration else {
      return nil
    }
    return stay(centre: (anchor.latitude, anchor.longitude), since: fix.timestamp, reason: .dwell)
  }

  private mutating func checkMotionDwell(at time: Date) -> Transition? {
    guard state.isMoving, let since = motionStationarySince,
      time.timeIntervalSince(since) >= parameters.dwellDuration
    else { return nil }
    let centre = lastUsableFix.map { ($0.latitude, $0.longitude) }
    return stay(centre: centre, since: time, reason: .motionDwell)
  }

  /// Without a Core Motion moving reading, the activity follows GPS speed after
  /// `activityConfirmationFixes` agreeing fixes.
  private mutating func updateActivity(current: Activity, speed: Double) -> Transition? {
    guard !motionSaysMoving, speed >= 0 else { return nil }
    let candidate = Self.activity(speed: speed, parameters: parameters)
    guard candidate != current else {
      pendingActivity = nil
      return nil
    }
    let count = pendingActivity?.activity == candidate ? (pendingActivity?.count ?? 0) + 1 : 1
    pendingActivity = (candidate, count)
    guard count >= parameters.activityConfirmationFixes else { return nil }
    return move(to: candidate, reason: .activity)
  }

  private var motionSaysMoving: Bool {
    if case .moving = motion { true } else { false }
  }

  private func movingActivity(speed: Double) -> Activity {
    if case .moving(let activity) = motion { return activity }
    return speed >= 0 ? Self.activity(speed: speed, parameters: parameters) : .unknown
  }

  private mutating func move(to activity: Activity, reason: Reason) -> Transition {
    let from = state
    state = .moving(activity)
    stayCentre = nil
    stayEnteredAt = nil
    dwellAnchor = nil
    pendingActivity = nil
    return Transition(from: from, to: state, reason: reason)
  }

  private mutating func stay(centre: (latitude: Double, longitude: Double)?, since time: Date, reason: Reason) -> Transition {
    let from = state
    state = .stationary
    stayCentre = centre
    stayEnteredAt = time
    dwellAnchor = nil
    pendingActivity = nil
    return Transition(from: from, to: state, reason: reason)
  }

  // MARK: - Helpers

  static func activity(speed: Double, parameters: Parameters) -> Activity {
    switch speed {
    case ..<parameters.walkingSpeed: .unknown
    case ..<parameters.cyclingSpeed: .walking
    case ..<parameters.automotiveSpeed: .cycling
    default: .automotive
    }
  }

  /// Equirectangular distance in metres; exact enough below a few kilometres.
  static func distance(from a: (latitude: Double, longitude: Double), to b: (latitude: Double, longitude: Double)) -> Double {
    let earthRadius = 6_371_000.0
    let meanLatitude = (a.latitude + b.latitude) / 2 * .pi / 180
    let x = (b.longitude - a.longitude) * .pi / 180 * cos(meanLatitude)
    let y = (b.latitude - a.latitude) * .pi / 180
    return (x * x + y * y).squareRoot() * earthRadius
  }
}
