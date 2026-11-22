import Foundation
import Testing

/// VS1 · Recording decisions (TraceNotes/Recording): heartbeat (D28), replayed fixes, persisted
/// engine state.
struct RecordingCoreTests {
  let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
  /// ~1 m of latitude in degrees.
  let metre = 1.0 / 111_195

  func fix(_ seconds: TimeInterval, north metres: Double = 0, accuracy: Double = 10, speed: Double = -1) -> LocationFix {
    LocationFix(
      timestamp: start.addingTimeInterval(seconds), latitude: 35 + metres * metre, longitude: 139,
      horizontalAccuracy: accuracy, speed: speed)
  }

  /// A core that has just entered a stay at t = 180 s (fixes every 10 s within 20 m).
  func stationaryCore(launchedAt: Date? = nil) -> RecordingCore {
    var core = RecordingCore(launchedAt: launchedAt ?? start)
    for second in stride(from: 0.0, through: 180, by: 10) {
      _ = core.handle(fix(second, north: second.truncatingRemainder(dividingBy: 20)))
    }
    return core
  }

  @Test func movingSavesEveryFix() {
    var core = RecordingCore(launchedAt: start)
    let decisions = (0..<30).map { core.handle(fix(Double($0), north: Double($0) * 1.4, speed: 1.4)) }
    #expect(decisions.filter { !$0.save }.isEmpty)
    #expect(core.state.isMoving)
  }

  @Test func stayEntryIsSaved() {
    var core = RecordingCore(launchedAt: start)
    var last: RecordingCore.Decision?
    for second in stride(from: 0.0, through: 180, by: 10) {
      last = core.handle(fix(second, north: 5))
    }
    #expect(last?.transition?.to == .stationary)
    #expect(last?.save == true)
  }

  /// D28 with a fake clock: one point per 5 minutes while stationary.
  @Test func heartbeatSavesOnePointEveryFiveMinutes() {
    var core = stationaryCore()
    var saved: [TimeInterval] = []
    // 15 minutes of fixes every 10 s, all within 10 m of the centre.
    for second in stride(from: 190.0, through: 180 + 900, by: 10) {
      let decision = core.handle(fix(second, north: second.truncatingRemainder(dividingBy: 10)))
      #expect(decision.transition == nil)
      if decision.save { saved.append(second) }
    }
    #expect(saved == [480, 780, 1080])
    #expect(core.state == .stationary)
  }

  @Test func pointOutsideTheStayIsSavedAtOnceAndEndsIt() {
    var core = stationaryCore()
    #expect(core.handle(fix(200, north: 5)).save == false)
    let outside = core.handle(fix(210, north: 400, speed: 1.4))
    #expect(outside.save)
    #expect(outside.transition?.reason == .displacement)
    #expect(core.state == .moving(.walking))
  }

  /// D38: the heartbeat skips the way out of the place, so the core remembers the last fix that
  /// was still at the place; the engine saves the skipped fixes from there when the stay ends.
  @Test func lastFixAtThePlaceMarksTheWayOut() {
    var core = stationaryCore()
    #expect(core.lastAtPlace == start.addingTimeInterval(180))
    #expect(core.handle(fix(200, north: 30)).save == false)  // still within 50 m
    #expect(core.handle(fix(210, north: 70)).save == false)  // on the way out
    #expect(core.handle(fix(220, north: 110)).save == false)
    #expect(core.lastAtPlace == start.addingTimeInterval(200))
    let outside = core.handle(fix(230, north: 400, speed: 1.4))
    #expect(outside.transition?.from == .stationary)
    #expect(core.lastAtPlace == start.addingTimeInterval(200))
  }

  /// A poor fix far away is not credible evidence of leaving (F3), so the heartbeat holds it.
  @Test func poorFixFarAwayDoesNotEndTheStay() {
    var core = stationaryCore()
    let poor = core.handle(fix(200, north: 900, accuracy: 1500))
    #expect(poor.save == false)
    #expect(poor.flags.contains(.lowAccuracy))
    #expect(core.state == .stationary)
  }

