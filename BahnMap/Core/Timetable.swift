import Foundation

/// A trip running on a specific service day. `shift` is the day offset (-1, 0, +1)
/// relative to the query day, so times are `stopTime + shift * 86400`.
public struct TripInstance: Hashable, Sendable {
    public let trip: Int32
    public let shift: Int32
    public init(trip: Int32, shift: Int32) { self.trip = trip; self.shift = shift }
    var packed: Int32 { trip * 3 + shift + 1 }
    init(packed: Int32) { trip = packed / 3; shift = packed % 3 - 1 }
}

public struct Departure: Identifiable, Hashable, Sendable {
    public var id: String { "\(instance.trip)/\(instance.shift)/\(stopIndex)" }
    public let instance: TripInstance
    public let stopIndex: Int32 // global stop time index
    public let time: Int32 // seconds after query-day midnight
    public let line: String
    public let category: LineCategory
    public let headsign: String
    public let platform: String
    public let isArrivalOnly: Bool
}

public struct TripStop: Identifiable, Hashable, Sendable {
    public var id: Int32 { stopIndex }
    public let stopIndex: Int32
    public let station: Int32
    public let arrival: Int32
    public let departure: Int32
    public let platform: String
}

public struct LineInfo: Hashable, Sendable {
    public let name: String
    public let category: LineCategory
}

public struct NetworkEdge: Sendable {
    public let a: Int32
    public let b: Int32
    public let category: LineCategory
}

public final class Timetable: @unchecked Sendable {
    public let data: TimetableData
    public let stTrip: [Int32]
    /// stop time indices per station: stationEvents[stationEventStart[s] ..< stationEventStart[s+1]]
    let stationEventStart: [Int32]
    let stationEvents: [Int32]
    public let importance: [Int32]
    let foldedNames: [String]
    // Walking transfers between nearby stations
    let footStart: [Int32]
    let footTo: [Int32]
    let footSecs: [Int32]
    public let edges: [NetworkEdge]

    private let lock = NSLock()
    private var connectionCache: [Int32: [Connection]] = [:]
    private var cacheOrder: [Int32] = []

    public init(data d: TimetableData) {
        data = d
        let nS = d.stationCount
        var stTrip = [Int32](repeating: 0, count: d.stStation.count)
        for t in 0..<d.tripCount {
            for k in Int(d.tripStart[t])..<Int(d.tripStart[t + 1]) { stTrip[k] = Int32(t) }
        }
        self.stTrip = stTrip

        var counts = [Int32](repeating: 0, count: nS + 1)
        for s in d.stStation { counts[Int(s) + 1] += 1 }
        importance = Array(counts.dropFirst())
        for i in 1..<counts.count { counts[i] += counts[i - 1] }
        var fill = counts
        var events = [Int32](repeating: 0, count: d.stStation.count)
        for (k, s) in d.stStation.enumerated() {
            events[Int(fill[Int(s)])] = Int32(k)
            fill[Int(s)] += 1
        }
        stationEventStart = counts
        stationEvents = events
        foldedNames = d.stationNames.map { Timetable.fold($0) }

        // Footpaths via a coarse grid (~1 km cells)
        var grid: [Int64: [Int32]] = [:]
        func cell(_ lat: Double, _ lon: Double) -> (Int64, Int64) { (Int64((lat * 100).rounded(.down)), Int64((lon * 70).rounded(.down))) }
        for s in 0..<nS {
            let (a, b) = cell(d.stationLat[s], d.stationLon[s])
            grid[a << 32 | (b & 0xFFFF_FFFF), default: []].append(Int32(s))
        }
        var fStart: [Int32] = [0], fTo: [Int32] = [], fSecs: [Int32] = []
        for s in 0..<nS {
            let (a, b) = cell(d.stationLat[s], d.stationLon[s])
            var found: [(Int32, Int32)] = []
            for da in -1...1 {
                for db in -1...1 {
                    let key = (a + Int64(da)) << 32 | ((b + Int64(db)) & 0xFFFF_FFFF)
                    for o in grid[key] ?? [] where o != Int32(s) {
                        let m = Timetable.distance(d.stationLat[s], d.stationLon[s], d.stationLat[Int(o)], d.stationLon[Int(o)])
                        if m <= 400 { found.append((o, Int32(m * 1.3 / 1.2 + 120))) }
                    }
                }
            }
            for (o, sec) in found { fTo.append(o); fSecs.append(sec) }
            fStart.append(Int32(fTo.count))
        }
        footStart = fStart; footTo = fTo; footSecs = fSecs

        // Network edges (unique station pairs, most important category wins)
        var edgeMap: [Int64: UInt8] = [:]
        for t in 0..<d.tripCount {
            let cat = d.routeCategory[Int(d.tripRoute[t])]
            let s0 = Int(d.tripStart[t]), s1 = Int(d.tripStart[t + 1])
            for k in s0..<(s1 - 1) {
                let a = d.stStation[k], b = d.stStation[k + 1]
                let key = Int64(min(a, b)) << 32 | Int64(max(a, b))
                if let old = edgeMap[key] { if cat < old { edgeMap[key] = cat } } else { edgeMap[key] = cat }
            }
        }
        edges = edgeMap.map { NetworkEdge(a: Int32($0.key >> 32), b: Int32($0.key & 0xFFFF_FFFF), category: LineCategory(rawValue: $0.value) ?? .other) }
    }

