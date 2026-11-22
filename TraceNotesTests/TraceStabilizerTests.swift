import CoreLocation
import XCTest


/// The legacy stabilizer tests (LEGACY_INVENTORY §3.4), adapted to the one-pass API (D34 ①). The
/// three live-vs-batch equivalence tests and the algorithm-version test went with the live API.
final class TraceStabilizerTests: XCTestCase {
  func testStationaryGPSCloudFreezesAtAnchorWithoutConfirmedDistance() {
    let points = [
      location(latitude: 35.00000, longitude: 135.00000, at: 0, accuracy: 30),
      location(latitude: 35.00015, longitude: 135.00016, at: 5, accuracy: 30),
      location(latitude: 34.99982, longitude: 134.99990, at: 10, accuracy: 30),
      location(latitude: 35.00018, longitude: 134.99988, at: 15, accuracy: 30),
      location(latitude: 34.99990, longitude: 135.00020, at: 20, accuracy: 30),
      location(latitude: 35.00004, longitude: 134.99984, at: 25, accuracy: 30),
      location(latitude: 35.00001, longitude: 135.00005, at: 30, accuracy: 30),
    ]

    let result = replay(points)

    XCTAssertEqual(result.state, .stationary)
    XCTAssertLessThan(result.confirmedDistanceMeters, 1)
    XCTAssertTrue(result.confirmedCoordinates.isEmpty)
    XCTAssertTrue(result.provisionalCoordinates.isEmpty)
    XCTAssertNotNil(result.stationaryAnchor)
  }

  func testStraightWalkWithLateralNoiseConfirmsForwardRoute() {
    let points = (0..<10).map { index in
      location(
        latitude: 35 + (index.isMultiple(of: 2) ? 0.00010 : -0.00010),
        longitude: 135 + Double(index) * 0.00022,
        at: Double(index * 5),
        accuracy: 8,
        speed: 3.5,
        course: 90
      )
    }

    let result = replay(points)
    let confirmed = result.confirmedCoordinates

    XCTAssertEqual(result.state, .moving)
    XCTAssertGreaterThan(result.confirmedDistanceMeters, 120)
    XCTAssertTrue(result.provisionalCoordinates.isEmpty)
    XCTAssertGreaterThanOrEqual(confirmed.count, 4)
    XCTAssertLessThan(abs(confirmed.last!.latitude - 35), 0.00015)
  }

  func testNinetyDegreeTurnRemainsAVisibleCorner() {
    let east = (0..<4).map { index in
      location(
        latitude: 35,
        longitude: 135 + Double(index) * 0.00035,
        at: Double(index * 5),
        accuracy: 8,
        speed: 4,
        course: 90
      )
    }
    let north = (1...4).map { index in
      location(
        latitude: 35 + Double(index) * 0.00035,
        longitude: 135 + 3 * 0.00035,
        at: Double((index + 3) * 5),
        accuracy: 8,
        speed: 4,
        course: 0
      )
    }

    let result = replay(east + north)
    let confirmed = result.confirmedCoordinates
    let turnIndex = confirmed.indices.dropFirst().dropLast().first { index in
      let incoming = bearing(from: confirmed[index - 1], to: confirmed[index])
      let outgoing = bearing(from: confirmed[index], to: confirmed[index + 1])
      return angleDifference(incoming, outgoing) > 45
    }

    XCTAssertNotNil(turnIndex)
  }

  func testStationaryStateRequiresHysteresisBeforeMovementResumes() {
    let initial = (0..<4).map { index in
      location(
        longitude: 135 + Double(index) * 0.00030,
        at: Double(index * 5),
        speed: 3,
        course: 90
      )
    }
    let cloud = [
      location(latitude: 35.00005, longitude: 135.00092, at: 20, accuracy: 25),
      location(latitude: 34.99990, longitude: 135.00108, at: 25, accuracy: 25),
      location(latitude: 35.00012, longitude: 135.00090, at: 30, accuracy: 25),
      location(latitude: 34.99994, longitude: 135.00110, at: 35, accuracy: 25),
      location(latitude: 35.00002, longitude: 135.00096, at: 40, accuracy: 25),
    ]
    let resume = (1...4).map { index in
      location(
        latitude: 35 + Double(index) * 0.00028,
        longitude: 135.0010,
        at: Double(40 + index * 5),
        speed: 3,
        course: 0
      )
    }

    let transitions = transitions(for: initial + cloud + resume)
    let states = transitions.map(\.state)

    XCTAssertTrue(states.contains(.stationary))
    XCTAssertEqual(states.last, .moving)
    XCTAssertNil(transitions.last!.stationaryAnchor)
    XCTAssertLessThan(
      transitions.last!.confirmedDistanceMeters,
      300
    )
  }

