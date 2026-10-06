import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var background = Settings.backgroundSync
    @State private var wifiOnly = Settings.wifiOnly
    @State private var album = Settings.albumName
    @State private var rescanText: String?
    @State private var confirmReset = false
    @AppStorage("reviewKeepRating") private var keepRating = 5
    @AppStorage("reviewHaptics") private var haptics = true
    @AppStorage("reviewEffects") private var effects = true

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    NavigationLink { ConnectView() } label: {
                        VStack(alignment: .leading) { Text(model.serverURL.isEmpty ? "Not set" : model.serverURL); Theme.meta(model.connected ? "Connected" : "Not reachable") }
                    }
                }
                Section {
                    Picker("Swipe right gives", selection: $keepRating) {
                        ForEach((1...5).reversed(), id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                    }
                    Toggle("Haptics", isOn: $haptics)
                    Toggle("Stars and confetti", isOn: $effects)
                } header: { Text("Review") } footer: {
                    Text("Swipe left rejects, up skips. Press and hold a photo to drop it into an album.")
                }
                Section {
                    Toggle("Sync in the background", isOn: $background)
                        .onChange(of: background) { _, v in Settings.backgroundSync = v; BackgroundSync.schedule() }
                    Toggle("Only on Wi-Fi", isOn: $wifiOnly)
                        .onChange(of: wifiOnly) { _, v in Settings.wifiOnly = v }
                } header: { Text("Background") } footer: {
                    Text("iOS decides when background syncs run — usually overnight on the charger. Opening the app always syncs.")
                }
                Section {
                    TextField("Album name", text: $album)
                        .onSubmit { let t = album.trimmingCharacters(in: .whitespaces); if !t.isEmpty { Settings.albumName = t } }
                    Button("Re-scan album") { Task { await rescan() } }
                    if let rescanText { Theme.meta(rescanText) }
                } header: { Text("Photos") } footer: {
                    Text("Re-scan rebuilds this phone's record of what is already in the album — needed after reinstalling the app, so nothing is added twice.")
                }
                Section {
                    Button("Forget what was synced", role: .destructive) { confirmReset = true }
                } footer: { Text("Nothing is deleted from Photos. The next sync re-adds every selected photo unless you re-scan first.") }
                UpdateSection()
                Section("About") {
                    LabeledContent("Device", value: ClientID.value)
                    Link("Source on GitHub", destination: URL(string: "https://github.com/MCDuckler/photoshopper-ios")!)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Forget the sync record?", isPresented: $confirmReset) {
                Button("Forget", role: .destructive) { SyncStore.shared.removeAll(); model.append(.info, "Sync record cleared") }
            }
        }
    }

    private func rescan() async {
        let w = PhotosWriter()
        guard await w.authorize() else { rescanText = "No Photos access."; return }
        do {
            let id = try await w.albumID(named: Settings.albumName)
            let n = await w.rescan(albumID: id, into: SyncStore.shared) { i, total in
                Task { @MainActor in rescanText = "Reading \(i) of \(total)…" }
            }
            rescanText = "Found \(n) Photoshopper photo\(n == 1 ? "" : "s") in the album."
            model.append(.info, "Re-scan: \(n) photos recognised")
        } catch { rescanText = error.localizedDescription }
    }
}
