import Foundation

/// Pipeline step ③ (ARCHITECTURE §5.1), VS2: turns raw points and visit events into stays, moves
/// and gaps. Pure and deterministic; feed it in time order, then `finish(at:)` returns the
/// segments, the last of which is still open.
///
/// Rules (PRODUCT F3, F6, F8; VS2 decisions of 2026-11-22):
/// - A **stay** starts where usable points remain within `dwellRadius` of an anchor point for
///   `minimumStay`, where the system reports a visit arrival that then lasts `minimumStay`, or
///   where the recorder was silent for longer than `gapInterval` without moving (the stationary
///   heartbeat and distance filter save few points, D28).
/// - A stay ends at the first usable point beyond `stayRadius` (plus its accuracy, as in the
///   recorder) or at a visit departure.
/// - A **gap** is more than `gapInterval` without points *and* a position change beyond the stay
///   radius. Its cause is not decided here (VS6).
/// - Segments are cut at local midnight in their own time zone (D30).
nonisolated struct Segmenter {
  /// Bump when the rules change: stored segments of another version are recomputed (§2.3).
  static let pipelineVersion = 3

  struct Parameters: Sendable {
    /// S3 dwell radius, shared with the recorder's state machine.
    var dwellRadius: Double = 50
    /// Shortest stay shown in the timeline (VS2 decision). Shorter pauses stay inside a move.
    var minimumStay: TimeInterval = 300
    /// S3 stay radius, shared with the recorder's heartbeat (D28).
    var stayRadius: Double = 150
    /// Longest silence that is not a gap or a silent stay (VS2 decision).
    var gapInterval: TimeInterval = 300
    /// Worse points are kept in their segment but decide nothing (S3).
    var maximumDecisionAccuracy: Double = 100
  }

  /// Where processing resumes.
  enum Seed: Sendable {
    /// Nothing before, or the previous segment really ended at `start`: a move begins there (or at
    /// the first point when `start` is nil).
    case fresh(start: Date?)
    /// The previous segment was cut at local midnight (`continuesNextDay`) and goes on.
    case continuing(Segment, pointBefore: RawPoint?)
  }

  private typealias Coordinate = (latitude: Double, longitude: Double)

  private struct Open {
    var kind: Segment.Kind
    var start: Date
    var timeZoneID: String
    var points: [RawPoint] = []
    /// Stays: running mean of the usable points.
    var centerSum: Coordinate = (0, 0)
    var centerCount = 0
    /// Moves: index in `points` of the oldest point of the current dwell window.
    var anchor: Int?
    /// Moves: a visit arrival waiting to last `minimumStay`, and where it happened.
    var visitArrival: Date?
    var visitCenter: Coordinate?

    var center: Coordinate? {
      centerCount == 0 ? nil : (centerSum.latitude / Double(centerCount), centerSum.longitude / Double(centerCount))
    }

    mutating func addToCenter(_ coordinate: Coordinate) {
      centerSum.latitude += coordinate.latitude
      centerSum.longitude += coordinate.longitude
      centerCount += 1
    }
  }

  let parameters: Parameters
  private var open: Open?
  private var freshStart: Date?
  private var lastPoint: RawPoint?
  private var output: [Segment] = []

  init(seed: Seed, parameters: Parameters = Parameters()) {
    self.parameters = parameters
    switch seed {
    case .fresh(let start):
      freshStart = start
    case .continuing(let segment, let pointBefore):
      var continued = Open(kind: segment.kind, start: segment.end, timeZoneID: segment.timeZoneID)
      if let latitude = segment.centerLatitude, let longitude = segment.centerLongitude {
        continued.addToCenter((latitude, longitude))
      }
      open = continued
      lastPoint = pointBefore
    }
  }

  // MARK: - Input

  mutating func add(_ point: RawPoint) {
    // Pipeline step ①: a replayed fix repeats an old position (S3) and is skipped.
    guard !point.flags.contains(.replayed) else { return }
    defer { lastPoint = point }
    guard let current = open else {
      startMove(at: freshStart ?? point.timestamp, timeZoneID: point.timeZoneID, points: [point])
      return
    }
    if current.kind == .gap {
      close(at: point.timestamp)
      startMove(at: point.timestamp, timeZoneID: point.timeZoneID, points: [point])
      return
    }
    let usable = isUsable(point)
    if let last = lastPoint, point.timestamp.timeIntervalSince(last.timestamp) > parameters.gapInterval {
      let reference = current.kind == .stay ? (current.center ?? coordinate(of: last)) : coordinate(of: last)
      let silenceStart = max(last.timestamp, current.start)
      if usable, isOutside(point, of: reference) {
        close(at: silenceStart)
        open = Open(kind: .gap, start: silenceStart, timeZoneID: last.timeZoneID)
        close(at: point.timestamp)
        startMove(at: point.timestamp, timeZoneID: point.timeZoneID, points: [point])
        return
      }
      if current.kind == .move {
        // Silent in the same place: a stay since the last point, or since the dwell window began
        // when the new point is still inside it (the recorder thins points out once it is still).
        if let anchor = current.anchor, usable, distance(current.points[anchor], point) <= parameters.dwellRadius {
          confirmStay(from: current.points[anchor].timestamp)
        } else {
          close(at: silenceStart)
          var stay = Open(kind: .stay, start: silenceStart, timeZoneID: last.timeZoneID)
          if last.timestamp >= silenceStart { stay.points = [last] }
          if isUsable(last) { stay.addToCenter(coordinate(of: last)) }
          open = stay
        }
      }
      appendToStay(point, usable: usable)
      return
    }
    switch current.kind {
    case .stay:
      if usable, let center = current.center, isOutside(point, of: center) {
        let end = lastPoint.map { max($0.timestamp, current.start) } ?? point.timestamp
        close(at: end)
        let boundary = lastPoint.flatMap { $0.timestamp >= end ? $0 : nil }
        startMove(at: end, timeZoneID: point.timeZoneID, points: [boundary, point].compactMap { $0 })
      } else {
        appendToStay(point, usable: usable)
      }
    case .move:
      appendToMove(point, usable: usable)
    case .gap:
      break  // handled above
    }
  }

  /// Only visit events matter here; the other kinds explain gaps later (VS6).
  mutating func add(_ event: RecorderEvent) {
    guard let current = open, event.timestamp >= current.start else { return }
    switch (event.kind, current.kind) {
    case (.visitArrive, .move):
      let center = lastPoint.flatMap { isUsable($0) ? coordinate(of: $0) : nil }
      open?.visitArrival = event.timestamp
      open?.visitCenter = center
    case (.visitDepart, .stay):
      close(at: event.timestamp)
      open = Open(kind: .move, start: event.timestamp, timeZoneID: current.timeZoneID)
    default:
      break
    }
  }

  /// The segments so far. The last one is open: a stay or gap lasts until `now`, a move until
  /// its last point.
  mutating func finish(at now: Date) -> [Segment] {
    if let current = open, current.kind == .move, let arrival = current.visitArrival,
      now.timeIntervalSince(arrival) >= parameters.minimumStay
    {
      confirmStay(from: arrival)
    }
    guard let current = open else { return output }
    let end: Date
    switch current.kind {
    case .stay, .gap: end = max(now, current.points.last?.timestamp ?? current.start)
    case .move: end = current.points.last.map { max($0.timestamp, current.start) } ?? current.start
    }
    return output + pieces(of: current, until: end, complete: false)
  }

  // MARK: - Moves and stays

  private mutating func startMove(at start: Date, timeZoneID: String, points: [RawPoint]) {
    open = Open(kind: .move, start: start, timeZoneID: timeZoneID)
    for point in points { appendToMove(point, usable: isUsable(point)) }
  }

  private mutating func appendToStay(_ point: RawPoint, usable: Bool) {
    let position = coordinate(of: point)
    // Only the core of the stay moves its centre; points on the way in or out (inside the stay
    // radius but beyond the dwell radius) belong to the stay without dragging the centre along.
    let isCore = open?.center.map { Self.distance(position, $0) <= parameters.dwellRadius } ?? true
    open?.points.append(point)
    if usable, isCore { open?.addToCenter(position) }
  }

  private mutating func appendToMove(_ point: RawPoint, usable: Bool) {
    guard var move = open else { return }
    move.points.append(point)
    open = move
    guard usable else { return }

    if let arrival = move.visitArrival {
      if let center = move.visitCenter, isOutside(point, of: center) {
        open?.visitArrival = nil  // left again before it became a stay
      } else {
        let position = coordinate(of: point)
        if move.visitCenter == nil { open?.visitCenter = position }
        if point.timestamp.timeIntervalSince(arrival) >= parameters.minimumStay {
          confirmStay(from: arrival)
          return
        }
      }
    }

    let newest = move.points.count - 1
    var anchor = move.anchor ?? newest
    while anchor < newest, distance(move.points[anchor], point) > parameters.dwellRadius {
      anchor = nextUsableIndex(in: move.points, after: anchor) ?? newest
    }
    open?.anchor = anchor
    let anchorTime = move.points[anchor].timestamp
    if point.timestamp.timeIntervalSince(anchorTime) >= parameters.minimumStay {
      confirmStay(from: anchorTime)
    }
  }

  /// Ends the open move at `start` and opens a stay there holding the move's points from `start`.
  private mutating func confirmStay(from start: Date) {
    guard let move = open else { return }
    let stayStart = max(start, move.start)
    close(at: stayStart)
    let points = move.points.filter { $0.timestamp >= stayStart }
    var stay = Open(kind: .stay, start: stayStart, timeZoneID: points.first?.timeZoneID ?? move.timeZoneID)
    stay.points = points
    // The dwell window (or the points since the visit arrival) is the stay's core.
    for point in points where isUsable(point) { stay.addToCenter(coordinate(of: point)) }
    if stay.centerCount == 0, let visitCenter = move.visitCenter { stay.addToCenter(visitCenter) }
    open = stay
  }

  // MARK: - Closing

  private mutating func close(at end: Date) {
    guard let current = open else { return }
    open = nil
    output += pieces(of: current, until: end, complete: true)
  }

  /// Cuts a segment at each local midnight of its zone (D30). Every piece but the last continues
  /// into the next; empty zero-length pieces are dropped.
  private func pieces(of segment: Open, until end: Date, complete: Bool) -> [Segment] {
    let zone = TimeZone(identifier: segment.timeZoneID) ?? .gmt
    var result: [Segment] = []
    var pieceStart = segment.start
    while true {
      let day = LocalDay(pieceStart, in: zone)
      let midnight = day.next.start(in: zone)
      let continues = midnight < end
      let pieceEnd = continues ? midnight : end
      let points = segment.points.filter { $0.timestamp >= pieceStart && $0.timestamp <= pieceEnd }
      if pieceEnd > pieceStart {
        result.append(makeSegment(segment, day: day, from: pieceStart, to: pieceEnd, points: points, complete: complete || continues, continues: continues))
      }
      guard continues else { return result }
      pieceStart = midnight
    }
  }

  private func makeSegment(
    _ segment: Open, day: LocalDay, from start: Date, to end: Date, points: [RawPoint], complete: Bool, continues: Bool
  ) -> Segment {
    let usable = points.filter(isUsable)
    var distance = 0.0
    var center: Coordinate?
    var radius: Double?
    switch segment.kind {
    case .move:
      for (a, b) in zip(usable, usable.dropFirst()) { distance += self.distance(a, b) }
    case .stay:
      center = segment.center ?? Self.mean(of: points.map(coordinate(of:)))
      if let center {
        radius = usable.map { Self.distance(coordinate(of: $0), center) }.max() ?? 0
      }
    case .gap:
      break
    }
    return Segment(
      id: nil, kind: segment.kind, start: start, end: end, timeZoneID: segment.timeZoneID, localDay: day,
      isComplete: complete, continuesNextDay: continues, pointCount: points.count, distance: distance,
      centerLatitude: center?.latitude, centerLongitude: center?.longitude, radius: radius,
      pipelineVersion: Self.pipelineVersion)
  }

  // MARK: - Geometry

  private func isUsable(_ point: RawPoint) -> Bool {
    point.horizontalAccuracy >= 0 && point.horizontalAccuracy <= parameters.maximumDecisionAccuracy
  }

  private func isOutside(_ point: RawPoint, of center: Coordinate) -> Bool {
    Self.distance(coordinate(of: point), center) > parameters.stayRadius + point.horizontalAccuracy
  }

  private func nextUsableIndex(in points: [RawPoint], after index: Int) -> Int? {
    points.indices.dropFirst(index + 1).first { isUsable(points[$0]) }
  }

  private func coordinate(of point: RawPoint) -> Coordinate {
    (point.latitude, point.longitude)
  }

  private func distance(_ a: RawPoint, _ b: RawPoint) -> Double {
    Self.distance(coordinate(of: a), coordinate(of: b))
  }

  private static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
    MotionStateMachine.distance(from: a, to: b)
  }

  private static func mean(of coordinates: [Coordinate]) -> Coordinate? {
    guard !coordinates.isEmpty else { return nil }
    let count = Double(coordinates.count)
    return (
      coordinates.map(\.latitude).reduce(0, +) / count,
      coordinates.map(\.longitude).reduce(0, +) / count
    )
  }
}
