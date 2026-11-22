import GRDB
import SwiftUI
import UIKit
import os

/// The main screen (F8): a day's map and timeline panel, with the recording status. It opens on
/// today; the day bar and the calendar show any other day (VS7, D43).
struct TodayView: View {
  let database: AppDatabase
  let engine: RecordingEngine
  @Environment(\.scenePhase) private var scenePhase
  @State private var day = LocalDay(.now, in: .current)
  @State private var today = LocalDay(.now, in: .current)
  @State private var recordedDays: Set<LocalDay> = []
  @State private var showsCalendar = false
  /// When the app last left the screen, to come back to today after a long absence (D43).
  @State private var backgroundedAt: Date?
  @State private var points: [RawPoint] = []
  @State private var segments: [Segment] = []
  @State private var renderCache: [Int64: [[RenderCache.Coordinate]]] = [:]
  @State private var places: [Int64: Place] = [:]
  @State private var hasLoaded = false
  @State private var loadError: String?
  @State private var processingError: String?
  @State private var focus: MapFocus?
  @State private var panelDetent = Self.collapsed
  #if DEBUG
  @State private var showsDeveloperMenu = false
  #endif

  /// Panel heights: a peek showing the first rows, a third of the screen, and full height.
  private static let collapsed = PresentationDetent.height(160)
  private static let half = PresentationDetent.fraction(0.4)
  /// Side margin of the top messages: the 44 pt corner button plus spacing on each side.
  private static let cornerButtonRoom: CGFloat = 16 + 44 + 8
  /// Away at least this long, the app opens on today again, as on a fresh launch (D43).
  private static let returnToTodayAfter: TimeInterval = 3600

