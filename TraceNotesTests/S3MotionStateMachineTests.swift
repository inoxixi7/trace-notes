import Foundation
import Testing

/// S3 spike: state machine and stats tracker (spikes/S3-sampling/Core).
struct S3MotionStateMachineTests {
  typealias Machine = S3MotionStateMachine
  let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
  /// ~1 m of latitude in degrees.
  let metre = 1.0 / 111_195

  func fix(_ seconds: TimeInterval, north metres: Double = 0, accuracy: Double = 10, speed: Double = -1)
    -> Machine.Fix
  {
    Machine.Fix(
      time: start.addingTimeInterval(seconds), latitude: 35 + metres * metre, longitude: 139,
      horizontalAccuracy: accuracy, speed: speed)
  }

  /// Feeds still fixes until the machine enters a stay.
  func stationaryMachine() -> Machine {
    var machine = Machine()
    for second in stride(from: 0.0, through: 200, by: 10) {
      _ = machine.ingest(fix(second, north: second.truncatingRemainder(dividingBy: 20)))
    }
    return machine
  }

  @Test func startsMovingForReliability() {
    #expect(Machine().state == .moving(.unknown))
  }

  @Test func dwellEntersStationary() {
    var machine = Machine()
    #expect(machine.ingest(fix(0)) == nil)
    #expect(machine.ingest(fix(170, north: 30)) == nil)
    let transition = machine.ingest(fix(180, north: 20))
    #expect(transition?.to == .stationary)
    #expect(transition?.reason == "dwell")
  }

  @Test func leavingDwellRadiusRestartsTheClock() {
    var machine = Machine()
    _ = machine.ingest(fix(0))
    _ = machine.ingest(fix(100, north: 80))
    #expect(machine.ingest(fix(200, north: 80)) == nil)
    #expect(machine.ingest(fix(280, north: 90))?.to == .stationary)
  }

  @Test func poorFixesNeitherEnterNorLeaveStays() {
    var machine = Machine()
    _ = machine.ingest(fix(0))
    #expect(machine.ingest(fix(300, north: 5, accuracy: 500)) == nil)
    #expect(machine.state.isMoving)

    var still = stationaryMachine()
    #expect(still.ingest(fix(400, north: 2000, accuracy: 1500)) == nil)
    #expect(still.state == .stationary)
  }

  @Test func motionMovingBlocksDwell() {
    var machine = Machine()
    _ = machine.ingest(Machine.MotionReading.moving(.automotive), at: start)
    _ = machine.ingest(fix(1))
    #expect(machine.ingest(fix(200)) == nil)
    #expect(machine.state == .moving(.automotive))
  }

  @Test func displacementLeavesStay() {
    var machine = stationaryMachine()
    #expect(machine.state == .stationary)
    #expect(machine.ingest(fix(300, north: 120)) == nil)  // within exit radius + accuracy
    let transition = machine.ingest(fix(310, north: 200, speed: 1.4))
    #expect(transition?.to == .moving(.walking))
    #expect(transition?.reason == "displacement")
  }

  @Test func motionLeavesStay() {
    var machine = stationaryMachine()
    let transition = machine.ingest(.moving(.walking), at: start.addingTimeInterval(300))
    #expect(transition?.to == .moving(.walking))
  }

  @Test func exitEventLeavesStayOnlyWhenStationary() {
    var moving = Machine()
    #expect(moving.ingestExit(reason: "geofence.exit", at: start) == nil)
    var still = stationaryMachine()
    #expect(still.ingestExit(reason: "geofence.exit", at: start)?.to == .moving(.unknown))
  }

  @Test func motionAloneEntersStayAfterDwellTime() {
    var machine = Machine()
    #expect(machine.ingest(.stationary, at: start) == nil)
    #expect(machine.ingest(.stationary, at: start.addingTimeInterval(120)) == nil)
    #expect(machine.ingest(.stationary, at: start.addingTimeInterval(180))?.reason == "motion.dwell")
  }