  /// S3 finding: a cached fix replayed on launch has an old timestamp; it is saved and flagged
  /// but never decides the state.
  @Test func replayedFixesAreSavedButDoNotDecide() {
    let launch = start.addingTimeInterval(3600)
    var core = RecordingCore(launchedAt: launch)
    // Ten minutes of still fixes, all from before the launch: would be a dwell if they counted.
    for second in stride(from: 0.0, through: 600, by: 10) {
      let decision = core.handle(fix(second, north: 2))
      #expect(decision.save)
      #expect(decision.flags.contains(.replayed))
      #expect(decision.transition == nil)
    }
    #expect(core.state == .moving(.unknown))
    #expect(core.handle(fix(3601)).flags.contains(.replayed) == false)
  }

  @Test func skippedPointsAreReportedOncePerHour() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let hourStart = calendar.dateInterval(of: .hour, for: start)!.start
    var core = RecordingCore(launchedAt: hourStart, calendar: calendar)
    let base = hourStart.timeIntervalSince(start)
    for second in stride(from: 0.0, through: 180, by: 10) {
      _ = core.handle(fix(base + second, north: 5))
    }
    var reports: [RecordingCore.SkippedReport] = []
    // Still fixes every 30 s until 70 minutes into the hour.
    for second in stride(from: 210.0, through: 4200, by: 30) {
      if let report = core.handle(fix(base + second, north: 5)).skippedReport { reports.append(report) }
    }
    #expect(reports.count == 1)
    #expect(reports.first?.hourStart == hourStart)
    // 113 fixes in the first hour after the stay began (210 s … 3570 s), 11 of them heartbeats.
    #expect(reports.first?.count == 102)
  }

  /// ARCHITECTURE §4.3: after a kill the engine resumes the stay at once instead of needing
  /// another 3 minutes of fixes (S3 round 4).
  @Test func persistedStateRestoresTheStay() throws {
    let store = EngineStateStore(defaults: try #require(UserDefaults(suiteName: "RecordingCoreTests-\(UUID().uuidString)")))
    #expect(try store.loadSnapshot() == nil)
    let before = stationaryCore()
    try store.save(before.snapshot)

    let snapshot = try #require(try store.loadSnapshot())
    #expect(snapshot == before.snapshot)
    var after = RecordingCore(launchedAt: start.addingTimeInterval(400), restoring: snapshot)
    #expect(after.state == .stationary)
    #expect(after.machine.stayEnteredAt == start.addingTimeInterval(180))
    // Heartbeat continues from the persisted last save (t = 180 s).
    #expect(after.handle(fix(401, north: 5)).save == false)
    #expect(after.handle(fix(481, north: 5)).save)
    #expect(after.handle(fix(500, north: 400)).transition?.reason == .displacement)
  }

  @Test func detectsAKilledPreviousProcess() throws {
    let store = EngineStateStore(defaults: try #require(UserDefaults(suiteName: "RecordingCoreTests-\(UUID().uuidString)")))
    #expect(store.markProcessStarted() == false)
    #expect(store.markProcessStarted() == true)  // never reached markProcessEnded
    store.markProcessEnded()
    #expect(store.markProcessStarted() == false)
  }

  @Test func motionDwellStartsAStayWithoutFixes() {
    var core = RecordingCore(launchedAt: start)
    #expect(core.handle(.stationary, at: start) == nil)
    #expect(core.handle(.stationary, at: start.addingTimeInterval(180))?.reason == .motionDwell)
    // The first usable fix becomes the centre; one 400 m away from it then ends the stay.
    _ = core.handle(fix(200))
    #expect(core.handle(fix(210, north: 400)).transition?.reason == .displacement)
  }

  @Test func vehicleMotionKeepsMovingThroughStops() {
    var core = RecordingCore(launchedAt: start)
    _ = core.handle(.moving(.automotive), at: start)
    for second in stride(from: 0.0, through: 600, by: 10) {
      #expect(core.handle(fix(second)).transition == nil)
    }
    #expect(core.state == .moving(.automotive))
  }
}
