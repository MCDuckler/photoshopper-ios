import SwiftUI

/// A hairline strip above the tabs when a newer build is on GitHub.
struct UpdateBanner: View {
    @EnvironmentObject var model: AppModel
    let release: Release
    @State private var failed = false

    var body: some View {
        HStack(spacing: 10) {
            Star().fill(Theme.red).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text("UPDATE \(release.version) READY").font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.3)
                Text(failed ? "SideStore not found — add the source in Settings" : (release.notes ?? release.size))
                    .font(.custom("Helvetica Neue", size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Update") { Task { failed = !(await Updates.install(release)) } }
                .font(.custom("Helvetica Neue", size: 13).weight(.bold)).foregroundStyle(Theme.red)
            Button { withAnimation { model.dismissUpdate() } } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// The Settings section: what is running, what GitHub has, and the two buttons.
struct UpdateSection: View {
    @EnvironmentObject var model: AppModel
    @State private var note: String?

    var body: some View {
        Section {
            LabeledContent("Installed", value: "\(Updates.runningVersion) (\(Updates.running))")
            if let r = model.update {
                LabeledContent("Latest", value: "\(r.version) (\(r.build))")
                if let n = r.notes { Theme.meta(n) }
            }
            if model.updateAvailable, let r = model.update {
                Button {
                    Task { note = (await Updates.install(r)) ? nil : "Could not open SideStore, AltStore or Safari." }
                } label: {
                    Text("UPDATE TO \(r.version) · \(r.size)").font(.custom("Helvetica Neue", size: 12).weight(.bold)).tracking(1.2).foregroundStyle(Theme.red)
                }
            } else {
                Button {
                    Task { await model.checkForUpdate(force: true); note = model.updateAvailable ? nil : "You have the latest build." }
                } label: {
                    HStack { Text("Check for updates"); if model.checkingUpdate { Spacer(); ProgressView() } }
                }
            }
            Button("Add Photoshopper source to SideStore") {
                Task { note = (await Updates.addSource()) ? nil : "Could not open SideStore." }
            }
            if let note { Theme.meta(note) }
        } header: { Text("App") } footer: {
            Text("With the source added, SideStore lists new builds as updates by itself. The app also checks GitHub when opened (every 6 hours at most).")
        }
    }
}
