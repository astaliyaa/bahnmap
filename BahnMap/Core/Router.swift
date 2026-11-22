import Foundation

public enum Leg: Hashable, Sendable {
    /// Ride on `instance` from stop time `fromStop` to `toStop` (global stop time indices).
    case ride(instance: TripInstance, fromStop: Int32, toStop: Int32)
    case walk(from: Int32, to: Int32, departure: Int32, seconds: Int32)
}

public struct Journey: Identifiable, Hashable, Sendable {
    public var id: String { legs.map { "\($0)" }.joined(separator: "|") }
    public let legs: [Leg]
    public let departure: Int32
    public let arrival: Int32
    public var duration: Int32 { arrival - departure }
    public var transfers: Int {
        max(0, legs.filter { if case .ride = $0 { return true } else { return false } }.count - 1)
    }
}

/// Result of a one-to-all earliest arrival search ("where can I get to").
public struct Reachability: Sendable {
    public let origin: Int32
    public let start: Int32
    public let arrival: [Int32] // Int32.max = unreachable
    public let rides: [UInt8]
    public func isReachable(_ s: Int32) -> Bool { arrival[Int(s)] != Int32.max }
}

public struct RoutingOptions: Sendable {
    public var minTransfer: Int32 = 4 * 60
    public var maxRides: Int = 8
    public var allowWalking = true
    public init(minTransfer: Int32 = 240, maxRides: Int = 8, allowWalking: Bool = true) {
        self.minTransfer = minTransfer
        self.maxRides = maxRides
        self.allowWalking = allowWalking
    }
}

extension Timetable {
    private struct SearchState {
        var arr: [Int32]
        var ready: [Int32]
        var rides: [UInt8]
        var kind: [UInt8] // 0 = none/origin, 1 = ride, 2 = walk
        var p1: [Int32]
        var p2: [Int32]
    }

