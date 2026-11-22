import GRDB

/// Why a gap has no points (PRODUCT F6), from the recorder's own events (ARCHITECTURE §2.3). A
/// subway ride is not a reason here: it is the gap's transport mode, so the user can correct it
/// like any other mode (D42).
nonisolated enum GapReason: String, CaseIterable, Sendable, DatabaseValueConvertible {
  case permissionChanged
  case locationOff
  /// The phone was off or the app was not running; the two cannot be told apart.
  case notRunning
  case lowPower
  case unknown
}
