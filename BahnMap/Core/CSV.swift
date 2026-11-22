import Foundation

/// A single parsed CSV record. Field accessors take the index of the column in the
/// `columns` list that was passed to `CSVFile.read`, not the index in the file.
struct CSVRow {
    let base: UnsafePointer<UInt8>
    let starts: [Int]
    let ends: [Int]
    let escaped: [Bool]
    let map: [Int] // requested column -> file column (-1 = missing)

    @inline(__always)
    private func range(_ c: Int) -> (Int, Int)? {
        let f = map[c]
        guard f >= 0, f < starts.count else { return nil }
        var s = starts[f], e = ends[f]
        while s < e, base[s] == 0x20 { s += 1 }
        while e > s, base[e - 1] == 0x20 { e -= 1 }
        return (s, e)
    }

    func isEmpty(_ c: Int) -> Bool {
        guard let (s, e) = range(c) else { return true }
        return s == e
    }

    func string(_ c: Int) -> String {
        guard let (s, e) = range(c), s < e else { return "" }
        let buf = UnsafeBufferPointer(start: base + s, count: e - s)
        let str = String(decoding: buf, as: UTF8.self)
        if escaped[map[c]] { return str.replacingOccurrences(of: "\"\"", with: "\"") }
        return str
    }

    func int(_ c: Int) -> Int? {
        guard let (s, e) = range(c), s < e else { return nil }
        var v = 0
        var neg = false
        var i = s
        if base[i] == 0x2D { neg = true; i += 1 }
        guard i < e else { return nil }
        while i < e {
            let d = Int(base[i]) - 48
            guard d >= 0, d <= 9 else { return nil }
            v = v * 10 + d
            i += 1
        }
        return neg ? -v : v
    }

    func double(_ c: Int) -> Double? {
        let s = string(c)
        return s.isEmpty ? nil : Double(s)
    }

    /// Parses GTFS times like "7:05:00" or "25:10:00" into seconds after midnight.
    func time(_ c: Int) -> Int32? {
        guard let (s, e) = range(c), s < e else { return nil }
        var parts = [0, 0, 0]
        var p = 0
        var digits = 0
        for i in s..<e {
            let ch = base[i]
            if ch == 0x3A { // ':'
                p += 1
                if p > 2 { return nil }
                continue
            }
            let d = Int(ch) - 48
            guard d >= 0, d <= 9 else { return nil }
            parts[p] = parts[p] * 10 + d
            digits += 1
        }
        guard digits > 0, p >= 1 else { return nil }
        return Int32(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    /// Compares a field's raw bytes to `bytes` without allocating.
    func equals(_ c: Int, _ bytes: [UInt8]) -> Bool {
        guard let (s, e) = range(c) else { return bytes.isEmpty }
        guard e - s == bytes.count else { return false }
        for i in 0..<bytes.count where base[s + i] != bytes[i] { return false }
        return true
    }

    func bytes(_ c: Int) -> [UInt8] {
        guard let (s, e) = range(c), s < e else { return [] }
        return Array(UnsafeBufferPointer(start: base + s, count: e - s))
    }
}

enum CSVFile {
    struct MissingFile: Error, LocalizedError {
        let name: String
        var errorDescription: String? { "Timetable file \(name) is missing." }
    }

    /// Streams the records of a CSV file. Handles RFC 4180 quoting, CRLF and a UTF-8 BOM.
    static func read(_ url: URL, columns: [String], row handler: (CSVRow) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFile(name: url.lastPathComponent)
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            try parse(p, raw.count, columns: columns, handler)
        }
    }

    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, columns: [String], _ handler: (CSVRow) throws -> Void) throws {
        let quote: UInt8 = 0x22, comma: UInt8 = 0x2C, lf: UInt8 = 0x0A, cr: UInt8 = 0x0D
        var i = 0
        if n >= 3, p[0] == 0xEF, p[1] == 0xBB, p[2] == 0xBF { i = 3 }
        var starts: [Int] = [], ends: [Int] = [], esc: [Bool] = []
        starts.reserveCapacity(16); ends.reserveCapacity(16); esc.reserveCapacity(16)
        var map: [Int]? = nil

        while i < n {
            starts.removeAll(keepingCapacity: true)
            ends.removeAll(keepingCapacity: true)
            esc.removeAll(keepingCapacity: true)
            while true {
                if i < n, p[i] == quote {
                    i += 1
                    let s = i
                    var e = false
                    while i < n {
                        if p[i] == quote {
                            if i + 1 < n, p[i + 1] == quote { e = true; i += 2; continue }
                            break
                        }
                        i += 1
                    }
                    starts.append(s); ends.append(min(i, n)); esc.append(e)
                    if i < n { i += 1 }
                    while i < n, p[i] != comma, p[i] != lf, p[i] != cr { i += 1 }
                } else {
                    let s = i
                    while i < n, p[i] != comma, p[i] != lf, p[i] != cr { i += 1 }
                    starts.append(s); ends.append(i); esc.append(false)
                }
                if i < n, p[i] == comma { i += 1; continue }
                if i < n, p[i] == cr { i += 1 }
                if i < n, p[i] == lf { i += 1 }
                break
            }
            if starts.count == 1, starts[0] == ends[0] { continue }

            if let map {
                try handler(CSVRow(base: p, starts: starts, ends: ends, escaped: esc, map: map))
            } else {
                var names: [String: Int] = [:]
                for k in 0..<starts.count {
                    let name = String(decoding: UnsafeBufferPointer(start: p + starts[k], count: ends[k] - starts[k]), as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    names[name] = k
                }
                map = columns.map { names[$0] ?? -1 }
            }
        }
    }
}