  @Test func speedActivityNeedsConfirmation() {
    var machine = Machine()
    var transition: Machine.Transition?
    for index in 0..<5 {
      transition = machine.ingest(fix(Double(index), north: Double(index) * 60, speed: 15))
      if index < 4 { #expect(transition == nil) }
    }
    #expect(transition?.to == .moving(.automotive))
  }

  @Test func systemStationaryIgnoredWhileMotionSaysMoving() {
    var machine = Machine()
    _ = machine.ingest(.moving(.automotive), at: start)
    // Core Motion reports changes only, so "automotive" still holds 20 minutes later.
    #expect(machine.ingestSystemStationary(at: start.addingTimeInterval(1200), lastFix: nil) == nil)
    _ = machine.ingest(.stationary, at: start.addingTimeInterval(1210))
    #expect(machine.ingestSystemStationary(at: start.addingTimeInterval(1220), lastFix: fix(1220))?.to == .stationary)
  }
}

struct S3StatsTrackerTests {
  let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @Test func accruesTimeAndGaps() {
    var tracker = S3StatsTracker(now: start)
    tracker.noteEvent(at: start, state: "moving.walking", strategy: "A", paused: false)
    tracker.notePoint(at: start, accuracy: 5, saved: true, moving: true, stayDrift: nil)
    tracker.noteEvent(at: start.addingTimeInterval(90), state: "moving.walking", strategy: "A", paused: false)
    tracker.notePoint(at: start.addingTimeInterval(90), accuracy: 30, saved: true, moving: true, stayDrift: nil)
    tracker.noteEvent(at: start.addingTimeInterval(100), state: "stationary", strategy: "A", paused: true)
    tracker.notePoint(at: start.addingTimeInterval(100), accuracy: 30, saved: false, moving: false, stayDrift: nil)
    tracker.noteEvent(at: start.addingTimeInterval(400), state: "stationary", strategy: "A", paused: true)

    let stats = tracker.today
    #expect(stats.secondsByState["moving.walking"] == 100)
    #expect(stats.secondsByState["stationary"] == 300)
    #expect(stats.pausedSeconds == 300)
    #expect(stats.longestMovingGap == 90)
    #expect(stats.longestSilence == 300)
    #expect(stats.savedPoints == 2 && stats.skippedPoints == 1)
    #expect(stats.pointsByAccuracy["≤10m"] == 1 && stats.pointsByAccuracy["≤50m"] == 1)
  }

  @Test func pauseIsNotAMovingGap() {
    var tracker = S3StatsTracker(now: start)
    tracker.notePoint(at: start, accuracy: 5, saved: true, moving: true, stayDrift: nil)
    tracker.notePoint(at: start.addingTimeInterval(10), accuracy: 5, saved: false, moving: true, stayDrift: nil)
    tracker.notePoint(at: start.addingTimeInterval(1000), accuracy: 5, saved: true, moving: true, stayDrift: nil)
    #expect(tracker.today.longestMovingGap == 0)
  }

  @Test func timeAfterAKillStillAccruesToTheLastState() {
    var before = S3StatsTracker(now: start)
    before.noteEvent(at: start, state: "stationary", strategy: "C", paused: false)
    // The process is killed; a new one loads the saved day and is relaunched an hour later.
    var after = S3StatsTracker(today: before.today, now: start.addingTimeInterval(3600))
    after.noteRelaunch(at: start.addingTimeInterval(3600))
    after.noteEvent(at: start.addingTimeInterval(3600), state: "moving.unknown", strategy: "C", paused: false)
    #expect(after.today.secondsByState["stationary"] == 3600)
    #expect(after.today.longestSilence == 3600)
  }

  @Test func replayedFixIsCountedButIsNotAGap() {
    var tracker = S3StatsTracker(now: start)
    let launch = start.addingTimeInterval(7000)
    tracker.noteRelaunch(at: launch)
    #expect(tracker.isReplay(start))
    tracker.notePoint(at: start, accuracy: 5, saved: true, moving: true, stayDrift: nil)
    tracker.notePoint(at: launch.addingTimeInterval(1), accuracy: 5, saved: true, moving: true, stayDrift: nil)
    tracker.notePoint(at: launch.addingTimeInterval(2), accuracy: 5, saved: true, moving: true, stayDrift: nil)
    #expect(tracker.today.savedPoints == 3)
    #expect(tracker.today.longestMovingGap == 1)
  }

  @Test func disarmBreaksTimeContinuity() {
    var tracker = S3StatsTracker(now: start)
    tracker.noteEvent(at: start, state: "stationary", strategy: "B", paused: false)
    tracker.breakContinuity()
    tracker.noteEvent(at: start.addingTimeInterval(600), state: "stationary", strategy: "B", paused: false)
    #expect(tracker.today.secondsByState["stationary"] == nil)
  }

  @Test func rollsOverAtMidnight() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 23))!
    var tracker = S3StatsTracker(now: day, calendar: calendar)
    #expect(tracker.rollOver(at: day.addingTimeInterval(1800)) == nil)
    #expect(tracker.rollOver(at: day.addingTimeInterval(3700))?.day == "2026-11-21")
    #expect(tracker.today.day == "2026-11-22")
  }
}