    // MARK: - Basic accessors

    public var stationCount: Int { data.stationCount }
    public func name(_ s: Int32) -> String { data.stationNames[Int(s)] }
    public func lat(_ s: Int32) -> Double { data.stationLat[Int(s)] }
    public func lon(_ s: Int32) -> Double { data.stationLon[Int(s)] }
    public func lineName(trip: Int32) -> String { data.routeNames[Int(data.tripRoute[Int(trip)])] }
    public func category(trip: Int32) -> LineCategory {
        LineCategory(rawValue: data.routeCategory[Int(data.tripRoute[Int(trip)])]) ?? .other
    }
    public func operatorName(trip: Int32) -> String {
        let a = data.routeAgency[Int(data.tripRoute[Int(trip)])]
        return a >= 0 ? data.agencyNames[Int(a)] : ""
    }
    public func headsign(trip: Int32) -> String {
        name(data.stStation[Int(data.tripStart[Int(trip) + 1]) - 1])
    }
    public func platform(_ stopIndex: Int32) -> String { data.platforms[Int(data.stPlatform[Int(stopIndex)])] }

    public func isActive(service: Int32, day: Int32) -> Bool {
        guard day >= 0, day < data.dayCount else { return false }
        return data.serviceActive[Int(service) * Int(data.dayCount) + Int(day)] != 0
    }

    public func isActive(trip: Int32, day: Int32) -> Bool { isActive(service: data.tripService[Int(trip)], day: day) }

    public var firstDate: (year: Int, month: Int, day: Int) { CivilDate.components(Int(data.firstDay)) }
    public var lastDate: (year: Int, month: Int, day: Int) { CivilDate.components(Int(data.firstDay + data.dayCount - 1)) }

