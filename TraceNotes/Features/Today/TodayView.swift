import GRDB
import SwiftUI
import UIKit
import os

/// The main screen (F8): a day's map and timeline panel, with the recording status. It opens on
/// today; the day bar and the calendar show any other day (VS7, D43). The overview shows every
/// day's tracks on the map alone, without the day bar and the timeline (D44, D45). The layout
/// follows Apple Maps (D47).
struct TodayView: View {
  let database: AppDatabase
  let engine: RecordingEngine
  @Environment(\.scenePhase) private var scenePhase
  @State private var day = LocalDay(.now, in: .current)
  @State private var today = LocalDay(.now, in: .current)
  @State private var recordedDays: Set<LocalDay> = []
  @State private var showsCalendar = false
  /// The settings screen (D53 ①), presented from the panel like the calendar.
  @State private var showsSettings = false
  /// A .gpx file opened from Files or the share sheet, imported by the settings screen (F9).
  @State private var openedGPX: URL?
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
  @State private var panelStop = PanelStop.collapsed
  /// The panel header's height, once laid out.
  @State private var panelHeaderHeight: CGFloat?
  @State private var showsOverview = false
  /// The bubble beside the status button; it closes by itself (D49).
  @State private var showsStatusBubble = false
  /// The top edge of the timeline panel in window coordinates, while it is shown.
  @State private var panelTop: CGFloat?
  @State private var overviewBounds: GeoBox?
  @State private var hasLoadedOverview = false
  /// The newest viewport the map asked for, and the tracks read for it.
  @State private var overviewRequest: OverviewRequest?
  @State private var overviewTracks: (request: OverviewRequest, tracks: [Int64: [RenderCache.Coordinate]])?
  /// The statistics' source while the overview is on, and the year they cover (nil: all, D50).
  @State private var statisticsInput: TravelStatistics.Input?
  @State private var statisticsYear: Int?
  /// Fog of World's imported layer while the overview is on (D54): whether there is one, the
  /// cells read for the newest viewport, and its estimated distance.
  @State private var fogOfWorld: AppDatabase.FogOfWorldSummary?
  /// Set once the layer's summary has been read, so the overview is framed with it (or without).
  @State private var hasLoadedFogOfWorld = false
  @State private var fogLines: (request: OverviewRequest, lines: [[FogOfWorld.LinePoint]])?
  @State private var fogDistance: Double?
  /// The overview's show / hide switch for Fog of World (D54 ⑧), kept across launches.
  @AppStorage("showsFogOfWorld") private var showsFogOfWorld = true
  #if DEBUG
  @State private var showsDeveloperMenu = false
  #endif

  /// Panel heights: the header, part of the screen, and full height.
  /// The collapsed panel is its header, the day bar and the day's summary (D48), measured so larger
  /// text never clips it (D49); the system adds the bottom safe area under it.
  /// No lower than this: below about 102 pt iOS 26 turns the sheet into a floating card whose
  /// content area is shorter than its detent, and the day bar runs into the drag indicator
  /// (measured in the simulator, D49).
  private static let minimumCollapsedHeight: CGFloat = 104
  private static let halfShare: CGFloat = 0.4
  private static let half = PresentationDetent.fraction(halfShare)
  /// Gap between the bottom controls and the panel (or the screen's safe area in the overview).
  private static let controlsSpacing: CGFloat = 8
  /// The bottom controls fade out while the panel is dragged above its half height: fully shown up
  /// to this far above it (the sheet's own margins), gone after `controlsFadeDistance` more.
  private static let controlsFadeSlack: CGFloat = 24
  private static let controlsFadeDistance: CGFloat = 60
  /// Room kept under the bottom controls until the panel's top is measured, for the Apple Maps logo
  /// and the Legal link, which must stay visible (MapKit gives no API for their size).
  private static let mapAttributionRoom: CGFloat = 32
  /// Away at least this long, the app opens on today again, as on a fresh launch (D43).
  private static let returnToTodayAfter: TimeInterval = 3600
  /// The status bubble closes this long after it opens, or as soon as the map is moved (D49).
  private static let statusBubbleDuration: Duration = .seconds(4)

