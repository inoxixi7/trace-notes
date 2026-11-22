import Foundation
import GRDB
import Testing

/// VS7 · days for the calendar (F8, D43): stepping across month and year ends, and which days
/// count as recorded.
struct CalendarTests {
  let helper = SegmenterTests()

  @Test func steppingDaysCrossesMonthsYearsAndLeapDays() {
    #expect(LocalDay(year: 2026, month: 1, day: 1).previous == LocalDay(year: 2025, month: 12, day: 31))
    #expect(LocalDay(year: 2028, month: 3, day: 1).previous == LocalDay(year: 2028, month: 2, day: 29))
    #expect(LocalDay(year: 2026, month: 12, day: 31).next == LocalDay(year: 2027, month: 1, day: 1))
    let day = LocalDay(year: 2026, month: 11, day: 22)
    #expect(day.next.previous == day)
    #expect(LocalDay(day.dateComponents) == day)
  }

  /// A trip from Tokyo (UTC+9) to Los Angeles (UTC−8): each day is marked under the local date
  /// where it was recorded, so the later walk files under the earlier date.
  @Test func recordedDaysFollowEachSegmentsLocalDate() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "CalendarTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try AppDatabase(url: directory.appending(path: "test.sqlite"))
    // 09:00 Tokyo on the 22nd is 00:00 UTC; four hours later it is 20:00 on the 21st in Los Angeles.
    let tokyo = helper.walk(from: 0, for: 600)
    let losAngeles = helper.walk(from: 4 * 3600, for: 600).map { point -> RawPoint in
      var point = point
      point.timeZoneID = "America/Los_Angeles"
      return point
    }
    try await database.append(points: tokyo + losAngeles, events: [])
    try await TrackProcessor(database: database).process(now: losAngeles.last!.timestamp)

    var iterator = database.observeRecordedDays().makeAsyncIterator()
    let days = try #require(try await iterator.next())
    #expect(days == [LocalDay(year: 2026, month: 11, day: 22), LocalDay(year: 2026, month: 11, day: 21)])
  }
}
