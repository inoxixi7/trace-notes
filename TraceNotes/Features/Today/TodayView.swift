import CoreLocation
import GRDB
import SwiftUI
import UIKit

/// The default screen (F8, VS1 scope): today's map with the raw track and the recording status.
/// The timeline panel arrives with VS2.
struct TodayView: View {
  let database: AppDatabase
  let engine: RecordingEngine
  @State private var day = LocalDay(.now, in: .current)
  @State private var points: [RawPoint] = []
  @State private var hasLoaded = false
  @State private var loadError: String?
  #if DEBUG
  @State private var showsDeveloperMenu = false
  #endif

  var body: some View {
    TodayMapView(coordinates: trackCoordinates)
      .ignoresSafeArea()
      .overlay(alignment: .top) {
        VStack(spacing: 8) {
          StatusCapsule(status: RecordingStatus(engine: engine), motionDenied: RecordingStatus.motionDenied(engine))
          if let loadError {
            MessageCard(title: Text("Today’s track can’t be shown"), detail: Text(verbatim: loadError))
          } else if hasLoaded, trackCoordinates.isEmpty {
            MessageCard(title: Text("Nothing recorded today yet"), detail: Text("Your track appears here as you move."))
          }
        }
        .padding(.horizontal)
      }
      #if DEBUG
      .overlay(alignment: .bottomTrailing) {
        Button {
          showsDeveloperMenu = true
        } label: {
          Image(systemName: "hammer")
            .padding(12)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(verbatim: "Developer"))
        .padding()
      }
      .sheet(isPresented: $showsDeveloperMenu) {
        DeveloperMenu()
      }
      #endif
      .task(id: day) {
        await observePoints(on: day)
      }
      .task {
        // Today changes at local midnight and when the time zone changes.
        for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
          day = LocalDay(.now, in: .current)
        }
      }
  }

  /// Replayed fixes are stored but not part of the track: they repeat an old, cached position
  /// (pipeline step ① skips them too, ARCHITECTURE §5.1).
  private var trackCoordinates: [CLLocationCoordinate2D] {
    points.filter { !$0.flags.contains(.replayed) }
      .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
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
