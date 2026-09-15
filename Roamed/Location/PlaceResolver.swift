import Foundation
import CoreLocation
import RoamedCore

/**
 Names the countries and regions you pass through, so the stats screen can say "17 countries"
 rather than only "0.004% of the planet".

 Deliberately lazy: it only asks the geocoder when a fix lands in a ~150 km square that has not
 been asked about before, so a day of commuting costs at most one lookup. That restraint is not
 only about politeness - Apple rate-limits reverse geocoding per app, and a tracker that asked on
 every fix would be throttled into uselessness within the hour. Everything about it is best effort:
 no network, no answer, no problem.
 */
final class PlaceResolver: @unchecked Sendable {

    /// z6 squares are roughly 150 km across at mid latitudes - about one lookup per region.
    private static let regionZoom = 6
    private static let minimumSecondsBetweenLookups: TimeInterval = 30

    private let geocoder = CLGeocoder()
    private let lock = NSLock()
    private var asked = Set<CellKeyValue>()
    private var lastLookupAt = Date.distantPast

    /// Returns a place to record, or nil if there is nothing new (or nothing knowable).
    func resolve(_ fix: Fix) async -> VisitedPlaceRow? {
        let region = CellKey.pack(
            TileMath.cellX(fix.longitude, PlaceResolver.regionZoom),
            TileMath.cellY(fix.latitude, PlaceResolver.regionZoom)
        )
        lock.lock()
        let alreadyAsked = asked.contains(region)
        let tooSoon = Date().timeIntervalSince(lastLookupAt) < PlaceResolver.minimumSecondsBetweenLookups
        if alreadyAsked || tooSoon {
            lock.unlock()
            return nil
        }
        asked.insert(region)
        lastLookupAt = Date()
        lock.unlock()

        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        let placemark: CLPlacemark?
        do {
            placemark = try await geocoder.reverseGeocodeLocation(location).first
        } catch {
            placemark = nil
        }

        guard let placemark, let countryCode = placemark.isoCountryCode, !countryCode.isEmpty else {
            // Let a failed lookup be retried later rather than poisoning the region forever.
            lock.lock()
            asked.remove(region)
            lock.unlock()
            return nil
        }
        return VisitedPlaceRow(
            countryCode: countryCode,
            countryName: placemark.country ?? countryCode,
            adminArea: placemark.administrativeArea ?? "",
            firstSeen: fix.timestamp,
            lastSeen: fix.timestamp
        )
    }
}
