import SwiftUI
import UIKit

/// F8: the day on screen, with the previous and next day either side; tapping the date opens the
/// month calendar (VS7, D43).
struct DayBar: View {
  let day: LocalDay
  let today: LocalDay
  let onChange: (LocalDay) -> Void
  let onOpenCalendar: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button { onChange(day.previous) } label: {
        Image(systemName: "chevron.left")
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .accessibilityLabel(Text("Previous day"))
      Button(action: onOpenCalendar) {
        DayTitle(day: day, today: today)
          .font(.subheadline.weight(.semibold))
          .frame(minWidth: 120, minHeight: 44)
          .contentShape(.rect)
      }
      .accessibilityHint(Text("Opens the calendar"))
      Button { onChange(day.next) } label: {
        Image(systemName: "chevron.right")
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .disabled(day >= today)
      .accessibilityLabel(Text("Next day"))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .glassEffect(.regular.interactive(), in: .capsule)
  }
}

/// "Today", or the date with its weekday in the user's locale.
struct DayTitle: View {
  let day: LocalDay
  let today: LocalDay

  var body: some View {
    if day == today {
      Text("Today")
    } else {
      // Noon avoids landing on the neighbouring date in zones that skip midnight.
      Text(day.start(in: .current).addingTimeInterval(12 * 3600), format: .dateTime.month().day().weekday())
    }
  }
}

/// The month calendar (F8): days with a stay or a move carry a dot; future days cannot be picked.
struct CalendarSheet: View {
  let day: LocalDay
  let today: LocalDay
  let recordedDays: Set<LocalDay>
  let onPick: (LocalDay) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        MonthCalendar(day: day, today: today, recordedDays: recordedDays) { picked in
          onPick(picked)
          dismiss()
        }
        .padding(.horizontal)
      }
      .navigationTitle(Text("Calendar"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if day != today {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              onPick(today)
              dismiss()
            } label: {
              Text("Today")
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .close) { dismiss() }
        }
      }
    }
  }
}

/// `UICalendarView`, the system month view, which can mark individual days.
private struct MonthCalendar: UIViewRepresentable {
  let day: LocalDay
  let today: LocalDay
  let recordedDays: Set<LocalDay>
  let onPick: (LocalDay) -> Void

  func makeUIView(context: Context) -> UICalendarView {
    let view = UICalendarView()
    view.calendar = Calendar(identifier: .gregorian)
    view.locale = .current
    view.fontDesign = .rounded
    view.delegate = context.coordinator
    let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
    selection.selectedDate = day.dateComponents
    view.selectionBehavior = selection
    view.visibleDateComponents = day.dateComponents
    view.setContentHuggingPriority(.required, for: .vertical)
    return view
  }

  func updateUIView(_ view: UICalendarView, context: Context) {
    let previous = context.coordinator.recordedDays
    context.coordinator.parent = self
    // Up to the last instant of today; future days have nothing to show.
    view.availableDateRange = DateInterval(start: .distantPast, end: today.next.start(in: .current).addingTimeInterval(-1))
    let changed = previous.symmetricDifference(recordedDays).map(\.dateComponents)
    if !changed.isEmpty { view.reloadDecorations(forDateComponents: changed, animated: false) }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
    var parent: MonthCalendar
    var recordedDays: Set<LocalDay> { parent.recordedDays }

    init(parent: MonthCalendar) {
      self.parent = parent
    }

    func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
      guard let day = LocalDay(dateComponents), parent.recordedDays.contains(day) else { return nil }
      return .default(color: .tintColor, size: .medium)
    }

    func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
      guard let picked = dateComponents.flatMap(LocalDay.init) else { return }
      parent.onPick(picked)
    }
  }
}
