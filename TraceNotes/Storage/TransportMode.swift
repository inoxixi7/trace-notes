import GRDB

/// How a move was made (PRODUCT F4). Stored by raw value in segments and overrides.
nonisolated enum TransportMode: String, CaseIterable, Sendable, DatabaseValueConvertible {
  case walking
  case running
  case cycling
  case car
  case train
  /// Never chosen automatically yet: it needs the underground gaps of VS6 (D19). The user can pick it.
  case subway
  case airplane
  case unknown
}
