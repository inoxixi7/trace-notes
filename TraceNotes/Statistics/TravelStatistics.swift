import Foundation

/// The overview's statistics (D50): distance in all and by transport mode, countries and regions,
/// recorded days, and the hours of the day spent on the move. Computed from the derived layer for
/// all records or one year.
nonisolated struct TravelStatistics: Equatable, Sendable {
  /// What the statistics are computed from, read in one transaction (`AppDatabase`).
  struct Input: Equatable, Sendable {
    /// Every stay and move, and every gap travelled by a mode (D42); oldest first.
    var segments: [Segment]
    /// The region code of each place that has one.
    var countryOfPlace: [Int64: String]
    /// The straight line across each travelled gap, by segment ID: from the last point before it
    /// to the first after it.
    var gapDistances: [Int64: Double]
    /// Places whose region is not looked up yet, so the country count may still grow.
    var placesAwaitingCountry: Int

    /// The years with a stay or a move, newest first.
    var years: [Int] {
      Set(segments.filter { $0.kind != .gap }.map(\.localDay.year)).sorted(by: >)
    }
  }

  struct ModeDistance: Equatable, Sendable {
    var mode: TransportMode
    var metres: Double
  }

  /// Metres moved, plus the straight line across gaps travelled by a mode (D50 ④), plus Fog of
  /// World's estimate for all records (D54 ⑤).
  var distance: Double
  /// Fog of World's estimated distance (D54 ⑤): counted for all records only, as it has no times.
  var fogOfWorldDistance: Double?
  /// The same, by mode, longest first; moves with no mode count as `.unknown`.
  var distanceByMode: [ModeDistance]
  /// Region codes in the order they were first visited.
  var countries: [String]
  var recordedDays: Int
  var firstDay: LocalDay?
  /// Minutes on the move in each local hour of the day, 0–23, in each segment's own time zone.
  var minutesByHour: [Double]
  var placesAwaitingCountry: Int

  static let hoursPerDay = 24

  /// The statistics of one year (by local day, F8), or of all records when `year` is nil.
  /// `fogOfWorld` is the estimated length of Fog of World's explored areas, if imported.
  init(_ input: Input, year: Int?, fogOfWorld: Double? = nil) {
    let segments = input.segments.filter { year == nil || $0.localDay.year == year }
    var byMode: [TransportMode: Double] = [:]
    var minutesByHour = Array(repeating: 0.0, count: Self.hoursPerDay)
    var firstVisit: [String: Date] = [:]
    var days = Set<LocalDay>()
    for segment in segments {
      switch segment.kind {
      case .stay:
        days.insert(segment.localDay)
        if let code = segment.placeID.flatMap({ input.countryOfPlace[$0] }) {
          firstVisit[code] = min(firstVisit[code] ?? segment.start, segment.start)
        }
      case .move:
        days.insert(segment.localDay)
        byMode[segment.displayedTransportMode ?? .unknown, default: 0] += segment.distance
        Self.addMinutes(of: segment, to: &minutesByHour)
      case .gap:
        guard let mode = segment.gapTravelMode else { continue }
        byMode[mode, default: 0] += segment.id.flatMap { input.gapDistances[$0] } ?? 0
        Self.addMinutes(of: segment, to: &minutesByHour)
      }
    }
    distanceByMode = byMode
      .filter { $0.value > 0 }
      .map { ModeDistance(mode: $0.key, metres: $0.value) }
      .sorted { ($0.metres, $1.mode.rawValue) > ($1.metres, $0.mode.rawValue) }
    fogOfWorldDistance = year == nil ? fogOfWorld.flatMap { $0 > 0 ? $0 : nil } : nil
    distance = distanceByMode.map(\.metres).reduce(0, +) + (fogOfWorldDistance ?? 0)
    countries = firstVisit.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
    recordedDays = days.count
    firstDay = days.min()
    self.minutesByHour = minutesByHour
    placesAwaitingCountry = input.placesAwaitingCountry
  }

  /// Spreads a segment's time over the local hours it covers.
  private static func addMinutes(of segment: Segment, to minutesByHour: inout [Double]) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: segment.timeZoneID) ?? .gmt
    var instant = segment.start
    while instant < segment.end {
      let hour = calendar.component(.hour, from: instant)
      let nextHour = calendar.nextDate(
        after: instant, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) ?? segment.end
      let until = min(nextHour, segment.end)
      minutesByHour[hour] += until.timeIntervalSince(instant) / 60
      instant = until
    }
  }
}
