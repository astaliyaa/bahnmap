import Foundation

/// Kind of regional train line, used for colouring and labels.
public enum LineCategory: UInt8, CaseIterable, Sendable {
    case sBahn = 0
    case regionalExpress = 1
    case regionalBahn = 2
    case other = 3

    public var label: String {
        switch self {
        case .sBahn: return "S-Bahn"
        case .regionalExpress: return "Regional-Express"
        case .regionalBahn: return "Regionalbahn"
        case .other: return "Other regional"
        }
    }

    static func classify(_ name: String) -> LineCategory {
        let n = name.uppercased().trimmingCharacters(in: .whitespaces)
        let chars = Array(n)
        func digitAt(_ i: Int) -> Bool { i < chars.count && chars[i].isNumber }
        if n.hasPrefix("S"), n.count == 1 || digitAt(1) || (chars.count > 1 && chars[1] == " ") { return .sBahn }
        for p in ["RE", "IRE", "MEX", "FEX", "RX"] where n.hasPrefix(p) {
            if n.count == p.count || digitAt(p.count) || chars[p.count] == " " { return .regionalExpress }
        }
        for p in ["RB", "RS", "ERB", "BRB", "NWB", "EB", "ME", "HLB", "VIA", "ODEG", "AKN", "A"] where n.hasPrefix(p) {
            if n.count == p.count || digitAt(p.count) || chars[p.count] == " " { return .regionalBahn }
        }
        return .other
    }
}

/// Flat, compact representation of a GTFS feed. All cross references are indices.
public struct TimetableData: Sendable {
    public static let formatVersion: Int64 = 3

    // Feed meta
    public var importedAt: Double = 0 // timeIntervalSince1970
    public var sourceURL: String = ""
    public var firstDay: Int32 = 0 // days since 1970-01-01 (civil)
    public var dayCount: Int32 = 0

    // Stations (GTFS parent stations)
    public var stationNames: [String] = []
    public var stationLat: [Double] = []
    public var stationLon: [Double] = []

    // Agencies and routes (lines)
    public var agencyNames: [String] = []
    public var routeNames: [String] = []
    public var routeAgency: [Int32] = []
    public var routeCategory: [UInt8] = []

    // Trips; stop times of trip t are tripStart[t] ..< tripStart[t+1]
    public var tripRoute: [Int32] = []
    public var tripService: [Int32] = []
    public var tripStart: [Int32] = [0]

    // Stop times
    public var stStation: [Int32] = []
    public var stArr: [Int32] = []
    public var stDep: [Int32] = []
    public var stPlatform: [UInt16] = []
    public var stFlags: [UInt8] = [] // bit 0: no pickup, bit 1: no drop-off
    public var platforms: [String] = [""]

    // Service calendar: serviceActive[service * dayCount + day] != 0
    public var serviceCount: Int32 = 0
    public var serviceActive: [UInt8] = []

    public var tripCount: Int { tripRoute.count }
    public var stationCount: Int { stationNames.count }
}

// MARK: - Civil date helpers (no Calendar needed)

