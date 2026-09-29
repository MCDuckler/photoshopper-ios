import SwiftUI

struct ViewerTarget: Identifiable { let id: Int }

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var lib = LibraryModel()
    @State private var showScopes = false
    @State private var viewer: ViewerTarget?
    @State private var toast: String?
    @State private var pinchBase: CGFloat = 120
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
            .sheet(isPresented: $showScopes) { ScopeSheet(lib: lib) { showScopes = false; Task { await lib.reload(app.api) } } }
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
        }
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
            } label: {
                Image(systemName: lib.filter == .any ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .onChange(of: lib.filter) { _, _ in Task { await lib.reload(app.api) } }
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
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }

    private func ordered(_ ids: Set<String>) -> [String] { lib.items.map(\.id).filter { ids.contains($0) } }

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
    @ObservedObject var lib: LibraryModel
    let done: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("All photos", count: nil, on: lib.scope == .all) { lib.scope = .all }
                    row("On the phone", count: lib.phoneIDs.count, on: lib.scope == .phone, icon: "iphone") { lib.scope = .phone }
                }
                Section("Albums") {
                    ForEach(lib.albums) { a in
                        row(a.name, count: a.count, on: lib.scope == .album(a.id, a.name), icon: (a.published ?? 0) > 0 ? "globe" : nil) { lib.scope = .album(a.id, a.name) }
                    }
                }
                Section("Folders") {
                    ForEach(lib.folders) { f in
                        row(f.path.isEmpty ? "Pictures" : f.path, count: f.count, on: lib.scope == .folder(f.path)) { lib.scope = .folder(f.path) }
                    }
                }
            }
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { done() } } }
        }
        .presentationDetents([.medium, .large])
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
