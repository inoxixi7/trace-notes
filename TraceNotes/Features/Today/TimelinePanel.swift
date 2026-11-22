import SwiftUI

/// Today's timeline (F8, VS2): stays, moves and gaps in time order. Place names (VS5),
/// transport modes (VS4) and gap causes (VS6) come later.
struct TimelinePanel: View {
  let segments: [Segment]
  let processingError: String?
  let onSelect: (Segment) -> Void
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
            Button {
              onSelect(segment)
            } label: {
              TimelineRow(segment: segment)
            }
            .buttonStyle(.plain)
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

private struct TimelineRow: View {
  let segment: Segment

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
    case .move: "point.bottomleft.forward.to.point.topright.scurvepath"
    case .gap: "questionmark.circle"
    }
  }

  private var title: Text {
    switch segment.kind {
    case .stay: Text("Stay")
    case .move: Text("Moving")
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
