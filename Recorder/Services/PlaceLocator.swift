import Foundation
import CoreLocation
import MapKit

/// Where a transcript was started: one location fix and a readable place name ("Mitte, Berlin").
nonisolated struct RecordingPlace: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var name: String?
}

/// One-shot location lookup when a recording starts. Asks for "While Using" permission the first time; denied, offline
/// or no fix within the timeout simply yields no place (or coordinates without a name), never an error.
/// The place name comes from Apple's reverse geocoding, which sends the coordinates to Apple; audio and text stay local.
@MainActor
enum PlaceLocator {
    static func current(timeout: Duration = .seconds(15)) async -> RecordingPlace? {
        let session = CLServiceSession(authorization: .whenInUse)   // shows the permission prompt once
        defer { session.invalidate() }
        guard let location = await firstFix(timeout: timeout) else { return nil }
        var place = RecordingPlace(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        if let request = MKReverseGeocodingRequest(location: location),
           let item = try? await request.mapItems.first {
            place.name = item.addressRepresentations?.cityWithContext ?? item.address?.shortAddress
        }
        return place
    }

    /// The first reasonably accurate fix, or nil when permission is missing or nothing arrives within `timeout`.
    private static func firstFix(timeout: Duration) async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                            return nil
                        }
                        if let location = update.location, location.horizontalAccuracy >= 0,
                           location.horizontalAccuracy <= 1_000 {
                            return location
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension Recording {
    func apply(_ place: RecordingPlace) {
        latitude = place.latitude
        longitude = place.longitude
        placeName = place.name
    }
}
