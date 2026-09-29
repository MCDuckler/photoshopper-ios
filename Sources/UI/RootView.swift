import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        Group {
            if model.serverURL.isEmpty {
                ConnectView(first: true)
            } else {
                VStack(spacing: 0) {
                if model.showUpdateBanner, let r = model.update { UpdateBanner(release: r) }
                TabView(selection: $tab) {
                    LibraryView().tabItem { Label("Library", systemImage: "photo.on.rectangle") }.tag(0)
                    HomeView().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(1)
                    LogView().tabItem { Label("Activity", systemImage: "list.bullet") }.tag(2)
                    SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
                }
                }
            }
        }
        .task {
            if !model.serverURL.isEmpty { _ = await model.connect(url: model.serverURL) }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 8) {
                        Star().fill(Theme.red).frame(width: 14, height: 14)
                        Theme.label("Photoshopper3000")
                        Spacer()
                        Circle().fill(model.connected ? Color.green : Theme.red).frame(width: 7, height: 7)
                        Theme.meta(model.connected ? "Connected" : "Offline")
                    }
                    Hairline()

                    VStack(alignment: .leading, spacing: 6) {
                        Theme.label("Photos album")
                        Text(Settings.albumName).font(.custom("Helvetica Neue", size: 26).weight(.bold))
                        Theme.meta("Photos you pick in the Library tab (or in Photoshopper on the computer) land here and upload through iCloud Photos. Re-edits replace the old version.")
                    }

                    HStack(spacing: 22) {
                        stat("Selected", model.counts.selected)
                        stat("In Photos", model.counts.inPhotos)
                        stat("To go", model.counts.pending, warn: model.counts.pending > 0)
                        stat("Failed", model.counts.failed, warn: model.counts.failed > 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: model.progress)
                            .tint(Theme.red)
                            .opacity(model.running ? 1 : 0.25)
                        Theme.meta(model.status)
                        if let last = model.lastSync {
                            Theme.meta("Last sync \(last.formatted(.relative(presentation: .named)))")
                        }
                    }

                    TextButton(title: model.running ? "Syncing…" : "Sync now", primary: true) {
                        Task { await model.sync(reason: "manual") }
                    }
                    .disabled(model.running || !model.connected)

                    Button {
                        if let u = URL(string: "photos-redirect://") { UIApplication.shared.open(u) }
                    } label: { Theme.label("Open Photos").foregroundStyle(Theme.red) }
                }
                .padding(20)
            }
            .refreshable { await model.sync(reason: "manual") }
        }
    }

    private func stat(_ k: String, _ v: Int, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.custom("Helvetica Neue", size: 9)).tracking(1.4).foregroundStyle(.secondary)
            Text("\(v)").font(.custom("Helvetica Neue", size: 20).weight(.bold)).foregroundStyle(warn ? Theme.red : .primary)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            List(model.log) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text).font(.custom("Helvetica Neue", size: 13))
                        .foregroundStyle(line.level == .error ? Theme.red : .primary)
                    Theme.meta("\(line.level.rawValue) · \(line.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Activity")
            .overlay { if model.log.isEmpty { Theme.meta("Nothing yet.") } }
        }
    }
}
