import SwiftUI

struct GalleryTarget: Decodable, Identifiable, Hashable {
    let id: Int
    let slug: String
    let title: String?
    let album_id: Int
    let album_name: String?
    let full_res: Bool
    let auto_sync: Bool
    let last_sync_at: Double?
    let album_count: Int?
    let live_count: Int?
    let url: String?

    var name: String { title ?? album_name ?? slug }
}

struct PublishJob: Decodable, Hashable {
    let target_id: Int?
    let state: String?
    let total: Int?
    let done: Int?
    let error: String?
    var running: Bool { state == "running" || state == "queued" }
}

private struct Items<T: Decodable>: Decodable { let items: [T] }

extension API {
    func galleries() async throws -> [GalleryTarget] {
        let (d, _) = try await send(request("/api/publish/targets"))
        return try JSONDecoder().decode(Items<GalleryTarget>.self, from: d).items
    }

    func publishJobs() async throws -> [PublishJob] {
        let (d, _) = try await send(request("/api/publish/status"))
        struct S: Decodable { let configured: Bool?; let jobs: [PublishJob]? }
        return try JSONDecoder().decode(S.self, from: d).jobs ?? []
    }

    func publishConfigured() async -> Bool {
        guard let r = try? await send(request("/api/publish/status")) else { return false }
        struct S: Decodable { let configured: Bool? }
        return (try? JSONDecoder().decode(S.self, from: r.0))?.configured ?? false
    }

    func publish(albumID: Int, title: String, fullRes: Bool, autoSync: Bool) async throws -> GalleryTarget {
        let body: JSONValue = ["album_id": .number(Double(albumID)), "title": .string(title), "full_res": .bool(fullRes), "auto_sync": .bool(autoSync)]
        let (d, _) = try await send(request("/api/publish/targets", method: "POST", body: body.data))
        return try JSONDecoder().decode(GalleryTarget.self, from: d)
    }

    func updateGallery(_ id: Int, fullRes: Bool? = nil, autoSync: Bool? = nil) async throws {
        var o: [String: JSONValue] = [:]
        if let fullRes { o["full_res"] = .bool(fullRes) }
        if let autoSync { o["auto_sync"] = .bool(autoSync) }
        _ = try await send(request("/api/publish/targets/\(id)", method: "PATCH", body: JSONValue.object(o).data))
    }

    func syncGallery(_ id: Int) async throws {
        _ = try await send(request("/api/publish/targets/\(id)/sync", method: "POST", body: Data("{}".utf8)))
    }

    func unpublish(_ id: Int) async throws {
        _ = try await send(request("/api/publish/targets/\(id)?purge=true", method: "DELETE", timeout: 120))
    }

    func reissueLink(_ id: Int) async throws {
        _ = try await send(request("/api/publish/targets/\(id)/refresh_link", method: "POST", body: Data("{}".utf8)))
    }

    func galleryQR(_ id: Int) -> URLRequest {
        var r = request("/api/publish/targets/\(id)/qr.png")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    func renameAlbum(_ id: Int, to name: String) async throws {
        _ = try await send(request("/api/albums/\(id)", method: "PATCH", body: JSONValue.object(["name": .string(name)]).data))
    }

    func deleteAlbum(_ id: Int) async throws {
        _ = try await send(request("/api/albums/\(id)", method: "DELETE", timeout: 60))
    }
}

/// Albums published to the web gallery: share the link, show the QR, keep in sync.
struct GalleriesView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var albums = AlbumStore.shared
    var publishAlbum: Album? = nil
    @State private var targets: [GalleryTarget] = []
    @State private var jobs: [Int: PublishJob] = [:]
    @State private var configured = true
    @State private var loading = false
    @State private var error: String?
    @State private var qr: GalleryTarget?
    @State private var publishing: Album?
    @State private var choosing = false
    @State private var unpublishing: GalleryTarget?
    @State private var reissuing: GalleryTarget?
    @State private var toast: String?
    @State private var autoOpened = false