  func testDegradedAccuracyTailIsPromotedAfterCoherentMovement() {
    let points = [
      location(longitude: 135.0000, at: 0, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0003, at: 5, accuracy: 12, speed: 3, course: 90),
      location(longitude: 135.0006, at: 10, accuracy: 45, speed: 3, course: 90),
      location(longitude: 135.0009, at: 15, accuracy: 38, speed: 3, course: 90),
      location(longitude: 135.0012, at: 20, accuracy: 10, speed: 3, course: 90),
      location(longitude: 135.0015, at: 25, accuracy: 10, speed: 3, course: 90),
    ]

    let result = replay(points)

    XCTAssertEqual(result.state, .moving)
    XCTAssertGreaterThan(result.confirmedDistanceMeters, 100)
    XCTAssertTrue(result.provisionalCoordinates.isEmpty)
  }

  func testIsolatedOutAndBackJumpNeverEntersConfirmedRoute() {
    let points = [
      location(longitude: 135, at: 0, accuracy: 8),
      location(longitude: 135.0008, at: 10, accuracy: 45),
      location(longitude: 135, at: 20, accuracy: 8),
      location(longitude: 135.00001, at: 30, accuracy: 8),
    ]

    let result = replay(points)

    XCTAssertLessThan(result.confirmedDistanceMeters, 5)
    XCTAssertTrue(result.confirmedCoordinates.isEmpty)
    XCTAssertTrue(
      result.points.contains { $0.decision == .suppressed }
    )
  }

  func testConfirmedRouteCanContinueThroughARealUTurn() {
    let points = [
      location(longitude: 135.0000, at: 0, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0003, at: 5, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0000, at: 10, accuracy: 8, speed: 3, course: 270),
      location(longitude: 134.9997, at: 15, accuracy: 8, speed: 3, course: 270),
      location(longitude: 134.9994, at: 20, accuracy: 8, speed: 3, course: 270),
    ]

    let result = replay(points)
    let confirmed = result.confirmedCoordinates

    XCTAssertEqual(result.state, .moving)
    XCTAssertGreaterThanOrEqual(confirmed.count, 4)
    XCTAssertGreaterThan(result.confirmedDistanceMeters, 60)
  }

  func testGenuineFastTransitMovementIsNotClassifiedAsJitter() {
    let points = (0..<6).map { index in
      location(
        longitude: 135 + Double(index) * 0.0010,
        at: Double(index * 10),
        accuracy: 25,
        speed: 8,
        course: 90
      )
    }

    let result = replay(points)

    XCTAssertEqual(result.state, .moving)
    XCTAssertGreaterThan(result.confirmedDistanceMeters, 350)
    XCTAssertTrue(result.provisionalCoordinates.isEmpty)
  }

  func testStationaryAnchorWeightsAccurateCandidateMoreStrongly() {
    let points = [
      location(latitude: 35, longitude: 135, at: 0, accuracy: 5),
      location(latitude: 35.00020, longitude: 135.00020, at: 5, accuracy: 40),
      location(latitude: 34.99980, longitude: 134.99985, at: 10, accuracy: 40),
      location(latitude: 35.00015, longitude: 134.99980, at: 15, accuracy: 40),
      location(latitude: 34.99990, longitude: 135.00018, at: 20, accuracy: 40),
      location(latitude: 35.00005, longitude: 135.00005, at: 25, accuracy: 5),
    ]

    let result = replay(points)
    let anchor = try! XCTUnwrap(result.stationaryAnchor)

    XCTAssertLessThan(distance(anchor, TraceCoordinate(latitude: 35, longitude: 135)), 12)
  }

