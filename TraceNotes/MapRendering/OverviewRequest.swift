import MapKit

/// What the overview reads for one viewport (D44): the tracks whose box meets the screen and a
/// margin around it, at the render-cache level for the zoom. A pan or pinch that stays inside the
/// margin at the same level needs no new read.
nonisolated struct OverviewRequest: Sendable {
  var box: GeoBox
  var level: Int
  /// The display-space rect `box` was made from.
  var rect: MKMapRect

  /// Extra room read on every side, as a share of the visible width and height.
  static let prefetchShare = 0.5

  init(visible: MKMapRect, level: Int) {
    let latitude = MKMapPoint(x: visible.midX, y: visible.midY).coordinate.latitude
    // The box is in stored (WGS-84) coordinates, the screen in display ones (D31).
    let shift = DisplayProjection.maximumShift * MKMapPointsPerMeterAtLatitude(latitude)
    rect = visible.insetBy(
      dx: -(visible.width * Self.prefetchShare + shift), dy: -(visible.height * Self.prefetchShare + shift))
    self.level = level
    box = Self.box(for: rect)
  }

  /// Whether the tracks read for this request are all a `visible` rect at `level` needs.
  func covers(_ visible: MKMapRect, level: Int) -> Bool {
    level == self.level && rect.contains(visible)
  }

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
    lhs.box == rhs.box && lhs.level == rhs.level
  }
}
