//
//  MapScreen.swift
//  Wander
//

import SwiftUI
import MapKit

struct MapScreen: View {
    @ObservedObject private var engine = SimulationEngine.shared
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @ObservedObject private var places = PlaceStore.shared
    @StateObject private var planner = Planner()
    @StateObject private var search = PlaceSearch()

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var followWalker = true
    @State private var mapStyleSatellite = false

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    @State private var showSettings = false
    @State private var showPlaces = false
    @State private var showPairingImporter = false
    @State private var showRouteImporter = false

    @State private var favouriteTarget: GeoPoint?
    @State private var favouriteName = ""

    var body: some View {
        ZStack(alignment: .top) {
            map

            VStack(spacing: 8) {
                topBar
                if searchFocused || !search.results.isEmpty {
                    searchResults
                }
                HStack {
                    ConnectionBadge(monitor: monitor) { showSettings = true }
                    Spacer()
                    mapButtons
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
            ControlPanel(
                engine: engine,
                planner: planner,
                monitor: monitor,
                importPairingFile: { showPairingImporter = true },
                importRoute: { showRouteImporter = true },
                openSettings: { showSettings = true },
                saveFavourite: { point in
                    favouriteName = ""
                    favouriteTarget = point
                }
            )
        }
        .onChange(of: engine.currentPoint) { _, newPoint in
            guard followWalker, engine.isMoving, let newPoint else { return }
            withAnimation(.linear(duration: 1)) {
                position = .region(MKCoordinateRegion(
                    center: newPoint.coordinate,
                    span: visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
            }
        }
        .onChange(of: planner.preview) { _, preview in
            if let preview, !engine.isMoving {
                frame(preview.points)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(monitor: monitor, engine: engine, showPairingImporter: $showPairingImporter)
        }
        .sheet(isPresented: $showPlaces) {
            PlacesSheet(store: places) { place in
                choose(place)
            }
            .presentationDetents([.medium, .large])
        }
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importPairingFile(result)
        }
        .background {
            // A second importer can't share a view with the first one.
            Color.clear
                .fileImporter(
                    isPresented: $showRouteImporter,
                    allowedContentTypes: CoordinateImportParser.supportedContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    importRoute(result)
                }
        }
        .alert("Save to Favourites", isPresented: Binding(
            get: { favouriteTarget != nil },
            set: { if !$0 { favouriteTarget = nil } }
        )) {
            TextField("Name", text: $favouriteName)
            Button("Save") {
                if let favouriteTarget {
                    places.addFavourite(name: favouriteName, point: favouriteTarget)
                }
                favouriteTarget = nil
            }
            Button("Cancel", role: .cancel) { favouriteTarget = nil }
        } message: {
            Text(favouriteTarget?.formatted ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPairingFilePicker)) { _ in
            showPairingImporter = true
        }
    }

    // MARK: - Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                mapContent
            }
            .mapStyle(mapStyleSatellite ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { screenPoint in
                searchFocused = false
                search.clear()
                guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                planner.handleTap(GeoPoint(coordinate))
                Haptics.selection()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                if position.positionedByUser {
                    followWalker = false
                }
            }
        }
        .ignoresSafeArea()
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        if let route = engine.route {
            let walked = route.walkedPortion(upTo: engine.distanceWalked)
            if walked.count >= 2 {
                MapPolyline(coordinates: walked.coordinates)
                    .stroke(.gray.opacity(0.6), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            MapPolyline(coordinates: route.remainingPortion(from: engine.distanceWalked).coordinates)
                .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }

        if let preview = planner.preview {
            MapPolyline(coordinates: preview.points.coordinates)
                .stroke(.purple, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [2, 9]))
        }

        if planner.mode == .draw {
            ForEach(Array(planner.waypoints.enumerated()), id: \.offset) { index, point in
                Annotation("", coordinate: point.coordinate) {
                    Text("\(index + 1)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.purple))
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }

        if planner.mode == .pin, let pin = planner.pin {
            Marker(pin.name, systemImage: "mappin", coordinate: pin.point.coordinate)
                .tint(.red)
        }

        if planner.mode == .walk {
            if engine.currentPoint == nil, let start = planner.walkStart {
                Marker("Start", systemImage: "figure.walk", coordinate: start.point.coordinate)
                    .tint(.green)
            }
            if let destination = planner.destination {
                Marker(destination.name, systemImage: "flag.fill", coordinate: destination.point.coordinate)
                    .tint(.red)
            }
        }

        if let point = engine.currentPoint {
            Annotation("", coordinate: point.coordinate, anchor: .center) {
                WalkerDot(phase: engine.phase)
            }
        }
    }

    private var mapButtons: some View {
        VStack(spacing: 0) {
            Button {
                mapStyleSatellite.toggle()
            } label: {
                Image(systemName: mapStyleSatellite ? "map" : "globe.americas")
                    .frame(width: 40, height: 40)
            }
            Divider().frame(width: 40)
            Button {
                followWalker = true
                if let point = engine.currentPoint {
                    withAnimation {
                        position = .region(MKCoordinateRegion(center: point.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
                    }
                } else {
                    position = .userLocation(fallback: .automatic)
                }
            } label: {
                Image(systemName: followWalker && engine.isMoving ? "location.fill" : "location")
                    .frame(width: 40, height: 40)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Search

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPrompt, text: $searchText)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _, query in
                        search.update(query: query, near: visibleRegion)
                    }
                    .onSubmit(submitSearch)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        search.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())

            circleButton("star.fill", label: "Places") { showPlaces = true }
            circleButton("gearshape.fill", label: "Settings") { showSettings = true }
        }
    }

    private var searchPrompt: String {
        switch planner.mode {
        case .pin: return "Search or enter coordinates"
        case .walk: return "Where to?"
        case .draw: return "Add a place to the route"
        }
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            ForEach(search.results, id: \.self) { result in
                Button {
                    Task { await select(result) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if result != search.results.last {
                    Divider().padding(.leading, 14)
                }
            }
            if search.results.isEmpty, !places.recents.isEmpty, searchText.isEmpty {
                ForEach(places.recents.prefix(4)) { place in
                    Button {
                        choose(place)
                    } label: {
                        Label(place.name, systemImage: "clock")
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func submitSearch() {
        let coordinates = CoordinateImportParser.parseInline(searchText)
        if coordinates.count == 1, let coordinate = coordinates.first {
            let point = GeoPoint(coordinate)
            choose(Place(name: point.formatted, point: point))
        } else if let first = search.results.first {
            Task { await select(first) }
        }
    }

    private func select(_ result: MKLocalSearchCompletion) async {
        do {
            let place = try await search.resolve(result)
            choose(place)
        } catch {
            planner.planError = error.localizedDescription
        }
    }

    private func choose(_ place: Place) {
        searchFocused = false
        searchText = ""
        search.clear()
        planner.handlePlace(place)
        if planner.preview == nil {
            withAnimation {
                position = .region(MKCoordinateRegion(center: place.point.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
            }
        }
    }

    // MARK: - Helpers

    private func frame(_ points: [GeoPoint]) {
        guard !points.isEmpty else { return }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.003),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.003)
        )
        withAnimation {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    private func circleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 42, height: 42)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func importPairingFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try PairingFileStore.importFromPicker(url)
                monitor.refresh()
                monitor.reconnect(showErrors: true)
            } catch {
                showAlert(title: "Import Failed", message: error.localizedDescription, showOk: true)
            }
        case .failure(let error):
            showAlert(title: "Import Failed", message: error.localizedDescription, showOk: true)
        }
    }

    private func importRoute(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let coordinates = try CoordinateImportParser.parse(url: url)
            planner.loadImportedTrack(coordinates.map(GeoPoint.init))
            if let preview = planner.preview {
                frame(preview.points)
            }
        } catch {
            planner.planError = error.localizedDescription
        }
    }
}

/// The simulated position on the map.
struct WalkerDot: View {
    let phase: SimulationEngine.Phase

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 44, height: 44)
            Circle()
                .fill(color)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(radius: 3)
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var color: Color {
        phase == .paused ? .orange : .blue
    }

    private var icon: String {
        switch phase {
        case .walking: return "figure.walk"
        case .paused: return "pause.fill"
        default: return "location.fill"
        }
    }
}
