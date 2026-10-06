import SwiftUI

/// Albums, shared by the library, the review deck and the editor. Membership
/// writes go through the outbox; the list itself is a plain GET.
@MainActor
final class AlbumStore: ObservableObject {
    static let shared = AlbumStore()

    @Published private(set) var albums: [Album] = []
    /// Most recently used first — the deck's drop targets start here.
    @Published private(set) var recent: [Int] = UserDefaults.standard.array(forKey: "recentAlbums") as? [Int] ?? []

    var last: Album? { recent.first.flatMap { id in albums.first { $0.id == id } } }

    /// Recent albums first, the rest in the server's order.
    var ordered: [Album] {
        let byID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let head = recent.compactMap { byID[$0] }
        let seen = Set(head.map(\.id))
        return head + albums.filter { !seen.contains($0.id) }
    }

    func load(_ api: API?) async {
        guard let api, let v = try? await api.albums() else { return }
        albums = v
    }

    func create(_ name: String, api: API?) async throws -> Album {
        guard let api else { throw APIError.status(0, "Not connected") }
        let a = try await api.createAlbum(name)
        albums.append(a)
        return a
    }

    func add(_ album: Album, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        Outbox.shared.albumAdd(album.id, ids)
        bump(album.id, by: ids.count)
        use(album.id)
    }

    func remove(_ album: Album, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        Outbox.shared.albumRemove(album.id, ids)
        bump(album.id, by: -ids.count)
    }

    private func bump(_ id: Int, by n: Int) {
        if let i = albums.firstIndex(where: { $0.id == id }) {
            let a = albums[i]
            albums[i] = Album(id: a.id, name: a.name, count: max(0, a.count + n), published: a.published)
        }
    }

    private func use(_ id: Int) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
        UserDefaults.standard.set(recent, forKey: "recentAlbums")
    }
}

extension API {
    func createAlbum(_ name: String) async throws -> Album {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let (d, _) = try await send(request("/api/albums", method: "POST", body: body))
        struct Made: Decodable { let id: Int; let name: String }
        let m = try JSONDecoder().decode(Made.self, from: d)
        return Album(id: m.id, name: m.name, count: 0, published: 0)
    }

    func albumIDs(of photoID: String) async throws -> Set<Int> {
        let (d, _) = try await send(request("/api/photos/\(photoID)/albums"))
        struct Row: Decodable { let id: Int }
        struct Rows: Decodable { let items: [Row] }
        return Set(try JSONDecoder().decode(Rows.self, from: d).items.map(\.id))
    }
}

/// Native album picker: checkmarks show membership for one photo; for a
/// selection, tapping an album files all of them.
struct AlbumPicker: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var store = AlbumStore.shared
    let photoIDs: [String]
    var onDone: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var members: Set<Int> = []
    @State private var query = ""
    @State private var naming = false
    @State private var newName = ""
    @State private var error: String?

    private var single: Bool { photoIDs.count == 1 }
    private var shown: [Album] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.ordered : store.ordered.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Theme.red).font(.footnote) }
                Section {
                    ForEach(shown) { a in
                        Button { toggle(a) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: members.contains(a.id) ? "checkmark.circle.fill" : (a.id == store.last?.id ? "star.fill" : "rectangle.stack"))
                                    .foregroundStyle(members.contains(a.id) || a.id == store.last?.id ? Theme.red : .secondary)
                                    .frame(width: 22)
                                Text(a.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(a.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } footer: {
                    Text(single ? "Tap an album to file this photo; tap a checked one to take it out." : "Tap an album to file \(photoIDs.count) photos.")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Albums")
            .navigationTitle(single ? "Albums" : "Add \(photoIDs.count) to album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = query; naming = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New album")
                }
            }
            .alert("New album", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await create() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await store.load(app.api)
            if single, let api = app.api, let m = try? await api.albumIDs(of: photoIDs[0]) { members = m }
        }
    }

    private func toggle(_ a: Album) {
        UISelectionFeedbackGenerator().selectionChanged()
        if single && members.contains(a.id) {
            store.remove(a, photoIDs)
            members.remove(a.id)
            onDone("Removed from \(a.name)")
        } else {
            store.add(a, photoIDs)
            members.insert(a.id)
            onDone("Added to \(a.name)")
            if !single { dismiss() }
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let a = try await store.create(name, api: app.api)
            toggle(a)
        } catch { self.error = error.localizedDescription }
    }
}