    private func scan(origin: Int32, day: Int32, start: Int32, end: Int32, target: Int32?, options: RoutingOptions) -> (SearchState, [Connection]) {
        let n = stationCount
        let conns = connections(day: day)
        let inf = Int32.max
        var st = SearchState(arr: [Int32](repeating: inf, count: n), ready: [Int32](repeating: inf, count: n),
                             rides: [UInt8](repeating: 0, count: n), kind: [UInt8](repeating: 0, count: n),
                             p1: [Int32](repeating: -1, count: n), p2: [Int32](repeating: -1, count: n))
        var tripBoard = [Int32](repeating: -1, count: data.tripCount * 3)
        var tripRides = [UInt8](repeating: 0, count: data.tripCount * 3)
        let flags = data.stFlags

        st.arr[Int(origin)] = start
        st.ready[Int(origin)] = start
        func relaxFoot(_ s: Int32, _ t: Int32) {
            guard options.allowWalking else { return }
            for f in footStart[Int(s)]..<footStart[Int(s) + 1] {
                let o = Int(footTo[Int(f)])
                let at = t + footSecs[Int(f)]
                if at < st.arr[o] {
                    st.arr[o] = at
                    st.ready[o] = at
                    st.rides[o] = st.rides[Int(s)]
                    st.kind[o] = 2
                    st.p1[o] = s
                    st.p2[o] = footSecs[Int(f)]
                }
            }
        }
        relaxFoot(origin, start)

        // binary search first connection departing at or after start
        var lo = 0, hi = conns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if conns[mid].dep < start { lo = mid + 1 } else { hi = mid }
        }
        let maxRides = UInt8(clamping: options.maxRides)
        var i = lo
        while i < conns.count {
            let c = conns[i]
            if c.dep > end { break }
            if let target, c.dep >= st.arr[Int(target)] { break }
            let ti = Int(c.trip)
            var boarded = tripBoard[ti] >= 0
            if !boarded, st.ready[Int(c.depStation)] <= c.dep, flags[Int(c.st)] & 1 == 0, st.rides[Int(c.depStation)] < maxRides {
                tripBoard[ti] = Int32(i)
                tripRides[ti] = st.rides[Int(c.depStation)] + 1
                boarded = true
            }
            if boarded, c.arr <= end, c.arr < st.arr[Int(c.arrStation)], flags[Int(c.st) + 1] & 2 == 0 {
                let a = Int(c.arrStation)
                st.arr[a] = c.arr
                st.ready[a] = c.arr + options.minTransfer
                st.rides[a] = tripRides[ti]
                st.kind[a] = 1
                st.p1[a] = tripBoard[ti]
                st.p2[a] = Int32(i)
                relaxFoot(c.arrStation, c.arr)
            }
            i += 1
        }
        return (st, conns)
    }

    private func reconstruct(_ st: SearchState, _ conns: [Connection], origin: Int32, target: Int32) -> Journey? {
        guard st.arr[Int(target)] != Int32.max, target != origin else { return nil }
        var legs: [Leg] = []
        var s = target
        var guardCount = 0
        while s != origin {
            guardCount += 1
            if guardCount > 64 { return nil }
            switch st.kind[Int(s)] {
            case 1:
                let enter = conns[Int(st.p1[Int(s)])], exit = conns[Int(st.p2[Int(s)])]
                legs.append(.ride(instance: TripInstance(packed: exit.trip), fromStop: enter.st, toStop: exit.st + 1))
                s = enter.depStation
            case 2:
                let from = st.p1[Int(s)]
                let secs = st.p2[Int(s)]
                legs.append(.walk(from: from, to: s, departure: st.arr[Int(s)] - secs, seconds: secs))
                s = from
            default:
                return nil
            }
        }
        legs.reverse()
        guard let first = legs.first else { return nil }
        let dep: Int32
        switch first {
        case let .ride(inst, from, _): dep = data.stDep[Int(from)] + inst.shift * 86400
        case let .walk(_, _, d, _): dep = d
        }
        return Journey(legs: legs, departure: dep, arrival: st.arr[Int(target)])
    }

    /// Earliest-arrival journeys from `from` to `to`, starting at `start` seconds after midnight of `day`.
    /// Returns up to `count` successive options.
    public func journeys(from: Int32, to: Int32, day: Int32, start: Int32, count: Int = 5, options: RoutingOptions = .init()) -> [Journey] {
        guard from != to else { return [] }
        var result: [Journey] = []
        var t = start
        var attempts = 0
        while result.count < count, attempts < count * 3, t < Timetable.horizon {
            attempts += 1
            let (st, conns) = scan(origin: from, day: day, start: t, end: Timetable.horizon, target: to, options: options)
            guard var j = reconstruct(st, conns, origin: from, target: to) else { break }
            j = tightened(j, from: from, to: to, day: day, options: options)
            if !result.contains(where: { $0.id == j.id }) { result.append(j) }
            t = j.departure + 60
        }
        // Drop options that are strictly dominated (leave later or same, arrive later)
        return result.enumerated().filter { idx, j in
            !result.enumerated().contains { k, o in k != idx && o.departure >= j.departure && o.arrival <= j.arrival && (o.departure > j.departure || o.arrival < j.arrival) }
        }.map(\.element).sorted { $0.departure < $1.departure }
    }

    /// Finds the latest departure that still reaches the same arrival time, to avoid needless waiting.
    private func tightened(_ j: Journey, from: Int32, to: Int32, day: Int32, options: RoutingOptions) -> Journey {
        var best = j
        var lo = j.departure + 60
        var hi = j.arrival
        var steps = 0
        while lo <= hi, steps < 8 {
            steps += 1
            let mid = (lo + hi) / 2
            let (st, conns) = scan(origin: from, day: day, start: mid, end: j.arrival, target: to, options: options)
            if let k = reconstruct(st, conns, origin: from, target: to), k.arrival <= j.arrival {
                best = k
                lo = k.departure + 60
            } else {
                hi = mid - 60
            }
        }
        return best
    }

    /// One-to-all earliest arrival within `maxDuration` seconds.
    public func reachability(from origin: Int32, day: Int32, start: Int32, maxDuration: Int32, options: RoutingOptions = .init()) -> Reachability {
        let (st, _) = scan(origin: origin, day: day, start: start, end: start + maxDuration, target: nil, options: options)
        return Reachability(origin: origin, start: start, arrival: st.arr, rides: st.rides)
    }
}
