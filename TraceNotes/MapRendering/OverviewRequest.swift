import MapKit

/// What the overview reads for one viewport (D44): the tracks whose box meets the screen and a
/// margin around it, at the render-cache level for the zoom. A pan or pinch that stays inside the
/// margin at the same level needs no new read.
nonisolated struct OverviewRequest: Sendable {
  var box: GeoBox
  var level: Int
  /// Fog of World's cells are 2^fogShift pixels across here (D54 ④); nil when they are not shown.
  var fogShift: Int?
  /// The display-space rect `box` was made from.
  var rect: MKMapRect

  /// Extra room read on every side, as a share of the visible width and height.
  static let prefetchShare = 0.5

  init(visible: MKMapRect, level: Int, fogShift: Int? = nil) {
    let latitude = MKMapPoint(x: visible.midX, y: visible.midY).coordinate.latitude
    // The box is in stored (WGS-84) coordinates, the screen in display ones (D31).
    let shift = DisplayProjection.maximumShift * MKMapPointsPerMeterAtLatitude(latitude)
    rect = visible.insetBy(
      dx: -(visible.width * Self.prefetchShare + shift), dy: -(visible.height * Self.prefetchShare + shift))
    self.level = level
    self.fogShift = fogShift
    box = Self.box(for: rect)
  }

  /// Whether the tracks read for this request are all a `visible` rect at `level` needs.
  func covers(_ visible: MKMapRect, level: Int, fogShift: Int? = nil) -> Bool {
    level == self.level && fogShift == self.fogShift && rect.contains(visible)
  }

  /// D54 ④: the coarsest grid whose cells are at most half of `lineWidth` screen points across:
  /// lines between cell centres then step by no more than a quarter of their width either side, so
  /// a diagonal path does not look like a staircase (simulator finding with whole-width cells).
  static func fogShift(pointsPerMapPoint: Double, lineWidth: Double) -> Int {
    let mapPointsPerPixel = MKMapRect.world.width / Double(FogOfWorld.pixelsPerSide)
    let pixelsPerCell = lineWidth / 2 / (pointsPerMapPoint * mapPointsPerPixel)
    guard pixelsPerCell >= 2 else { return 0 }
    return min(Int(log2(pixelsPerCell).rounded(.down)), Self.maximumFogShift)
  }

  /// At most the whole world in one cell.
  private static let maximumFogShift = FogOfWorld.pixelsPerSide.trailingZeroBitCount

  /// The latitudes and longitudes of a map rect, split at the antimeridian. Map points run past the
  /// world's edge when the map shows ±180°.
  static func box(for rect: MKMapRect) -> GeoBox {
    let world = MKMapRect.world
    let north = MKMapPoint(x: world.midX, y: max(world.minY, rect.minY)).coordinate.latitude
    let south = MKMapPoint(x: world.midX, y: min(world.maxY, rect.maxY)).coordinate.latitude
    let degreesPerMapPoint = 360 / world.width
    let span = rect.width * degreesPerMapPoint
    guard span < 360 else { return GeoBox(latitudes: south...north, longitudes: [-180...180]) }
    var west = (rect.minX - world.minX) * degreesPerMapPoint - 180
    west -= 360 * ((west + 180) / 360).rounded(.down)
    let east = west + span
    let longitudes = east <= 180 ? [west...east] : [west...180, -180...(east - 360)]
    return GeoBox(latitudes: south...north, longitudes: longitudes)
  }
}

extension OverviewRequest: Equatable {
  static func == (lhs: OverviewRequest, rhs: OverviewRequest) -> Bool {
    lhs.box == rhs.box && lhs.level == rhs.level && lhs.fogShift == rhs.fogShift
  }
}
