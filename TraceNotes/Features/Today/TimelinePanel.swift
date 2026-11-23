import SwiftUI

/// Today's timeline (F8, VS2): stays, moves and gaps in time order, moves with their transport
/// mode (F4, VS4), stays with their place (F5, VS5) and gaps with their cause or the mode they
/// were travelled by (F6, VS6). Its header is the day bar and a one-line summary of the day, which
/// is all the collapsed panel shows (D48).
struct TimelinePanel: View {
  let day: LocalDay
  let today: LocalDay
  let segments: [Segment]
  let places: [Int64: Place]
  let processingError: String?
  /// False while collapsed to the header, so no row peeks out under it.
  let showsList: Bool
  /// Reports the header's height, which the collapsed detent is made of (D49).
  let onHeaderHeight: (CGFloat) -> Void
  let onChangeDay: (LocalDay) -> Void
  let onOpenCalendar: () -> Void
  let onSelect: (Segment) -> Void
  let onChangeMode: (Segment, TransportMode) -> Void
  let onRenamePlace: (Int64, String?) -> Void
  @State private var renaming: Place?
  @State private var newName = ""
  #if DEBUG
  let onOpenDeveloperMenu: () -> Void
  #endif

  var body: some View {
    VStack(spacing: 0) {
      header
        // Measured so the collapsed panel is exactly the header (D48, D49).
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          onHeaderHeight(height)
        }
      ScrollViewReader { proxy in
        List {
          if let processingError {
            Label { Text("The timeline can’t be updated: \(processingError)") } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
          }
          if segments.isEmpty {
            Text("Stays and trips appear here.")
              .foregroundStyle(.secondary)
          }
          ForEach(segments, id: \.start) { segment in
            HStack(spacing: 8) {
              Button {
                onSelect(segment)
              } label: {
                TimelineRow(segment: segment, place: segment.placeID.flatMap { places[$0] }, showsTimeZone: spansTimeZones)
              }
              .buttonStyle(.plain)
              if segment.kind != .stay {
                ModeMenu(segment: segment) { onChangeMode(segment, $0) }
              } else if segment.kind == .stay, let place = segment.placeID.flatMap({ places[$0] }) {
                Button {
                  newName = place.userName ?? place.displayName ?? ""
                  renaming = place
                } label: {
                  Image(systemName: "pencil")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Rename place"))
              }
            }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .opacity(showsList ? 1 : 0)
        .animation(.default, value: showsList)
        // Rows are in time order (F8); today's newest one is what matters, so show it when the
        // list first fills and whenever a new segment begins.
        .onChange(of: segments.last?.start, initial: true) { _, newest in
          if let newest { proxy.scrollTo(newest, anchor: .bottom) }
        }
      }
      .alert(Text("Rename place"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
        TextField(text: $newName) { Text("Place name") }
        Button { save(newName) } label: { Text("Save") }
        if renaming?.userName != nil {
          Button { save(nil) } label: { Text("Use automatic name") }
        }
        Button(role: .cancel) { renaming = nil } label: { Text("Cancel") }
      } message: {
        Text("The new name is shown for every visit to this place.")
      }
    }
  }

  private var header: some View {
    VStack(spacing: 6) {
      DayBar(day: day, today: today, onChange: onChangeDay, onOpenCalendar: onOpenCalendar)
        .padding(.horizontal, Self.dayBarInset)
        #if DEBUG
        .overlay(alignment: .trailing) {
          Button(action: onOpenDeveloperMenu) {
            Image(systemName: "hammer")
              .frame(width: 44, height: 44)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel(Text(verbatim: "Developer"))
        }
        #endif
      DaySummary(segments: segments)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal)
    .padding(.top, Self.headerTopPadding)
    .padding(.bottom, 8)
  }

  /// Below the sheet's drag indicator.
  private static let headerTopPadding: CGFloat = 18
  /// Side room around the day bar (for the Debug button on the right, kept on both sides).
  private static let dayBarInset: CGFloat = 48
}

/// One line under the day bar: how many stays and how far the moves went (D48). Empty for a day
/// without either; the list says so.
private struct DaySummary: View {
  let segments: [Segment]

  var body: some View {
    let stays = segments.count { $0.kind == .stay }
    let metres = segments.filter { $0.kind == .move }.map(\.distance).reduce(0, +)
    HStack(spacing: 6) {
      if stays > 0 {
        Text("\(stays) stays")
      }
      if stays > 0, metres > 0 {
        Text(verbatim: "·")
      }
      if metres > 0 {
        Text(verbatim: Measurement(value: metres, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
      }
    }
    // Keeps the collapsed panel the same height on an empty day.
    .frame(minHeight: lineHeight)
  }

  @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 18
}

extension TimelinePanel {
  /// A day recorded in more than one time zone labels every row's times with its zone (D43).
  fileprivate var spansTimeZones: Bool {
    Set(segments.map(\.timeZoneID)).count > 1
  }

  fileprivate func save(_ name: String?) {
    if let id = renaming?.id { onRenamePlace(id, name) }
    renaming = nil
  }
}

private struct TimelineRow: View {
  let segment: Segment
  let place: Place?
  let showsTimeZone: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(segment.kind == .gap && segment.gapTravelMode == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        title.font(.body.weight(.semibold))
        timeRange.font(.footnote).foregroundStyle(.secondary)
      }
      Spacer()
      detail
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  private var symbol: String {
    switch segment.kind {
    case .stay: "mappin.circle.fill"
    case .move: (segment.displayedTransportMode ?? .unknown).symbol
    case .gap: segment.gapTravelMode?.symbol ?? (segment.gapReason ?? .unknown).symbol
    }
  }

  private var title: Text {
    switch segment.kind {
    case .stay:
      if let name = place?.displayName {
        Text(verbatim: name)
      } else if place?.status == .pending {
        Text("Looking up place…")
      } else {
        Text("Unknown place")
      }
    case .move: (segment.displayedTransportMode ?? .unknown).name
    case .gap: segment.gapTravelMode?.name ?? (segment.gapReason ?? .unknown).name
    }
  }

  /// F8: times in the zone where the segment was recorded, with the zone's short name when the
  /// day spans zones (D43).
  private var timeRange: some View {
    let zone = TimeZone(identifier: segment.timeZoneID) ?? .current
    let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
    let start = segment.start.formatted(style)
    return HStack(spacing: 4) {
      if isOngoing {
        Text("\(start) – now")
      } else {
        Text(verbatim: "\(start) – \(segment.end.formatted(style))")
      }
      if showsTimeZone {
        Text(verbatim: segment.start.formatted(Date.FormatStyle(timeZone: zone).timeZone(.specificName(.short))))
      }
    }
  }

  /// The newest stay lasts until now; the recorder saves few points while still (D28).
  private var isOngoing: Bool {
    !segment.isComplete && segment.kind == .stay
  }

  private var detail: Text {
    let duration = Duration.seconds(segment.end.timeIntervalSince(segment.start))
      .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    guard segment.kind == .move else { return Text(verbatim: duration) }
    let distance = Measurement(value: segment.distance, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road))
    return Text(verbatim: "\(distance) · \(duration)")
  }
}

/// F4: the user corrects a move's transport mode, or says how a gap was travelled (a car in a
/// tunnel, a subway the sensors missed; D42). The choice is kept by time range, so it survives
/// recomputation (ARCHITECTURE §2.2). For a gap, `unknown` ("None") shows its cause again.
private struct ModeMenu: View {
  let segment: Segment
  let onChange: (TransportMode) -> Void

  var body: some View {
    Menu {
      Picker(selection: Binding(get: { segment.displayedTransportMode ?? .unknown }, set: { onChange($0) })) {
        ForEach(TransportMode.allCases, id: \.self) { mode in
          if segment.kind == .gap, mode == .unknown {
            Label { Text("None") } icon: { Image(systemName: "questionmark.circle") }
          } else {
            Label { mode.name } icon: { Image(systemName: mode.symbol) }
          }
        }
      } label: {
        Text("Transport mode")
      }
    } label: {
      Image(systemName: "chevron.up.chevron.down")
        .font(.footnote.weight(.semibold))
        .frame(width: 32, height: 44)
        .contentShape(.rect)
    }
    .accessibilityLabel(Text("Change transport mode"))
  }
}

extension GapReason {
  var name: Text {
    switch self {
    case .permissionChanged: Text("Location access turned off")
    case .locationOff: Text("Location Services off")
    case .notRunning: Text("Phone off or app not running")
    case .lowPower: Text("Low Power Mode on")
    case .unknown: Text("No record")
    }
  }

  var symbol: String {
    switch self {
    case .permissionChanged: "location.slash"
    case .locationOff: "location.slash.fill"
    case .notRunning: "iphone.slash"
    case .lowPower: "battery.25percent"
    case .unknown: "questionmark.circle"
    }
  }
}

extension TransportMode {
  var name: Text {
    switch self {
    case .walking: Text("Walking")
    case .running: Text("Running")
    case .cycling: Text("Cycling")
    case .car: Text("Car")
    case .train: Text("Train")
    case .subway: Text("Subway (estimated)")
    case .airplane: Text("Plane")
    case .unknown: Text("Moving")
    }
  }

  var symbol: String {
    switch self {
    case .walking: "figure.walk"
    case .running: "figure.run"
    case .cycling: "bicycle"
    case .car: "car.fill"
    case .train: "tram.fill"
    case .subway: "tram.fill.tunnel"
    case .airplane: "airplane"
    case .unknown: "point.bottomleft.forward.to.point.topright.scurvepath"
    }
  }
}
