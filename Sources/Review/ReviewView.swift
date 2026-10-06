import SwiftUI

/// Swipe review. Right keeps (★5 by default), left rejects, up skips; the stars
/// below grade (tap or slide across them). Press and hold the photo to lift it,
/// then drop it on an album. Pinch or double-tap to check focus.
struct ReviewView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var deck = ReviewModel()
    @ObservedObject private var albums = AlbumStore.shared
    @AppStorage("reviewKeepRating") private var keepRating = 5
    @AppStorage("reviewHaptics") private var hapticsOn = true
    @AppStorage("reviewEffects") private var effectsOn = true

    @State private var drag: CGSize = .zero
    @State private var armed: SwipeDir?
    @State private var enterFrom: CGSize = .zero
    @State private var flying: [Flyer] = []
    @State private var holding = false
    @State private var hot: DropTarget?
    @State private var targets: [DropTarget: CGRect] = [:]
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var box: CGSize = .zero
    @State private var burst = BurstToken()
    @State private var toast: String?
    @State private var showScopes = false
    @State private var folders: [Folder] = []
    @State private var picker: PickerTarget?
    @State private var naming: String?
    @State private var newName = ""
    @State private var started = false
    @State private var editing: EditorTarget?

    private let threshold: CGFloat = 110
    private var zoomed: Bool { zoom > 1.01 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                GeometryReader { geo in
                    deckArea
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onAppear { box = geo.size }
                        .onChange(of: geo.size) { _, s in box = s }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
                caption
                controls
            }
            .overlay { BurstView(token: burst).allowsHitTesting(false).ignoresSafeArea() }
            .overlay(alignment: .bottom) {
                if holding { tray.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .toast($toast, bottom: 170)
            .background(shortcuts)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showScopes) {
                ScopeSheet(scope: $deck.scope, folders: folders, phoneCount: nil, onReview: nil) {
                    showScopes = false
                    Task { await deck.reload(app.api) }
                }
            }
            .fullScreenCover(item: $editing) { t in
                if let api = app.api { EditorView(api: api, items: t.items, index: t.index).environmentObject(app) }
            }
            .sheet(item: $picker) { t in
                AlbumPicker(photoIDs: [t.id]) { msg in toast = msg }.environmentObject(app)
            }
            .alert("New album", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { let pid = naming; Task { await createAndFile(pid) } }
            } message: { Text("The photo goes straight in.") }
        }
        .task {
            guard !started else { return }
            started = true
            Haptics.prepare()
            await albums.load(app.api)
            await deck.reload(app.api)
            prefetch()
            if let f = try? await app.api?.folders() { folders = f }
        }
        .onChange(of: app.reviewRequest) { _, r in
            guard let r else { return }
            deck.scope = r.scope
            deck.filter = r.filter
            app.reviewRequest = nil
            Task { await deck.reload(app.api); prefetch() }
        }
        .onChange(of: deck.idx) { _, _ in prefetch() }
    }

    // MARK: deck

    private struct DeckCard: Identifiable { let item: PhotoItem; let depth: Int; var id: String { item.id } }

    private var visible: [DeckCard] {
        [1, 0].compactMap { d in deck.item(deck.idx + d).map { DeckCard(item: $0, depth: d) } }
    }

    @ViewBuilder private var deckArea: some View {
        ZStack {
            stateLayer
            ForEach(visible) { c in
                card(c.item, top: c.depth == 0)
                    .zIndex(c.depth == 0 ? 1 : 0)
                    .transition(.asymmetric(insertion: .offset(enterFrom).combined(with: .opacity), removal: .identity))
            }
            ForEach(flying) { f in
                FlyerView(flyer: f, box: box)
                    .zIndex(2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func cardSize(_ p: PhotoItem) -> CGSize {
        let w = max(box.width, 1), h = max(box.height, 1), a = max(p.aspect, 0.1)
        return a > w / h ? CGSize(width: w, height: w / a) : CGSize(width: h * a, height: h)
    }

    private var progress: CGFloat { min(1, hypot(drag.width, drag.height) / threshold) }

    private func card(_ p: PhotoItem, top: Bool) -> some View {
        let size = cardSize(p)
        let behind = 0.93 + 0.07 * progress
        return CardFace(item: p, api: app.api, size: size, zoom: top ? zoom : 1, pan: top ? pan : .zero, sharp: top && zoom > 1.6)
            .overlay { Stamps(drag: top ? drag : .zero, threshold: threshold, keepRating: keepRating) }
            .overlay {
                CardGestures(
                    zoomed: zoomed,
                    onPan: panChanged, onPanEnd: panEnded,
                    onHold: holdBegan, onHoldMove: holdMoved, onHoldEnd: holdEnded,
                    onPinch: pinched, onDoubleTap: { doubleTapped($0, size) })
                .allowsHitTesting(top)
            }
            .overlay(alignment: .topLeading) { quickAlbum.opacity(top && !holding && !zoomed ? 1 : 0).allowsHitTesting(top && !holding && !zoomed) }
            .scaleEffect(top ? (holding ? 0.6 : 1) : behind, anchor: top && holding ? .top : .center)
            .rotationEffect(.degrees(top ? Double(drag.width / 18) : 0))
            .offset(top ? drag : CGSize(width: 0, height: 12 * (1 - progress)))
            .brightness(top ? 0 : Double(-0.06 * (1 - progress)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.filename ?? "Photo")
            .accessibilityValue(ratingText(p.rating))
            .accessibilityAction(named: "Keep") { act(keepRating, .right) }
            .accessibilityAction(named: "Reject") { act(-1, .left) }
            .accessibilityAction(named: "Skip") { act(nil, .up) }
            .accessibilityAction(named: "Add to album") { picker = PickerTarget(id: p.id) }
            .accessibilityAction(named: "Edit") { openEditor() }
    }

    @ViewBuilder private var quickAlbum: some View {
        if let last = albums.last {
            Button {
                guard let p = deck.current else { return }
                file(p, into: last)
            } label: {
                Label(last.name, systemImage: "plus")
                    .font(.custom("Helvetica Neue", size: 12).weight(.bold))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(Pressable())
            .padding(10)
            .accessibilityLabel("Add to \(last.name)")
        }
    }

    @ViewBuilder private var stateLayer: some View {
        if deck.items.isEmpty {
            if let e = deck.error {
                Placeholder(icon: "wifi.exclamationmark", title: "Can't reach the server", detail: e,
                            action: "Try again") { Task { await deck.reload(app.api) } }
            } else if deck.loading || !deck.complete {
                ProgressView()
            } else {
                Placeholder(icon: "checkmark.circle", title: "Nothing to review", detail: emptyDetail,
                            action: deck.filter == .any ? "Choose photos" : "Show every rating") {
                    if deck.filter == .any { showScopes = true } else { deck.filter = .any; Task { await deck.reload(app.api) } }
                }
            }
        } else if deck.idx >= deck.items.count {
            if deck.complete { done } else { ProgressView("Loading more…") }
        }
    }

    private var emptyDetail: String {
        let f = deck.filter == .any ? "" : deck.filter.rawValue.lowercased() + " "
        return "No \(f)photos in \(deck.scope.title)."
    }

    private var done: some View {
        VStack(spacing: 18) {
            Star().fill(Theme.red).frame(width: 44, height: 44)
            VStack(spacing: 6) {
                Text("All done").font(.custom("Helvetica Neue", size: 24).weight(.bold))
                Theme.meta("Reviewed \(deck.reviewed) photo\(deck.reviewed == 1 ? "" : "s") in \(deck.scope.title).")
            }
            HStack(spacing: 12) {
                TextButton(title: "Start over") { withAnimation { deck.restart() } }
                TextButton(title: "Something else", primary: true) { showScopes = true }.frame(maxWidth: 200)
            }
        }
        .padding(24)
        .onAppear {
            if deck.reviewed > 0 { fire(.keep, strength: 5); Haptics.success() }
        }
    }

    // MARK: chrome

    private var progressBar: some View {
        GeometryReader { g in
            let total = max(deck.items.count, 1)
            Rectangle().fill(Theme.red)
                .frame(width: g.size.width * CGFloat(min(deck.idx, total)) / CGFloat(total))
                .animation(.easeOut(duration: 0.25), value: deck.idx)
        }
        .frame(height: 2)
        .background(Theme.hair)
    }

    @ViewBuilder private var caption: some View {
        if let p = deck.current, !holding {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text((p.filename ?? "").uppercased()).font(.custom("Helvetica Neue", size: 12).weight(.bold)).tracking(1.2).lineLimit(1)
                        if p.has_edit {
                            Text("EDITED").font(.custom("Helvetica Neue", size: 9).weight(.bold)).tracking(1)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .overlay(Rectangle().stroke(Theme.red, lineWidth: 1)).foregroundStyle(Theme.red)
                        }
                    }
                    Text([p.captureDate?.formatted(date: .abbreviated, time: .shortened), p.camera].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.custom("Helvetica Neue", size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if deck.streak >= 3 {
                    Text("★ ×\(deck.streak)")
                        .font(.custom("Helvetica Neue", size: 13).weight(.bold)).foregroundStyle(Theme.red)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3), value: deck.streak)
                }
                Text(ratingText(p.rating)).font(.custom("Helvetica Neue", size: 12))
                    .foregroundStyle(p.rating == -1 ? Theme.red : .secondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
        } else {
            Color.clear.frame(height: 40)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            StarScrubber(rating: deck.current?.rating ?? 0) { n in act(n, .right) }
                .disabled(deck.current == nil)
            HStack {
                RoundAction(icon: "arrow.uturn.backward", size: 46, style: .plain, label: "Undo") { undo() }
                    .disabled(!deck.canUndo)
                Spacer()
                RoundAction(icon: "xmark", size: 64, style: .outline, label: "Reject") { act(-1, .left) }
                Spacer()
                RoundAction(icon: "arrow.up", size: 46, style: .plain, label: "Skip") { act(nil, .up) }
                Spacer()
                RoundAction(icon: "star.fill", size: 64, style: .filled, label: "Keep, \(keepRating) stars") { act(keepRating, .right) }
                Spacer()
                RoundAction(icon: "rectangle.stack.badge.plus", size: 46, style: .plain, label: "Add to album") {
                    if let p = deck.current { picker = PickerTarget(id: p.id) }
                }
            }
            .disabled(deck.current == nil && !deck.canUndo)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .opacity(holding ? 0 : 1)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { showScopes = true } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(deck.scope.title.uppercased()).font(.custom("Helvetica Neue", size: 12).weight(.bold)).tracking(1.4).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    Text(counter).font(.custom("Helvetica Neue", size: 10)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(.plain)
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Show", selection: Binding(get: { deck.filter }, set: { f in
                    deck.filter = f
                    Task { await deck.reload(app.api); prefetch() }
                })) {
                    ForEach(RatingFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: deck.filter == .any ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { openEditor() } label: { Image(systemName: "slider.horizontal.3") }
                .disabled(deck.current == nil)
                .accessibilityLabel("Edit this photo")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Swipe right gives", selection: $keepRating) {
                    ForEach((1...5).reversed(), id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("Haptics", isOn: $hapticsOn)
                Toggle("Stars and confetti", isOn: $effectsOn)
                Divider()
                Button { withAnimation { deck.restart() } } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
                Button { Task { await deck.reload(app.api) } } label: { Label("Reload", systemImage: "arrow.clockwise") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private var counter: String {
        if deck.items.isEmpty { return deck.loading ? "loading…" : deck.filter.rawValue }
        let shown = min(deck.idx + 1, deck.items.count)
        return "\(shown) of \(deck.items.count)\(deck.complete ? "" : "+") · \(deck.filter.rawValue)"
    }

    private var shortcuts: some View {
        ZStack {
            Button("Keep") { act(keepRating, .right) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Reject") { act(-1, .left) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Skip") { act(nil, .up) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("Skip") { act(nil, .up) }.keyboardShortcut(.space, modifiers: [])
            Button("Undo") { undo() }.keyboardShortcut("z", modifiers: [])
            Button("Undo") { undo() }.keyboardShortcut(.downArrow, modifiers: [])
            Button("Clear") { act(0, .up) }.keyboardShortcut("0", modifiers: [])
            Button("1") { act(1, .right) }.keyboardShortcut("1", modifiers: [])
            Button("2") { act(2, .right) }.keyboardShortcut("2", modifiers: [])
            Button("3") { act(3, .right) }.keyboardShortcut("3", modifiers: [])
            Button("4") { act(4, .right) }.keyboardShortcut("4", modifiers: [])
            Button("5") { act(5, .right) }.keyboardShortcut("5", modifiers: [])
            Button("Edit") { openEditor() }.keyboardShortcut(.return, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: actions

    private func act(_ rating: Int?, _ dir: SwipeDir, velocity: CGSize = .zero) {
        guard let p = deck.current, !holding else { return }
        let from = drag
        let w = max(box.width, 320) * 1.6, h = max(box.height, 480) * 1.4
        let to: CGSize
        switch dir {
        case .right: to = CGSize(width: w, height: from.height + velocity.height * 0.12)
        case .left: to = CGSize(width: -w, height: from.height + velocity.height * 0.12)
        case .up: to = CGSize(width: from.width + velocity.width * 0.12, height: -h)
        }
        let f = Flyer(item: p, size: cardSize(p), from: from, to: to, spin: dir == .right ? 22 : dir == .left ? -22 : 0)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            enterFrom = .zero
            flying.append(f)
            drag = .zero
            armed = nil
            zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero
            deck.commit(rating, dir: dir)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { flying.removeAll { $0.id == f.id } }
        switch rating {
        case .some(let r) where r > 0: Haptics.keep(); fire(.keep, strength: r)
        case .some(-1): Haptics.reject(); fire(.reject)
        default: Haptics.skip(); fire(.skip)
        }
    }

    private func undo() {
        guard deck.canUndo, !holding else { Haptics.warn(); return }
        let w = max(box.width, 320) * 1.3, h = max(box.height, 480) * 1.2
        let dir = deck.history.last?.dir ?? .up
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            enterFrom = dir == .right ? CGSize(width: w, height: 0) : dir == .left ? CGSize(width: -w, height: 0) : CGSize(width: 0, height: -h)
            drag = .zero
            zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero
            _ = deck.undo()
        }
        Haptics.disarm()
    }

    private func openEditor() {
        guard deck.current != nil, !holding else { return }
        editing = EditorTarget(items: deck.items, index: deck.idx)
    }

    private func fire(_ kind: BurstKind, strength: Int = 1) {
        burst = BurstToken(n: burst.n + 1, kind: kind, strength: strength)
    }

    private func prefetch() {
        guard let api = app.api else { return }
        for d in 0...3 {
            guard let p = deck.item(deck.idx + d) else { break }
            ImageLoader.shared.prefetch(api.preview(p))
        }
    }

    // MARK: gestures

    private func direction(_ t: CGSize) -> SwipeDir? {
        if abs(t.width) >= abs(t.height) {
            if t.width > threshold { return .right }
            if t.width < -threshold { return .left }
        } else if t.height < -threshold { return .up }
        return nil
    }

    private func panChanged(_ t: CGSize) {
        if zoomed {
            pan = clampPan(CGSize(width: panBase.width + t.width, height: panBase.height + t.height))
            return
        }
        guard deck.current != nil else { return }
        drag = t
        let d = direction(t)
        if d != armed {
            if d != nil { Haptics.arm() } else { Haptics.disarm() }
            armed = d
        }
    }

    private func panEnded(_ t: CGSize, _ v: CGSize) {
        if zoomed {
            panBase = clampPan(CGSize(width: panBase.width + t.width, height: panBase.height + t.height))
            withAnimation(.spring(response: 0.3)) { pan = panBase }
            return
        }
        armed = nil
        let projected = CGSize(width: t.width + v.width * 0.12, height: t.height + v.height * 0.12)
        switch direction(projected) {
        case .right: act(keepRating, .right, velocity: v)
        case .left: act(-1, .left, velocity: v)
        case .up: act(nil, .up, velocity: v)
        case nil: withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = .zero }
        }
    }

    private func pinched(_ scale: CGFloat, _ ended: Bool) {
        if !ended {
            zoom = min(5, max(1, zoomBase * scale))
            pan = clampPan(pan)
            return
        }
        if zoom < 1.08 {
            withAnimation(.spring(response: 0.3)) { zoom = 1; pan = .zero }
            zoomBase = 1; panBase = .zero
        } else {
            zoomBase = zoom; panBase = pan
        }
    }

    private func doubleTapped(_ pt: CGPoint, _ size: CGSize) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if zoomed {
                zoom = 1; pan = .zero
            } else {
                zoom = 2.5
                let r = CGSize(width: pt.x - size.width / 2, height: pt.y - size.height / 2)
                pan = clampPan(CGSize(width: -r.width * (zoom - 1), height: -r.height * (zoom - 1)))
            }
        }
        zoomBase = zoom; panBase = pan
        Haptics.tick()
    }

    private func clampPan(_ p: CGSize) -> CGSize {
        guard let item = deck.current else { return .zero }
        let s = cardSize(item)
        let mx = (zoom - 1) * s.width / 2, my = (zoom - 1) * s.height / 2
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }

    // MARK: hold to file

    private func holdBegan(_ p: CGPoint) {
        guard deck.current != nil, !zoomed else { return }
        Haptics.lift()
        hot = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { holding = true; drag = .zero }
    }

    private func holdMoved(_ p: CGPoint) {
        guard holding else { return }
        let t = targets.first { $0.value.contains(p) }?.key
        if t != hot {
            hot = t
            if t != nil { Haptics.tick() }
        }
    }

    private func holdEnded(_ p: CGPoint, _ cancelled: Bool) {
        guard holding else { return }
        let t = cancelled ? nil : targets.first { $0.value.contains(p) }?.key
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { holding = false; hot = nil }
        guard let t, let photo = deck.current else { return }
        switch t {
        case .album(let id):
            if let a = albums.albums.first(where: { $0.id == id }) { file(photo, into: a) }
        case .new:
            newName = ""
            naming = photo.id
        case .more:
            picker = PickerTarget(id: photo.id)
        }
    }

    private func file(_ p: PhotoItem, into a: Album) {
        albums.add(a, [p.id])
        Haptics.success()
        fire(.file, strength: 2)
        toast = "Added to \(a.name)"
    }

    private func createAndFile(_ photoID: String?) async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let photoID, let p = deck.items.first(where: { $0.id == photoID }) else { return }
        do {
            let a = try await albums.create(name, api: app.api)
            file(p, into: a)
        } catch { toast = error.localizedDescription }
    }

    private var trayAlbums: [Album] { Array(albums.ordered.prefix(13)) }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Theme.label("Drop on an album")
                Spacer()
                Theme.meta("release elsewhere to cancel")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(trayAlbums) { a in
                    DropChip(target: .album(a.id), title: a.name, detail: "\(a.count)", icon: a.id == albums.last?.id ? "star.fill" : nil, hot: hot == .album(a.id))
                }
                DropChip(target: .new, title: "New album", detail: nil, icon: "plus", hot: hot == .new)
                if albums.albums.count > trayAlbums.count {
                    DropChip(target: .more, title: "More…", detail: "\(albums.albums.count - trayAlbums.count)", icon: "ellipsis", hot: hot == .more)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onPreferenceChange(DropFrames.self) { targets = $0 }
    }

    private func ratingText(_ r: Int) -> String {
        r == -1 ? "Rejected" : r > 0 ? String(repeating: "★", count: r) : "Unrated"
    }
}

// MARK: - pieces

struct PickerTarget: Identifiable { let id: String }

enum DropTarget: Hashable { case album(Int), new, more }

struct DropFrames: PreferenceKey {
    static var defaultValue: [DropTarget: CGRect] = [:]
    static func reduce(value: inout [DropTarget: CGRect], nextValue: () -> [DropTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

struct DropChip: View {
    let target: DropTarget
    let title: String
    let detail: String?
    let icon: String?
    let hot: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(hot ? .white : Theme.red) }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if let detail { Text(detail).foregroundStyle(hot ? .white.opacity(0.8) : .secondary).monospacedDigit() }
        }
        .font(.custom("Helvetica Neue", size: 13).weight(.medium))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(hot ? Theme.red : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(hot ? .white : .primary)
        .scaleEffect(hot ? 1.07 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hot)
        .background(GeometryReader { g in Color.clear.preference(key: DropFrames.self, value: [target: g.frame(in: .global)]) })
    }
}

/// The photo on a card: thumb first, preview over it, a sharper render when zoomed.
struct CardFace: View {
    let item: PhotoItem
    let api: API?
    let size: CGSize
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var sharp = false

    var body: some View {
        ZStack {
            RemoteImage(request: api?.thumb(item))
            RemoteImage(request: api?.preview(item), placeholder: false)
            if sharp, let hq = api?.hq(item) { RemoteImage(request: hq, placeholder: false) }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(zoom)
        .offset(pan)
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

struct Stamps: View {
    let drag: CGSize
    let threshold: CGFloat
    let keepRating: Int

    var body: some View {
        let horiz = abs(drag.width) >= abs(drag.height)
        let keep = horiz && drag.width > 0 ? min(1, drag.width / threshold) : 0
        let nope = horiz && drag.width < 0 ? min(1, -drag.width / threshold) : 0
        let skip = !horiz && drag.height < 0 ? min(1, -drag.height / threshold) : 0
        ZStack {
            stamp("Keep " + String(repeating: "★", count: keepRating), Theme.red).rotationEffect(.degrees(-14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(22).opacity(keep)
            stamp("Nope", .black).rotationEffect(.degrees(14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(22).opacity(nope)
            stamp("Skip", .gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(28).opacity(skip)
        }
        .allowsHitTesting(false)
    }

    private func stamp(_ s: String, _ c: Color) -> some View {
        Text(s.uppercased())
            .font(.custom("Helvetica Neue", size: 24).weight(.heavy)).tracking(2.5)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(c)
            .background(Color.white.opacity(0.92))
            .overlay(Rectangle().stroke(c, lineWidth: 3))
    }
}

struct Flyer: Identifiable {
    let id = UUID()
    let item: PhotoItem
    let size: CGSize
    let from: CGSize
    let to: CGSize
    let spin: Double
}

/// A card on its way off the table; animates itself once it appears.
struct FlyerView: View {
    @EnvironmentObject var app: AppModel
    let flyer: Flyer
    let box: CGSize
    @State private var gone = false

    var body: some View {
        CardFace(item: flyer.item, api: app.api, size: flyer.size)
            .rotationEffect(.degrees(gone ? flyer.spin : Double(flyer.from.width / 18)))
            .offset(gone ? flyer.to : flyer.from)
            .opacity(gone ? 0.0 : 1)
            .onAppear { withAnimation(.easeIn(duration: 0.26)) { gone = true } }
    }
}

/// Five stars: tap one, or slide across and let go.
struct StarScrubber: View {
    let rating: Int
    let commit: (Int) -> Void
    @State private var preview: Int?
    @Environment(\.isEnabled) private var enabled

    private var shown: Int { preview ?? max(0, rating) }

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { n in
                    Image(systemName: shown >= n ? "star.fill" : "star")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(shown >= n ? Theme.red : Color.secondary.opacity(0.45))
                        .scaleEffect(preview == n ? 1.3 : 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if abs(v.translation.height) > 70 { if preview != nil { preview = nil; Haptics.disarm() }; return }
                        let n = max(1, min(5, Int(v.location.x / max(1, g.size.width / 5)) + 1))
                        if n != preview { preview = n; Haptics.tick() }
                    }
                    .onEnded { _ in
                        if let p = preview { commit(p) }
                        preview = nil
                    }
            )
        }
        .frame(height: 38)
        .frame(maxWidth: 270)
        .opacity(enabled ? 1 : 0.35)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: preview)
        .accessibilityElement()
        .accessibilityLabel("Grade")
        .accessibilityValue(rating > 0 ? "\(rating) stars" : "none")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: commit(min(5, max(1, rating + 1)))
            case .decrement: commit(max(1, rating - 1))
            @unknown default: break
            }
        }
    }
}

struct RoundAction: View {
    enum Style { case plain, outline, filled }
    let icon: String
    let size: CGFloat
    let style: Style
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .bold))
                .frame(width: size, height: size)
                .foregroundStyle(style == .filled ? Color.white : style == .outline ? Color.primary : Color.secondary)
                .background {
                    switch style {
                    case .filled: Circle().fill(Theme.red).shadow(color: Theme.red.opacity(0.35), radius: 8, y: 3)
                    case .outline: Circle().stroke(Color.primary.opacity(0.85), lineWidth: 2)
                    case .plain: Circle().fill(Color(uiColor: .secondarySystemBackground))
                    }
                }
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(label)
    }
}

/// Springy press: shrinks under the finger, like system controls.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct Placeholder: View {
    let icon: String
    let title: String
    let detail: String
    let action: String
    let run: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.custom("Helvetica Neue", size: 20).weight(.bold))
            Theme.meta(detail).multilineTextAlignment(.center)
            TextButton(title: action, action: run).padding(.top, 4)
        }
        .padding(28)
    }
}
