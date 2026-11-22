import SwiftUI

struct StationSheet: View {
    let station: Int32
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var arrivals = false

    var body: some View {
        NavigationStack {
            if let tt = model.timetable {
                List {
                    header(tt)
                    Section {
                        Picker("Board", selection: $arrivals) {
                            Text("Departures").tag(false)
                            Text("Arrivals").tag(true)
                        }
                        .pickerStyle(.segmented)
                        DatePicker("From", selection: $date)
                    }
                    board(tt)
                }
                .listStyle(.insetGrouped)
                .navigationTitle(tt.name(station))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.toggleFavorite(station)
                        } label: {
                            Image(systemName: model.isFavorite(station) ? "star.fill" : "star")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationDestination(for: Departure.self) { d in
                    TripView(instance: d.instance, focusStop: d.stopIndex)
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ tt: Timetable) -> some View {
        Section {
            if let r = model.reachResult, let reach = model.reach, r.origin != station, r.isReachable(station) {
                let rides = Int(r.rides[Int(station)])
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(ServiceClock.duration(r.arrival[Int(station)] - r.start)) from \(tt.name(r.origin))",
                          systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Text("Arrive \(ServiceClock.hhmm(r.arrival[Int(station)])) · " + (rides <= 1 ? "direct" : "\(rides - 1) change\(rides == 2 ? "" : "s")"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Show connections") {
                        model.planRoute(from: r.origin, to: station, date: reach.date)
                    }
                    .font(.subheadline)
                }
            }
            HStack(spacing: 8) {
                action("From here", "arrow.up.right.circle.fill") { model.planRoute(from: station, to: nil) }
                action("To here", "arrow.down.right.circle.fill") { model.planRoute(from: nil, to: station) }
                action("Where to?", "scope") { model.explore(from: station, date: date) }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            let lines = tt.lines(at: station)
            if !lines.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(lines, id: \.name) { LineBadge(name: $0.name, category: $0.category) }
                    }
                }
            }
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder
    private func board(_ tt: Timetable) -> some View {
        let q = ServiceClock.query(date, tt)
        if !ServiceClock.isCovered(date, tt) {
            Section {
                Text("This date is outside the downloaded timetable (\(ServiceClock.dateString(civilDay: Int(tt.data.firstDay))) – \(ServiceClock.dateString(civilDay: Int(tt.data.firstDay + tt.data.dayCount - 1)))).")
                    .foregroundStyle(.secondary)
            }
        } else {
            let items = tt.departures(station: station, day: q.day, from: q.seconds - 60, window: 4 * 3600, arrivals: arrivals)
            Section(arrivals ? "Arrivals" : "Departures") {
                if items.isEmpty {
                    Text("No trains in the next 4 hours.").foregroundStyle(.secondary)
                }
                ForEach(items) { d in
                    NavigationLink(value: d) {
                        DepartureRow(departure: d, arrivals: arrivals)
                    }
                }
            }
        }
    }
}

struct TripView: View {
    let instance: TripInstance
    var focusStop: Int32? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tt = model.timetable {
            let stops = tt.stops(of: instance)
            List {
                Section {
                    HStack {
                        LineBadge(name: tt.lineName(trip: instance.trip), category: tt.category(trip: instance.trip))
                        Text("→ \(tt.headsign(trip: instance.trip))").font(.headline)
                    }
                    let op = tt.operatorName(trip: instance.trip)
                    if !op.isEmpty {
                        Text(op).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button {
                        model.show(trip: instance)
                    } label: {
                        Label("Show on map", systemImage: "map")
                    }
                }
                Section("\(stops.count) stops") {
                    ForEach(Array(stops.enumerated()), id: \.element.id) { i, s in
                        StopRow(name: tt.name(s.station), stop: s, isFirst: i == 0, isLast: i == stops.count - 1,
                                color: tt.category(trip: instance.trip).color, highlighted: s.stopIndex == focusStop)
                            .contentShape(Rectangle())
                            .onTapGesture { model.focusStation(s.station) }
                    }
                }
            }
            .navigationTitle(tt.lineName(trip: instance.trip))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct StopRow: View {
    let name: String
    let stop: TripStop
    let isFirst: Bool
    let isLast: Bool
    let color: Color
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                if !isFirst { TimeText(seconds: stop.arrival).font(.caption).foregroundStyle(isLast ? .primary : .secondary) }
                if !isLast && (isFirst || stop.departure != stop.arrival) { TimeText(seconds: stop.departure).font(.caption) }
            }
            .frame(width: 46, alignment: .trailing)
            ZStack {
                Rectangle().fill(color).frame(width: 4)
                    .padding(.top, isFirst ? 22 : -12)
                    .padding(.bottom, isLast ? 22 : -12)
                Circle()
                    .strokeBorder(color, lineWidth: 3)
                    .background(Circle().fill(highlighted ? color : Color(.systemBackground)))
                    .frame(width: 14, height: 14)
            }
            .frame(width: 16)
            Text(name)
                .font(highlighted || isFirst || isLast ? .body.weight(.semibold) : .body)
                .lineLimit(2)
            Spacer()
            if !stop.platform.isEmpty {
                Text("Pl. \(stop.platform)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowSeparator(.hidden)
    }
}
