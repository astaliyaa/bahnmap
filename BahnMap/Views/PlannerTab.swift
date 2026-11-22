import MapKit
import SwiftUI

struct PlannerTab: View {
    @Environment(AppModel.self) private var model
    @State private var journeys: [Journey] = []
    @State private var searching = false
    @State private var message: String?
    @State private var picking: PickTarget?
    @State private var directOnly = false

    enum PickTarget: String, Identifiable {
        case from, to
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    stationRow("From", model.plannerFrom, icon: "circle.circle") { picking = .from }
                    stationRow("To", model.plannerTo, icon: "mappin.circle.fill") { picking = .to }
                    Button {
                        let f = model.plannerFrom
                        model.plannerFrom = model.plannerTo
                        model.plannerTo = f
                        journeys = []
                    } label: {
                        Label("Swap", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(model.plannerFrom == nil && model.plannerTo == nil)
                }
                Section {
                    DatePicker("Departure", selection: $model.plannerDate)
                    HStack {
                        Button("Now") { model.plannerDate = Date() }
                        Spacer()
                        Button("+1 h") { model.plannerDate.addTimeInterval(3600) }
                    }
                    .buttonStyle(.borderless)
                    Toggle("Direct trains only", isOn: $directOnly)
                }
                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Spacer()
                            if searching { ProgressView() } else { Text("Search connections").bold() }
                            Spacer()
                        }
                    }
                    .disabled(model.plannerFrom == nil || model.plannerTo == nil || searching)
                }
                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
                if !journeys.isEmpty {
                    Section("Connections · Deutschlandticket") {
                        ForEach(journeys) { j in
                            NavigationLink(value: j) { JourneyRow(journey: j) }
                        }
                        Button("Later connections") {
                            if let last = journeys.last, let tt = model.timetable {
                                let q = ServiceClock.query(model.plannerDate, tt)
                                model.plannerDate.addTimeInterval(TimeInterval(last.departure - q.seconds + 60))
                                Task { await search() }
                            }
                        }
                    }
                }
                if let tt = model.timetable, !model.favorites.isEmpty, journeys.isEmpty {
                    Section("Favourites") {
                        ForEach(model.favorites, id: \.self) { s in
                            Menu {
                                Button("From here") { model.plannerFrom = s }
                                Button("To here") { model.plannerTo = s }
                            } label: {
                                Label(tt.name(s), systemImage: "star.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Plan a trip")
            .navigationDestination(for: Journey.self) { JourneyDetailView(journey: $0) }
            .sheet(item: $picking) { target in
                StationPicker(title: target == .from ? "From" : "To") { s in
                    if target == .from { model.plannerFrom = s } else { model.plannerTo = s }
                    journeys = []
                    picking = nil
                }
            }
            .task(id: model.plannerRequest) {
                if model.plannerRequest != nil { await search() }
            }
        }
    }

    private func stationRow(_ label: String, _ s: Int32?, icon: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
                Text(label).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                if let s, let tt = model.timetable {
                    Text(tt.name(s)).foregroundStyle(.primary)
                } else {
                    Text("Choose station").foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private func search() async {
        guard let tt = model.timetable, let from = model.plannerFrom, let to = model.plannerTo else { return }
        guard ServiceClock.isCovered(model.plannerDate, tt) else {
            journeys = []
            message = "This date is outside the downloaded timetable."
            return
        }
        searching = true
        message = nil
        let q = ServiceClock.query(model.plannerDate, tt)
        var options = Settings.routingOptions
        if directOnly { options.maxRides = 1 }
        let found = await Task.detached(priority: .userInitiated) {
            tt.journeys(from: from, to: to, day: q.day, start: q.seconds, count: 6, options: options)
        }.value
        journeys = found
        searching = false
        if found.isEmpty {
            message = directOnly ? "No direct regional train found. Try allowing changes." : "No regional connection found for this day."
        }
    }
}

struct StationPicker: View {
    let title: String
    let onPick: (Int32) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if let tt = model.timetable {
                    if query.isEmpty {
                        if let loc = LocationProvider.shared.location,
                           let s = tt.nearest(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude).first {
                            Section("Nearby") {
                                Button {
                                    onPick(s)
                                } label: {
                                    Label(tt.name(s), systemImage: "location.fill")
                                }
                            }
                        }
                        if !model.favorites.isEmpty {
                            Section("Favourites") {
                                ForEach(model.favorites, id: \.self) { s in
                                    Button { onPick(s) } label: { Label(tt.name(s), systemImage: "star.fill") }
                                }
                            }
                        }
                    } else {
                        StationSearchResults(results: tt.search(query), onPick: onPick)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station name")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { LocationProvider.shared.request() }
        }
    }
}

struct JourneyDetailView: View {
    let journey: Journey
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tt = model.timetable {
            List {
                Section {
                    JourneyMap(segments: model.segments(for: journey))
                        .frame(height: 230)
                        .listRowInsets(EdgeInsets())
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(ServiceClock.hhmm(journey.departure)) – \(ServiceClock.hhmm(journey.arrival))")
                                .font(.title3.weight(.semibold)).monospacedDigit()
                            Text("\(ServiceClock.duration(journey.duration)) · " + (journey.transfers == 0 ? "direct" : "\(journey.transfers) change\(journey.transfers == 1 ? "" : "s")"))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.show(journey: journey)
                        } label: {
                            Label("Map", systemImage: "map")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { i, leg in
                    legSection(tt, leg, previous: i > 0 ? journey.legs[i - 1] : nil)
                }
                Section {
                    Text("Times are from the published timetable. Check live delays on bahn.de or in the DB Navigator before you travel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func legEnd(_ tt: Timetable, _ leg: Leg) -> Int32? {
        switch leg {
        case let .ride(inst, _, to): return tt.data.stArr[Int(to)] + inst.shift * 86400
        case let .walk(_, _, dep, secs): return dep + secs
        }
    }

    @ViewBuilder
    private func legSection(_ tt: Timetable, _ leg: Leg, previous: Leg?) -> some View {
        switch leg {
        case let .ride(inst, from, to):
            let stops = tt.stops(of: inst).filter { $0.stopIndex >= from && $0.stopIndex <= to }
            let color = tt.category(trip: inst.trip).color
            Section {
                HStack {
                    LineBadge(name: tt.lineName(trip: inst.trip), category: tt.category(trip: inst.trip))
                    Text("→ \(tt.headsign(trip: inst.trip))").font(.subheadline.weight(.medium)).lineLimit(1)
                }
                if let first = stops.first, let last = stops.last {
                    StopRow(name: tt.name(first.station), stop: first, isFirst: true, isLast: false, color: color, highlighted: true)
                    if stops.count > 2 {
                        DisclosureGroup("\(stops.count - 2) intermediate stop\(stops.count == 3 ? "" : "s") · \(ServiceClock.duration(last.arrival - first.departure))") {
                            ForEach(stops.dropFirst().dropLast()) { s in
                                StopRow(name: tt.name(s.station), stop: s, isFirst: false, isLast: false, color: color)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    StopRow(name: tt.name(last.station), stop: last, isFirst: false, isLast: true, color: color, highlighted: true)
                }
            } header: {
                if let previous, let end = legEnd(tt, previous), let first = stops.first {
                    Text("Change · \(ServiceClock.duration(max(0, first.departure - end)))")
                }
            } footer: {
                let op = tt.operatorName(trip: inst.trip)
                if !op.isEmpty { Text(op) }
            }
        case let .walk(from, to, _, secs):
            Section {
                Label("Walk \(ServiceClock.duration(secs)) from \(tt.name(from)) to \(tt.name(to))", systemImage: "figure.walk")
                    .font(.subheadline)
            }
        }
    }
}

struct JourneyMap: View {
    let segments: [HighlightSegment]

    var body: some View {
        let all = segments.flatMap(\.coordinates)
        Map(initialPosition: position(all), interactionModes: [.pan, .zoom]) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                MapPolyline(coordinates: seg.coordinates)
                    .stroke(Color(seg.color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: seg.dashed ? [4, 6] : []))
            }
            if let f = all.first {
                Marker("Start", systemImage: "circle.circle", coordinate: f).tint(.green)
            }
            if let l = all.last {
                Marker("Destination", systemImage: "mappin", coordinate: l).tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
    }

    private func position(_ coords: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard !coords.isEmpty else { return .automatic }
        var pts = coords
        let r = MKPolyline(coordinates: &pts, count: pts.count).boundingMapRect
        let padded = r.insetBy(dx: -max(r.width * 0.2, 3000), dy: -max(r.height * 0.25, 3000))
        return .rect(padded)
    }
}