public enum CivilDate {
    /// Days since 1970-01-01 for a proleptic Gregorian date.
    public static func days(year y0: Int, month m: Int, day d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public static func fromYYYYMMDD(_ v: Int) -> Int {
        days(year: v / 10000, month: (v / 100) % 100, day: v % 100)
    }

    public static func components(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// 0 = Monday ... 6 = Sunday
    public static func weekday(_ z: Int) -> Int {
        ((z % 7) + 7 + 3) % 7
    }
}

// MARK: - Binary serialisation

struct BinaryWriter {
    var data = Data()

    mutating func int(_ v: Int64) {
        var x = v
        withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
    }

    mutating func array<T>(_ a: [T]) {
        int(Int64(a.count))
        a.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    mutating func strings(_ a: [String]) {
        var lengths: [Int32] = []
        var bytes: [UInt8] = []
        lengths.reserveCapacity(a.count)
        for s in a {
            let u = Array(s.utf8)
            lengths.append(Int32(u.count))
            bytes.append(contentsOf: u)
        }
        array(lengths)
        array(bytes)
    }

    mutating func double(_ v: Double) { array([v]) }
}

struct BinaryReader {
    struct Corrupt: Error {}
    let data: Data
    var pos = 0

    mutating func int() throws -> Int64 {
        guard pos + 8 <= data.count else { throw Corrupt() }
        var v: Int64 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: data.startIndex + pos ..< data.startIndex + pos + 8)
        }
        pos += 8
        return v
    }

    mutating func array<T>(_: T.Type) throws -> [T] {
        let count = Int(try int())
        let size = MemoryLayout<T>.stride * count
        guard count >= 0, pos + size <= data.count else { throw Corrupt() }
        let result = [T](unsafeUninitializedCapacity: count) { buf, initialized in
            let raw = UnsafeMutableRawBufferPointer(buf)
            data.copyBytes(to: raw.bindMemory(to: UInt8.self), from: data.startIndex + pos ..< data.startIndex + pos + size)
            initialized = count
        }
        pos += size
        return result
    }

    mutating func strings() throws -> [String] {
        let lengths = try array(Int32.self)
        let bytes = try array(UInt8.self)
        var out: [String] = []
        out.reserveCapacity(lengths.count)
        var o = 0
        try bytes.withUnsafeBufferPointer { b in
            for l in lengths {
                let len = Int(l)
                guard o + len <= b.count else { throw Corrupt() }
                out.append(String(decoding: UnsafeBufferPointer(rebasing: b[o ..< o + len]), as: UTF8.self))
                o += len
            }
        }
        return out
    }

    mutating func double() throws -> Double {
        let a = try array(Double.self)
        guard let v = a.first else { throw Corrupt() }
        return v
    }
}

extension TimetableData {
    static let magic: Int64 = 0x4241_484E_4D41_5031 // "BAHNMAP1"

    public func serialized() -> Data {
        var w = BinaryWriter()
        w.int(Self.magic)
        w.int(Self.formatVersion)
        w.double(importedAt)
        w.strings([sourceURL])
        w.int(Int64(firstDay)); w.int(Int64(dayCount))
        w.strings(stationNames); w.array(stationLat); w.array(stationLon)
        w.strings(agencyNames); w.strings(routeNames); w.array(routeAgency); w.array(routeCategory)
        w.array(tripRoute); w.array(tripService); w.array(tripStart)
        w.array(stStation); w.array(stArr); w.array(stDep); w.array(stPlatform); w.array(stFlags)
        w.strings(platforms)
        w.int(Int64(serviceCount)); w.array(serviceActive)
        return w.data
    }

    public init(serialized data: Data) throws {
        var r = BinaryReader(data: data)
        guard try r.int() == Self.magic, try r.int() == Self.formatVersion else { throw BinaryReader.Corrupt() }
        importedAt = try r.double()
        sourceURL = try r.strings().first ?? ""
        firstDay = Int32(try r.int()); dayCount = Int32(try r.int())
        stationNames = try r.strings(); stationLat = try r.array(Double.self); stationLon = try r.array(Double.self)
        agencyNames = try r.strings(); routeNames = try r.strings()
        routeAgency = try r.array(Int32.self); routeCategory = try r.array(UInt8.self)
        tripRoute = try r.array(Int32.self); tripService = try r.array(Int32.self); tripStart = try r.array(Int32.self)
        stStation = try r.array(Int32.self); stArr = try r.array(Int32.self); stDep = try r.array(Int32.self)
        stPlatform = try r.array(UInt16.self); stFlags = try r.array(UInt8.self)
        platforms = try r.strings()
        serviceCount = Int32(try r.int()); serviceActive = try r.array(UInt8.self)
        guard tripStart.count == tripRoute.count + 1,
              stArr.count == stStation.count,
              stationLat.count == stationNames.count,
              serviceActive.count == Int(serviceCount) * Int(dayCount)
        else { throw BinaryReader.Corrupt() }
    }
}