    /// Distinct lines serving a station, sorted.
    public func lines(at station: Int32) -> [LineInfo] {
        var seen: Set<Int32> = []
        for k in stationEventStart[Int(station)]..<stationEventStart[Int(station) + 1] {
            seen.insert(data.tripRoute[Int(stTrip[Int(stationEvents[Int(k)])])])
        }
        var names: [String: LineCategory] = [:]
        for r in seen {
            names[data.routeNames[Int(r)]] = LineCategory(rawValue: data.routeCategory[Int(r)]) ?? .other
        }
        return names.map { LineInfo(name: $0.key, category: $0.value) }.sorted {
            $0.category != $1.category ? $0.category.rawValue < $1.category.rawValue
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Boards & trips

    /// Departures (or arrivals) at a station on `day` from `from` seconds for `window` seconds.
    public func departures(station: Int32, day: Int32, from: Int32, window: Int32 = 3 * 3600, arrivals: Bool = false, limit: Int = 150) -> [Departure] {
        var out: [Departure] = []
        for k in stationEventStart[Int(station)]..<stationEventStart[Int(station) + 1] {
            let st = stationEvents[Int(k)]
            let trip = stTrip[Int(st)]
            let first = data.tripStart[Int(trip)], last = data.tripStart[Int(trip) + 1] - 1
            if !arrivals && st == last { continue }
            if arrivals && st == first { continue }
            if !arrivals && data.stFlags[Int(st)] & 1 != 0 { continue }
            if arrivals && data.stFlags[Int(st)] & 2 != 0 { continue }
            for shift: Int32 in -1...1 where isActive(trip: trip, day: day + shift) {
                let t = (arrivals ? data.stArr[Int(st)] : data.stDep[Int(st)]) + shift * 86400
                guard t >= from, t <= from + window else { continue }
                let origin = name(data.stStation[Int(first)])
                out.append(Departure(instance: TripInstance(trip: trip, shift: shift), stopIndex: st, time: t,
                                     line: lineName(trip: trip), category: category(trip: trip),
                                     headsign: arrivals ? origin : headsign(trip: trip),
                                     platform: platform(st), isArrivalOnly: st == last))
            }
        }
        out.sort { $0.time != $1.time ? $0.time < $1.time : $0.line < $1.line }
        return Array(out.prefix(limit))
    }

    public func stops(of instance: TripInstance) -> [TripStop] {
        let off = instance.shift * 86400
        return (Int(data.tripStart[Int(instance.trip)])..<Int(data.tripStart[Int(instance.trip) + 1])).map { k in
            TripStop(stopIndex: Int32(k), station: data.stStation[k], arrival: data.stArr[k] + off,
                     departure: data.stDep[k] + off, platform: data.platforms[Int(data.stPlatform[k])])
        }
    }

    // MARK: - Search

    public static func fold(_ s: String) -> String {
        s.lowercased().folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "hauptbahnhof", with: "hbf")
            .replacingOccurrences(of: "bahnhof", with: "bf")
            .replacingOccurrences(of: "bf.", with: "bf")
            .replacingOccurrences(of: "strasse", with: "str")
            .replacingOccurrences(of: "str.", with: "str")
    }

    public func search(_ query: String, limit: Int = 40) -> [Int32] {
        let q = Timetable.fold(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let tokens = q.split(separator: " ").map(String.init)
        var scored: [(Int32, Int)] = []
        for (i, n) in foldedNames.enumerated() {
            var score = 0
            var ok = true
            for (ti, t) in tokens.enumerated() {
                if ti == 0 && n.hasPrefix(t) { score += 0 }
                else if n.hasPrefix(t) || n.contains(" " + t) || n.contains("-" + t) || n.contains("/" + t) { score += 1 }
                else if n.contains(t) { score += 3 }
                else { ok = false; break }
            }
            guard ok else { continue }
            if n == q { score -= 5 }
            scored.append((Int32(i), score))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 < $1.1 : importance[Int($0.0)] > importance[Int($1.0)] }
        return scored.prefix(limit).map(\.0)
    }

    public func nearest(lat: Double, lon: Double, limit: Int = 1) -> [Int32] {
        var best: [(Int32, Double)] = []
        for s in 0..<stationCount where importance[s] > 0 {
            let dl = data.stationLat[s] - lat, dn = (data.stationLon[s] - lon) * 0.63
            best.append((Int32(s), dl * dl + dn * dn))
        }
        best.sort { $0.1 < $1.1 }
        return best.prefix(limit).map(\.0)
    }

    static func distance(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = la1 * .pi / 180, p2 = la2 * .pi / 180
        let dp = p2 - p1, dl = (lo2 - lo1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - Connections (for routing)

    struct Connection {
        var depStation: Int32
        var arrStation: Int32
        var dep: Int32
        var arr: Int32
        var trip: Int32 // packed TripInstance
        var st: Int32 // stop time index of the departure stop
    }

    static let horizon: Int32 = 36 * 3600

    func connections(day: Int32) -> [Connection] {
        lock.lock()
        if let c = connectionCache[day] { lock.unlock(); return c }
        lock.unlock()

        var conns: [Connection] = []
        conns.reserveCapacity(700_000)
        for shift: Int32 in -1...1 {
            for t in 0..<Int32(data.tripCount) where isActive(trip: t, day: day + shift) {
                let s0 = Int(data.tripStart[Int(t)]), s1 = Int(data.tripStart[Int(t) + 1])
                let off = shift * 86400
                let packed = TripInstance(trip: t, shift: shift).packed
                for k in s0..<(s1 - 1) {
                    let dep = data.stDep[k] + off
                    guard dep >= 0, dep < Timetable.horizon else { continue }
                    conns.append(Connection(depStation: data.stStation[k], arrStation: data.stStation[k + 1],
                                            dep: dep, arr: data.stArr[k + 1] + off, trip: packed, st: Int32(k)))
                }
            }
        }
        conns.sort { $0.dep != $1.dep ? $0.dep < $1.dep : ($0.arr != $1.arr ? $0.arr < $1.arr : $0.st < $1.st) }

        lock.lock()
        connectionCache[day] = conns
        cacheOrder.append(day)
        if cacheOrder.count > 2 { connectionCache[cacheOrder.removeFirst()] = nil }
        lock.unlock()
        return conns
    }
}
