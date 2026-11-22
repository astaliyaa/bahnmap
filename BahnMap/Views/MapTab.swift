import MapKit
import SwiftUI

struct MapTab: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var showLegend = false
    @AppStorage("showNetwork") private var showNetwork = true
    @FocusState private var searchFocused: Bool

    private var results: [Int32] {
        guard let tt = model.timetable, !query.isEmpty else { return [] }
        return tt.search(query, limit: 12)
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            NetworkMapView(timetable: model.timetable,
                           reach: model.reachResult,
                           reachMaxSeconds: Int32((model.reach?.maxMinutes ?? 120) * 60),
                           highlight: model.highlight,
                           focus: model.focus,
                           showNetwork: showNetwork) { s in
                searchFocused = false
                model.openStation(s)
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                searchBar
                if searchFocused || !query.isEmpty {
                    if !results.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                StationSearchResults(results: results) { s in
                                    query = ""
                                    searchFocused = false
                                    model.focusStation(s)
                                }
                            }
                            .padding()
                        }
                        .frame(maxHeight: 320)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                } else if model.reach != nil {
                    ReachPanel()
                } else if let h = model.highlight {
                    HStack {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        Text(h.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer()
                        Button {
                            model.highlight = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if model.dataExpiresSoon {
                    Label("Timetable data is about to expire. Update it in Settings.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(8)
                        .background(.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                if showLegend { legend }
                HStack(spacing: 10) {
                    mapButton(showNetwork ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted") {
                        showNetwork.toggle()
                    }
                    mapButton("info.circle") { withAnimation { showLegend.toggle() } }
                    mapButton("location") {
                        LocationProvider.shared.request()
                        if let loc = LocationProvider.shared.location, let tt = model.timetable,
                           let s = tt.nearest(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude).first {
                            model.focusStation(s)
                        }
                    }
                }
            }
            .padding()
        }
        .sheet(item: $model.stationSheet) { ref in
            StationSheet(station: ref.id)
                .presentationDetents([.fraction(0.5), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
                .presentationContentInteraction(.scrolls)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search station", text: $query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit {
                    if let first = results.first {
                        query = ""
                        model.focusStation(first)
                    }
                }
            if !query.isEmpty || searchFocused {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private func mapButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(LineCategory.allCases, id: \.self) { c in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(c.color).frame(width: 22, height: 4)
                    Text(c.label).font(.caption)
                }
            }
            Divider()
            Text("Only Deutschlandticket trains\n(S-Bahn, RE, RB) are shown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Controls for the "where can I go" (isochrone) mode.
struct ReachPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showList = false

    private let rideOptions: [(String, Int)] = [("Direct", 1), ("≤ 1 change", 2), ("≤ 2", 3), ("Any", 8)]

    var body: some View {
        if let tt = model.timetable, let reach = model.reach {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "scope").foregroundStyle(.purple)
                    Text(tt.name(reach.origin)).font(.headline).lineLimit(1)
                    Spacer()
                    if model.reachComputing { ProgressView().controlSize(.small) }
                    Button {
                        model.clearReach()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Leave")
                        .font(.subheadline)
                    DatePicker("Leave", selection: Binding(get: { model.reach?.date ?? Date() },
                                                           set: { model.reach?.date = $0 }))
                        .labelsHidden()
                        .datePickerStyle(.compact)
                    Spacer()
                }
                HStack {
                    Text("Within \(ServiceClock.duration(Int32(reach.maxMinutes * 60)))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .frame(width: 118, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.reach?.maxMinutes ?? 120) },
                                          set: { model.reach?.maxMinutes = Int($0) }),
                           in: 15...480, step: 15)
                }
                Picker("Changes", selection: Binding(get: { model.reach?.maxRides ?? 8 }, set: { model.reach?.maxRides = $0 })) {
                    ForEach(rideOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                .pickerStyle(.segmented)
                HStack {
                    if let r = model.reachResult {
                        let n = r.arrival.indices.filter { r.arrival[$0] != Int32.max && Int32($0) != r.origin && tt.importance[$0] > 0 }.count
                        Text("\(n) stations reachable").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showList = true
                    } label: {
                        Label("List", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.reachResult == nil)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .task(id: reach) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                await model.computeReach()
            }
            .sheet(isPresented: $showList) {
                ReachListView { s in
                    showList = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { model.focusStation(s) }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

struct ReachListView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    let onPick: (Int32) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let tt = model.timetable, let r = model.reachResult {
                    let folded = Timetable.fold(filter)
                    let items = r.arrival.indices
                        .filter { r.arrival[$0] != Int32.max && Int32($0) != r.origin && tt.importance[$0] > 0 }
                        .filter { filter.isEmpty || Timetable.fold(tt.name(Int32($0))).contains(folded) }
                        .sorted { r.arrival[$0] < r.arrival[$1] }
                    ForEach(items, id: \.self) { i in
                        Button {
                            onPick(Int32(i))
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(tt.name(Int32(i))).foregroundStyle(.primary)
                                    let rides = Int(r.rides[i])
                                    Text("arrive \(ServiceClock.hhmm(r.arrival[i])) · " + (rides <= 1 ? "direct" : "\(rides - 1) change\(rides == 2 ? "" : "s")"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ServiceClock.duration(r.arrival[i] - r.start))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Filter destinations")
            .navigationTitle("Reachable")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
