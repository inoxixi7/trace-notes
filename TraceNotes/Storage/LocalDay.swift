import Foundation

/// A calendar date in the time zone where a point was recorded (F8: a day's track is split by
/// each point's own local date, so a trip across time zones files points under the local date).
nonisolated struct LocalDay: Hashable, Comparable, Sendable, CustomStringConvertible {
  let year: Int
  let month: Int
  let day: Int

  init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  /// The local date of `date` in `timeZone`.
  init(_ date: Date, in timeZone: TimeZone) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    // Gregorian components of a real Date are always present.
    self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
  }

  /// The local date of a point recorded at `date` in the IANA zone `timeZoneID`.
  ///
  /// Every stored ID comes from `TimeZone.current.identifier`, so it resolves. An ID this OS does
  /// not know (for example an imported file from a newer OS) falls back to UTC, which can file a
  /// point under the neighbouring day but never drops it.
  init(_ date: Date, timeZoneID: String) {
    self.init(date, in: TimeZone(identifier: timeZoneID) ?? .gmt)
  }

  /// UTC instants that can belong to this local date in *some* time zone: from the day's start
  /// at UTC+14 to its end at UTC−12. Used to pre-select points by timestamp before filtering by
  /// each point's own zone.
  var possibleInstants: Range<Date> {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    let start = utc.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    let earliestOffset = 14.0 * 3600
    let latestOffset = 12.0 * 3600
    let dayLength = 24.0 * 3600
    return start.addingTimeInterval(-earliestOffset)..<start.addingTimeInterval(dayLength + latestOffset)
  }

  static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  var description: String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }
}
