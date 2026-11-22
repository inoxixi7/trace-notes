import Foundation

/// Engine state that must survive a process kill, in the App Group (ARCHITECTURE §4.3): the
/// state machine snapshot (state, stay centre, entry time) and whether the last process ended
/// cleanly.
nonisolated struct EngineStateStore: Sendable {
  static let appGroupID = "group.com.inoxixi.tracenotes"

  private enum Keys {
    static let snapshot = "engine.snapshot"
    static let processRunning = "engine.processRunning"
  }

  /// `UserDefaults` is documented as thread-safe but not marked `Sendable`.
  nonisolated(unsafe) private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// The App Group store. A missing App Group entitlement is a build configuration error.
  static func appGroup() -> EngineStateStore {
    guard let defaults = UserDefaults(suiteName: appGroupID) else {
      preconditionFailure("App Group \(appGroupID) is missing from the entitlements")
    }
    return EngineStateStore(defaults: defaults)
  }

  /// Throws when stored data cannot be decoded; the caller logs it and starts fresh.
  func loadSnapshot() throws -> RecordingCore.Snapshot? {
    guard let data = defaults.data(forKey: Keys.snapshot) else { return nil }
    return try JSONDecoder().decode(RecordingCore.Snapshot.self, from: data)
  }

  func save(_ snapshot: RecordingCore.Snapshot) throws {
    defaults.set(try JSONEncoder().encode(snapshot), forKey: Keys.snapshot)
  }

  /// Marks a process as running. Returns true if the previous process never reached
  /// `markProcessEnded()`, i.e. it was killed.
  func markProcessStarted() -> Bool {
    let previousWasRunning = defaults.bool(forKey: Keys.processRunning)
    defaults.set(true, forKey: Keys.processRunning)
    return previousWasRunning
  }

  func markProcessEnded() {
    defaults.set(false, forKey: Keys.processRunning)
  }
}
