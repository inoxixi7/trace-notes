import Foundation
import GRDB
import MapKit
import os

/// Pipeline step ⑤ (ARCHITECTURE §5.1): names new places one at a time, in the background of the
/// app, and retries failed lookups later (F5: offline or failed → "unknown place", retried).
nonisolated final class PlaceResolver: Sendable {
  /// What a lookup found for a place.
  struct Lookup: Equatable, Sendable {
    var name: String?
    var address: String?
    /// ISO 3166 region code; nil where the lookup names none.
    var countryCode: String? = nil
  }

  typealias LookupFunction = @Sendable (_ latitude: Double, _ longitude: Double) async throws -> Lookup

  /// Places looked up per wake-up; the rest wait for the next one, which keeps the request rate
  /// low (Apple throttles bursts).
  static let batchSize = 5

  private let database: AppDatabase
  private let lookup: LookupFunction

  init(database: AppDatabase, lookup: @escaping LookupFunction = PlaceResolver.appleMaps) {
    self.database = database
    self.lookup = lookup
  }

  /// Looks up due places whenever a new place appears or points arrive, until cancelled.
  func run() async throws {
    for try await _ in database.observePlaceWork() {
      try await resolveDue(at: .now)
    }
  }

  /// One pass over the places due at `now`. Lookup failures are stored for a retry; only database
  /// errors are thrown.
  func resolveDue(at now: Date) async throws {
    for var place in try await database.placesToResolve(at: now, limit: Self.batchSize) {
      do {
        let found = try await lookup(place.latitude, place.longitude)
        if !place.needsCountryOnly {
          place.name = found.name
          place.address = found.address
          place.status = .resolved
        }
        place.countryCode = found.countryCode
        place.countryStatus = .resolved
        place.attempts += 1
        place.lastAttemptAt = now
        place.nextAttemptAt = nil
        try await database.saveLookup(of: place)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        place.recordFailure(at: now)
        AppLog.processing.notice(
          "place lookup failed (attempt \(place.attempts)): \(error.localizedDescription, privacy: .public)")
        try await database.saveLookup(of: place)
        // A throttled or offline lookup fails the same way for the next place too.
        return
      }
    }
  }

  // MARK: - Apple Maps

  /// Point-of-interest categories that never name a stay: street furniture next to the real place.
  static let ignoredCategories: Set<MKPointOfInterestCategory> = [.atm, .evCharger, .mailbox, .restroom]

  /// The nearest point of interest within `Place.matchRadius` (D37), and the address from reverse
  /// geocoding. Both send the coordinate to Apple (F5). No point of interest is not an error.
  @Sendable static func appleMaps(latitude: Double, longitude: Double) async throws -> Lookup {
    let location = CLLocation(latitude: latitude, longitude: longitude)
    var lookup = Lookup()
    let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: Place.matchRadius)
    do {
      let items = try await MKLocalSearch(request: request).start().mapItems
      lookup.name = items
        .filter { item in
          guard let category = item.pointOfInterestCategory else { return false }
          return !ignoredCategories.contains(category) && item.name?.isEmpty == false
        }
        .min { $0.location.distance(from: location) < $1.location.distance(from: location) }?
        .name
    } catch let error as MKError where error.code == .placemarkNotFound {
      // Nothing nearby: the address names the place.
    }
    guard let reverse = MKReverseGeocodingRequest(location: location) else {
      throw LookupError.invalidCoordinate
    }
    let item = try await reverse.mapItems.first
    lookup.address = item?.address?.shortAddress ?? item?.address?.fullAddress
    lookup.countryCode = item?.addressRepresentations?.region?.identifier
    if lookup.name == nil, lookup.address == nil { throw LookupError.nothingFound }
    return lookup
  }

  enum LookupError: Error {
    case invalidCoordinate
    case nothingFound
  }
}
