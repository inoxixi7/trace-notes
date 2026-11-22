import MapKit
import UIKit
import os

/// Draws the day over the map (D39, D40): the track as one smooth Bézier path and the stays as
/// small dots, plus a grey layer that turns the base map monochrome in light and dark mode.
///
/// MapKit presents its map a frame after UIKit commits, so a view laid over the map led it by a
/// frame while panning (device finding: the track "floated"). Annotation views are moved by MapKit
/// in step with the map, so the canvas lives inside one: an `Anchor` annotation near the middle of
/// the screen, and the canvas draws relative to it. Panning then needs no redraw at all. MapKit
/// drops the views of annotations that leave the screen, so a new anchor takes over before that.
///
/// Zooming and rotating do need a redraw, and the camera the delegate reports is again a frame
/// ahead of the map: MapKit positions the annotation views for a camera only at its next display
/// frame (simulator probe, D40). So each reported camera is queued, and the canvas redraws when
/// MapKit moves the anchor's layer, with the queued camera that puts the anchor exactly there.
///
/// MapKit has no greyscale map, so a grey view with a saturation blend sits between the map and
/// the annotation views; the track, the dots and the user-location dot stay in colour above it.
final class TrackCanvas: UIView {
  /// An annotation whose view carries the canvas. It never moves: a new one replaces it when the
  /// map has moved far from it.
  final class Anchor: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D

