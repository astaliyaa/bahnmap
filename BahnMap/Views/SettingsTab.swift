import SwiftUI

struct SettingsTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Settings.minTransferKey) private var minTransfer = 4
    @AppStorage(Settings.feedURLKey) private var feedURL = GTFSImporter.defaultFeedURL.absoluteString

    var body: some View {
        NavigationStack {
            Form {
                if let tt = model.timetable {
                    Section("Timetable") {
                        LabeledContent("Valid", value: "\(ServiceClock.dateString(civilDay: Int(tt.data.firstDay))) – \(ServiceClock.dateString(civilDay: Int(tt.data.firstDay + tt.data.dayCount - 1)))")
                        LabeledContent("Stations", value: tt.stationCount.formatted())
                        LabeledContent("Lines", value: tt.data.routeNames.count.formatted())
                        LabeledContent("Trips", value: tt.data.tripCount.formatted())
                        LabeledContent("Downloaded", value: Date(timeIntervalSince1970: tt.data.importedAt).formatted(date: .abbreviated, time: .shortened))
                        Button {
                            Task { await model.download() }
                        } label: {
                            HStack {
                                Text("Update timetable now")
                                Spacer()
                                if model.isWorking { ProgressView() }
                            }
                        }
                        .disabled(model.isWorking)
                        if let s = model.status { Text(s).font(.caption).foregroundStyle(.secondary) }
                        if let e = model.errorMessage { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
                Section {
                    Stepper("Minimum change time: \(minTransfer) min", value: $minTransfer, in: 1...20)
                } header: {
                    Text("Routing")
                } footer: {
                    Text("Time you need to change trains at the same station. Walking between nearby stations is added automatically.")
                }
                Section {
                    TextField("GTFS feed URL", text: $feedURL, axis: .vertical)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("Reset to default") { feedURL = GTFSImporter.defaultFeedURL.absoluteString }
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Default: the free German regional rail feed from GTFS.de. It's refreshed weekly and the app updates itself automatically.")
                }
                Section("About") {
                    Text("BahnMap shows regional trains (S-Bahn, RE, RB) that the Deutschlandticket covers. It leaves out ICE/IC/EC, FlixTrain, night trains and heritage railways. A few cross-border sections may need an extra ticket, so check if you're unsure.")
                        .font(.footnote)
                    Text("Timetable data © DELFI e.V., provided by GTFS.de, licensed CC BY 4.0. Timetable times only, no live delays.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("gtfs.de", destination: URL(string: "https://gtfs.de")!)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