  var body: some View {
    GeometryReader { geometry in
      TodayMapView(
        day: day, segments: segments, points: points, renderCache: renderCache, focus: focus,
        bottomInset: panelHeight(in: geometry.size.height), overview: overview
      ) { overviewRequest = $0 } onUserMove: {
        hideStatusBubble()
      }
        .ignoresSafeArea()
    }
    .ignoresSafeArea()
    // Laid out like Apple Maps (D47): the day at the top, the overview at the bottom left and the
    // other controls at the bottom right, just above the timeline panel.
    .overlay(alignment: .top) {
      let status = RecordingStatus(engine: engine)
      // The day bar is the timeline panel's handle (D48), so only messages are up here.
      VStack(spacing: 8) {
        // A problem stays in view in full (F1); "Recording" fits in the round button.
        if status.isProblem {
          StatusCard(status: status)
        }
        message
      }
      .padding(.horizontal)
    }
    .overlay {
      GeometryReader { geometry in
        bottomControls(in: geometry)
      }
    }
    // One panel throughout: the day's timeline, or the statistics in the overview (D48 ④, D50).
    .sheet(isPresented: .constant(true)) {
      panelContent
        .sheet(isPresented: $showsSettings) {
          SettingsView(database: database, day: day, openedFile: $openedGPX)
        }
        .presentationDetents([collapsedDetent, Self.half, .large], selection: panelDetent)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.half))
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        // Follows the panel while it is dragged, so the bottom controls ride on top of it.
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.frame(in: .global).minY
        } action: { top in
          panelTop = top
        }
    }
    .onOpenURL { url in
      openedGPX = url
      showsSettings = true
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
    .task(id: showsStatusBubble) {
      await closeStatusBubbleLater()
    }
    .task(id: OverviewBoundsKey(isOn: showsOverview && hasLoadedFogOfWorld, includesFog: drawsFogOfWorld)) {
      guard showsOverview, hasLoadedFogOfWorld else { return }
      await observeOverviewBounds()
    }
    .task(id: showsOverview) {
      guard showsOverview else { return }
      await observeFogOfWorld()
    }
    .task(id: showsOverview) {
      guard showsOverview else { return }
      await observeStatistics()
    }
    .task(id: showsOverview) {
      guard showsOverview else { return }
      await observeFogDistance()
    }
    .task(id: overviewRequest) {
      guard showsOverview, let overviewRequest else { return }
      await observeOverviewTracks(for: overviewRequest)
    }
    .task(id: overviewRequest) {
      guard showsOverview, let overviewRequest, overviewRequest.fogShift != nil else { return }
      await observeFogLines(for: overviewRequest)
    }
    .onChange(of: showsOverview) {
      // Cleared on closing, so the next opening starts from nothing (the map asks again).
      guard !showsOverview else { return }
      overviewBounds = nil
      hasLoadedOverview = false
      overviewRequest = nil
      overviewTracks = nil
      statisticsInput = nil
      fogOfWorld = nil
      hasLoadedFogOfWorld = false
      fogLines = nil
      fogDistance = nil
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

  /// The overview button and the map controls, standing on the bottom panel (the timeline, or the
  /// statistics in the overview).
  private func bottomControls(in geometry: GeometryProxy) -> some View {
    let frame = geometry.frame(in: .global)
    let screenHeight = frame.maxY + geometry.safeAreaInsets.bottom
    let lift = panelTop.map { frame.maxY - $0 } ?? Self.mapAttributionRoom
    var opacity = 1.0
    if let panelTop {
      let fadeStart = screenHeight * (1 - Self.halfShare) - Self.controlsFadeSlack
      opacity = min(1, max(0, (panelTop - (fadeStart - Self.controlsFadeDistance)) / Self.controlsFadeDistance))
    }
    let status = RecordingStatus(engine: engine)
    return HStack(alignment: .bottom) {
      VStack(spacing: Self.controlsSpacing) {
        if showsOverview, fogOfWorld != nil {
          FogOfWorldButton(isOn: $showsFogOfWorld)
            .transition(.scale.combined(with: .opacity))
        }
        OverviewButton(isOn: $showsOverview)
      }
      Spacer()
      MapControls(
        status: status, motionDenied: RecordingStatus.motionDenied(engine), showsStatus: $showsStatusBubble,
        onOpenSettings: { showsSettings = true })
    }
    .padding(.horizontal)
    .padding(.bottom, lift + Self.controlsSpacing)
    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
    .opacity(opacity)
    .allowsHitTesting(opacity > 0)
  }

  /// What the map says it has nothing to show, or could not load.
  @ViewBuilder private var message: some View {
    if showsOverview {
      if hasLoadedOverview, overviewBounds == nil {
        MessageCard(title: Text("No tracks yet"), detail: Text("Every day’s tracks appear here once you’ve moved."))
      }
    } else if let loadError {
      MessageCard(title: Text("The track can’t be shown"), detail: Text(verbatim: loadError))
    } else if hasLoaded, points.isEmpty {
      if day == today {
        MessageCard(title: Text("Nothing recorded today yet"), detail: Text("Your track appears here as you move."))
      } else {
        MessageCard(title: Text("Nothing recorded on this day"), detail: Text("Pick another day in the calendar."))
      }
    }
  }

  private var overview: TodayMapView.Overview? {
    guard showsOverview else { return nil }
    return TodayMapView.Overview(
      bounds: overviewBounds, request: overviewTracks?.request, tracks: overviewTracks?.tracks ?? [:],
      showsFogOfWorld: drawsFogOfWorld, fogRequest: fogLines?.request, fogLines: fogLines?.lines ?? [])
  }

  /// Fog of World is drawn when there is an import and the switch is on (D54 ⑧).
  private var drawsFogOfWorld: Bool {
    showsFogOfWorld && fogOfWorld != nil
  }

  private struct OverviewBoundsKey: Equatable {
    var isOn: Bool
    var includesFog: Bool
  }

  private func observeFogOfWorld() async {
    do {
      for try await summary in database.observeFogOfWorld() {
        fogOfWorld = summary
        hasLoadedFogOfWorld = true
      }
    } catch is CancellationError {
      // The overview was closed.
    } catch {
      AppLog.storage.error("reading the Fog of World layer failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }

  private func observeFogLines(for request: OverviewRequest) async {
    guard let shift = request.fogShift else { return }
    do {
      for try await lines in database.observeFogOfWorldLines(in: request.box, shift: shift) {
        fogLines = (request, lines)
      }
    } catch is CancellationError {
      // A newer viewport, or the overview was closed.
    } catch {
      AppLog.storage.error("reading the Fog of World layer failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }

  /// D54 ⑤: counted in the statistics whether or not the layer is drawn.
  private func observeFogDistance() async {
    do {
      for try await distance in database.observeFogOfWorldDistance(tolerance: Segmenter.Parameters().dwellRadius) {
        fogDistance = distance
      }
    } catch is CancellationError {
      // The overview closed.
    } catch {
      AppLog.storage.error("estimating the Fog of World distance failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }

  private func observeOverviewBounds() async {
    do {
      for try await bounds in database.observeOverviewBounds(includingFogOfWorld: drawsFogOfWorld) {
        overviewBounds = bounds
        hasLoadedOverview = true
      }
    } catch is CancellationError {
      // The overview was closed.
    } catch {
      AppLog.processing.error("reading the overview failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }

  private func observeOverviewTracks(for request: OverviewRequest) async {
    do {
      for try await tracks in database.observeOverviewTracks(in: request.box, level: request.level) {
        overviewTracks = (request, tracks)
      }
    } catch is CancellationError {
      // A newer viewport, or the overview was closed.
    } catch {
      AppLog.processing.error("reading the overview failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
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

  @ViewBuilder private var panelContent: some View {
    if showsOverview {
      StatisticsPanel(
        input: statisticsInput, fogOfWorldDistance: fogDistance, year: $statisticsYear, showsList: panelStop != .collapsed,
        onHeaderHeight: { panelHeaderHeight = $0 })
    } else {
      timelinePanel
    }
  }

  private func observeStatistics() async {
    do {
      for try await input in database.observeStatisticsInput() {
        statisticsInput = input
      }
    } catch is CancellationError {
      // The overview closed.
    } catch {
      AppLog.processing.error("reading statistics failed: \(error.localizedDescription, privacy: .public)")
      processingError = error.localizedDescription
    }
  }

  private var timelinePanel: some View {
    #if DEBUG
    TimelinePanel(
      day: day, today: today, segments: segments, places: places, processingError: processingError,
      showsList: panelStop != .collapsed, onHeaderHeight: { panelHeaderHeight = $0 }, onChangeDay: show, onOpenCalendar: { showsCalendar = true },
      onSelect: select, onChangeMode: changeMode, onRenamePlace: renamePlace
    ) {
      showsDeveloperMenu = true
    }
    .sheet(isPresented: $showsDeveloperMenu) {
      DeveloperMenu()
    }
    .sheet(isPresented: $showsCalendar) { calendar }
    #else
    TimelinePanel(
      day: day, today: today, segments: segments, places: places, processingError: processingError,
      showsList: panelStop != .collapsed, onHeaderHeight: { panelHeaderHeight = $0 }, onChangeDay: show, onOpenCalendar: { showsCalendar = true },
      onSelect: select, onChangeMode: changeMode, onRenamePlace: renamePlace)
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

  private func hideStatusBubble() {
    guard showsStatusBubble else { return }
    withAnimation(.bouncy) { showsStatusBubble = false }
  }

  /// Closes the bubble after its time; a new opening or a close restarts or ends the wait.
  private func closeStatusBubbleLater() async {
    guard showsStatusBubble else { return }
    do {
      try await Task.sleep(for: Self.statusBubbleDuration)
    } catch {
      return  // Cancelled: the bubble was closed or the view went away.
    }
    hideStatusBubble()
  }

  private enum PanelStop {
    case collapsed, half, large
  }

  private var collapsedHeight: CGFloat {
    max(panelHeaderHeight ?? 0, Self.minimumCollapsedHeight)
  }

  private var collapsedDetent: PresentationDetent { .height(collapsedHeight) }

  /// The collapsed detent's value changes with the header's height, so the panel's position is
  /// kept as a stop and mapped to whichever detent stands for it now.
  private var panelDetent: Binding<PresentationDetent> {
    Binding {
      switch panelStop {
      case .collapsed: collapsedDetent
      case .half: Self.half
      case .large: .large
      }
    } set: { detent in
      panelStop = switch detent {
      case Self.half: .half
      case .large: .large
      default: .collapsed
      }
    }
  }

  private func panelHeight(in height: CGFloat) -> CGFloat {
    switch panelStop {
    case .collapsed: collapsedHeight
    case .half: height * 0.4
    default: height * 0.4  // full height covers the map; focusing collapses it to half first
    }
  }

  /// F8: picking a row focuses the map on it.
  private func select(_ segment: Segment) {
    guard let target = MapFocus.of(segment, in: points) else { return }
    if panelStop == .large { panelStop = .half }
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

/// Size of the round controls at the bottom of the map (D47), as in Apple Maps.
private let mapControlSize: CGFloat = 48

/// The round glass button at the bottom left that turns the overview on and off (D44, D47); tinted
/// while it is on.
/// Shows or hides Fog of World's explored areas in the overview (D54 ⑧); there only when an
/// import exists.
private struct FogOfWorldButton: View {
  @Binding var isOn: Bool

  var body: some View {
    Button { isOn.toggle() } label: {
      Image(systemName: isOn ? "cloud.fog.fill" : "cloud.fog")
        .font(.title3.weight(.semibold))
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(width: mapControlSize, height: mapControlSize)
        .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Fog of World"))
    .accessibilityValue(isOn ? Text("Shown") : Text("Hidden"))
  }
}

private struct OverviewButton: View {
  @Binding var isOn: Bool

  var body: some View {
    Button { isOn.toggle() } label: {
      Image(systemName: isOn ? "map.fill" : "map")
        .font(.title3.weight(.semibold))
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(width: mapControlSize, height: mapControlSize)
        .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Overview"))
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// The glass column at the bottom right (D47): the recording status, orange when recording has a
/// problem (F1), and the settings. Tapping the status shows its name in a small capsule beside the
/// column (D45); another tap hides it. A problem's detail and Open Settings are in the card.
private struct MapControls: View {
  let status: RecordingStatus
  let motionDenied: Bool
  @Binding var showsStatus: Bool
  let onOpenSettings: () -> Void

  /// The widest the status capsule grows, so a long note wraps.
  private static let statusMaximumWidth: CGFloat = 250
  private static let dividerWidth: CGFloat = 28

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        if showsStatus {
          statusCapsule
            .transition(.scale(scale: 0.5, anchor: .trailing).combined(with: .opacity))
        }
        VStack(spacing: 0) {
          Button {
            withAnimation(.bouncy) { showsStatus.toggle() }
          } label: {
            Image(systemName: status.symbol)
              .font(.title3.weight(.semibold))
              .foregroundStyle(status.color)
              .frame(width: mapControlSize, height: mapControlSize)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(status.title)
          .accessibilityHint(showsStatus ? Text("Hides the recording status") : Text("Shows the recording status"))
          Divider()
            .frame(width: Self.dividerWidth)
          SettingsButton(size: mapControlSize, action: onOpenSettings)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
      }
    }
  }

  private var statusCapsule: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: status.symbol)
        .font(.body.weight(.semibold))
        .foregroundStyle(status.color)
      VStack(alignment: .leading, spacing: 2) {
        status.title
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
        if motionDenied, status == .recording {
          RecordingStatus.motionDeniedNote
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(minHeight: mapControlSize)
    .frame(maxWidth: Self.statusMaximumWidth, alignment: .leading)
    .fixedSize()
    .glassEffect(.regular, in: .rect(cornerRadius: mapControlSize / 2))
    .accessibilityElement(children: .combine)
  }
}

/// A recording problem in full under the day bar, with the way to fix it (F1).
private struct StatusCard: View {
  let status: RecordingStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label { status.title } icon: { Image(systemName: status.symbol) }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(status.color)
      if let detail = status.detail {
        detail
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if status.needsSettings {
        Button("Open Settings", action: RecordingStatus.openSettings)
          .font(.footnote.weight(.semibold))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: .rect(cornerRadius: 22))
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