  var body: some View {
    GeometryReader { geometry in
      TodayMapView(
        day: day, segments: segments, points: points, renderCache: renderCache, focus: focus,
        bottomInset: panelHeight(in: geometry.size.height))
        .ignoresSafeArea()
    }
    .ignoresSafeArea()
    .overlay(alignment: .top) {
      VStack(spacing: 8) {
        StatusCapsule(status: RecordingStatus(engine: engine), motionDenied: RecordingStatus.motionDenied(engine))
        DayBar(day: day, today: today, onChange: show) { showsCalendar = true }
        if let loadError {
          MessageCard(title: Text("The track can’t be shown"), detail: Text(verbatim: loadError))
        } else if hasLoaded, points.isEmpty {
          if day == today {
            MessageCard(title: Text("Nothing recorded today yet"), detail: Text("Your track appears here as you move."))
          } else {
            MessageCard(title: Text("Nothing recorded on this day"), detail: Text("Pick another day in the calendar."))
          }
        }
      }
      // Room for the appearance button on the right, kept on both sides so the capsule stays centred.
      .padding(.horizontal, Self.cornerButtonRoom)
    }
    .overlay(alignment: .topTrailing) {
      AppearanceButton()
        .padding(.trailing)
    }
    .sheet(isPresented: .constant(true)) {
      timelinePanel
        .presentationDetents([Self.collapsed, Self.half, .large], selection: $panelDetent)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.half))
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
    .task(id: day) {
      await observe(day)
    }
    .task(id: ProcessingKey(day: day, isActive: scenePhase == .active)) {
      // The derived layer is kept current only while the app is on screen; when it comes back,
      // the processor catches up from the database (ARCHITECTURE §5.2). Restarting on a new day
      // also cuts an ongoing stay at midnight.
      guard scenePhase == .active else { return }
      await runProcessor()
    }
    .task {
      // Today changes at local midnight and when the time zone changes; a screen showing today
      // follows it, one showing another day stays there (D43).
      for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
        let wasShowingToday = day == today
        today = LocalDay(.now, in: .current)
        if wasShowingToday { show(today) }
      }
    }
    .task {
      await observeRecordedDays()
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background:
        backgroundedAt = .now
      case .active:
        today = LocalDay(.now, in: .current)
        if let backgroundedAt, Date.now.timeIntervalSince(backgroundedAt) >= Self.returnToTodayAfter { show(today) }
        backgroundedAt = nil
      default:
        break
      }
    }
  }

  /// Switches the screen to another day; nothing from the previous day stays on screen.
  private func show(_ newDay: LocalDay) {
    guard newDay != day, newDay <= today else { return }
    points = []
    segments = []
    renderCache = [:]
    places = [:]
    hasLoaded = false
    loadError = nil
    focus = nil
    day = newDay
  }

  private var timelinePanel: some View {
    #if DEBUG
    TimelinePanel(
      segments: segments, places: places, processingError: processingError, onSelect: select, onChangeMode: changeMode,
      onRenamePlace: renamePlace
    ) {
      showsDeveloperMenu = true
    }
    .sheet(isPresented: $showsDeveloperMenu) {
      DeveloperMenu()
    }
    .sheet(isPresented: $showsCalendar) { calendar }
    #else
    TimelinePanel(
      segments: segments, places: places, processingError: processingError, onSelect: select, onChangeMode: changeMode,
      onRenamePlace: renamePlace)
    .sheet(isPresented: $showsCalendar) { calendar }
    #endif
  }

  /// Presented from the panel: the screen already presents the panel as its sheet.
  private var calendar: some View {
    CalendarSheet(day: day, today: today, recordedDays: recordedDays, onPick: show)
      .presentationDetents([.large])
  }

  private func observeRecordedDays() async {
    do {
      for try await days in database.observeRecordedDays() {
        recordedDays = days
      }
    } catch is CancellationError {
      // The view went away.
    } catch {
      AppLog.processing.error("reading recorded days failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }

  private struct ProcessingKey: Equatable {
    var day: LocalDay
    var isActive: Bool
  }

  private func panelHeight(in height: CGFloat) -> CGFloat {
    switch panelDetent {
    case Self.collapsed: 160
    case Self.half: height * 0.4
    default: height * 0.4  // full height covers the map; focusing collapses it to half first
    }
  }

  /// F8: picking a row focuses the map on it.
  private func select(_ segment: Segment) {
    guard let target = MapFocus.of(segment, in: points) else { return }
    if panelDetent == .large { panelDetent = Self.half }
    focus = target
  }

  /// F4: the user's correction, saved in the modification layer.
  private func changeMode(_ segment: Segment, to mode: TransportMode) {
    Task {
      do {
        try await database.setTransportMode(mode, for: segment)
      } catch {
        AppLog.processing.error("saving transport mode failed: \(error.localizedDescription, privacy: .public)")
        processingError = error.localizedDescription
      }
    }
  }

  /// F5: the user's name for a place, shown on every visit (D37); blank restores the looked-up name.
  private func renamePlace(_ placeID: Int64, to name: String?) {
    Task {
      do {
        try await database.renamePlace(id: placeID, to: name)
      } catch {
        AppLog.processing.error("renaming a place failed: \(error.localizedDescription, privacy: .public)")
        processingError = error.localizedDescription
      }
    }
  }

  private func observe(_ day: LocalDay) async {
    await withTaskGroup { group in
      group.addTask { await observePoints(on: day) }
      group.addTask { await observeSegments(on: day) }
      group.addTask { await observeRenderCache(on: day) }
      group.addTask { await observePlaces(on: day) }
    }
  }

  private func observePoints(on day: LocalDay) async {
    do {
      for try await dayPoints in database.observePoints(on: day) {
        points = dayPoints
        hasLoaded = true
        loadError = nil
      }
    } catch is CancellationError {
      // The day changed or the view went away; the next task observes again.
    } catch {
      loadError = error.localizedDescription
    }
  }

  private func observeSegments(on day: LocalDay) async {
    do {
      for try await daySegments in database.observeSegments(on: day) {
        segments = daySegments
      }
    } catch is CancellationError {
      // As above.
    } catch {
      processingError = error.localizedDescription
    }
  }

  private func observeRenderCache(on day: LocalDay) async {
    do {
      for try await cache in database.observeRenderCache(on: day) {
        renderCache = cache
      }
    } catch is CancellationError {
      // As above.
    } catch {
      processingError = error.localizedDescription
    }
  }

  private func observePlaces(on day: LocalDay) async {
    do {
      for try await dayPlaces in database.observePlaces(on: day) {
        places = dayPlaces
      }
    } catch is CancellationError {
      // As above.
    } catch {
      processingError = error.localizedDescription
    }
  }

  private func runProcessor() async {
    await withTaskGroup { group in
      group.addTask { await runTrackProcessor() }
      group.addTask { await runPlaceResolver() }
    }
  }

  /// Pipeline step ⑤: place names are looked up while the app is on screen, like the segments.
  private func runPlaceResolver() async {
    do {
      try await PlaceResolver(database: database).run()
    } catch is CancellationError {
      // As for the processor.
    } catch {
      AppLog.processing.error("place lookup stopped: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }

  private func runTrackProcessor() async {
    do {
      try await TrackProcessor(database: database).run()
    } catch is CancellationError {
      // Left the foreground or the day changed; the next run continues from the database.
    } catch {
      AppLog.processing.error("processing failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }
}

private struct StatusCapsule: View {
  let status: RecordingStatus
  let motionDenied: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label { title } icon: { Image(systemName: symbol) }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
      if let detail {
        detail
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if motionDenied, status == .recording {
        Text("Motion & Fitness is off, so transport is judged by speed only.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if status.needsSettings {
        Button("Open Settings", action: openSettings)
          .font(.footnote.weight(.semibold))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
  }

  private var title: Text {
    switch status {
    case .recording: Text("Recording")
    case .waitingForPermission: Text("Waiting for location access")
    case .backgroundUnavailable: Text("Can’t record in the background")
    case .notRecording: Text("Not recording")
    case .locationServicesOff: Text("Location Services are off")
    // Debug builds only; not localized.
    case .yieldingToSpike: Text(verbatim: "Paused: the S1 spike recorder is running")
    }
  }

  private var detail: Text? {
    switch status {
    case .recording, .waitingForPermission, .yieldingToSpike: nil
    case .backgroundUnavailable: Text("Location access is set to “While Using the App”. Choose “Always” to keep recording when the app is closed.")
    case .notRecording: Text("Location access is off for Trace Notes. Your saved history is still here.")
    case .locationServicesOff: Text("Turn on Location Services in Settings to record.")
    }
  }

  private var symbol: String {
    switch status {
    case .recording: "record.circle"
    case .waitingForPermission: "location"
    case .backgroundUnavailable, .notRecording, .locationServicesOff: "location.slash"
    case .yieldingToSpike: "pause.circle"
    }
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}

private struct MessageCard: View {
  let title: Text
  let detail: Text

  var body: some View {
    VStack(spacing: 4) {
      title.font(.headline)
      detail.font(.footnote).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .padding()
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
  }
}
