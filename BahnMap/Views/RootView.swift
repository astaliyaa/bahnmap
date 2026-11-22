import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        switch model.phase {
        case .starting:
            ProgressView("Loading timetable…")
        case .needsData:
            WelcomeView()
        case .ready:
            TabView(selection: $model.selectedTab) {
                MapTab()
                    .tabItem { Label("Map", systemImage: "map") }
                    .tag(AppTab.map)
                PlannerTab()
                    .tabItem { Label("Connections", systemImage: "arrow.triangle.swap") }
                    .tag(AppTab.planner)
                SettingsTab()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "tram.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white)
                .frame(width: 120, height: 120)
                .background(LinearGradient(colors: [Color(red: 0.86, green: 0.1, blue: 0.12), Color(red: 0.55, green: 0.05, blue: 0.1)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text("BahnMap").font(.largeTitle.bold())
            Text("Every station and line you can ride with the Deutschlandticket: S-Bahn, RE and RB, on one map. Find out where you can get to and plan your trip, even offline.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            Spacer()
            if model.isWorking {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.status ?? "Working…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(height: 70)
            } else {
                VStack(spacing: 8) {
                    if let e = model.errorMessage {
                        Text(e).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await model.download() }
                    } label: {
                        Text("Download timetable (≈ 15 MB)")
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.86, green: 0.1, blue: 0.12))
                }
                .frame(height: 70)
            }
            Text("Timetable data: DELFI e.V. via GTFS.de (CC BY 4.0)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
