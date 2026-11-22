import MapKit
import UIKit
import os

/// Draws the day over the map (D39, D40): the track as one smooth Bézier path and the stays as
/// small dots, plus a grey layer that turns the base map monochrome in light and dark mode.
///
/// MapKit presents its map a frame after UIKit commits, so a view laid over the map led it by a
/// frame while panning (device finding: the track "floated"). Annotation views are moved by MapKit
/// in step with the map, so the canvas lives inside one: an `Anchor` annotation near the middle of
/// the screen, and the canvas draws relative to it. MapKit drops the views of annotations that
/// leave the screen, so a new pair of anchors takes over before that.
///
/// Zooming and rotating need a redraw at the scale MapKit is showing. The camera the delegate
/// reports runs ahead of the map, and MapKit may show cameras the delegate never reports (device
/// finding: the line still drifted while a pinch was held). So a second anchor sits a little below
/// the first, and the scale and rotation come from where MapKit itself puts the two (D40): two
/// points fix a flat map's scale, rotation and shift exactly.
///
/// MapKit has no greyscale map, so a grey view with a saturation blend sits between the map and
/// the annotation views; the track, the dots and the user-location dot stay in colour above it.
final class TrackCanvas: UIView {
  /// An annotation whose view carries or measures the canvas. It never moves: a new pair replaces
  /// it when the map has moved far from it.
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
        let layer = ObjectIdentifier(self)
        let canvas = canvas
        MainActor.assumeIsolated { canvas?.anchorLayerMoved(layer) }
      }
    }
  }

  private final class AnchorView: MKAnnotationView {
    override class var layerClass: AnyClass { AnchorLayer.self }
  }

  /// The canvas lives in `primary`'s view; `secondary` only measures the scale and rotation.
  private struct Pair {
    let primary: Anchor
    let secondary: Anchor
    var primaryView: MKAnnotationView?
    var secondaryView: MKAnnotationView?

    func contains(_ annotation: (any MKAnnotation)?) -> Bool {
      annotation === primary || annotation === secondary
    }
  }

  /// The pair in use, and the one waiting for MapKit to add both views.
  private var pair: Pair?
  private var pendingPair: Pair?
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
  /// Map-point offsets to screen-point offsets (scale and rotation only) the canvas is drawn with.
  private var drawnScale: CGAffineTransform?

  /// Screen points, the same at every zoom level (F7).
  static let lineWidth: CGFloat = 5
  static let casingWidth: CGFloat = 8
  static let dotDiameter: CGFloat = 10
  static let dotRingWidth: CGFloat = 2.5
  /// Stay dots appear from about neighbourhood scale (≈ 2 km across a phone screen); further out
  /// the day reads as lines only (device feedback, D39).
  static let dotsMaximumMetresPerPoint = 5.0
  /// Shares of the screen's shorter side: the secondary anchor starts this far below the primary
  /// (far enough that a rounding of its position changes the scale by well under a percent)...
  static let anchorSeparationShare = 0.3
  /// ...and a new pair takes over once either anchor is this far from the middle (before MapKit
  /// drops its view for being off screen) or the two have come this close (zooming out).
  static let anchorReplacementShare = 0.45
  static let anchorMinimumSeparationShare = 0.15

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

  /// Adds a new pair in the middle of the screen when there is none, or when the current one has
  /// drifted towards the edge or shrunk. It takes over in `adopt` once MapKit has added both views.
  func keepAnchorsNearCentre(on map: MKMapView) {
    guard pendingPair == nil, map.bounds.width > 0, map.visibleMapRect.width > 0 else { return }
    let shorter = min(map.bounds.width, map.bounds.height)
    let centre = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
    if let pair {
      let first = map.convert(pair.primary.coordinate, toPointTo: map)
      let second = map.convert(pair.secondary.coordinate, toPointTo: map)
      let drifted = max(hypot(first.x - centre.x, first.y - centre.y), hypot(second.x - centre.x, second.y - centre.y))
        > shorter * Self.anchorReplacementShare
      let shrunk = hypot(second.x - first.x, second.y - first.y) < shorter * Self.anchorMinimumSeparationShare
      guard drifted || shrunk else { return }
    }
    let below = CGPoint(x: centre.x, y: centre.y + shorter * Self.anchorSeparationShare)
    let next = Pair(
      primary: Anchor(map.convert(centre, toCoordinateFrom: map)), secondary: Anchor(map.convert(below, toCoordinateFrom: map)))
    pendingPair = next
    map.addAnnotations([next.primary, next.secondary])
  }

  /// Collects the pending pair's views as MapKit adds them; once both exist, moves the canvas into
  /// the new primary view, draws from the new pair in the same pass (so the track does not move on
  /// screen) and removes the old pair. Other views are ignored.
  func adopt(_ view: MKAnnotationView, on map: MKMapView) {
    guard var next = pendingPair, next.contains(view.annotation) else { return }
    if view.annotation === next.primary { next.primaryView = view } else { next.secondaryView = view }
    guard let primaryView = next.primaryView, next.secondaryView != nil else {
      pendingPair = next
      return
    }
    let old = pair
    pair = next
    pendingPair = nil
    primaryView.addSubview(self)
    redrawFromAnchors(on: map, force: true)
    if let old { map.removeAnnotations([old.primary, old.secondary]) }
    if !placeGrey(below: primaryView) {
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

  /// The map has settled: draw from where the anchors ended up (a zoom exactly about an anchor may
  /// not move it, and a level change waits for the next move otherwise).
  func mapDidSettle(_ map: MKMapView) {
    redrawFromAnchors(on: map, force: true)
  }

  /// MapKit moved one of the current pair's views: follow it.
  fileprivate func anchorLayerMoved(_ layer: ObjectIdentifier) {
    guard let pair, let primaryView = pair.primaryView, let secondaryView = pair.secondaryView,
      ObjectIdentifier(primaryView.layer) == layer || ObjectIdentifier(secondaryView.layer) == layer,
      let map = Self.map(containing: primaryView)
    else { return }
    redrawFromAnchors(on: map, force: false)
  }

  /// Takes the scale and rotation from the two anchors' positions as MapKit placed them. A pan only
  /// shifts both, and the canvas, drawn relative to the primary anchor, is then unchanged; so the
  /// path is only rebuilt when the scale or rotation differ (or when forced).
  private func redrawFromAnchors(on map: MKMapView, force: Bool) {
    guard let pair, let primaryView = pair.primaryView, let secondaryView = pair.secondaryView else { return }
    let first = MKMapPoint(pair.primary.coordinate)
    let second = MKMapPoint(pair.secondary.coordinate)
    let mapX = second.x - first.x
    let mapY = second.y - first.y
    let screenX = secondaryView.layer.position.x - primaryView.layer.position.x
    let screenY = secondaryView.layer.position.y - primaryView.layer.position.y
    let lengthSquared = mapX * mapX + mapY * mapY
    guard lengthSquared > 0 else { return }
    // screen = k · map as complex numbers: k = screen · conj(map) / |map|² (Web Mercator and the
    // screen both have y pointing down, so there is no reflection).
    let real = (screenX * mapX + screenY * mapY) / lengthSquared
    let imaginary = (screenY * mapX - screenX * mapY) / lengthSquared
    let scale = CGAffineTransform(a: real, b: imaginary, c: -imaginary, d: real, tx: 0, ty: 0)
    guard force || drawnScale != scale else { return }
    drawnScale = scale
    redraw(on: map)
  }

  private static func map(containing view: UIView) -> MKMapView? {
    sequence(first: view, next: \.superview).lazy.compactMap { $0 as? MKMapView }.first
  }

  /// Redraws relative to the primary anchor at the scale it was last placed at (the map's current
  /// one before the anchors exist); call when the data changes and on a light/dark switch.
  func redraw(on map: MKMapView) {
    if drawnScale == nil, let camera = Self.camera(on: map) {
      drawnScale = CGAffineTransform(a: camera.a, b: camera.b, c: camera.c, d: camera.d, tx: 0, ty: 0)
    }
    guard let pair, let scale = drawnScale else { return }
    let anchorPoint = MKMapPoint(pair.primary.coordinate)
    // Map points to canvas points: relative to the anchor, then scaled and rotated.
    let toCanvas = CGAffineTransform(translationX: -anchorPoint.x, y: -anchorPoint.y).concatenating(scale)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let traits = map.traitCollection
    let background = UIColor.systemBackground.resolvedColor(with: traits).cgColor
    let accent = map.tintColor.resolvedColor(with: traits).cgColor

    var relative = CGAffineTransform(translationX: origin.x - anchorPoint.x, y: origin.y - anchorPoint.y).concatenating(scale)
    let canvasPath = trackPath.flatMap { $0.copy(using: &relative) }
    casing.path = canvasPath
    line.path = canvasPath
    casing.strokeColor = background
    line.strokeColor = accent

    let pointsPerMapPoint = hypot(scale.a, scale.b)
    let metresPerPoint = 1 / (pointsPerMapPoint * MKMapPointsPerMeterAtLatitude(pair.primary.coordinate.latitude))
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

  /// Map points to the map view's points for the current camera, from `convert`; only used before
  /// the anchors exist. Exact while the map is not pitched (pitch is off).
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
