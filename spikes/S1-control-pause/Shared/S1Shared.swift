import Foundation
import os

/// S1 spike: state shared by the app and the widget extension through the App Group.
///
/// Throwaway code for the Control Center pause/resume spike. Compiled into both targets.
nonisolated enum S1Shared {
  static let appGroupID = "group.com.inoxixi.tracenotes"
  static let controlKind = "com.inoxixi.tracenotes.s1.recording-toggle"
  /// Darwin notification posted by the widget extension after it changes the pause flag.
  static let pauseChangedNotification = "com.inoxixi.tracenotes.s1.pause-changed"
  static let logger = Logger(subsystem: "com.inoxixi.tracenotes", category: "S1")

  /// What the app does with the location stream while paused. Both are measured in the spike.
  enum PauseStrategy: String, CaseIterable, Sendable {
    /// Keep sessions and live updates running; drop samples instead of saving them.
    case keepUpdates
    /// Keep sessions alive but stop iterating live updates; restart them on resume.
    case stopUpdates
  }

  private enum Key {
    static let isPaused = "s1.isPaused"
    static let isArmed = "s1.isArmed"
    static let pauseStrategy = "s1.pauseStrategy"
  }

  private static var defaults: UserDefaults {
    guard let defaults = UserDefaults(suiteName: appGroupID) else {
      preconditionFailure("App Group \(appGroupID) is missing from the entitlements")
    }
    return defaults
  }

  static var isPaused: Bool {
    get { defaults.bool(forKey: Key.isPaused) }
    set { defaults.set(newValue, forKey: Key.isPaused) }
  }

  /// True once the user has started recording in the app; launches re-create the sessions while set.
  static var isArmed: Bool {
    get { defaults.bool(forKey: Key.isArmed) }
    set { defaults.set(newValue, forKey: Key.isArmed) }
  }

  static var pauseStrategy: PauseStrategy {
    get {
      defaults.string(forKey: Key.pauseStrategy).flatMap(PauseStrategy.init(rawValue:))
        ?? .keepUpdates
    }
    set { defaults.set(newValue.rawValue, forKey: Key.pauseStrategy) }
  }

  static func postPauseChanged() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(pauseChangedNotification as CFString),
      nil,
      nil,
      true
    )
  }
}
