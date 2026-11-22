import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Converts a GTFS feed (directory or zip) into `TimetableData`.
public enum GTFSImporter {
    public static let defaultFeedURL = URL(string: "https://download.gtfs.de/germany/rv_free/latest.zip")!

    public struct ImportError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    #if canImport(ZIPFoundation)
    /// Unzips `zip` into a temporary directory and imports it.
    public static func importZip(_ zip: URL, sourceURL: String, progress: (String) -> Void) throws -> TimetableData {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gtfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        progress("Unpacking timetable…")
        try FileManager.default.unzipItem(at: zip, to: dir)
        // Some feeds put the files in a subdirectory.
        var root = dir
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("stops.txt").path),
           let sub = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("stops.txt").path) }) {
            root = sub
        }
        return try importDirectory(root, sourceURL: sourceURL, progress: progress)
    }
    #endif

    public static func importDirectory(_ dir: URL, sourceURL: String, progress: (String) -> Void) throws -> TimetableData {
        var out = TimetableData()
        out.sourceURL = sourceURL
        out.importedAt = Date().timeIntervalSince1970

        // Agencies
        progress("Reading operators…")
        var agencyIndex: [String: Int32] = [:]
        var excludedAgencies: Set<Int32> = []
        try CSVFile.read(dir.appendingPathComponent("agency.txt"), columns: ["agency_id", "agency_name"]) { r in
            let idx = Int32(out.agencyNames.count)
            agencyIndex[r.string(0)] = idx
            out.agencyNames.append(cleanAgency(r.string(1)))
            if DTicket.excludes(agency: r.string(1)) { excludedAgencies.insert(idx) }
        }

        // Stations
        progress("Reading stations…")
        struct RawStop { var id: String; var name: String; var parent: String; var lat: Double; var lon: Double; var type: Int; var platform: String }
        var rawStops: [RawStop] = []
        try CSVFile.read(dir.appendingPathComponent("stops.txt"),
                         columns: ["stop_id", "stop_name", "parent_station", "stop_lat", "stop_lon", "location_type", "platform_code"]) { r in
            rawStops.append(RawStop(id: r.string(0), name: r.string(1), parent: r.string(2),
                                    lat: r.double(3) ?? 0, lon: r.double(4) ?? 0,
                                    type: r.int(5) ?? 0, platform: r.string(6)))
        }
        var stationOf: [String: Int32] = [:]
        var platformOf: [String: UInt16] = [:]
        var platformIndex: [String: UInt16] = ["": 0]
        let ids = Set(rawStops.map(\.id))
        for s in rawStops where (s.parent.isEmpty || !ids.contains(s.parent)) && (s.type == 0 || s.type == 1) {
            stationOf[s.id] = Int32(out.stationNames.count)
            out.stationNames.append(s.name)
            out.stationLat.append(s.lat)
            out.stationLon.append(s.lon)
        }
        for s in rawStops {
            if stationOf[s.id] == nil, let p = stationOf[s.parent] { stationOf[s.id] = p }
            if !s.platform.isEmpty {
                if platformIndex[s.platform] == nil, platformIndex.count < Int(UInt16.max) {
                    platformIndex[s.platform] = UInt16(out.platforms.count)
                    out.platforms.append(s.platform)
                }
                platformOf[s.id] = platformIndex[s.platform] ?? 0
            }
        }
        rawStops = []

        // Routes
        progress("Reading lines…")
        var routeIndex: [String: Int32] = [:]
        try CSVFile.read(dir.appendingPathComponent("routes.txt"),
                         columns: ["route_id", "route_short_name", "route_long_name", "agency_id"]) { r in
            var name = r.string(1)
            if name.isEmpty { name = r.string(2) }
            let agency = agencyIndex[r.string(3)] ?? -1
            if excludedAgencies.contains(agency) || DTicket.excludes(line: name) { return }
            routeIndex[r.string(0)] = Int32(out.routeNames.count)
            out.routeNames.append(name)
            out.routeAgency.append(agency)
            out.routeCategory.append(LineCategory.classify(name).rawValue)
        }

        // Calendar
        progress("Reading calendar…")
        struct Cal { var mask: [Bool]; var start: Int; var end: Int }
        var calendars: [String: Cal] = [:]
        var exceptions: [(String, Int, Int)] = []
        var minDay = Int.max, maxDay = Int.min
        let calURL = dir.appendingPathComponent("calendar.txt")
        if FileManager.default.fileExists(atPath: calURL.path) {
            try CSVFile.read(calURL, columns: ["service_id", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "start_date", "end_date"]) { r in
                guard let s = r.int(8), let e = r.int(9) else { return }
                let sd = CivilDate.fromYYYYMMDD(s), ed = CivilDate.fromYYYYMMDD(e)
                calendars[r.string(0)] = Cal(mask: (1...7).map { r.int($0) == 1 }, start: sd, end: ed)
                minDay = min(minDay, sd); maxDay = max(maxDay, ed)
            }
        }
        let cdURL = dir.appendingPathComponent("calendar_dates.txt")
        if FileManager.default.fileExists(atPath: cdURL.path) {
            try CSVFile.read(cdURL, columns: ["service_id", "date", "exception_type"]) { r in
                guard let d = r.int(1), let t = r.int(2) else { return }
                let day = CivilDate.fromYYYYMMDD(d)
                exceptions.append((r.string(0), day, t))
                minDay = min(minDay, day); maxDay = max(maxDay, day)
            }
        }
        guard minDay <= maxDay else { throw ImportError(message: "The timetable has no service calendar.") }
        maxDay = min(maxDay, minDay + 399)
        let dayCount = maxDay - minDay + 1
        out.firstDay = Int32(minDay)
        out.dayCount = Int32(dayCount)

        var serviceIndex: [String: Int32] = [:]
        func service(_ id: String) -> Int32 {
            if let i = serviceIndex[id] { return i }
            let i = Int32(serviceIndex.count)
            serviceIndex[id] = i
            out.serviceActive.append(contentsOf: [UInt8](repeating: 0, count: dayCount))
            return i
        }
        for (id, cal) in calendars {
            let base = Int(service(id)) * dayCount
            var d = max(cal.start, minDay)
            while d <= min(cal.end, maxDay) {
                if cal.mask[CivilDate.weekday(d)] { out.serviceActive[base + d - minDay] = 1 }
                d += 1
            }
        }
        for (id, day, type) in exceptions where day <= maxDay {
            let base = Int(service(id)) * dayCount
            out.serviceActive[base + day - minDay] = type == 1 ? 1 : 0
        }
        out.serviceCount = Int32(serviceIndex.count)

        // Trips
        progress("Reading trips…")
        var tripIndex: [String: Int32] = [:]
        var tripRoute: [Int32] = [], tripService: [Int32] = []
        try CSVFile.read(dir.appendingPathComponent("trips.txt"), columns: ["trip_id", "route_id", "service_id"]) { r in
            guard let route = routeIndex[r.string(1)] else { return }
            tripIndex[r.string(0)] = Int32(tripRoute.count)
            tripRoute.append(route)
            tripService.append(service(r.string(2)))
        }
        out.serviceCount = Int32(serviceIndex.count)

        // Stop times
        progress("Reading stop times (this takes a moment)…")
        var rTrip: [Int32] = [], rSeq: [Int32] = [], rStation: [Int32] = []
        var rArr: [Int32] = [], rDep: [Int32] = [], rPlat: [UInt16] = [], rFlags: [UInt8] = []
        let estimate = 2_500_000
        rTrip.reserveCapacity(estimate); rSeq.reserveCapacity(estimate); rStation.reserveCapacity(estimate)
        rArr.reserveCapacity(estimate); rDep.reserveCapacity(estimate); rPlat.reserveCapacity(estimate); rFlags.reserveCapacity(estimate)
        var lastTripBytes: [UInt8] = []
        var lastTrip: Int32 = -1
        var lastStopBytes: [UInt8] = []
        var lastStop: (Int32, UInt16) = (-1, 0)
        try CSVFile.read(dir.appendingPathComponent("stop_times.txt"),
                         columns: ["trip_id", "arrival_time", "departure_time", "stop_id", "stop_sequence", "pickup_type", "drop_off_type"]) { r in
            if !r.equals(0, lastTripBytes) {
                lastTripBytes = r.bytes(0)
                lastTrip = tripIndex[r.string(0)] ?? -1
            }
            guard lastTrip >= 0 else { return }
            if !r.equals(3, lastStopBytes) {
                lastStopBytes = r.bytes(3)
                let id = r.string(3)
                lastStop = (stationOf[id] ?? -1, platformOf[id] ?? 0)
            }
            guard lastStop.0 >= 0 else { return }
            let a = r.time(1), d = r.time(2)
            rTrip.append(lastTrip)
            rSeq.append(Int32(r.int(4) ?? 0))
            rStation.append(lastStop.0)
            rPlat.append(lastStop.1)
            rArr.append(a ?? d ?? -1)
            rDep.append(d ?? a ?? -1)
            var f: UInt8 = 0
            if r.int(5) == 1 { f |= 1 }
            if r.int(6) == 1 { f |= 2 }
            rFlags.append(f)
        }

        progress("Building timetable…")
        // Order stop times by trip, then sequence.
        var order = Array(0..<Int32(rTrip.count))
        var sorted = true
        for i in 1..<max(1, rTrip.count) {
            let a = Int(i - 1), b = Int(i)
            if rTrip[a] > rTrip[b] || (rTrip[a] == rTrip[b] && rSeq[a] >= rSeq[b]) {
                sorted = false
                break
            }
        }
        if !sorted {
            order.sort { x, y in
                let a = Int(x), b = Int(y)
                return rTrip[a] != rTrip[b] ? rTrip[a] < rTrip[b] : rSeq[a] < rSeq[b]
            }
        }

        var pos = 0
        let n = order.count
        out.stStation.reserveCapacity(n); out.stArr.reserveCapacity(n); out.stDep.reserveCapacity(n)
        out.stPlatform.reserveCapacity(n); out.stFlags.reserveCapacity(n)
        while pos < n {
            let trip = rTrip[Int(order[pos])]
            var end = pos
            while end < n, rTrip[Int(order[end])] == trip { end += 1 }
            let count = end - pos
            if count >= 2 {
                let start = out.stStation.count
                for k in pos..<end {
                    let i = Int(order[k])
                    // Merge consecutive stops at the same station (e.g. two platforms of one station).
                    if out.stStation.count > start, out.stStation.last == rStation[i] {
                        out.stDep[out.stDep.count - 1] = rDep[i]
                        continue
                    }
                    out.stStation.append(rStation[i])
                    out.stArr.append(rArr[i])
                    out.stDep.append(rDep[i])
                    out.stPlatform.append(rPlat[i])
                    out.stFlags.append(rFlags[i])
                }
                let stored = out.stStation.count - start
                if stored >= 2 && interpolate(&out, start: start, end: out.stStation.count) {
                    out.tripRoute.append(tripRoute[Int(trip)])
                    out.tripService.append(tripService[Int(trip)])
                    out.tripStart.append(Int32(out.stStation.count))
                } else {
                    let drop = out.stStation.count - start
                    out.stStation.removeLast(drop); out.stArr.removeLast(drop); out.stDep.removeLast(drop)
                    out.stPlatform.removeLast(drop); out.stFlags.removeLast(drop)
                }
            }
            pos = end
        }
        guard out.tripCount > 0 else { throw ImportError(message: "The timetable contains no trips.") }
        return out
    }

    /// Fills missing (-1) times by linear interpolation. Returns false if the trip is unusable.
    private static func interpolate(_ d: inout TimetableData, start: Int, end: Int) -> Bool {
        guard d.stDep[start] >= 0, d.stArr[end - 1] >= 0 else { return false }
        var k = start
        while k < end {
            if d.stArr[k] < 0 || d.stDep[k] < 0 {
                var j = k
                while j < end, d.stArr[j] < 0 || d.stDep[j] < 0 { j += 1 }
                guard j < end else { return false }
                let t0 = d.stDep[k - 1], t1 = d.stArr[j]
                let steps = Int32(j - k + 1)
                for m in k..<j {
                    let t = t0 + (t1 - t0) * Int32(m - k + 1) / steps
                    d.stArr[m] = t
                    d.stDep[m] = t
                }
                k = j
            }
            k += 1
        }
        return true
    }

    /// Heuristics for what the Deutschlandticket does *not* cover (long distance, private open-access,
    /// heritage and international trains). The regional GTFS feed contains a few of these.
    public enum DTicket {
        static let agencyKeywords = [
            "fernverkehr", "flixtrain", "eurostar", "european sleeper", "westbahn", "partyzug",
            "bahntouristikexpress", "autozug", "rombs touristik", "touristische bahnen",
            "harzer schmalspurbahn", "molli", "brohltalbahn", "kasbachtalbahn", "wanderbahn",
            "bayernbahn", "dampfeisenbahn", "gaildorf", "mainschleifenbahn", "trenitalia",
            "pkp intercity", "hzzp", "zssk", "dänische staatsbahnen", "snälltåget", "regiojet", "leo express",
        ]
        static let excludedLines: Set<String> = [
            "FLX", "IC", "ICE", "EC", "ECE", "ECM", "EN", "NJ", "RJ", "RJX", "TGV", "TGD", "THA",
            "DRF", "HSB", "MBB", "P", "SP", "OS", "RR",
        ]

        public static func excludes(agency: String) -> Bool {
            let a = agency.lowercased()
            if a == "mav" || a.hasSuffix(" mav") { return true }
            return agencyKeywords.contains { a.contains($0) }
        }

        public static func excludes(line: String) -> Bool {
            let n = line.uppercased().trimmingCharacters(in: .whitespaces)
            if n.isEmpty { return false }
            // Pure train numbers (often night / long distance trains in this feed), e.g. "27", "62N".
            if n.allSatisfy({ $0.isNumber }) || (n.dropLast().allSatisfy({ $0.isNumber }) && n.last == "N" && n.count > 1) { return true }
            let prefix = String(n.prefix { $0.isLetter })
            return excludedLines.contains(prefix)
        }
    }

    /// "8006A7 DB RegioNetz Verkehrs GmbH" -> "DB RegioNetz Verkehrs GmbH"
    static func cleanAgency(_ name: String) -> String {
        let parts = name.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].count == 6,
           parts[0].allSatisfy({ $0.isHexDigit }), parts[0].contains(where: { $0.isNumber }) {
            return String(parts[1])
        }
        return name
    }
}
