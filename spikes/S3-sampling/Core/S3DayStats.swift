import Foundation

/// S3 spike: one day's counters (local calendar day). Contains **no coordinates**.
nonisolated struct S3DayStats: Codable, Sendable, Equatable {
  /// Local date, "yyyy-MM-dd".
  var day: String
  var secondsByState: [String: Double] = [:]
  var secondsByStrategy: [String: Double] = [:]
  var pausedSeconds: Double = 0
  var savedPoints = 0
  var skippedPoints = 0
  var pointsByAccuracy: [String: Int] = [:]
  /// Saved points per local hour (0–23).
  var pointsByHour = [Int](repeating: 0, count: 24)
  /// Longest time between two consecutive saved points while moving.
  var longestMovingGap: Double = 0
  var longestMovingGapEnd: Date?
  /// Longest time with no event at all while recording (suspension or no deliveries).
  var longestSilence: Double = 0
  var longestSilenceEnd: Date?
  var transitions = 0
  var launches = 0
  /// Largest distance of a saved point from the stay anchor while stationary (F3 drift).
  var maximumStayDrift: Double = 0
  /// The last event, persisted so that time spent after it is still accrued when the process was
  /// killed (iOS terminates suspended apps without a callback) and later relaunched.
  var lastEvent: EventMark?

  struct EventMark: Codable, Sendable, Equatable {
    var time: Date
    var state: String
    var strategy: String
    var paused: Bool
  }

  static func dayString(for date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func accuracyBucket(_ accuracy: Double) -> String {
    switch accuracy {
    case ..<0: "invalid"
    case ...10: "≤10m"
    case ...50: "≤50m"
    case ...100: "≤100m"
    case ...1000: "≤1km"
    default: ">1km"
    }
  }

  static let accuracyBucketOrder = ["≤10m", "≤50m", "≤100m", "≤1km", ">1km", "invalid"]
}

/// Accumulates `S3DayStats` from recorder events. Time between two events is attributed to the
/// state, strategy and pause flag that held during it, and to the day of the later event.
nonisolated struct S3StatsTracker: Sendable {
  private(set) var today: S3DayStats
  private var lastSavedPoint: (time: Date, moving: Bool)?
  /// Fixes timestamped before this (the process launch) are cached replays, e.g. the last known
  /// location that significant-change monitoring delivers on every launch.
  private var replayCutoff: Date?
  private let calendar: Calendar

  init(today: S3DayStats? = nil, now: Date, calendar: Calendar = .current) {
    self.calendar = calendar
    self.today = today ?? S3DayStats(day: S3DayStats.dayString(for: now, calendar: calendar))
  }

  /// Rolls over to a new day if needed; returns the finished day so the caller can archive it.
  mutating func rollOver(at time: Date) -> S3DayStats? {
    let day = S3DayStats.dayString(for: time, calendar: calendar)
    guard day != today.day else { return nil }
    let finished = today
    today = S3DayStats(day: day)
    today.lastEvent = finished.lastEvent
    return finished
  }

  /// Any event while recording. Accrues the elapsed time and tracks silence.
  mutating func noteEvent(at time: Date, state: String, strategy: String, paused: Bool) {
    if let lastEvent = today.lastEvent {
      let elapsed = max(0, time.timeIntervalSince(lastEvent.time))
      today.secondsByState[lastEvent.state, default: 0] += elapsed
      today.secondsByStrategy[lastEvent.strategy, default: 0] += elapsed
      if lastEvent.paused { today.pausedSeconds += elapsed }
      if elapsed > today.longestSilence {
        today.longestSilence = elapsed
        today.longestSilenceEnd = time
      }
    }
    today.lastEvent = S3DayStats.EventMark(time: time, state: state, strategy: strategy, paused: paused)
  }

  /// Recording stopped: the next interval is not attributable.
  mutating func breakContinuity() {
    today.lastEvent = nil
    lastSavedPoint = nil
  }

  /// A new process. Time since the persisted last event still counts (the phone kept its state while
  /// the app was not running), but point continuity starts again.
  mutating func noteRelaunch(at time: Date) {
    lastSavedPoint = nil
    replayCutoff = time
  }

  /// A fix timestamped before this process started.
  func isReplay(_ time: Date) -> Bool {
    replayCutoff.map { time < $0 } ?? false
  }

  mutating func notePoint(
    at time: Date, accuracy: Double, saved: Bool, moving: Bool, stayDrift: Double?
  ) {
    guard saved else {
      today.skippedPoints += 1
      // A pause is not a gap in the recording.
      lastSavedPoint = nil
      return
    }
    today.savedPoints += 1
    today.pointsByAccuracy[S3DayStats.accuracyBucket(accuracy), default: 0] += 1
    let hour = calendar.component(.hour, from: time)
    if today.pointsByHour.indices.contains(hour) { today.pointsByHour[hour] += 1 }
    if let stayDrift, stayDrift > today.maximumStayDrift { today.maximumStayDrift = stayDrift }
    // A replayed fix is not news; it neither ends nor starts a gap.
    guard !isReplay(time) else { return }
    if let last = lastSavedPoint, last.moving, moving {
      let gap = time.timeIntervalSince(last.time)
      if gap > today.longestMovingGap {
        today.longestMovingGap = gap
        today.longestMovingGapEnd = time
      }
    }
    lastSavedPoint = (time, moving)
  }

  mutating func noteTransition() { today.transitions += 1 }
  mutating func noteLaunch() { today.launches += 1 }
}
