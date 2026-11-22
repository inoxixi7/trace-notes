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

  /// Parses the `yyyy-MM-dd` form of `description`.
  init?(string: String) {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    self.init(year: parts[0], month: parts[1], day: parts[2])
  }

  /// The instant this date begins in `timeZone`.
  func start(in timeZone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    // A valid year/month/day always resolves (days that skip midnight start at the first
    // existing instant).
    return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
  }

  /// The following calendar date.
  var next: LocalDay {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    return LocalDay(start.addingTimeInterval(36 * 3600), in: .gmt)
  }

  /// The preceding calendar date.
  var previous: LocalDay {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    return LocalDay(start.addingTimeInterval(-12 * 3600), in: .gmt)
  }

  /// Gregorian year, month and day, for calendar views.
  var dateComponents: DateComponents {
    DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day)
  }

  init?(_ components: DateComponents) {
    guard let year = components.year, let month = components.month, let day = components.day else { return nil }
    self.init(year: year, month: month, day: day)
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
