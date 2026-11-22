import CoreLocation
import Foundation
import Testing

/// VS6 · GapExplainer (pipeline step ⑥): one cause per gap in the confirmed order, and the subway
/// rule (D42).
struct GapExplainerTests {
  let helper = SegmenterTests()
  /// A 20-minute gap from 0 s to 1200 s.
  let start = 0.0
  let end = 1200.0

  func coordinate(north metres: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: 35 + metres * helper.metre, longitude: 139)
  }

  func event(_ seconds: TimeInterval, _ kind: RecorderEvent.Kind, _ payload: String? = nil) -> RecorderEvent {
    var event = helper.event(seconds, kind)
    event.payload = payload
    return event
  }

  func riding(_ seconds: TimeInterval) -> RecorderEvent {
    event(seconds, .motionActivity, "activity=automotive confidence=high")
  }

  func walking(_ seconds: TimeInterval) -> RecorderEvent {
    event(seconds, .motionActivity, "activity=walking confidence=high")
  }

  /// 8 km in 20 minutes (24 km/h) unless told otherwise.
  func explain(
    _ events: [RecorderEvent], lowPowerBefore: RecorderEvent? = nil, activityBefore: TransportClassifier.ActivityReading? = nil,
    exitNorth: Double = 8_000
  ) -> GapExplainer.Explanation {
    GapExplainer.explain(
      start: helper.base.addingTimeInterval(start), end: helper.base.addingTimeInterval(end), events: events,
      lowPowerBefore: lowPowerBefore, activityBefore: activityBefore,
      entry: coordinate(north: 0), exit: coordinate(north: exitNorth))
  }

  @Test func nothingRecordedIsUnknown() {
    #expect(explain([]) == .init(reason: .unknown, isSubway: false))
  }

  /// Every launch writes the current status; a granted one is not a cause.
  @Test func onlyStatusesThatStopRecordingCount() {
    #expect(explain([event(600, .authorizationChanged, "status=always")]).reason == .unknown)
    #expect(explain([event(600, .authorizationChanged, "status=denied")]).reason == .permissionChanged)
    #expect(explain([event(600, .locationServicesOff)]).reason == .locationOff)
  }

  @Test func aRelaunchMeansNotRunning() {
    #expect(explain([event(1150, .terminatedDetected), event(1150, .launch)]).reason == .notRunning)
    #expect(explain([event(1190, .backgroundRelaunch)]).reason == .notRunning)
  }

  @Test func lowPowerOnAtTheStartOrDuringTheGap() {
    #expect(explain([], lowPowerBefore: event(-600, .lowPowerModeOn)).reason == .lowPower)
    #expect(explain([], lowPowerBefore: event(-600, .lowPowerModeOff)).reason == .unknown)
    #expect(explain([event(300, .lowPowerModeOn)]).reason == .lowPower)
  }

  @Test func riding8KilometresIsASubway() {
    #expect(explain([riding(400)]).isSubway)
    // Riding before and after, with nothing inside (the train left a station, the app slept).
    let before = TransportClassifier.ActivityReading(timestamp: helper.base, activity: .automotive)
    #expect(explain([riding(1300)], activityBefore: before).isSubway)
    // Riding before only: walking out of the station afterwards is not enough.
    #expect(!explain([walking(1300)], activityBefore: before).isSubway)
  }

  @Test func walkingOrTheWrongSpeedIsNotASubway() {
    #expect(!explain([walking(400)]).isSubway)
    #expect(!explain([riding(400)], exitNorth: 900).isSubway)  // under 1 km
    #expect(!explain([riding(400)], exitNorth: 3_000).isSubway)  // 9 km/h
    #expect(!explain([riding(400)], exitNorth: 40_000).isSubway)  // 120 km/h
  }

  /// The confirmed order (D42): access first, then subway, then not running, then Low Power Mode.
  @Test func causesAreRankedInTheConfirmedOrder() {
    let denied = explain([riding(400), event(600, .authorizationChanged, "status=denied")])
    #expect(denied == .init(reason: .permissionChanged, isSubway: false))
    // A subway ride during which the app was killed: the subway is shown (it is the gap's mode),
    // and the cause underneath is kept for when the user says it was no ride.
    let killed = explain([riding(400), event(1150, .terminatedDetected), event(1150, .launch)])
    #expect(killed == .init(reason: .notRunning, isSubway: true))
    let both = explain([event(1150, .launch)], lowPowerBefore: event(-600, .lowPowerModeOn))
    #expect(both.reason == .notRunning)
  }
}
