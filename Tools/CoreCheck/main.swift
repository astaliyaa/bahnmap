import Foundation
import TimetableCore

// Usage: CoreCheck <gtfs.zip | gtfs-dir> [cache.bin]
// Imports a feed, round-trips it through the binary cache and runs some sample queries.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: CoreCheck <gtfs.zip|dir> [cache.bin]"); exit(2) }
let input = URL(fileURLWithPath: args[1])
func ms(_ t: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000) }

var t0 = Date()
let data: TimetableData
if input.pathExtension == "zip" {
    data = try GTFSImporter.importZip(input, sourceURL: input.path) { print("  ·", $0) }
} else {
    data = try GTFSImporter.importDirectory(input, sourceURL: input.path) { print("  ·", $0) }
}
print("import: \(ms(t0)); stations \(data.stationCount), trips \(data.tripCount), stop times \(data.stStation.count), days \(data.dayCount)")

t0 = Date()
let blob = data.serialized()
let back = try TimetableData(serialized: blob)
print("serialize roundtrip: \(ms(t0)), \(blob.count / 1_000_000) MB")
if args.count >= 3 { try blob.write(to: URL(fileURLWithPath: args[2])) }
precondition(back.stStation == data.stStation && back.stationNames == data.stationNames && back.serviceActive == data.serviceActive)

t0 = Date()
let tt = Timetable(data: back)
print("index: \(ms(t0)); edges \(tt.edges.count)")
let cats = Dictionary(grouping: tt.data.routeCategory, by: { $0 }).mapValues(\.count)
print("route categories:", cats.sorted { $0.key < $1.key }.map { "\(LineCategory(rawValue: $0.key)!.label)=\($0.value)" })

func station(_ q: String) -> Int32 {
    let r = tt.search(q)
    print("search '\(q)':", r.prefix(4).map { tt.name($0) })
    return r[0]
}
func hhmm(_ t: Int32) -> String { String(format: "%02d:%02d", (t / 3600) % 24, (t / 60) % 60) + (t >= 86400 ? "+1" : "") }

let day: Int32 = 2 // a few days into the feed
let leipzig = station("Leipzig Hbf")
let dresden = station("dresden hbf")
let muenchen = station("München Hbf")
let berlin = station("berlin hbf")
_ = station("Köln")

t0 = Date()
let deps = tt.departures(station: leipzig, day: day, from: 8 * 3600, window: 3600)
print("departures Leipzig 08-09 (\(deps.count)) \(ms(t0)):")
for d in deps.prefix(8) { print("  \(hhmm(d.time)) \(d.line) → \(d.headsign) Gl. \(d.platform)") }
print("lines at Leipzig:", tt.lines(at: leipzig).map(\.name).prefix(25).joined(separator: ", "))

func show(_ js: [Journey]) {
    for j in js {
        print("  \(hhmm(j.departure)) → \(hhmm(j.arrival))  \(j.duration / 60) min, \(j.transfers) transfers")
        for l in j.legs {
            switch l {
            case let .ride(inst, f, to):
                print("     \(tt.lineName(trip: inst.trip)) \(tt.name(tt.data.stStation[Int(f)])) \(hhmm(tt.data.stDep[Int(f)] + inst.shift * 86400)) → \(tt.name(tt.data.stStation[Int(to)])) \(hhmm(tt.data.stArr[Int(to)] + inst.shift * 86400))")
            case let .walk(f, to, d, s):
                print("     walk \(tt.name(f)) → \(tt.name(to)) \(hhmm(d)) (\(s / 60) min)")
            }
        }
    }
}
t0 = Date()
_ = tt.reachability(from: leipzig, day: day, start: 0, maxDuration: 60)
print("connections build: \(ms(t0))")
for (a, b) in [(leipzig, dresden), (leipzig, berlin), (berlin, muenchen)] {
    t0 = Date()
    let js = tt.journeys(from: a, to: b, day: day, start: 8 * 3600, count: 4)
    print("journeys \(tt.name(a)) → \(tt.name(b)) at 08:00: \(js.count) in \(ms(t0))")
    show(js)
}
t0 = Date()
let r = tt.reachability(from: leipzig, day: day, start: 8 * 3600, maxDuration: 2 * 3600)
let reached = (0..<tt.stationCount).filter { r.isReachable(Int32($0)) }
print("reachable from Leipzig in 2h: \(reached.count) stations (\(ms(t0)))")
let direct = tt.reachability(from: leipzig, day: day, start: 8 * 3600, maxDuration: 2 * 3600, options: .init(maxRides: 1))
print("  direct only: \((0..<tt.stationCount).filter { direct.isReachable(Int32($0)) }.count)")