  func testReplayIsDeterministic() {
    let points: [RawPoint] = (0..<8).map { index in
      let latitude = 35 + Double(index % 2) * 0.00005
      let longitude = 135 + Double(index) * 0.0002
      let timestamp = Double(index * 5)
      let accuracy = index == 4 ? 35.0 : 8.0
      return location(
        latitude: latitude,
        longitude: longitude,
        at: timestamp,
        accuracy: accuracy,
        speed: 3,
        course: 90
      )
    }

    let first = replay(points)
    let second = replay(points)
    XCTAssertEqual(first.state, second.state)
    XCTAssertEqual(first.points, second.points)
    XCTAssertEqual(first.confirmedCoordinates, second.confirmedCoordinates)
    XCTAssertEqual(first.provisionalCoordinates, second.provisionalCoordinates)
    XCTAssertEqual(first.stationaryAnchor, second.stationaryAnchor)
    // CLLocation's geodesic implementation can vary by a few micrometres
    // between simulator runs; that is below GPS and display precision.
    XCTAssertEqual(
      first.confirmedDistanceMeters,
      second.confirmedDistanceMeters,
      accuracy: 0.01
    )
    XCTAssertEqual(first.rawDistanceMeters, second.rawDistanceMeters, accuracy: 0.01)
  }

  func testMultiPointExcursionReturningToConfirmedCorridorIsSuppressed() {
    let points = [
      location(longitude: 135.0000, at: 0, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0003, at: 5, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0006, at: 10, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0009, at: 15, accuracy: 8, speed: 3, course: 90),
      // A short cloud with missing course/speed evidence leaves the corridor,
      // loops, and returns before the real route continues.
      location(latitude: 35.00035, longitude: 135.00120, at: 20, accuracy: 8),
      location(latitude: 35.00052, longitude: 135.00145, at: 25, accuracy: 8),
      location(latitude: 35.00034, longitude: 135.00125, at: 30, accuracy: 8),
      location(latitude: 35.00002, longitude: 135.00092, at: 35, accuracy: 8),
      location(longitude: 135.00120, at: 40, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.00150, at: 45, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.00180, at: 50, accuracy: 8, speed: 3, course: 90),
    ]

    let allTransitions = transitions(for: points)
    let result = allTransitions.last!

    XCTAssertLessThan(result.confirmedDistanceMeters, 260)
    XCTAssertTrue(result.provisionalCoordinates.isEmpty)
    XCTAssertTrue(
      allTransitions.contains { transition in
        transition.points.contains { $0.decision == .suppressed }
      }
    )
    XCTAssertGreaterThanOrEqual(result.multiPointExcursionCount, 1)
    XCTAssertGreaterThanOrEqual(result.excursionSuppressedPointCount, 1)
  }

  func testExcursionDetectorSuppressesWeakMultiPointReturn() {
    let points = [
      location(longitude: 135.0000, at: 0, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0003, at: 5, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0006, at: 10, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0009, at: 15, accuracy: 8, speed: 3, course: 90),
      location(latitude: 35.00035, longitude: 135.00120, at: 20, accuracy: 8),
      location(latitude: 35.00052, longitude: 135.00145, at: 25, accuracy: 8),
      location(latitude: 35.00034, longitude: 135.00125, at: 30, accuracy: 8),
      location(latitude: 35.00002, longitude: 135.00092, at: 35, accuracy: 8),
      location(longitude: 135.00120, at: 40, accuracy: 8, speed: 3, course: 90),
    ]
    let analysis = TraceExcursionDetector.analyze(
      locations: points,
      decisions: Array(repeating: .confirmed, count: points.count),
      configuration: .default
    )

    XCTAssertTrue(analysis.detected)
    XCTAssertEqual(analysis.excursionCount, 1)
    XCTAssertGreaterThanOrEqual(analysis.suppressedIndices.count, 3)
    XCTAssertGreaterThan(analysis.maximumLateralDeviationMeters, 20)
  }

  func testShortStopWithTenSecondGPSDriftDoesNotLeaveTriangle() {
    let points = [
      location(longitude: 135.0000, at: 0, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0003, at: 5, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0006, at: 10, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0009, at: 15, accuracy: 8, speed: 3, course: 90),
      location(latitude: 35.00022, longitude: 135.0010, at: 20, accuracy: 32),
      location(latitude: 34.99980, longitude: 135.0011, at: 25, accuracy: 32),
      location(longitude: 135.0012, at: 30, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0015, at: 35, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0018, at: 40, accuracy: 8, speed: 3, course: 90),
    ]

    let result = replay(points)

    XCTAssertLessThan(result.confirmedDistanceMeters, 240)
    XCTAssertTrue(result.provisionalCoordinates.isEmpty)
    XCTAssertTrue(result.points.contains { $0.decision == .suppressed })
  }

