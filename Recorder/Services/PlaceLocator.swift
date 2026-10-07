import Foundation
import CoreLocation
import MapKit

/// Where a transcript was started: one location fix and a readable place name ("Mitte, Berlin").
nonisolated struct RecordingPlace: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var name: String?
}

/// One-shot location lookup when a recording starts. Denied, offline or no fix within the timeout simply yields no place
/// (or coordinates without a name), never an error. The place name comes from Apple's reverse geocoding, which sends
/// the coordinates to Apple; audio and text stay local.
/// "Save Location" (Settings › Recording, on by default, like Voice Memos' location-based naming) turns it off. The
/// permission isn't asked when a recording starts: the system alert then covered the first live recording right after
/// the microphone's (HIG: ask in context, without interrupting). While it is undetermined, the first recording asks at
/// its Stop instead (RecordingSession), so that transcript gets where it ended, and every later one where it started.
/// With Precise Location off the fix is several km wide; it is accepted then (`accuracyLimited`), since only the town
/// or district is shown. Before, fixes over 1 km were dropped and such users never got a place.
@MainActor
enum PlaceLocator {
    /// UserDefaults key of "Save Location"; absent means on.
    nonisolated static let saveLocationKey = "saveLocation"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: saveLocationKey) as? Bool ?? true }

    /// The user hasn't answered the location prompt yet.
    static var isUndetermined: Bool { CLLocationManager().authorizationStatus == .notDetermined }

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
                        let limit: CLLocationAccuracy = update.accuracyLimited ? 20_000 : 1_000
                        if let location = update.location, location.horizontalAccuracy >= 0,
                           location.horizontalAccuracy <= limit {
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
