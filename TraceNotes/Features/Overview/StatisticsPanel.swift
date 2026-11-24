import Charts
import SwiftUI

/// The bottom panel in the overview (D48 ④, D50): the year bar and a one-line summary as its
/// header, which is all the collapsed panel shows, and the statistics below it.
struct StatisticsPanel: View {
  /// Nil until the first read.
  let input: TravelStatistics.Input?
  /// Fog of World's estimated distance, when imported (D54 ⑤).
  let fogOfWorldDistance: Double?
  /// Nil for all records.
  @Binding var year: Int?
  /// False while collapsed to the header, so nothing peeks out under it.
  let showsList: Bool
  /// Reports the header's height, which the collapsed detent is made of (D49).
  let onHeaderHeight: (CGFloat) -> Void

  var body: some View {
    let statistics = input.map { TravelStatistics($0, year: year, fogOfWorld: fogOfWorldDistance) }
    VStack(spacing: 0) {
      header(statistics)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          onHeaderHeight(height)
        }
      List {
        if let statistics {
          if statistics.recordedDays == 0, statistics.fogOfWorldDistance == nil {
            Text("Statistics appear here once you’ve moved.")
              .foregroundStyle(.secondary)
          } else {
            content(statistics)
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .opacity(showsList ? 1 : 0)
      .animation(.default, value: showsList)
    }
  }

  private func header(_ statistics: TravelStatistics?) -> some View {
    VStack(spacing: 6) {
      YearBar(years: input?.years ?? [], year: $year)
      HStack(spacing: 6) {
        if let statistics, statistics.distance > 0 {
          Text(verbatim: Self.format(statistics.distance))
        }
        if let statistics, statistics.distance > 0, !statistics.countries.isEmpty {
          Text(verbatim: "·")
        }
        if let statistics, !statistics.countries.isEmpty {
          Text("\(statistics.countries.count) countries and regions")
        }
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      // Keeps the collapsed panel the same height with nothing to show yet.
      .frame(minHeight: lineHeight)
    }
    .padding(.horizontal)
    .padding(.top, Self.headerTopPadding)
    .padding(.bottom, 8)
  }

  @ViewBuilder private func content(_ statistics: TravelStatistics) -> some View {
    Section {
      let longest = max(statistics.distanceByMode.first?.metres ?? 0, statistics.fogOfWorldDistance ?? 0)
      ForEach(statistics.distanceByMode, id: \.mode) { entry in
        DistanceRow(
          title: entry.mode.name, symbol: entry.mode.symbol, distance: Text(verbatim: Self.format(entry.metres)),
          metres: entry.metres, longest: longest)
      }
      if let fog = statistics.fogOfWorldDistance {
        DistanceRow(
          title: Text("Fog of World (estimated)"), symbol: "cloud.fog",
          distance: Text("about \(Self.format(fog))"), metres: fog, longest: longest)
      }
    } header: {
      SectionTitle(title: Text("Distance"), value: Text(verbatim: Self.format(statistics.distance)))
    }
    Section {
      ForEach(statistics.countries, id: \.self) { code in
        Text(verbatim: Self.countryName(code))
      }
      if statistics.placesAwaitingCountry > 0 {
        Text("\(statistics.placesAwaitingCountry) places are still being looked up")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      SectionTitle(title: Text("Countries and Regions"), value: Text(verbatim: "\(statistics.countries.count)"))
    }
    Section {
      if let firstDay = statistics.firstDay {
        Text("Since \(firstDay.start(in: .current).addingTimeInterval(12 * 3600), format: .dateTime.year().month().day())")
          .foregroundStyle(.secondary)
      }
    } header: {
      SectionTitle(title: Text("Recorded Days"), value: Text(verbatim: "\(statistics.recordedDays)"))
    }
    Section {
      HourChart(minutesByHour: statistics.minutesByHour)
    } header: {
      SectionTitle(title: Text("When You’re Out"), value: nil)
    }
  }

  /// Metres as a road distance in the user's units, as in the day's summary.
  static func format(_ metres: Double) -> String {
    Measurement(value: metres, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
  }

  /// The flag and the region's name in the user's language; the code alone if the system has no
  /// name for it.
  static func countryName(_ code: String) -> String {
    let flag = code.uppercased().unicodeScalars
      .compactMap { scalar in ("A"..."Z").contains(Character(scalar)) ? UnicodeScalar(0x1F1A5 + scalar.value) : nil }
      .map(String.init)
      .joined()
    let name = Locale.current.localizedString(forRegionCode: code) ?? code
    return flag.isEmpty ? name : "\(flag) \(name)"
  }

  @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 18
  /// Below the sheet's drag indicator, as in the timeline panel.
  private static let headerTopPadding: CGFloat = 18
}

/// "All Time" or a year, with the next older and newer choice either side; the title opens the
/// list of years.
private struct YearBar: View {
  let years: [Int]
  @Binding var year: Int?

  /// All records first, then the years from newest to oldest.
  private var choices: [Int?] { [nil] + years.map(Optional.some) }

  var body: some View {
    let index = choices.firstIndex(of: year) ?? 0
    HStack(spacing: 0) {
      Button { year = choices[index + 1] } label: {
        Image(systemName: "chevron.left")
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .disabled(index + 1 >= choices.count)
      .accessibilityLabel(Text("Earlier year"))
      Menu {
        Picker(selection: $year) {
          ForEach(choices, id: \.self) { choice in
            title(choice).tag(choice)
          }
        } label: {
          Text("Year")
        }
      } label: {
        title(year)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .frame(minWidth: 120, minHeight: 44)
          .contentShape(.rect)
      }
      .tint(.primary)
      Button { year = choices[index - 1] } label: {
        Image(systemName: "chevron.right")
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .disabled(index == 0)
      .accessibilityLabel(Text("Later year"))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .background(.fill.tertiary, in: .capsule)
  }

  private func title(_ choice: Int?) -> Text {
    choice.map { Text(verbatim: String($0)) } ?? Text("All Time")
  }
}

private struct SectionTitle: View {
  let title: Text
  let value: Text?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      title
      Spacer()
      if let value {
        value.monospacedDigit()
      }
    }
    .font(.headline)
    .foregroundStyle(.primary)
  }
}

/// A mode's (or Fog of World's) icon, name and distance, with a bar against the longest.
private struct DistanceRow: View {
  let title: Text
  let symbol: String
  let distance: Text
  let metres: Double
  let longest: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label { title } icon: { Image(systemName: symbol) }
        Spacer()
        distance
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Capsule()
        .fill(.quaternary)
        .frame(height: Self.barHeight)
        .overlay(alignment: .leading) {
          GeometryReader { proxy in
            Capsule()
              .fill(.tint)
              .frame(width: longest > 0 ? max(Self.barHeight, proxy.size.width * metres / longest) : 0)
          }
        }
    }
    .accessibilityElement(children: .combine)
  }

  private static let barHeight: CGFloat = 4
}

/// Minutes on the move in each hour of the day (D50), one bar per hour.
private struct HourChart: View {
  let minutesByHour: [Double]

  var body: some View {
    Chart(minutesByHour.indices, id: \.self) { hour in
      BarMark(x: .value(Text("Hour"), hour), y: .value(Text("Minutes"), minutesByHour[hour]))
        .foregroundStyle(.tint)
    }
    .chartXScale(domain: -0.5...Double(TravelStatistics.hoursPerDay) - 0.5)
    .chartXAxis {
      AxisMarks(values: Self.labelledHours) { value in
        AxisGridLine()
        AxisValueLabel {
          if let hour = value.as(Int.self) {
            Text(verbatim: "\(hour):00")
          }
        }
      }
    }
    .chartYAxis(.hidden)
    .frame(height: Self.height)
    .accessibilityLabel(Text("Minutes on the move by hour of the day"))
  }

  private static let labelledHours = [0, 6, 12, 18]
  private static let height: CGFloat = 120
}
