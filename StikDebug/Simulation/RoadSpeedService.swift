//
//  RoadSpeedService.swift
//  Wander
//
//  Looks up the roads along a driving route in OpenStreetMap (via the public
//  Overpass API): speed limits, road types, stop signs and traffic lights.
//

import Foundation
import CoreLocation

enum RoadSpeedService {
    struct Result {
        var profile: DriveProfile
        /// Why road data is missing, if it is.
        var problem: String?
    }

    private static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!
    ]

    private static let drivableRoads = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|road|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"

    /// Builds a drive profile for a route. Corners always work; road speeds
    /// and stops need the network and are skipped if it fails.
    static func profile(for route: WalkRoute) async -> Result {
        var profile = DriveProfile(caps: DriveProfile.cornerCaps(for: route))
        do {
            let data = try await fetch(for: route)
            try Task.checkCancellation()
            let osm = try JSONDecoder().decode(OverpassResponse.self, from: data)
            let matched = match(route: route, osm: osm)
            profile.segments = matched.segments
            profile.stops = matched.stops
            if matched.segments.isEmpty {
                return Result(profile: profile, problem: "No road data found along this route.")
            }
            return Result(profile: profile, problem: nil)
        } catch is CancellationError {
            return Result(profile: profile, problem: nil)
        } catch {
            return Result(profile: profile, problem: "Couldn't load road speed limits (\(error.localizedDescription)).")
        }
    }

    // MARK: - Network

    private static func fetch(for route: WalkRoute) async throws -> Data {
        let outline = simplified(route.points, tolerance: 6)
        let coordinates = outline
            .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
            .joined(separator: ",")
        let query = """
        [out:json][timeout:40];
        way(around:20,\(coordinates))[highway~"^(\(drivableRoads))$"]->.roads;
        .roads out body geom;
        node(w.roads)[highway~"^(stop|traffic_signals|give_way)$"];
        out body;
        """

        var lastError: Error = URLError(.cannotConnectToHost)
        for endpoint in endpoints {
            var request = URLRequest(url: endpoint, timeoutInterval: 45)
            request.httpMethod = "POST"
            request.setValue("Wander/0.1 (personal location simulator)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [URLQueryItem(name: "data", value: query)]
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    lastError = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "server busy (HTTP \(http.statusCode))"])
                    continue
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    private struct OverpassResponse: Decodable {
        let elements: [Element]

        struct Element: Decodable {
            let type: String
            let id: Int64
            let lat: Double?
            let lon: Double?
            let tags: [String: String]?
            let nodes: [Int64]?
            let geometry: [LatLon?]?
        }

        struct LatLon: Decodable {
            let lat: Double
            let lon: Double
        }
    }

    // MARK: - Matching

    /// A flat x/y projection in metres, accurate enough over a city or two.
    private struct Projection {
        let lat0: Double
        let lon0: Double
        let metersPerDegreeLon: Double

        init(origin: GeoPoint) {
            lat0 = origin.latitude
            lon0 = origin.longitude
            metersPerDegreeLon = 111_320 * cos(origin.latitude * .pi / 180)
        }

        func xy(_ lat: Double, _ lon: Double) -> SIMD2<Double> {
            SIMD2((lon - lon0) * metersPerDegreeLon, (lat - lat0) * 110_540)
        }
    }

    private struct Road {
        let points: [SIMD2<Double>]
        let nodeIDs: [Int64]
        let minCorner: SIMD2<Double>
        let maxCorner: SIMD2<Double>
        let limit: CLLocationSpeed
        let isPosted: Bool
        let name: String?
    }

    private static func match(route: WalkRoute, osm: OverpassResponse) -> (segments: [DriveProfile.Segment], stops: [DriveProfile.Stop]) {
        let projection = Projection(origin: route.start)
        let usesMiles = Locale.current.measurementSystem == .us

        var roads: [Road] = []
        for element in osm.elements where element.type == "way" {
            guard let tags = element.tags,
                  let highway = tags["highway"],
                  let geometry = element.geometry else { continue }
            let points = geometry.compactMap { $0.map { projection.xy($0.lat, $0.lon) } }
            guard points.count >= 2 else { continue }

            let posted = tags["maxspeed"].flatMap(parseSpeedLimit)
            let limit = posted ?? typicalSpeed(for: highway, miles: usesMiles)
            var minCorner = points[0]
            var maxCorner = points[0]
            for point in points {
                minCorner = pointwiseMin(minCorner, point)
                maxCorner = pointwiseMax(maxCorner, point)
            }
            roads.append(Road(
                points: points,
                nodeIDs: element.nodes ?? [],
                minCorner: minCorner - 20,
                maxCorner: maxCorner + 20,
                limit: limit,
                isPosted: posted != nil,
                name: tags["name"] ?? tags["ref"]
            ))
        }
        guard !roads.isEmpty else { return ([], []) }

        // Walk the route every 15 m and find which road each stretch is on.
        let step: CLLocationDistance = 15
        var samples: [(distance: CLLocationDistance, road: Int?)] = []
        var distance: CLLocationDistance = 0
        while distance <= route.totalDistance {
            let here = route.point(atDistance: distance)
            let ahead = route.point(atDistance: min(distance + 8, route.totalDistance))
            let behind = route.point(atDistance: max(distance - 8, 0))
            let position = projection.xy(here.latitude, here.longitude)
            let heading = projection.xy(ahead.latitude, ahead.longitude) - projection.xy(behind.latitude, behind.longitude)
            samples.append((distance, nearestRoad(to: position, heading: heading, in: roads)))
            distance += step
        }

        // Fill gaps (bridges, parking lots, missing data) from the neighbours.
        var filled = samples.map(\.road)
        var lastKnown: Int?
        for index in filled.indices {
            if let road = filled[index] { lastKnown = road } else { filled[index] = lastKnown }
        }
        lastKnown = nil
        for index in filled.indices.reversed() {
            if let road = filled[index] { lastKnown = road } else { filled[index] = lastKnown }
        }

        var segments: [DriveProfile.Segment] = []
        for (index, sample) in samples.enumerated() {
            guard let roadIndex = filled[index] else { continue }
            let road = roads[roadIndex]
            let end = min(sample.distance + step, route.totalDistance)
            if var last = segments.last, last.limit == road.limit, last.name == road.name {
                last.end = end
                segments[segments.count - 1] = last
            } else {
                if !segments.isEmpty {
                    segments[segments.count - 1].end = sample.distance
                }
                segments.append(DriveProfile.Segment(
                    start: segments.isEmpty ? 0 : sample.distance,
                    end: end,
                    limit: road.limit,
                    name: road.name,
                    isPosted: road.isPosted
                ))
            }
        }
        if !segments.isEmpty {
            segments[segments.count - 1].end = route.totalDistance
        }

        let stops = findStops(route: route, osm: osm, roads: roads, onRoute: Set(samples.compactMap(\.road)), projection: projection)
        return (segments, stops)
    }

    private static func nearestRoad(to position: SIMD2<Double>, heading: SIMD2<Double>, in roads: [Road]) -> Int? {
        let headingLength = (heading * heading).sum().squareRoot()
        var best: (index: Int, distance: Double)?

        for (index, road) in roads.enumerated() {
            guard position.x >= road.minCorner.x, position.x <= road.maxCorner.x,
                  position.y >= road.minCorner.y, position.y <= road.maxCorner.y else { continue }

            for (a, b) in zip(road.points, road.points.dropFirst()) {
                let segment = b - a
                let lengthSquared = (segment * segment).sum()
                guard lengthSquared > 0.01 else { continue }
                let t = min(max(((position - a) * segment).sum() / lengthSquared, 0), 1)
                let offset = position - (a + segment * t)
                let distance = (offset * offset).sum().squareRoot()
                guard distance <= 15 else { continue }

                // The road must run the same way as the route (either direction),
                // so cross streets at intersections don't get picked.
                if headingLength > 1 {
                    let cosine = abs((segment * heading).sum()) / (lengthSquared.squareRoot() * headingLength)
                    guard cosine >= 0.82 else { continue }
                }
                if best == nil || distance < best!.distance {
                    best = (index, distance)
                }
            }
        }
        return best?.index
    }

    private static func findStops(
        route: WalkRoute,
        osm: OverpassResponse,
        roads: [Road],
        onRoute: Set<Int>,
        projection: Projection
    ) -> [DriveProfile.Stop] {
        // Which on-route road(s) each node belongs to, and where.
        var nodeRoads: [Int64: [(road: Int, position: Int)]] = [:]
        for roadIndex in onRoute {
            for (position, nodeID) in roads[roadIndex].nodeIDs.enumerated() {
                nodeRoads[nodeID, default: []].append((roadIndex, position))
            }
        }

        let routeXY = route.points.map { projection.xy($0.latitude, $0.longitude) }
        var stops: [DriveProfile.Stop] = []

        for element in osm.elements where element.type == "node" {
            guard let lat = element.lat, let lon = element.lon,
                  let highway = element.tags?["highway"],
                  let memberships = nodeRoads[element.id] else { continue }

            let kind: DriveProfile.StopKind
            switch highway {
            case "stop": kind = .stopSign
            case "traffic_signals": kind = .trafficSignal
            case "give_way": kind = .yield
            default: continue
            }

            let position = projection.xy(lat, lon)
            guard let (distance, routeDirection) = project(position, onto: routeXY, cumulative: route.cumulative),
                  distance > 30, distance < route.totalDistance - 10 else { continue }

            // Signs tagged for one direction only apply when driving that way.
            let direction = element.tags?["direction"] ?? element.tags?["traffic_signals:direction"]
            if direction == "forward" || direction == "backward", let membership = memberships.first {
                let road = roads[membership.road]
                let i = membership.position
                guard road.points.count == road.nodeIDs.count else { continue }
                let from = road.points[max(i - 1, 0)]
                let to = road.points[min(i + 1, road.points.count - 1)]
                let roadForward = ((to - from) * routeDirection).sum() > 0
                if (direction == "forward") != roadForward { continue }
            }

            stops.append(DriveProfile.Stop(distance: distance, kind: kind))
        }

        // One stop per intersection.
        stops.sort { $0.distance < $1.distance }
        var merged: [DriveProfile.Stop] = []
        for stop in stops {
            if let last = merged.last, stop.distance - last.distance < 20 { continue }
            merged.append(stop)
        }
        return merged
    }

    /// Distance along the route of the closest point to `position` (within 12 m),
    /// plus the route's direction there.
    private static func project(
        _ position: SIMD2<Double>,
        onto routeXY: [SIMD2<Double>],
        cumulative: [CLLocationDistance]
    ) -> (CLLocationDistance, SIMD2<Double>)? {
        var best: (distance: Double, along: CLLocationDistance, direction: SIMD2<Double>)?
        for index in 0..<(routeXY.count - 1) {
            let a = routeXY[index]
            let segment = routeXY[index + 1] - a
            let lengthSquared = (segment * segment).sum()
            guard lengthSquared > 0.01 else { continue }
            let t = min(max(((position - a) * segment).sum() / lengthSquared, 0), 1)
            let offset = position - (a + segment * t)
            let distance = (offset * offset).sum().squareRoot()
            if distance <= 12, best == nil || distance < best!.distance {
                let along = cumulative[index] + (cumulative[index + 1] - cumulative[index]) * t
                best = (distance, along, segment)
            }
        }
        return best.map { ($0.along, $0.direction) }
    }

    // MARK: - Speeds

    static func parseSpeedLimit(_ raw: String) -> CLLocationSpeed? {
        let value = raw.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if value == "none" { return 130 / 3.6 }
        guard let number = Scanner(string: value).scanDouble(), number > 0 else { return nil }
        if value.contains("mph") { return number * 0.44704 }
        if value.contains("knot") { return number * 0.514444 }
        return number / 3.6
    }

    /// A believable speed for roads without a posted limit.
    static func typicalSpeed(for highway: String, miles: Bool) -> CLLocationSpeed {
        if miles {
            let mph: Double
            switch highway {
            case "motorway": mph = 65
            case "trunk": mph = 55
            case "primary": mph = 45
            case "secondary": mph = 40
            case "tertiary": mph = 35
            case "motorway_link": mph = 45
            case "trunk_link", "primary_link": mph = 35
            case "secondary_link", "tertiary_link", "unclassified", "road": mph = 30
            case "residential": mph = 25
            default: mph = 15
            }
            return mph * 0.44704
        }
        let kmh: Double
        switch highway {
        case "motorway": kmh = 110
        case "trunk": kmh = 90
        case "primary": kmh = 70
        case "secondary", "tertiary", "unclassified", "road": kmh = 50
        case "motorway_link": kmh = 60
        case "trunk_link", "primary_link", "secondary_link", "tertiary_link": kmh = 45
        case "residential": kmh = 30
        default: kmh = 20
        }
        return kmh / 3.6
    }

    // MARK: - Simplification

    /// Ramer–Douglas–Peucker in metres, so the Overpass query stays small.
    private static func simplified(_ points: [GeoPoint], tolerance: Double) -> [GeoPoint] {
        guard points.count > 2 else { return points }
        let projection = Projection(origin: points[0])
        let xy = points.map { projection.xy($0.latitude, $0.longitude) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let a = xy[first]
            let segment = xy[last] - a
            let lengthSquared = max((segment * segment).sum(), 0.0001)
            var farthest = (index: first, distance: 0.0)
            for index in (first + 1)..<last {
                let t = min(max(((xy[index] - a) * segment).sum() / lengthSquared, 0), 1)
                let offset = xy[index] - (a + segment * t)
                let distance = (offset * offset).sum().squareRoot()
                if distance > farthest.distance { farthest = (index, distance) }
            }
            if farthest.distance > tolerance {
                keep[farthest.index] = true
                stack.append((first, farthest.index))
                stack.append((farthest.index, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}
