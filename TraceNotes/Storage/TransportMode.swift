import GRDB

/// How a move was made (PRODUCT F4). Stored by raw value in segments and overrides.
nonisolated enum TransportMode: String, CaseIterable, Sendable, DatabaseValueConvertible {
  case walking
  case running
  case cycling
  case car
  case train
  /// Chosen automatically only for a gap that looks like a subway ride (D19, D42); the user can pick it.
  case subway
  case airplane
  case unknown
}