  func testWeakAccuracyLateralSZDriftStaysNearForwardTrend() {
    let points = [
      location(longitude: 135.0000, at: 0, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0003, at: 5, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0006, at: 10, accuracy: 8, speed: 3, course: 90),
      location(latitude: 35.00020, longitude: 135.0009, at: 15, accuracy: 38),
      location(latitude: 34.99978, longitude: 135.0012, at: 20, accuracy: 38),
      location(latitude: 35.00022, longitude: 135.0015, at: 25, accuracy: 38),
      location(latitude: 34.99980, longitude: 135.0018, at: 30, accuracy: 38),
      location(longitude: 135.0021, at: 35, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0024, at: 40, accuracy: 8, speed: 3, course: 90),
      location(longitude: 135.0027, at: 45, accuracy: 8, speed: 3, course: 90),
    ]

    let result = replay(points)
    let confirmed = result.confirmedCoordinates

    XCTAssertLessThan(result.confirmedDistanceMeters, 330)
    XCTAssertGreaterThan(result.confirmedDistanceMeters, 180)
    XCTAssertTrue(result.provisionalCoordinates.isEmpty)
    XCTAssertLessThan(confirmed.map(\.latitude).max()! - confirmed.map(\.latitude).min()!, 0.00030)
  }

  func testRealHighAccuracyBlockLoopIsPreserved() {
    let corners = [
      (35.00000, 135.00000),
      (35.00000, 135.00065),
      (35.00045, 135.00065),
      (35.00045, 135.00000),
      (35.00000, 135.00000),
      (35.00000, 135.00065),
    ]
    let points = corners.enumerated().map { index, coordinate in
      location(
        latitude: coordinate.0,
        longitude: coordinate.1,
        at: Double(index * 20),
        accuracy: 6,
        speed: 2.5,
        course: index == 0 ? 90 : nil
      )
    }

    let result = replay(points)

    XCTAssertEqual(result.state, .moving)
    XCTAssertGreaterThan(result.confirmedDistanceMeters, 180)
    XCTAssertGreaterThanOrEqual(result.confirmedCoordinates.count, 5)
  }

  /// D34 ⑤: a pause up to the timeline's 5-minute gap keeps the confirmed route connected; a
  /// longer one splits it, as the timeline does.
  func testGapThresholdFollowsTheTimeline() {
    func walk(pause: TimeInterval) -> StabilizedTrace {
      let before = (0..<6).map { location(longitude: 135 + Double($0) * 0.0003, at: Double($0 * 5), speed: 3, course: 90) }
      let after = (6..<12).map {
        location(longitude: 135 + Double($0) * 0.0003, at: pause + Double($0 * 5), speed: 3, course: 90)
      }
      return replay(before + after)
    }
    let connected = walk(pause: 240)
    let split = walk(pause: 360)
    XCTAssertEqual(connected.confirmedDistanceMeters - split.confirmedDistanceMeters, 27, accuracy: 3)
  }

  private func replay(_ points: [RawPoint]) -> StabilizedTrace {
    TraceStabilizer.stabilize(points, finalize: true)
  }

  /// What the open move looks like after each new point, then once the move is completed: the
  /// processor re-derives the open move on every append (the legacy live callbacks).
  private func transitions(for points: [RawPoint]) -> [StabilizedTrace] {
    points.indices.map { TraceStabilizer.stabilize(Array(points[...$0]), finalize: false) } + [replay(points)]
  }

  private func location(
    latitude: Double = 35,
    longitude: Double,
    at seconds: TimeInterval,
    accuracy: Double = 8,
    speed: Double? = nil,
    course: Double? = nil
  ) -> RawPoint {
    RawPoint(
      id: nil, timestamp: Date(timeIntervalSince1970: seconds), latitude: latitude, longitude: longitude,
      horizontalAccuracy: accuracy, altitude: nil, verticalAccuracy: nil, speed: speed, course: course,
      timeZoneID: "Asia/Tokyo", source: .recorded, importBatchID: nil, flags: [])
  }

  private func distance(_ lhs: TraceCoordinate, _ rhs: TraceCoordinate) -> CLLocationDistance {
    CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
      .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
  }

  private func bearing(from lhs: TraceCoordinate, to rhs: TraceCoordinate) -> Double {
    let lat1 = lhs.latitude * .pi / 180
    let lat2 = rhs.latitude * .pi / 180
    let deltaLongitude = (rhs.longitude - lhs.longitude) * .pi / 180
    let y = sin(deltaLongitude) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
    return atan2(y, x) * 180 / .pi
  }

  private func angleDifference(_ lhs: Double, _ rhs: Double) -> Double {
    abs((lhs - rhs + 180).truncatingRemainder(dividingBy: 360) - 180)
  }
}
