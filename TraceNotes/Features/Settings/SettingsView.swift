import GRDB
import SwiftUI
import os
import UniformTypeIdentifiers

nonisolated extension UTType {
  /// Declared as an imported type in the app's Info.plist, so Files and the share sheet offer
  /// Trace Notes for .gpx files.
  static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// The settings screen (F10, D53 ①, D55 ①): the appearance (D40), GPX export and import (F9),
/// the Fog of World import (F12, D54), the diagnostic report, about, and deleting all data. A .gpx
/// file opened from Files or the share sheet arrives as `openedFile` and is imported here, so its
/// result shows in the same place.
struct SettingsView: View {
  let database: AppDatabase
  let engine: RecordingEngine
  /// The day on screen, the export's default range.
  let day: LocalDay
  @Binding var openedFile: URL?
  @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
  @Environment(\.dismiss) private var dismiss
  /// What the file picker is open for; nil while it is closed.
  @State private var choosing: FileKind?
  @State private var importState = ImportState.idle
  @State private var fogOfWorld: AppDatabase.FogOfWorldSummary?
  @State private var fogState = FogState.idle
  @State private var confirmsFogRemoval = false
  @State private var dataSummary: AppDatabase.DataSummary?
  @State private var deletion = DeleteState.idle
  /// The first and second confirmation of deleting all data (D55 ④).
  @State private var confirmsDeletion = false
  @State private var confirmsDeletionAgain = false
  /// Opened from the first confirmation, to export everything before deleting it.
  @State private var exportsAllFirst = false

  enum DeleteState: Equatable {
    case idle
    case deleting
    case deleted
    case failed(String)
  }

  enum FileKind {
    case gpx
    /// A Sync folder, or a zip of one (D54 ①).
    case fogOfWorld
  }

  enum FogState: Equatable {
    case idle
    case importing
    case failed(String)
  }

  enum ImportState: Equatable {
    case idle
    case running
    case done(AppDatabase.GPXImport, skipped: Int)
    case failed(String)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker(selection: $appearance) {
            ForEach(Appearance.allCases) { option in
              Label(option.title, systemImage: option.symbol).tag(option)
            }
          } label: {
            Text("Appearance")
          }
        }
        Section {
          NavigationLink {
            GPXExportView(database: database, day: day)
          } label: {
            Label { Text("Export GPX") } icon: { Image(systemName: "square.and.arrow.up") }
          }
          Button {
            choosing = .gpx
          } label: {
            // Text in the primary colour, like the export row; the icon keeps the accent colour.
            Label { Text("Import GPX") } icon: {
              Image(systemName: "square.and.arrow.down").foregroundStyle(Color.accentColor)
            }
          }
          .tint(.primary)
          .disabled(importState == .running)
          ImportStatusRow(state: importState)
        } header: {
          Text(verbatim: "GPX")
        } footer: {
          Text("Imported points appear only where Trace Notes has no recording of its own.")
        }
        fogOfWorldSection
        Section {
          NavigationLink {
            DiagnosticReportView(database: database, engine: engine)
          } label: {
            Label { Text("Diagnostic Report") } icon: { Image(systemName: "stethoscope") }
          }
        } header: {
          Text("Diagnostics")
        } footer: {
          Text("For reporting a problem: you see the whole report before sharing it. It has no coordinates or place names.")
        }
        Section {
          LabeledContent {
            Text(verbatim: Self.version)
          } label: {
            Text("Version")
          }
          NavigationLink { PrivacyPolicyView() } label: { Text("Privacy Policy") }
          NavigationLink { LicensesView() } label: { Text("Open-Source Licenses") }
        } header: {
          Text("About")
        }
        deletionSection
      }
      .navigationDestination(isPresented: $exportsAllFirst) {
        GPXExportView(database: database, day: day, selectsAllRecords: true)
      }
      .navigationTitle(Text("Settings"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button { dismiss() } label: { Text("Done") }
        }
      }
    }
    .fileImporter(
      isPresented: Binding { choosing != nil } set: { if !$0 { choosing = nil } },
      allowedContentTypes: choosing == .fogOfWorld ? [.folder, .zip] : [.gpx]
    ) { [choosing] result in
      switch (choosing, result) {
      case (.fogOfWorld, .success(let url)):
        Task { await importFogOfWorld(from: url) }
      case (_, .success(let url)):
        Task { await importFile(at: url, ownsFile: false) }
      case (.fogOfWorld, .failure(let error)):
        AppLog.storage.error("choosing a Fog of World folder failed: \(error.localizedDescription, privacy: .public)")
        fogState = .failed(error.localizedDescription)
      case (_, .failure(let error)):
        AppLog.storage.error("choosing a GPX file failed: \(error.localizedDescription, privacy: .public)")
        importState = .failed(error.localizedDescription)
      }
    }
    .confirmationDialog(Text("Remove Fog of World data?"), isPresented: $confirmsFogRemoval, titleVisibility: .visible) {
      Button(role: .destructive) {
        Task { await removeFogOfWorld() }
      } label: {
        Text("Remove")
      }
    } message: {
      Text("Only the explored areas you imported are removed. Your own records stay.")
    }
    .confirmationDialog(Text("Delete all data?"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
      Button { exportsAllFirst = true } label: { Text("Export GPX First") }
      Button(role: .destructive) { confirmsDeletionAgain = true } label: { Text("Delete All Data") }
    } message: {
      deletionMessage
    }
    .alert(Text("This can’t be undone."), isPresented: $confirmsDeletionAgain) {
      Button(role: .destructive) {
        Task { await deleteAllData() }
      } label: {
        Text("Delete")
      }
    } message: {
      Text("All records are deleted from this iPhone. Recording goes on from now.")
    }
    .task {
      do {
        for try await summary in database.observeDataSummary() { dataSummary = summary }
      } catch is CancellationError {
        // The settings closed.
      } catch {
        AppLog.storage.error("reading the data summary failed: \(error.localizedDescription, privacy: .public)")
        deletion = .failed(error.localizedDescription)
      }
    }
    .task {
      do {
        for try await summary in database.observeFogOfWorld() { fogOfWorld = summary }
      } catch is CancellationError {
        // The settings closed.
      } catch {
        AppLog.storage.error("reading the Fog of World layer failed: \(error.localizedDescription, privacy: .public)")
        fogState = .failed(error.localizedDescription)
      }
    }
    .task(id: openedFile) {
      guard let url = openedFile else { return }
      openedFile = nil
      await importFile(at: url, ownsFile: true)
    }
  }

  /// `ownsFile`: the system copied the file into the app's inbox for us, so it is removed after.
  private func importFile(at url: URL, ownsFile: Bool) async {
    importState = .running
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
      if ownsFile { removeInboxCopy(url) }
    }
    do {
      let data = try Data(contentsOf: url)
      let read = try GPXReader.read(data, timeZoneID: TimeZone.current.identifier)
      let result = try await database.importGPX(read.points)
      AppLog.storage.notice("GPX import: \(result.added) added, \(result.duplicates) duplicates, \(read.skipped) skipped")
      importState = .done(result, skipped: read.skipped)
    } catch let failure as GPXReader.Failure {
      AppLog.storage.notice("GPX import refused: \(String(describing: failure), privacy: .public)")
      importState = .failed(failure.message)
    } catch {
      AppLog.storage.error("GPX import failed: \(error.localizedDescription, privacy: .public)")
      importState = .failed(error.localizedDescription)
    }
  }

  /// D54: the explored areas in Fog of World's Sync folder (or a zip of it), measured and stored in
  /// place of an earlier import.
  @ViewBuilder private var fogOfWorldSection: some View {
    Section {
      if let fogOfWorld {
        LabeledContent {
          Text(fogOfWorld.importedAt, format: .dateTime.year().month().day().hour().minute())
        } label: {
          Text("\(fogOfWorld.pixelCount) explored cells")
        }
      }
      Button {
        choosing = .fogOfWorld
      } label: {
        Label {
          Text(fogOfWorld == nil ? "Import from Fog of World" : "Import Again")
        } icon: {
          Image(systemName: "cloud.fog").foregroundStyle(Color.accentColor)
        }
      }
      .tint(.primary)
      .disabled(fogState == .importing)
      if fogOfWorld != nil {
        Button(role: .destructive) {
          confirmsFogRemoval = true
        } label: {
          // The icon in red too, like the destructive title.
          Label { Text("Remove Fog of World Data") } icon: { Image(systemName: "trash").foregroundStyle(.red) }
        }
        .disabled(fogState == .importing)
      }
      switch fogState {
      case .idle:
        EmptyView()
      case .importing:
        HStack(spacing: 8) {
          ProgressView()
          Text("Importing…")
        }
        .foregroundStyle(.secondary)
      case .failed(let message):
        Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    } header: {
      Text("Fog of World")
    } footer: {
      Text("Choose the Sync folder in Fog of World’s iCloud Drive folder, or a zip of it. Explored areas appear in the overview and count towards the total distance; they have no times, so they stay out of the timeline. A new import replaces the old one.")
    }
  }

  private func importFogOfWorld(from url: URL) async {
    fogState = .importing
    do {
      let imported = try await Task.detached(priority: .userInitiated) {
        try FogOfWorld.read(archive: try FogOfWorldFile.archive(at: url))
      }.value
      try await database.replaceFogOfWorld(imported.blocks, importedAt: .now)
      AppLog.storage.notice("Fog of World import: \(imported.tiles) tiles, \(imported.blocks.count) blocks")
      fogState = .idle
    } catch let failure as FogOfWorld.Failure {
      AppLog.storage.notice("Fog of World import refused: \(String(describing: failure), privacy: .public)")
      fogState = .failed(failure.message)
    } catch {
      AppLog.storage.error("Fog of World import failed: \(error.localizedDescription, privacy: .public)")
      fogState = .failed(error.localizedDescription)
    }
  }

  private func removeFogOfWorld() async {
    do {
      try await database.removeFogOfWorld()
      fogState = .idle
    } catch {
      AppLog.storage.error("removing the Fog of World layer failed: \(error.localizedDescription, privacy: .public)")
      fogState = .failed(error.localizedDescription)
    }
  }

  /// D55 ①②: last, on its own, in red.
  @ViewBuilder private var deletionSection: some View {
    Section {
      Button(role: .destructive) {
        confirmsDeletion = true
      } label: {
        Label { Text("Delete All Data") } icon: { Image(systemName: "trash").foregroundStyle(.red) }
      }
      .disabled(deletion == .deleting || dataSummary == nil)
      switch deletion {
      case .idle:
        EmptyView()
      case .deleting:
        HStack(spacing: 8) {
          ProgressView()
          Text("Deleting…")
        }
        .foregroundStyle(.secondary)
      case .deleted:
        Label { Text("All data was deleted.") } icon: { Image(systemName: "checkmark.circle.fill") }
          .font(.footnote)
          .foregroundStyle(.green)
      case .failed(let message):
        Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    } footer: {
      Text("Deletes every record, your changes to them and the Fog of World data. Your settings stay.")
    }
  }

  /// What the first confirmation says will go (D55 ④).
  private var deletionMessage: Text {
    let summary = dataSummary ?? AppDatabase.DataSummary(days: 0, metres: 0, hasFogOfWorld: false)
    let distance = Measurement(value: summary.metres, unit: UnitLength.meters)
      .formatted(.measurement(width: .abbreviated, usage: .road))
    return summary.hasFogOfWorld
      ? Text("This deletes \(summary.days) days and about \(distance) of records, and the Fog of World data. You can export GPX first.")
      : Text("This deletes \(summary.days) days and about \(distance) of records. You can export GPX first.")
  }

  private func deleteAllData() async {
    deletion = .deleting
    do {
      try await database.deleteAllData()
      AppLog.storage.notice("all data deleted")
      deletion = .deleted
    } catch {
      AppLog.storage.error("deleting all data failed: \(error.localizedDescription, privacy: .public)")
      deletion = .failed(error.localizedDescription)
    }
  }

  /// "1.0 (12)".
  private static var version: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
  }

  private func removeInboxCopy(_ url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      AppLog.storage.error("removing the imported GPX copy failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}

extension FogOfWorld.Failure {
  var message: String {
    switch self {
    case .notArchive: String(localized: "This isn’t a folder or zip file Trace Notes can read.")
    case .noTiles: String(localized: "No Fog of World data was found. Choose the Sync folder in Fog of World’s iCloud Drive folder.")
    case .damagedTile: String(localized: "Some of the Fog of World data is damaged, so nothing was imported.")
    }
  }
}

/// Reads a picked folder or file through file coordination, so an iCloud Drive item is downloaded
/// first; a folder comes back zipped by the system (D54 ①).
nonisolated enum FogOfWorldFile {
  static func archive(at url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let isFolder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
    var coordinationError: NSError?
    var result: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: url, options: isFolder ? .forUploading : [], error: &coordinationError) { readable in
      result = Result { try Data(contentsOf: readable) }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
  }
}

extension GPXReader.Failure {
  var message: String {
    switch self {
    case .notGPX: String(localized: "This file isn’t a GPX file, or it’s damaged.")
    case .noPoints: String(localized: "This GPX file has no tracks or routes.")
    case .noUsablePoints: String(localized: "None of the points in this GPX file has both a time and a valid position, so nothing can be placed on the timeline.")
    }
  }
}

private struct ImportStatusRow: View {
  let state: SettingsView.ImportState

  var body: some View {
    switch state {
    case .idle:
      EmptyView()
    case .running:
      HStack(spacing: 8) {
        ProgressView()
        Text("Importing…")
      }
      .foregroundStyle(.secondary)
    case .done(let result, let skipped):
      VStack(alignment: .leading, spacing: 2) {
        if result.added > 0 {
          Label { Text("\(result.added) points imported") } icon: { Image(systemName: "checkmark.circle.fill") }
            .foregroundStyle(.green)
        } else {
          Label { Text("Nothing new to import") } icon: { Image(systemName: "checkmark.circle") }
        }
        if result.duplicates > 0 {
          Text("\(result.duplicates) points were already imported")
        }
        if skipped > 0 {
          Text("\(skipped) points without a time or position were left out")
        }
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
    case .failed(let message):
      Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
        .font(.footnote)
        .foregroundStyle(.orange)
    }
  }
}

/// D53 ②④: pick the days, then share them as a GPX file. The file is written only when the user
/// picks where it goes in the share sheet.
struct GPXExportView: View {
  let database: AppDatabase
  @State private var from: Date
  @State private var through: Date
  @State private var recordedDays: ClosedRange<LocalDay>?
  /// Nil while counting.
  @State private var pointCount: Int?
  @State private var failure: String?

  /// Pick all recorded days once they are known, instead of `day` (export before deleting, D55 ④).
  private let selectsAllRecords: Bool

  init(database: AppDatabase, day: LocalDay, selectsAllRecords: Bool = false) {
    self.database = database
    self.selectsAllRecords = selectsAllRecords
    let date = Self.date(of: day)
    _from = State(initialValue: date)
    _through = State(initialValue: date)
  }

  private var days: ClosedRange<LocalDay> {
    let first = LocalDay(from, in: .current)
    let last = LocalDay(through, in: .current)
    return min(first, last)...max(first, last)
  }

  var body: some View {
    Form {
      Section {
        DatePicker(selection: $from, displayedComponents: .date) { Text("From") }
        DatePicker(selection: $through, in: from..., displayedComponents: .date) { Text("To") }
        Button {
          guard let recordedDays else { return }
          from = Self.date(of: recordedDays.lowerBound)
          through = Self.date(of: recordedDays.upperBound)
        } label: {
          Text("All Records")
        }
        .disabled(recordedDays == nil)
      }
      Section {
        if let failure {
          Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .foregroundStyle(.orange)
        } else if let pointCount {
          if pointCount == 0 {
            Text("No records on these days.")
              .foregroundStyle(.secondary)
          } else {
            ShareLink(item: GPXFile(database: database, days: days), preview: SharePreview(Text(verbatim: GPXFile.name(of: days)))) {
              Label { Text("Share \(pointCount) points") } icon: { Image(systemName: "square.and.arrow.up") }
            }
          }
        } else {
          ProgressView()
        }
      } footer: {
        Text("The file holds what the map shows: one track per day, without poor or estimated fixes.")
      }
    }
    .navigationTitle(Text("Export GPX"))
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: from) { _, newValue in
      if through < newValue { through = newValue }
    }
    .task {
      do {
        recordedDays = try await database.pointDays()
        if selectsAllRecords, let recordedDays {
          from = Self.date(of: recordedDays.lowerBound)
          through = Self.date(of: recordedDays.upperBound)
        }
      } catch {
        AppLog.storage.error("reading the recorded days failed: \(error.localizedDescription, privacy: .public)")
        failure = error.localizedDescription
      }
    }
    .task(id: days) {
      pointCount = nil
      do {
        pointCount = try await database.exportPoints(on: days).count
        failure = nil
      } catch is CancellationError {
        // Other days were picked.
      } catch {
        AppLog.storage.error("counting GPX points failed: \(error.localizedDescription, privacy: .public)")
        failure = error.localizedDescription
      }
    }
  }

  /// Midday, so the date picker shows the same day in any zone offset.
  private static func date(of day: LocalDay) -> Date {
    day.start(in: .current).addingTimeInterval(12 * 3600)
  }
}

/// The exported file, written into the temporary folder when the share sheet asks for it.
struct GPXFile: Transferable {
  let database: AppDatabase
  let days: ClosedRange<LocalDay>

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .gpx) { file in
      let points = try await file.database.exportPoints(on: file.days)
      let url = FileManager.default.temporaryDirectory.appending(path: name(of: file.days))
      try GPXWriter.document(of: points, gapInterval: Segmenter.Parameters().gapInterval).write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }

  static func name(of days: ClosedRange<LocalDay>) -> String {
    days.lowerBound == days.upperBound
      ? "Trace Notes \(days.lowerBound).gpx" : "Trace Notes \(days.lowerBound) – \(days.upperBound).gpx"
  }
}