    var body: some View {
        List {
            if !configured {
                Section { Text("Publishing is not set up on the server (R2 credentials in server/.env).").foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(Theme.red) } }
            Section {
                ForEach(targets) { t in row(t) }
                if targets.isEmpty && !loading { Text("Nothing published yet.").foregroundStyle(.secondary) }
            } footer: {
                Text("A published album stays in step with its photos: re-edits re-upload themselves.")
            }
        }
        .navigationTitle("Galleries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { choosing = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Publish an album")
                    .disabled(!configured)
            }
        }
        .refreshable { await load() }
        .task {
            await load()
            if let a = publishAlbum, !autoOpened { autoOpened = true; publishing = a }
        }
        .toast($toast)
        .sheet(item: $qr) { t in QRSheet(target: t).environmentObject(app) }
        .sheet(item: $publishing) { a in PublishSheet(album: a) { t in targets.insert(t, at: 0); toast = "Publishing \(t.name)…"; Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await load() } }.environmentObject(app) }
        .confirmationDialog("Publish which album?", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(albums.ordered.filter { a in !targets.contains { $0.album_id == a.id } }.prefix(20)) { a in
                Button(a.name) { publishing = a }
            }
        }
        .confirmationDialog("Unpublish?", isPresented: Binding(get: { unpublishing != nil }, set: { if !$0 { unpublishing = nil } }), titleVisibility: .visible) {
            Button("Unpublish and Delete Online Copies", role: .destructive) {
                if let t = unpublishing { Task { await run("Unpublished") { try await $0.unpublish(t.id) } } }
            }
        } message: { Text("The link stops working at once. The album and photos here are untouched.") }
        .confirmationDialog("Issue a new link?", isPresented: Binding(get: { reissuing != nil }, set: { if !$0 { reissuing = nil } }), titleVisibility: .visible) {
            Button("New Link", role: .destructive) {
                if let t = reissuing { Task { await run("New link on its way") { try await $0.reissueLink(t.id) } } }
            }
        } message: { Text("The old link stops working — how you take back a link sent to the wrong person.") }
    }

    private func row(_ t: GalleryTarget) -> some View {
        let job = jobs[t.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "globe").foregroundStyle(Theme.red)
                Text(t.name).font(.headline)
                Spacer()
                if job?.running == true { ProgressView().controlSize(.small) }
            }
            Text(status(t, job)).font(.footnote).foregroundStyle(.secondary)
            if let u = t.url, let url = URL(string: u) {
                HStack(spacing: 18) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.url = url; toast = "Link copied" } label: { Label("Copy", systemImage: "link") }
                    Button { qr = t } label: { Label("QR", systemImage: "qrcode") }
                    Link(destination: url) { Label("Open", systemImage: "safari") }
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 18))
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button { Task { await run("Sync started") { try await $0.syncGallery(t.id) } } } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
            Button { Task { await run(t.full_res ? "Web size only" : "Full resolution offered") { try await $0.updateGallery(t.id, fullRes: !t.full_res) } } } label: {
                Label(t.full_res ? "Stop Offering Full Resolution" : "Offer Full-Resolution Downloads", systemImage: "arrow.down.circle")
            }
            Button { Task { await run(t.auto_sync ? "Manual sync" : "Keeps itself in sync") { try await $0.updateGallery(t.id, autoSync: !t.auto_sync) } } } label: {
                Label(t.auto_sync ? "Stop Syncing Automatically" : "Keep in Sync Automatically", systemImage: "clock.arrow.circlepath")
            }
            Button { reissuing = t } label: { Label("Issue New Link…", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { unpublishing = t } label: { Label("Unpublish…", systemImage: "trash") }
        }
        .swipeActions {
            Button(role: .destructive) { unpublishing = t } label: { Label("Unpublish", systemImage: "trash") }
            Button { Task { await run("Sync started") { try await $0.syncGallery(t.id) } } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tint(.gray)
        }
    }

    private func status(_ t: GalleryTarget, _ job: PublishJob?) -> String {
        if let job, job.running { return "Syncing \(job.done ?? 0) of \(job.total ?? 0)…" }
        var parts = ["\(t.live_count ?? 0) of \(t.album_count ?? 0) online"]
        if t.full_res { parts.append("full-res") }
        if t.auto_sync { parts.append("auto") }
        if let at = t.last_sync_at { parts.append(Date(timeIntervalSince1970: at).formatted(.relative(presentation: .named))) }
        if let e = job?.error, !e.isEmpty { parts.append("error: \(e)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let api = app.api else { return }
        loading = true
        defer { loading = false }
        configured = await api.publishConfigured()
        do {
            targets = try await api.galleries()
            error = nil
        } catch { self.error = error.localizedDescription }
        if let js = try? await api.publishJobs() {
            var m: [Int: PublishJob] = [:]
            for j in js { if let id = j.target_id { m[id] = j } }
            jobs = m
        }
        await albums.load(api)
    }

    private func run(_ done: String, _ work: (API) async throws -> Void) async {
        guard let api = app.api else { return }
        do { try await work(api); toast = done; Haptics.success() } catch { toast = error.localizedDescription }
        await load()
    }
}

struct PublishSheet: View {
    @EnvironmentObject var app: AppModel
    let album: Album
    let done: (GalleryTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var fullRes = true
    @State private var autoSync = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Title", text: $title) } footer: { Text("\(album.count) photos. Everything in the album is published.") }
                Section {
                    Toggle("Offer full-resolution downloads", isOn: $fullRes)
                    Toggle("Keep in sync automatically", isOn: $autoSync)
                }
                if let error { Text(error).foregroundStyle(Theme.red) }
            }
            .tint(Theme.red)
            .navigationTitle("Publish “\(album.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Publish") { Task { await publish() } }.bold().disabled(busy)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { if title.isEmpty { title = album.name } }
    }

    private func publish() async {
        guard let api = app.api else { return }
        busy = true
        defer { busy = false }
        do {
            let t = try await api.publish(albumID: album.id, title: title.isEmpty ? album.name : title, fullRes: fullRes, autoSync: autoSync)
            try? await api.syncGallery(t.id)
            done(t)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct QRSheet: View {
    @EnvironmentObject var app: AppModel
    let target: GalleryTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                RemoteImage(request: app.api?.galleryQR(target.id), fill: false, placeholder: false)
                    .frame(width: 260, height: 260)
                    .padding(12)
                    .background(Color.white)
                if let u = target.url { Text(u).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.center) }
                if let u = target.url, let url = URL(string: u) {
                    ShareLink(item: url) { Label("Share Link", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent).tint(Theme.red)
                }
            }
            .padding()
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
