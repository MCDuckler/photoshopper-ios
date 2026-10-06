import SwiftUI
import Photos

struct ShareBatch: Identifiable { let id = UUID(); let urls: [URL] }

struct ViewerTarget: Identifiable { let id: Int }

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var lib = LibraryModel()
    @State private var showScopes = false
    @State private var viewer: ViewerTarget?
    @State private var toast: String?
    @State private var pinchBase: CGFloat = 120
    @State private var showAlbumPicker = false
    @State private var presets: [Preset] = []
    @State private var exporting: String?
    @State private var shareFiles: ShareBatch?
    @State private var confirmClear = false
    private let gap: CGFloat = 6

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    grid(width: geo.size.width - 24)
                        .padding(.horizontal, 12)
                        .padding(.bottom, lib.selecting ? 120 : 24)
                }
                .refreshable { await lib.reload(app.api); await lib.loadMeta(app.api) }
                .overlay { overlayState }
                .gesture(MagnificationGesture()
                    .onChanged { v in lib.rowHeight = min(320, max(70, pinchBase * v)) }
                    .onEnded { _ in pinchBase = lib.rowHeight })
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if lib.selecting { selectionBar } }
            .sheet(isPresented: $showScopes) {
                ScopeSheet(scope: $lib.scope, folders: lib.folders, phoneCount: lib.phoneIDs.count,
                           onReview: { sc in showScopes = false; app.startReview(scope: sc, filter: .any) }) {
                    showScopes = false
                    Task { await lib.reload(app.api) }
                }
            }
            .sheet(item: $shareFiles) { b in ShareSheet(items: b.urls).ignoresSafeArea() }
            .sheet(isPresented: $showAlbumPicker) {
                AlbumPicker(photoIDs: ordered(lib.selected)) { msg in flash(msg); lib.endSelection() }
                    .environmentObject(app)
            }
            .fullScreenCover(item: $viewer) { t in
                PhotoViewer(lib: lib, index: t.id) { msg in flash(msg) }
                    .environmentObject(app)
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast.uppercased()).font(.custom("Helvetica Neue", size: 11).weight(.medium)).tracking(1.2)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.primary).foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.bottom, lib.selecting ? 130 : 20)
                        .transition(.opacity)
                }
            }
        }
        .task {
            if lib.items.isEmpty { await lib.loadMeta(app.api); await lib.reload(app.api) }
            if presets.isEmpty, let p = try? await app.api?.presets() { presets = p }
        }
        .confirmationDialog("Reset edits?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Reset \(lib.selected.count) Photos", role: .destructive) { Task { await batch(mode: "clear", done: "back to original") } }
        } message: { Text("Removes every adjustment from the selected photos.") }
    }

    // MARK: grid

    @ViewBuilder private func grid(width: CGFloat) -> some View {
        let sections = width > 0 ? lib.sections(width: width, gap: gap) : []
        LazyVStack(alignment: .leading, spacing: gap, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { sec in
                Section {
                    ForEach(sec.rows) { row in
                        HStack(spacing: gap) {
                            ForEach(row.cells) { cell in
                                PhotoCell(item: cell.item, api: app.api,
                                          onPhone: lib.phoneIDs.contains(cell.item.id),
                                          selecting: lib.selecting,
                                          selected: lib.selected.contains(cell.item.id))
                                    .frame(width: cell.w, height: row.height)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if lib.selecting { lib.toggle(cell.item.id) }
                                        else if let i = lib.items.firstIndex(where: { $0.id == cell.item.id }) { viewer = ViewerTarget(id: i) }
                                    }
                                    .onLongPressGesture(minimumDuration: 0.35) {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        lib.toggle(cell.item.id)
                                    }
                            }
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(LibraryModel.monthTitle(sec.key)).font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.6)
                        Text("\(sec.count)").font(.custom("Helvetica Neue", size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .systemBackground).opacity(0.94))
                }
            }
        }
    }

    @ViewBuilder private var overlayState: some View {
        if lib.items.isEmpty {
            VStack(spacing: 12) {
                if lib.loading { ProgressView() }
                else if let e = lib.error { Theme.meta(e).multilineTextAlignment(.center) }
                else { Star().fill(Theme.red).frame(width: 18, height: 18); Theme.meta("No photos here.") }
            }.padding(40)
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { showScopes = true } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(lib.scope.title.uppercased()).font(.custom("Helvetica Neue", size: 12).weight(.bold)).tracking(1.4).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    Text(lib.loading ? "loading… \(lib.items.count)" : "\(lib.items.count) photos")
                        .font(.custom("Helvetica Neue", size: 10)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Rating", selection: $lib.filter) {
                    ForEach(RatingFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Sort", selection: Binding(get: { lib.sort }, set: { lib.sort = $0; Task { await lib.reload(app.api) } })) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: lib.filter == .any ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .onChange(of: lib.filter) { _, _ in Task { await lib.reload(app.api) } }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { app.startReview(scope: lib.scope, filter: lib.filter) } label: { Image(systemName: "rectangle.stack") }
                .accessibilityLabel("Review these photos")
                .disabled(lib.selecting)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(lib.selecting ? "Done" : "Select") {
                if lib.selecting { lib.endSelection() } else { lib.selecting = true }
            }
            .font(.custom("Helvetica Neue", size: 13).weight(.medium))
        }
    }

    // MARK: selection

    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(lib.selected.isEmpty ? "TAP PHOTOS TO SELECT" : "\(lib.selected.count) SELECTED")
                    .font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.4)
                Spacer()
                Button("All") { lib.selected = Set(lib.items.map(\.id)) }
                Button("None") { lib.selected.removeAll() }
            }
            .font(.custom("Helvetica Neue", size: 13))
            HStack(spacing: 18) {
                Menu {
                    Button { showAlbumPicker = true } label: { Label("Add to Album…", systemImage: "rectangle.stack.badge.plus") }
                    if case .album(let aid, let aname) = lib.scope {
                        Button(role: .destructive) { removeFromAlbum(aid, aname) } label: { Label("Remove from \(aname)", systemImage: "minus.circle") }
                    }
                } label: { Label("Album", systemImage: "rectangle.stack.badge.plus") }
                Menu {
                    Button { Task { await exportSelection(share: true) } } label: { Label("Share (web size)…", systemImage: "square.and.arrow.up") }
                    Button { Task { await exportSelection(share: false) } } label: { Label("Save to Photos (full)", systemImage: "square.and.arrow.down") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(exporting != nil)
                Menu {
                    ForEach((1...5).reversed(), id: \.self) { n in
                        Button(String(repeating: "★", count: n)) { rateSelection(n) }
                    }
                    Button("Clear rating") { rateSelection(0) }
                    Button("Reject", role: .destructive) { rateSelection(-1) }
                } label: { Label("Rate", systemImage: "star") }
                Menu {
                    Button { Task { await batchPaste() } } label: { Label("Paste Edits", systemImage: "doc.on.clipboard") }
                        .disabled(EditClipboard.value == nil)
                    Menu {
                        ForEach(presets) { p in Button(p.name) { Task { await batch(mode: "preset", presetID: p.id, done: "\(p.name) applied") } } }
                    } label: { Label("Apply Preset", systemImage: "square.stack.3d.down.right") }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Reset Edits", systemImage: "arrow.counterclockwise") }
                } label: { Label("Edits", systemImage: "slider.horizontal.3") }
                Spacer()
            }
            .font(.custom("Helvetica Neue", size: 13).weight(.medium))
            .disabled(lib.selected.isEmpty)
            HStack(spacing: 10) {
                Menu {
                    Button("Full quality") { Task { await add("full") } }
                    Button("Web size (2048 px)") { Task { await add("web") } }
                } label: {
                    Text("SYNC TO PHONE").font(.custom("Helvetica Neue", size: 12).weight(.bold)).tracking(1.2)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.red).foregroundStyle(.white)
                }
                .disabled(lib.selected.isEmpty)
                Button { Task { await remove() } } label: {
                    Text("REMOVE").font(.custom("Helvetica Neue", size: 12).weight(.medium)).tracking(1.2)
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .overlay(Rectangle().stroke(Theme.red, lineWidth: 1))
                        .foregroundStyle(Theme.red)
                }
                .disabled(lib.selected.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }

    private func ordered(_ ids: Set<String>) -> [String] { lib.items.map(\.id).filter { ids.contains($0) } }

    private func removeFromAlbum(_ id: Int, _ name: String) {
        let ids = ordered(lib.selected)
        if let a = AlbumStore.shared.albums.first(where: { $0.id == id }) { AlbumStore.shared.remove(a, ids) }
        else { Outbox.shared.albumRemove(id, ids) }
        flash("\(ids.count) removed from \(name)")
        lib.endSelection()
    }

    /// Render each selected photo with its edit, then share the files or add them to Photos.
    private func exportSelection(share: Bool) async {
        guard let api = app.api else { return }
        let ids = Array(ordered(lib.selected).prefix(share ? 40 : 200))
        guard !ids.isEmpty else { return }
        var urls: [URL] = []
        var saved = 0
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !share {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { flash("No permission to add photos"); return }
        }
        for (i, id) in ids.enumerated() {
            exporting = "Rendering \(i + 1) of \(ids.count)…"
            flash(exporting ?? "")
            do {
                let saved0 = try await api.edit(id)
                let recipe = Recipe(server: saved0?.recipe).json
                let (data, name) = try await api.render(id, recipe: recipe, web: share)
                if share {
                    let u = dir.appendingPathComponent(name)
                    try data.write(to: u, options: .atomic)
                    urls.append(u)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                    }
                    saved += 1
                }
            } catch { flash("\(id): \(error.localizedDescription)") }
        }
        exporting = nil
        if share { if !urls.isEmpty { shareFiles = ShareBatch(urls: urls) } }
        else { flash("\(saved) saved to Photos"); UINotificationFeedbackGenerator().notificationOccurred(.success) }
        lib.endSelection()
    }

    private func batchPaste() async {
        guard let clip = EditClipboard.value else { return }
        await batch(mode: "merge", recipe: Recipe(server: .object(clip)).json, fields: Array(clip.keys), done: "Edits pasted")
    }

    private func batch(mode: String, presetID: Int? = nil, recipe: JSONValue? = nil, fields: [String]? = nil, done: String) async {
        guard let api = app.api else { return }
        let ids = ordered(lib.selected)
        do {
            try await api.batchEdits(ids, mode: mode, presetID: presetID, recipe: recipe, fields: fields)
            let now = Date().timeIntervalSince1970
            for id in ids { Outbox.shared.announce(.edited(id, mode != "clear", now)) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            flash("\(ids.count) · \(done)")
            lib.endSelection()
        } catch { flash(error.localizedDescription) }
    }

    private func rateSelection(_ r: Int) {
        let ids = ordered(lib.selected)
        Outbox.shared.rate(ids, r)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        flash(r == -1 ? "\(ids.count) rejected" : r == 0 ? "\(ids.count) cleared" : "\(ids.count) rated " + String(repeating: "★", count: r))
        lib.endSelection()
    }

    private func add(_ variant: String) async {
        let ids = ordered(lib.selected)
        if await lib.addToPhone(ids, variant: variant, api: app.api) {
            flash("\(ids.count) added — syncing")
            lib.endSelection()
            await app.sync(reason: "manual")
        } else if let e = lib.error { flash(e) }
    }

    private func remove() async {
        let ids = ordered(lib.selected)
        if await lib.removeFromPhone(ids, api: app.api) {
            flash("\(ids.count) removed — syncing")
            lib.endSelection()
            await app.sync(reason: "manual")
        } else if let e = lib.error { flash(e) }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        Task { try? await Task.sleep(nanoseconds: 2_400_000_000); withAnimation { if toast == s { toast = nil } } }
    }
}

struct PhotoCell: View {
    let item: PhotoItem
    let api: API?
    let onPhone: Bool
    let selecting: Bool
    let selected: Bool

    var body: some View {
        RemoteImage(request: api?.thumb(item))
            .opacity(item.rating < 0 ? 0.35 : 1)
            .overlay(alignment: .bottomLeading) {
                if item.rating > 0 {
                    Text(String(repeating: "★", count: item.rating)).font(.system(size: 8)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1).padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if onPhone {
                    Image(systemName: "iphone").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(3).background(Theme.red).padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if selecting {
                    Star().fill(selected ? Theme.red : Color.clear)
                        .overlay(Star().stroke(selected ? Theme.red : .white, lineWidth: 1.4))
                        .frame(width: 18, height: 18).shadow(color: .black.opacity(0.4), radius: 1).padding(6)
                }
            }
            .overlay { if selected { Rectangle().stroke(Theme.red, lineWidth: 3) } }
    }
}

struct ScopeSheet: View {
    @Binding var scope: Scope
    let folders: [Folder]
    let phoneCount: Int?
    var onReview: ((Scope) -> Void)? = nil
    let done: () -> Void
    @ObservedObject private var albums = AlbumStore.shared
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: Album?
    @State private var deleting: Album?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(Theme.red) }
                Section {
                    row("All photos", count: nil, on: scope == .all) { scope = .all }
                    row("On the phone", count: phoneCount, on: scope == .phone, icon: "iphone") { scope = .phone }
                    NavigationLink { GalleriesView().environmentObject(AppModel.shared) } label: {
                        Label("Galleries", systemImage: "globe").foregroundStyle(.primary)
                    }
                }
                Section {
                    ForEach(albums.ordered) { a in
                        row(a.name, count: a.count, on: scope == .album(a.id, a.name), icon: (a.published ?? 0) > 0 ? "globe" : nil) { scope = .album(a.id, a.name) }
                            .contextMenu { albumMenu(a) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleting = a } label: { Label("Delete", systemImage: "trash") }
                                Button { newName = a.name; renaming = a } label: { Label("Rename", systemImage: "pencil") }.tint(.gray)
                            }
                    }
                } header: {
                    HStack {
                        Text("Albums")
                        Spacer()
                        Button { newName = ""; naming = true } label: { Image(systemName: "plus") }.accessibilityLabel("New album")
                    }
                }
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders) { f in
                            row(f.path.isEmpty ? "Pictures" : f.path, count: f.count, on: scope == .folder(f.path)) { scope = .folder(f.path) }
                        }
                    }
                }
            }
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { done() } } }
            .alert("New album", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { let n = newName; Task { await create(n) } }
            }
            .alert("Rename album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { if let a = renaming { let n = newName; Task { await rename(a, n) } } }
            }
            .confirmationDialog("Delete album?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Album", role: .destructive) { if let a = deleting { Task { await delete(a) } } }
            } message: { Text("The photos stay in the library. A published gallery of this album goes offline.") }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func albumMenu(_ a: Album) -> some View {
        if let onReview {
            Button { onReview(.album(a.id, a.name)) } label: { Label("Review This Album", systemImage: "rectangle.stack") }
        }
        Button { newName = a.name; renaming = a } label: { Label("Rename…", systemImage: "pencil") }
        Button(role: .destructive) { deleting = a } label: { Label("Delete…", systemImage: "trash") }
    }

    private func create(_ name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        do { _ = try await albums.create(n, api: AppModel.shared.api); await albums.load(AppModel.shared.api) }
        catch { self.error = error.localizedDescription }
    }

    private func rename(_ a: Album, _ name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let api = AppModel.shared.api else { return }
        do {
            try await api.renameAlbum(a.id, to: n)
            await albums.load(api)
            if scope == .album(a.id, a.name) { scope = .album(a.id, n) }
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ a: Album) async {
        guard let api = AppModel.shared.api else { return }
        do {
            try await api.deleteAlbum(a.id)
            await albums.load(api)
            if scope == .album(a.id, a.name) { scope = .all; done() }
        } catch { self.error = error.localizedDescription }
    }

    private func row(_ title: String, count: Int?, on: Bool, icon: String? = nil, _ pick: @escaping () -> Void) -> some View {
        Button { pick(); done() } label: {
            HStack {
                if let icon { Image(systemName: icon).foregroundStyle(Theme.red).font(.system(size: 12)) }
                Text(title).foregroundStyle(on ? Theme.red : .primary)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.secondary).font(.custom("Helvetica Neue", size: 12)) }
            }
        }
    }
}
