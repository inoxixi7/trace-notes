import MapKit
import SwiftUI

/// MKMapView wrapper (D27). VS1 draws today's raw points as one plain polyline; smoothing, LOD,
/// pixel line widths and GCJ-02 display arrive with VS3.
struct TodayMapView: UIViewRepresentable {
  let coordinates: [CLLocationCoordinate2D]

  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView()
    map.delegate = context.coordinator
    map.showsUserLocation = true
    map.pointOfInterestFilter = .excludingAll
    return map
  }

  func updateUIView(_ map: MKMapView, context: Context) {
    context.coordinator.show(coordinates, on: map)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, MKMapViewDelegate {
    private var polyline: MKPolyline?
    private var shownCount = 0
    private var hasFramedTrack = false
    /// Room around the track when the map first frames it, in points.
    private static let framePadding = UIEdgeInsets(top: 120, left: 40, bottom: 80, right: 40)
    /// Span shown around a track that is still a single point (a zero-size rect would zoom in fully).
    private static let minimumSpanMetres: CLLocationDistance = 1000

    func show(_ coordinates: [CLLocationCoordinate2D], on map: MKMapView) {
      guard coordinates.count != shownCount else { return }
      shownCount = coordinates.count
      if let polyline { map.removeOverlay(polyline) }
      polyline = nil
      guard !coordinates.isEmpty else { return }
      let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
      map.addOverlay(line)
      polyline = line
      // Frame the track once; afterwards the user's own panning and zooming wins.
      if !hasFramedTrack {
        hasFramedTrack = true
        let rect = line.boundingMapRect
        if rect.size.width == 0, rect.size.height == 0 {
          let region = MKCoordinateRegion(center: coordinates[0], latitudinalMeters: Self.minimumSpanMetres, longitudinalMeters: Self.minimumSpanMetres)
          map.setRegion(region, animated: false)
        } else {
          map.setVisibleMapRect(rect, edgePadding: Self.framePadding, animated: false)
        }
      }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
      guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
      let renderer = MKPolylineRenderer(polyline: line)
      renderer.strokeColor = .tintColor
      renderer.lineWidth = 4
      renderer.lineCap = .round
      renderer.lineJoin = .round
      return renderer
    }
  }
}
