import Foundation

/// The coarse motion classification used by the trace stabilizer.
///
/// `uncertain` is intentionally a first-class state.  A short burst of GPS
/// samples is not enough evidence to call either a route or a stationary
/// cloud, so the stabilizer keeps the samples reversible until it has a
/// coherent window.
nonisolated enum MotionState: String, Equatable, Sendable {
  case moving
  case stationary
  case uncertain
}

/// The display decision for one raw point of a move.
nonisolated enum TraceDecision: String, Equatable, Sendable {
  case confirmed
  case provisional
  case suppressed
}