    init(_ coordinate: CLLocationCoordinate2D) {
      self.coordinate = coordinate
    }
  }

  /// Reports every position MapKit gives an anchor's view, which is when MapKit applies a camera.
  nonisolated final class AnchorLayer: CALayer {
    weak var canvas: TrackCanvas?

    override var position: CGPoint {
      didSet {
        let position = position
        let layer = ObjectIdentifier(self)
        let canvas = canvas
        MainActor.assumeIsolated { canvas?.anchorLayer(layer, movedTo: position) }
      }
    }
  }

  private final class AnchorView: MKAnnotationView {
    override class var layerClass: AnyClass { AnchorLayer.self }
  }

  /// The anchor whose view holds the canvas, and the one about to replace it.
  private(set) var anchor: Anchor?
  private(set) var pendingAnchor: Anchor?
  /// Blends with what is behind it, so it must be a view between the map and the annotations.
  private let grey = UIView()
  private let casing = CAShapeLayer()
  private let line = CAShapeLayer()
  private let dotRings = CAShapeLayer()
  private let dots = CAShapeLayer()

  /// The tracks, in map points relative to `origin` (see `TrackGeometry.path`).
  private var trackPath: CGPath?
  private var origin = MKMapPoint(x: 0, y: 0)
  private var stays: [MKMapPoint] = []
  /// Cameras (map points to map-view points) the delegate reported that MapKit has not applied to
  /// the anchor yet, oldest first, and the camera the canvas is drawn with.
  private var reportedCameras: [CGAffineTransform] = []
  private var drawnCamera: CGAffineTransform?

  /// Screen points, the same at every zoom level (F7).
  static let lineWidth: CGFloat = 5
  static let casingWidth: CGFloat = 8
  static let dotDiameter: CGFloat = 10
  static let dotRingWidth: CGFloat = 2.5
  /// Stay dots appear from about neighbourhood scale (≈ 2 km across a phone screen); further out
  /// the day reads as lines only (device feedback, D39).
  static let dotsMaximumMetresPerPoint = 5.0
  /// A new anchor replaces the current one once it is this share of the screen's shorter side
  /// away from the middle, well before MapKit drops its view for being off screen.
  static let anchorReplacementShare = 0.25
  /// A queued camera matches the anchor's new position when it puts the anchor within this many
  /// points of it: far below anything visible, far above floating-point noise (probe: ≈ 1e-9).
  static let cameraMatchTolerance: CGFloat = 0.01
  /// MapKit applies a camera within a frame or two; this bounds the queue if it skips some.
  static let reportedCamerasLimit = 8

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    grey.backgroundColor = .gray
    // The saturation blend takes hue and saturation from this (none) and luminosity from the map.
    grey.layer.compositingFilter = "saturationBlendMode"
    grey.isUserInteractionEnabled = false
    grey.autoresizingMask = [.flexibleWidth, .flexibleHeight]

    for (layer, width) in [(casing, Self.casingWidth), (line, Self.lineWidth)] {
      layer.fillColor = nil
      layer.lineWidth = width
      layer.lineCap = .round
      layer.lineJoin = .round
    }
    for layer in [casing, line, dotRings, dots] { self.layer.addSublayer(layer) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// The view for one of the canvas's anchors: empty, zero-sized and touch-transparent, centred on
  /// the anchor, so the canvas's origin is the anchor's screen point (its layers draw outside its
  /// bounds).
  func view(for anchor: Anchor) -> MKAnnotationView {
    let view = AnchorView(annotation: anchor, reuseIdentifier: nil)
    view.frame = .zero
    (view.layer as? AnchorLayer)?.canvas = self
    view.isEnabled = false
    view.isUserInteractionEnabled = false
    view.canShowCallout = false
    view.displayPriority = .required
    view.zPriority = .min
    view.collisionMode = .none
    return view
  }

  /// Adds an anchor in the middle of the screen when there is none or the current one has drifted
  /// towards the edge. Its view takes over in `adopt` once MapKit has placed it.
  func keepAnchorNearCentre(on map: MKMapView) {
    guard pendingAnchor == nil, map.bounds.width > 0, map.visibleMapRect.width > 0 else { return }
    if let anchor {
      let point = map.convert(anchor.coordinate, toPointTo: map)
      let distance = hypot(point.x - map.bounds.midX, point.y - map.bounds.midY)
      guard distance > min(map.bounds.width, map.bounds.height) * Self.anchorReplacementShare else { return }
    }
    let visible = map.visibleMapRect
    let next = Anchor(MKMapPoint(x: visible.midX, y: visible.midY).coordinate)
    pendingAnchor = next
    map.addAnnotation(next)
  }

  /// Moves the canvas into the pending anchor's view, which MapKit has just added and placed, and
  /// removes the old anchor. Drawn relative to the new anchor in the same pass, the track does not
  /// move on screen. Other views are ignored.
  func adopt(_ view: MKAnnotationView, on map: MKMapView) {
    guard let next = pendingAnchor, view.annotation === next else { return }
    let old = anchor
    anchor = next
    pendingAnchor = nil
    view.addSubview(self)
    // MapKit has placed the new view for some camera already; draw with that one.
    drawnCamera = takeCamera(placing: next, at: view.layer.position) ?? Self.camera(on: map)
    redraw(on: map)
    if let old { map.removeAnnotation(old) }
    if !placeGrey(below: view) {
      AppLog.rendering.error("map view hierarchy changed: the base map stays in colour")
    }
  }

  /// Puts the grey layer right under the view that holds the annotation views; that view and the
  /// map's drawing share a parent. Returns false when the anchor's view has no such container.
  private func placeGrey(below anchorView: UIView) -> Bool {
    guard let container = anchorView.superview, let parent = container.superview else { return false }
    grey.frame = parent.bounds
    if grey.superview !== parent { parent.insertSubview(grey, belowSubview: container) }
    return true
  }

  func setTracks(_ path: CGPath?, origin: MKMapPoint) {
    trackPath = path
    self.origin = origin
  }

  func setStays(_ stays: [MKMapPoint]) {
    self.stays = stays
  }

  /// Queues the map's current camera; the canvas follows when MapKit moves the anchor for it.
  /// Call from the delegate's visible-region callback.
  func mapDidChangeCamera(_ map: MKMapView) {
    guard let camera = Self.camera(on: map) else { return }
    reportedCameras.append(camera)
    if reportedCameras.count > Self.reportedCamerasLimit { reportedCameras.removeFirst() }
  }

  /// The map has settled: draw with its final camera, whether or not MapKit moved the anchor for it
  /// (a zoom exactly about the anchor leaves it in place).
  func mapDidSettle(_ map: MKMapView) {
    reportedCameras.removeAll()
    drawnCamera = Self.camera(on: map)
    redraw(on: map)
  }

  /// MapKit moved an anchor's view: when it is the canvas's anchor, draw with the camera that put
  /// it there.
  fileprivate func anchorLayer(_ layer: ObjectIdentifier, movedTo position: CGPoint) {
    guard let anchor, let view = superview, ObjectIdentifier(view.layer) == layer, let map = Self.map(containing: view),
      let camera = takeCamera(placing: anchor, at: position)
    else { return }
    // A pan only shifts the camera; drawn relative to the anchor, the canvas is then unchanged.
    let sameScaleAndRotation = drawnCamera.map { $0.a == camera.a && $0.b == camera.b && $0.c == camera.c && $0.d == camera.d } ?? false
    drawnCamera = camera
    if !sameScaleAndRotation { redraw(on: map) }
  }

  /// The oldest queued camera that puts `anchor` at `position`, dropping it and every older one.
  private func takeCamera(placing anchor: Anchor, at position: CGPoint) -> CGAffineTransform? {
    let point = MKMapPoint(anchor.coordinate)
    guard let index = reportedCameras.firstIndex(where: { camera in
      let screen = CGPoint(x: point.x, y: point.y).applying(camera)
      return abs(screen.x - position.x) <= Self.cameraMatchTolerance && abs(screen.y - position.y) <= Self.cameraMatchTolerance
    }) else { return nil }
    let camera = reportedCameras[index]
    reportedCameras.removeFirst(index + 1)
    return camera
  }

  private static func map(containing view: UIView) -> MKMapView? {
    sequence(first: view, next: \.superview).lazy.compactMap { $0 as? MKMapView }.first
  }

  /// Redraws with the camera the anchor is placed for (the map's current one before any); call
  /// when the data changes and on a light/dark switch.
  func redraw(on map: MKMapView) {
    if drawnCamera == nil { drawnCamera = Self.camera(on: map) }
    guard let anchor, let toScreen = drawnCamera else { return }
    let anchorPoint = MKMapPoint(anchor.coordinate)
    let anchorScreen = CGPoint(x: anchorPoint.x, y: anchorPoint.y).applying(toScreen)
    let toCanvas = toScreen.concatenating(CGAffineTransform(translationX: -anchorScreen.x, y: -anchorScreen.y))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let traits = map.traitCollection
    let background = UIColor.systemBackground.resolvedColor(with: traits).cgColor
    let accent = map.tintColor.resolvedColor(with: traits).cgColor

    var relative = CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(toCanvas)
    let canvasPath = trackPath.flatMap { $0.copy(using: &relative) }
    casing.path = canvasPath
    line.path = canvasPath
    casing.strokeColor = background
    line.strokeColor = accent

    let pointsPerMapPoint = hypot(toScreen.a, toScreen.b)
    let latitude = MKMapPoint(x: map.visibleMapRect.midX, y: map.visibleMapRect.midY).coordinate.latitude
    let metresPerPoint = 1 / (pointsPerMapPoint * MKMapPointsPerMeterAtLatitude(latitude))
    let ringPath = CGMutablePath()
    let dotPath = CGMutablePath()
    if metresPerPoint <= Self.dotsMaximumMetresPerPoint {
      for stay in stays {
        let centre = CGPoint(x: stay.x, y: stay.y).applying(toCanvas)
        let outer = Self.dotDiameter / 2 + Self.dotRingWidth
        ringPath.addEllipse(in: CGRect(x: centre.x - outer, y: centre.y - outer, width: outer * 2, height: outer * 2))
        let inner = Self.dotDiameter / 2
        dotPath.addEllipse(in: CGRect(x: centre.x - inner, y: centre.y - inner, width: inner * 2, height: inner * 2))
      }
    }
    dotRings.path = ringPath
    dots.path = dotPath
    dotRings.fillColor = background
    dots.fillColor = accent
  }

  /// Map points to the map view's points for the current camera. Exact while the map is not
  /// pitched (pitch is off): Web Mercator to screen is then a rotation, scale and shift.
  private static func camera(on map: MKMapView) -> CGAffineTransform? {
    let visible = map.visibleMapRect
    guard visible.width > 0, map.bounds.width > 0 else { return nil }
    let step = visible.width / 4
    let p0 = MKMapPoint(x: visible.midX, y: visible.midY)
    let s0 = map.convert(p0.coordinate, toPointTo: map)
    let s1 = map.convert(MKMapPoint(x: p0.x + step, y: p0.y).coordinate, toPointTo: map)
    let s2 = map.convert(MKMapPoint(x: p0.x, y: p0.y + step).coordinate, toPointTo: map)
    let a = (s1.x - s0.x) / step
    let b = (s1.y - s0.y) / step
    let c = (s2.x - s0.x) / step
    let d = (s2.y - s0.y) / step
    return CGAffineTransform(a: a, b: b, c: c, d: d, tx: s0.x - a * p0.x - c * p0.y, ty: s0.y - b * p0.x - d * p0.y)
  }
}
