import SwiftUI

struct LineBadge: View {
    let name: String
    let category: LineCategory
    var small = false

    var body: some View {
        Text(name)
            .font(small ? .caption2.weight(.bold) : .caption.weight(.bold))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, small ? 5 : 7)
            .padding(.vertical, small ? 2 : 3)
            .foregroundStyle(.white)
            .background(category.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct TimeText: View {
    let seconds: Int32
    var body: some View {
        Text(ServiceClock.hhmm(seconds)).monospacedDigit()
    }
}

struct DepartureRow: View {
    let departure: Departure
    var arrivals = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TimeText(seconds: departure.time)
                .font(.body.weight(.semibold))
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    LineBadge(name: departure.line, category: departure.category)
                    Text(arrivals ? "from \(departure.headsign)" : departure.headsign)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !departure.platform.isEmpty {
                Text("Pl. \(departure.platform)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct JourneyRow: View {
    let journey: Journey
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(ServiceClock.hhmm(journey.departure)) – \(ServiceClock.hhmm(journey.arrival))")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                Text(ServiceClock.duration(journey.duration))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                if let tt = model.timetable {
                    ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                        switch leg {
                        case let .ride(inst, _, _):
                            LineBadge(name: tt.lineName(trip: inst.trip), category: tt.category(trip: inst.trip), small: true)
                        case .walk:
                            Image(systemName: "figure.walk").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Text(journey.transfers == 0 ? "direct" : "\(journey.transfers) change\(journey.transfers == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StationSearchResults: View {
    let results: [Int32]
    let onPick: (Int32) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tt = model.timetable {
            ForEach(results, id: \.self) { s in
                Button {
                    onPick(s)
                } label: {
                    HStack {
                        Image(systemName: "tram.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(tt.name(s)).foregroundStyle(.primary)
                            Text(tt.lines(at: s).prefix(6).map(\.name).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
