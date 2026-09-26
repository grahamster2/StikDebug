//
//  PlaceStore.swift
//  Wander
//

import Foundation
import MapKit

struct Place: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var point: GeoPoint
    var date = Date()
}

/// Favourites and recently used locations, stored on the device.
@MainActor
final class PlaceStore: ObservableObject {
    static let shared = PlaceStore()

    @Published private(set) var favourites: [Place] = []
    @Published private(set) var recents: [Place] = []

    private static let favouritesKey = "favouritePlaces"
    private static let recentsKey = "recentPlaces"
    private static let maxRecents = 30

    private init() {
        favourites = Self.load(Self.favouritesKey)
        recents = Self.load(Self.recentsKey)
    }

    func addFavourite(name: String, point: GeoPoint) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        favourites.insert(Place(name: trimmed.isEmpty ? point.formatted : trimmed, point: point), at: 0)
        save()
    }

    func removeFavourites(at offsets: IndexSet) {
        favourites.remove(atOffsets: offsets)
        save()
    }

    func isFavourite(_ point: GeoPoint) -> Bool {
        favourites.contains { $0.point.distance(to: point) < 5 }
    }

    func recordRecent(name: String?, point: GeoPoint) {
        recents.removeAll { $0.point.distance(to: point) < 10 }
        recents.insert(Place(name: name ?? point.formatted, point: point), at: 0)
        if recents.count > Self.maxRecents {
            recents.removeLast(recents.count - Self.maxRecents)
        }
        save()
    }

    func clearRecents() {
        recents = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        UserDefaults.standard.set(try? encoder.encode(favourites), forKey: Self.favouritesKey)
        UserDefaults.standard.set(try? encoder.encode(recents), forKey: Self.recentsKey)
    }

    private static func load(_ key: String) -> [Place] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let places = try? JSONDecoder().decode([Place].self, from: data) else {
            return []
        }
        return places
    }
}

/// Place search backed by Apple Maps autocomplete.
@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, near region: MKCoordinateRegion?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        if let region {
            completer.region = region
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        results = []
        completer.queryFragment = ""
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Place {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Apple Maps couldn't locate that place."])
        }
        return Place(name: completion.title, point: GeoPoint(item.placemark.coordinate))
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = Array(results.prefix(6)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}
