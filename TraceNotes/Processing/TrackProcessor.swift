import CoreLocation
import Foundation
import GRDB
import os

/// Keeps the derived segments up to date with the raw layer (ARCHITECTURE §5).
///
/// Each run recomputes only the tail after the newest *completed* segment, so it holds no state
/// between runs: after a kill or a relaunch the next run simply continues from the database
/// (§5.2). The open segment is rewritten on every run, which also covers the 30-minute checkpoint
/// (D30).
nonisolated final class TrackProcessor: Sendable {
  private let database: AppDatabase
  private let parameters: Segmenter.Parameters

  init(database: AppDatabase, parameters: Segmenter.Parameters = Segmenter.Parameters()) {
    self.database = database
    self.parameters = parameters
  }

  /// Processes now and after every append until the calling task is cancelled.
  func run() async throws {
    let dropped = try await database.deleteSegments(otherThan: Segmenter.pipelineVersion)
    if dropped > 0 {
      AppLog.processing.notice("pipeline v\(Segmenter.pipelineVersion): dropped \(dropped) old segments")
    }
    for try await _ in database.observeRawAppends() {
      try await process(now: .now)
    }
  }

  /// One run: segment everything after the last completed segment and store the result. Reads
  /// again when the data changed underneath (all data deleted, D55 ②).
  func process(now: Date) async throws {
    while try await !processOnce(now: now) {
      AppLog.processing.notice("the derived layer changed while processing; reading again")
    }
  }

  /// False when the result was not stored because the data changed after it was read.
  private func processOnce(now: Date) async throws -> Bool {
    let input = try await database.segmentationInput()
    let seed: Segmenter.Seed
    if let last = input.lastComplete, last.continuesNextDay {
      seed = .continuing(last, pointBefore: input.pointBeforeCursor)
    } else {
      seed = .fresh(start: input.lastComplete?.end)
    }
    var segmenter = Segmenter(seed: seed, parameters: parameters)
    var events = input.events.makeIterator()
    var nextEvent = events.next()
    for point in input.points {
      while let event = nextEvent, event.timestamp <= point.timestamp {
        segmenter.add(event)
        nextEvent = events.next()
      }
      segmenter.add(point)
    }
    while let event = nextEvent {
      segmenter.add(event)
      nextEvent = events.next()
    }
    let segmented = segmenter.finish(at: now)
    // Pipeline step ④: transport modes, then the user's corrections (ARCHITECTURE §2.2).
    let activities = ([input.activityBeforeCursor].compactMap { $0 } + input.events)
      .compactMap(TransportClassifier.ActivityReading.init)
    var segments = segmented.flatMap { segment in
      segment.kind == .move ? TransportClassifier.split(segment, points: input.points, activities: activities) : [segment]
    }
    // Pipeline step ⑥: why each gap has no points, and whether it was a subway ride (F6, D42).
    for index in segments.indices where segments[index].kind == .gap {
      explain(&segments[index], input: input, activities: activities)
    }
    let unmatched = SegmentOverride.applyTransportModes(input.overrides, to: &segments)
    if unmatched > 0 {
      AppLog.processing.notice("\(unmatched) transport-mode overrides match no segment by half their range")
    }
    // Pipeline step ⑦: every move's distance is the length of the track the map draws; completed
    // moves also get their simplified levels now, while the open one is simplified in memory by
    // the map as it grows (ARCHITECTURE §5.1).
    var renderLevels: [Int: [[RenderCache.Coordinate]]] = [:]
    for (index, segment) in segments.enumerated() where segment.kind == .move {
      let before = index > 0 ? segments[index - 1] : input.lastComplete
      let after = index + 1 < segments.count ? segments[index + 1] : nil
      let track = RenderCache.track(
        of: segment, previous: before, next: after, points: index > 0 ? input.points : input.lastStayPoints + input.points)
      segments[index].distance = RenderCache.length(of: track)
      if segment.isComplete, track.count > 1 { renderLevels[index] = RenderCache.levels(of: track) }
    }
    return try await database.replaceOpenSegments(madeFrom: input, with: segments, renderLevels: renderLevels)
  }

  private func explain(_ gap: inout Segment, input: AppDatabase.SegmentationInput, activities: [TransportClassifier.ActivityReading]) {
    let usable = ([input.pointBeforeCursor].compactMap { $0 } + input.points).filter { !$0.flags.contains(.replayed) }
    let entry = usable.last { $0.timestamp <= gap.start }
    let exit = usable.first { $0.timestamp >= gap.end }
    let lowPower = input.events.last { [.lowPowerModeOn, .lowPowerModeOff].contains($0.kind) && $0.timestamp < gap.start }
      ?? input.lowPowerBeforeCursor
    let explanation = GapExplainer.explain(
      start: gap.start, end: gap.end, events: input.events, lowPowerBefore: lowPower,
      activityBefore: activities.last { $0.timestamp <= gap.start },
      entry: entry.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
      exit: exit.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
    gap.gapReason = explanation.reason
    gap.transportMode = explanation.isSubway ? .subway : nil
  }
}
