import SwiftUI

/// Today's timeline (F8, VS2): stays, moves and gaps in time order, moves with their transport
/// mode (F4, VS4) and stays with their place (F5, VS5). Gap causes (VS6) come later.
struct TimelinePanel: View {
  let segments: [Segment]
  let places: [Int64: Place]
  let processingError: String?
  let onSelect: (Segment) -> Void
  let onChangeMode: (Segment, TransportMode) -> Void
  let onRenamePlace: (Int64, String?) -> Void
  @State private var renaming: Place?
  @State private var newName = ""
  #if DEBUG
  let onOpenDeveloperMenu: () -> Void
  #endif

  var body: some View {
    NavigationStack {
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
                TimelineRow(segment: segment, place: segment.placeID.flatMap { places[$0] })
              }
              .buttonStyle(.plain)
              if segment.kind == .move {
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
      .navigationTitle(Text("Timeline"))
      .navigationBarTitleDisplayMode(.inline)
      #if DEBUG
      .toolbar {
        Button(action: onOpenDeveloperMenu) {
          Image(systemName: "hammer")
        }
        .accessibilityLabel(Text(verbatim: "Developer"))
      }
      #endif
    }
  }
}

extension TimelinePanel {
  fileprivate func save(_ name: String?) {
    if let id = renaming?.id { onRenamePlace(id, name) }
    renaming = nil
  }
}

private struct TimelineRow: View {
  let segment: Segment
  let place: Place?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(segment.kind == .gap ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
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
    case .gap: "questionmark.circle"
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
    case .gap: Text("No record")
    }
  }

  /// F8: times in the zone where the segment was recorded.
  private var timeRange: Text {
    let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: segment.timeZoneID) ?? .current)
    let start = segment.start.formatted(style)
    if isOngoing {
      return Text("\(start) – now")
    }
    return Text(verbatim: "\(start) – \(segment.end.formatted(style))")
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

/// F4: the user corrects a move's transport mode. The choice is kept by time range, so it survives
/// recomputation (ARCHITECTURE §2.2).
private struct ModeMenu: View {
  let segment: Segment
  let onChange: (TransportMode) -> Void

  var body: some View {
    Menu {
      Picker(selection: Binding(get: { segment.displayedTransportMode ?? .unknown }, set: { onChange($0) })) {
        ForEach(TransportMode.allCases, id: \.self) { mode in
          Label { mode.name } icon: { Image(systemName: mode.symbol) }
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
