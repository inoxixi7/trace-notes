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

  /// One run: segment everything after the last completed segment and store the result.
  func process(now: Date) async throws {
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
    try await database.replaceOpenSegments(with: segmenter.finish(at: now))
  }
}
