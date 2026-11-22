import Foundation
import MapKit
import Observation
import SwiftUI

struct StationRef: Identifiable, Hashable {
    let id: Int32
}

struct HighlightSegment {
    var coordinates: [CLLocationCoordinate2D]
    var color: UIColor
    var dashed: Bool = false
}

struct Highlight: Equatable {
    let id = UUID()
    var title: String
    var segments: [HighlightSegment]
    static func == (a: Highlight, b: Highlight) -> Bool { a.id == b.id }

    var allCoordinates: [CLLocationCoordinate2D] { segments.flatMap(\.coordinates) }
}

struct MapFocus: Equatable {
    enum Target {
        case station(Int32)
        case coordinates([CLLocationCoordinate2D])
    }
    let id = UUID()
    var target: Target
    static func == (a: MapFocus, b: MapFocus) -> Bool { a.id == b.id }
}

struct ReachSettings: Equatable {
    var origin: Int32
    var date: Date
    var maxMinutes: Int = 120
    var maxRides: Int = 8 // 1 = direct only
}

enum AppTab: Hashable { case map, planner, settings }

enum Settings {
    static let minTransferKey = "minTransferMinutes"
    static let feedURLKey = "feedURL"
    static let favoritesKey = "favorites"

    static var minTransferMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: minTransferKey)
        return v == 0 ? 4 : v
    }

    static var feedURL: URL {
        if let s = UserDefaults.standard.string(forKey: feedURLKey), let u = URL(string: s), u.scheme != nil { return u }
        return GTFSImporter.defaultFeedURL
    }

    static var routingOptions: RoutingOptions {
        RoutingOptions(minTransfer: Int32(minTransferMinutes * 60))
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case needsData
        case ready
    }

    var phase: Phase = .starting
    var timetable: Timetable?
    var isWorking = false
    var status: String?
    var errorMessage: String?

    // Map state
    var selectedTab: AppTab = .map
    var stationSheet: StationRef?
    var focus: MapFocus?
    var highlight: Highlight?
    var reach: ReachSettings?
    var reachResult: Reachability?
    var reachComputing = false

    // Planner state
    var plannerFrom: Int32?
    var plannerTo: Int32?
    var plannerDate = Date()
    var plannerRequest: UUID?

    // Favourites are stored by name so they survive timetable updates.
    var favoriteNames: [String] = UserDefaults.standard.stringArray(forKey: Settings.favoritesKey) ?? []

    private var nameIndex: [String: Int32] = [:]

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timetable.bin")
    }

    // MARK: - Loading

    func start() async {
        guard phase == .starting else { return }
        let url = Self.cacheURL
        let loaded: Timetable? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                  let td = try? TimetableData(serialized: data) else { return nil }
            return Timetable(data: td)
        }.value
        if let loaded {
            install(loaded)
            // Refresh automatically once a week, keeping the old data until the new one is ready.
            let age = Date().timeIntervalSince1970 - loaded.data.importedAt
            if age > 7 * 86400 || dataExpiresSoon {
                await download()
            }
        } else {
            phase = .needsData
        }
    }

    private func install(_ tt: Timetable) {
        timetable = tt
        var idx: [String: Int32] = [:]
        for (i, n) in tt.data.stationNames.enumerated() where idx[n] == nil || tt.importance[i] > tt.importance[Int(idx[n]!)] {
            idx[n] = Int32(i)
        }
        nameIndex = idx
        reach = nil
        reachResult = nil
        highlight = nil
        stationSheet = nil
        plannerFrom = nil
        plannerTo = nil
        phase = .ready
    }

    var dataExpiresSoon: Bool {
        guard let tt = timetable else { return false }
        let last = Int(tt.data.firstDay + tt.data.dayCount - 1)
        return ServiceClock.civilDay(Date()) + 5 >= last
    }

    func download() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        status = "Downloading timetable…"
        defer { isWorking = false }
        do {
            let feed = Settings.feedURL
            let (tmp, response) = try await URLSession.shared.download(from: feed)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GTFSImporter.ImportError(message: "Download failed (HTTP \(http.statusCode)).")
            }
            let zip = FileManager.default.temporaryDirectory.appendingPathComponent("feed-\(UUID().uuidString).zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            let cache = Self.cacheURL
            let tt: Timetable = try await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: zip) }
                let data = try GTFSImporter.importZip(zip, sourceURL: feed.absoluteString) { msg in
                    Task { @MainActor in self.status = msg }
                }
                try data.serialized().write(to: cache, options: .atomic)
                return Timetable(data: data)
            }.value
            install(tt)
            status = nil
        } catch {
            status = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Stations

    func station(named name: String) -> Int32? { nameIndex[name] }

    var favorites: [Int32] { favoriteNames.compactMap { nameIndex[$0] } }

    func isFavorite(_ s: Int32) -> Bool {
        guard let tt = timetable else { return false }
        return favoriteNames.contains(tt.name(s))
    }

    func toggleFavorite(_ s: Int32) {
        guard let tt = timetable else { return }
        let n = tt.name(s)
        if let i = favoriteNames.firstIndex(of: n) { favoriteNames.remove(at: i) } else { favoriteNames.append(n) }
        UserDefaults.standard.set(favoriteNames, forKey: Settings.favoritesKey)
    }

    func openStation(_ s: Int32) {
        stationSheet = StationRef(id: s)
    }

    func focusStation(_ s: Int32) {
        focus = MapFocus(target: .station(s))
        stationSheet = StationRef(id: s)
    }

    // MARK: - Reachability

    func explore(from s: Int32, date: Date = Date()) {
        highlight = nil
        reach = ReachSettings(origin: s, date: date, maxMinutes: reach?.maxMinutes ?? 120, maxRides: reach?.maxRides ?? 8)
        reachResult = nil
        stationSheet = nil
        selectedTab = .map
        focus = MapFocus(target: .station(s))
    }

    func clearReach() {
        reach = nil
        reachResult = nil
    }

    func computeReach() async {
        guard let tt = timetable, let r = reach else { return }
        reachComputing = true
        let q = ServiceClock.query(r.date, tt)
        var options = Settings.routingOptions
        options.maxRides = r.maxRides
        let result = await Task.detached(priority: .userInitiated) {
            tt.reachability(from: r.origin, day: q.day, start: q.seconds, maxDuration: Int32(r.maxMinutes * 60), options: options)
        }.value
        if reach == r { reachResult = result }
        reachComputing = false
    }

    // MARK: - Planner

    func planRoute(from: Int32?, to: Int32?, date: Date? = nil) {
        if let from { plannerFrom = from }
        if let to { plannerTo = to }
        if let date { plannerDate = date }
        stationSheet = nil
        selectedTab = .planner
        if plannerFrom != nil, plannerTo != nil { plannerRequest = UUID() }
    }

    // MARK: - Highlights

    func coordinate(_ s: Int32) -> CLLocationCoordinate2D {
        guard let tt = timetable else { return .init() }
        return CLLocationCoordinate2D(latitude: tt.lat(s), longitude: tt.lon(s))
    }

    func segments(for journey: Journey) -> [HighlightSegment] {
        guard let tt = timetable else { return [] }
        return journey.legs.map { leg in
            switch leg {
            case let .ride(inst, from, to):
                let coords = (Int(from)...Int(to)).map { coordinate(tt.data.stStation[$0]) }
                return HighlightSegment(coordinates: coords, color: tt.category(trip: inst.trip).uiColor)
            case let .walk(from, to, _, _):
                return HighlightSegment(coordinates: [coordinate(from), coordinate(to)], color: .systemGray, dashed: true)
            }
        }
    }

    func show(journey: Journey) {
        guard let tt = timetable else { return }
        let title: String
        if case let .ride(_, f, _)? = journey.legs.first, case let .ride(_, _, t)? = journey.legs.last {
            title = "\(tt.name(tt.data.stStation[Int(f)])) → \(tt.name(tt.data.stStation[Int(t)]))"
        } else {
            title = "Connection"
        }
        clearReach()
        let h = Highlight(title: title, segments: segments(for: journey))
        highlight = h
        focus = MapFocus(target: .coordinates(h.allCoordinates))
        stationSheet = nil
        selectedTab = .map
    }

    func show(trip: TripInstance) {
        guard let tt = timetable else { return }
        let stops = tt.stops(of: trip)
        let coords = stops.map { coordinate($0.station) }
        clearReach()
        let h = Highlight(title: "\(tt.lineName(trip: trip.trip)) → \(tt.headsign(trip: trip.trip))",
                          segments: [HighlightSegment(coordinates: coords, color: tt.category(trip: trip.trip).uiColor)])
        highlight = h
        focus = MapFocus(target: .coordinates(coords))
    }
}

extension LineCategory {
    var uiColor: UIColor {
        switch self {
        case .sBahn: return UIColor(red: 0.0, green: 0.55, blue: 0.27, alpha: 1)
        case .regionalExpress: return UIColor(red: 0.86, green: 0.1, blue: 0.12, alpha: 1)
        case .regionalBahn: return UIColor(red: 0.1, green: 0.38, blue: 0.78, alpha: 1)
        case .other: return UIColor(red: 0.45, green: 0.38, blue: 0.62, alpha: 1)
        }
    }

    var color: Color { Color(uiColor) }
}
