import SwiftUI
import UIKit

struct EditorTarget: Identifiable {
    let items: [PhotoItem]
    let index: Int
    var id: String { items.indices.contains(index) ? items[index].id : "" }
}

private enum EditorSheet: String, Identifiable {
    case presets, copy, paste, info, albums
    var id: String { rawValue }
}

struct ShareFile: Identifiable { let url: URL; var id: String { url.path } }

/// Full-screen editor, dark like Photos'. Photo on top; under it the panel for the
/// chosen tool, the tool strip and the five categories. Hold the photo to see the
/// original, pinch to zoom, swipe sideways for the next photo.
struct EditorView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var m: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var original = false
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var swipe: CGFloat = 0
    @State private var sheet: EditorSheet?
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var confirmRevert = false
    @State private var share: ShareFile?
    @State private var exporting = false

    init(api: API, items: [PhotoItem], index: Int) {
        _m = StateObject(wrappedValue: EditorModel(api: api, items: items, index: index))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            imageArea
            panel
                .frame(minHeight: 70)
                .animation(.easeOut(duration: 0.18), value: m.tool)
            if !m.category.tools.isEmpty { toolStrip }
            categoryBar
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .toast($m.toast, bottom: 230)
        .task { await m.load() }
        .onDisappear { Task { await m.flushSave() } }
        .sheet(item: $sheet) { s in sheetView(s) }
        .sheet(item: $share) { f in ShareSheet(items: [f.url]).ignoresSafeArea() }
        .alert("Save as preset", isPresented: $namingPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { let n = presetName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { Task { await m.savePreset(named: n) } } }
        } message: { Text("Saves the current edit; photos you apply it to stay linked to it.") }
        .confirmationDialog("Revert to original?", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("Revert to Original", role: .destructive) { Task { await m.revert() } }
        } message: { Text("Removes every adjustment on this photo. Undo still brings them back while the editor is open.") }
        .statusBarHidden(true)
    }

    // MARK: top bar

    private var saveText: String {
        switch m.save {
        case .saved: return m.loaded ? "Saved" : "Loading…"
        case .dirty: return "Edited"
        case .saving: return "Saving…"
        case .queued: return "Saved on the phone — sends when online"
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                Task { await m.flushSave(); dismiss() }
            } label: {
                Text("Done").font(.custom("Helvetica Neue", size: 16).weight(.bold)).foregroundStyle(Theme.red)
            }
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text((m.item.filename ?? "").uppercased()).font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.2).lineLimit(1)
                HStack(spacing: 4) {
                    if m.rendering { ProgressView().controlSize(.mini).tint(.white) }
                    Text(saveText).font(.custom("Helvetica Neue", size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { m.undo(); Haptics.tick() } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .disabled(!m.canUndo).accessibilityLabel("Undo")
            Button { m.redo(); Haptics.tick() } label: { Image(systemName: "arrow.uturn.forward.circle") }
                .disabled(!m.canRedo).accessibilityLabel("Redo")
            menu
        }
        .font(.system(size: 20))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(m.loaded ? 1 : 0.6)
    }

    private var menu: some View {
        Menu {
            Section {
                Picker("Rating", selection: Binding(get: { m.rating }, set: { m.rate($0) })) {
                    ForEach((1...5).reversed(), id: \.self) { n in Text(String(repeating: "★", count: n)).tag(n) }
                    Text("Unrated").tag(0)
                    Text("Rejected").tag(-1)
                }
                .pickerStyle(.menu)
            }
            Section {
                Button { sheet = .presets } label: { Label("Presets…", systemImage: "square.stack.3d.down.right") }
                Button { presetName = ""; namingPreset = true } label: { Label("Save as Preset…", systemImage: "plus.square.on.square") }
                Button { sheet = .copy } label: { Label("Copy Edits…", systemImage: "doc.on.doc") }
                Button { sheet = .paste } label: { Label("Paste Edits…", systemImage: "doc.on.clipboard") }
                    .disabled(EditClipboard.value == nil)
            }
            Section {
                Toggle(isOn: $m.showHistogram) { Label("Histogram", systemImage: "chart.bar") }
                Button { sheet = .info } label: { Label("Info", systemImage: "info.circle") }
            }
            Section {
                Button { sheet = .albums } label: { Label("Add to Album…", systemImage: "rectangle.stack.badge.plus") }
                Button { Task { await syncToPhone() } } label: { Label("Sync to Phone", systemImage: "iphone.and.arrow.forward") }
            }
            Section("Export") {
                Button { Task { await shareExport(web: false) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                Button { Task { await shareExport(web: true) } } label: { Label("Share Web Size…", systemImage: "square.and.arrow.up.on.square") }
                Button { Task { await m.saveToPhotos(web: false) } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
            }
            Section {
                Button(role: .destructive) { confirmRevert = true } label: { Label("Revert to Original", systemImage: "arrow.counterclockwise") }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("More")
    }

    // MARK: picture

    private var imageArea: some View {
        GeometryReader { g in
            let box = CGSize(width: max(1, g.size.width - 24), height: max(1, g.size.height - 16))
            let aspect = original ? m.sourceAspect : m.frameAspect
            let fit = Self.fit(aspect, in: box)
            ZStack {
                picture
                    .frame(width: fit.width, height: fit.height)
                    .scaleEffect(m.zoom)
                    .offset(x: pan.width + swipe, y: pan.height)
                    .overlay {
                        if m.cropping && !original {
                            CropOverlay(crop: m.recipe.crop, rel: m.cropAspect.map { $0 / max(m.frameAspect, 0.01) },
                                        onChange: { c in m.recipe.crop = c; m.commit(history: false) },
                                        onEnd: { m.endGesture() })
                        } else {
                            CardGestures(
                                zoomed: m.zoom > 1.01,
                                onPan: { t in panned(t, fit) },
                                onPanEnd: { t, v in panEnded(t, v, fit) },
                                onHold: { _ in showOriginal(true) },
                                onHoldMove: { _ in },
                                onHoldEnd: { _, _ in showOriginal(false) },
                                onPinch: { s, end in pinched(s, end, fit) },
                                onDoubleTap: { p in doubleTapped(p, fit) })
                        }
                    }
                if original {
                    Text("ORIGINAL").font(.custom("Helvetica Neue", size: 10).weight(.bold)).tracking(1.4)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                }
                if m.showHistogram, let h = m.histogram, !m.cropping {
                    HistogramView(h: h)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(14)
                        .allowsHitTesting(false)
                }
                if !m.loaded && m.server == nil { ProgressView().tint(.white) }
                navArrows
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
    }

    @ViewBuilder private var picture: some View {
        ZStack {
            if original, let b = m.base {
                Image(uiImage: b).resizable().scaledToFit()
            } else {
                if let s = m.server { Image(uiImage: s).resizable().scaledToFit() }
                if let r = m.renderer, m.liveReady {
                    let inputs = m.shaderInputs(original: false)
                    MetalPreviewView(renderer: r, params: inputs.params, curve: inputs.curve)
                        .opacity(m.showLive ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: m.showLive)
                }
                if let h = m.hq, m.zoom > 1.4, !m.showLive { Image(uiImage: h).resizable().scaledToFit() }
            }
        }
    }

    @ViewBuilder private var navArrows: some View {
        if m.items.count > 1 && m.zoom <= 1.01 && !m.cropping {
            HStack {
                arrow("chevron.left", enabled: m.hasPrev) { Task { await step(-1) } }
                Spacer()
                arrow("chevron.right", enabled: m.hasNext) { Task { await step(1) } }
            }
            .padding(.horizontal, 4)
        }
    }

    private func arrow(_ icon: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold))
                .frame(width: 30, height: 44)
                .background(.black.opacity(0.35), in: Capsule())
        }
        .opacity(enabled ? 0.8 : 0)
        .disabled(!enabled)
    }

    static func fit(_ a: CGFloat, in box: CGSize) -> CGSize {
        let a = max(a, 0.05)
        return a > box.width / box.height ? CGSize(width: box.width, height: box.width / a) : CGSize(width: box.height * a, height: box.height)
    }

    // MARK: gestures

    private func showOriginal(_ on: Bool) {
        guard on != original else { return }
        if on { Haptics.lift() }
        original = on
    }

    private func clamp(_ p: CGSize, _ size: CGSize) -> CGSize {
        let mx = (m.zoom - 1) * size.width / 2, my = (m.zoom - 1) * size.height / 2
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }

    private func panned(_ t: CGSize, _ size: CGSize) {
        if m.zoom > 1.01 {
            pan = clamp(CGSize(width: panBase.width + t.width, height: panBase.height + t.height), size)
        } else if m.items.count > 1 {
            swipe = t.width * 0.6
        }
    }

    private func panEnded(_ t: CGSize, _ v: CGSize, _ size: CGSize) {
        if m.zoom > 1.01 {
            panBase = clamp(CGSize(width: panBase.width + t.width, height: panBase.height + t.height), size)
            withAnimation(.spring(response: 0.3)) { pan = panBase }
            return
        }
        let flick = t.width + v.width * 0.15
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { swipe = 0 }
        if flick < -90, m.hasNext { Task { await step(1) } }
        else if flick > 90, m.hasPrev { Task { await step(-1) } }
    }

    private func pinched(_ s: CGFloat, _ ended: Bool, _ size: CGSize) {
        if !ended {
            m.zoom = min(6, max(1, zoomBase * s))
            pan = clamp(pan, size)
            return
        }
        if m.zoom < 1.06 {
            withAnimation(.spring(response: 0.3)) { m.zoom = 1; pan = .zero }
            zoomBase = 1; panBase = .zero
        } else {
            zoomBase = m.zoom; panBase = pan
        }
        m.scheduleHQ()
    }

    private func doubleTapped(_ p: CGPoint, _ size: CGSize) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if m.zoom > 1.01 {
                m.zoom = 1; pan = .zero
            } else {
                m.zoom = 2.5
                let r = CGSize(width: p.x - size.width / 2, height: p.y - size.height / 2)
                pan = clamp(CGSize(width: -r.width * 1.5, height: -r.height * 1.5), size)
            }
        }
        zoomBase = m.zoom; panBase = pan
        m.scheduleHQ()
        Haptics.tick()
    }

    private func step(_ d: Int) async {
        zoomBase = 1; pan = .zero; panBase = .zero
        Haptics.tick()
        await m.go(d)
    }

    // MARK: panel + strips

    @ViewBuilder private var panel: some View {
        switch m.category {
        case .looks: LooksPanel(m: m)
        case .crop: CropPanel(m: m)
        default:
            switch m.tool {
            case .slider(let k): SliderPanel(m: m, key: k)
            case .curve:
                CurveEditor(ys: m.recipe.nums("tone_curve"), onChange: { m.recipe.setNums("tone_curve", $0); m.commit(history: false) }, onEnd: { m.endGesture() })
                    .overlay(alignment: .topTrailing) {
                        if !m.recipe.isDefault("tone_curve") {
                            Button("Reset") { m.recipe.setNums("tone_curve", Recipe.identityCurve); m.commit() }
                                .font(.custom("Helvetica Neue", size: 11).weight(.bold)).foregroundStyle(Theme.red).padding(.trailing, 22)
                        }
                    }
            case .hsl: HSLPanel(m: m)
            case .mixer: MixerPanel(m: m)
            case .splitColors: SplitPanel(m: m)
            case .auto, .autoLight:
                Theme.meta(m.tool == .auto ? "Exposure, contrast, white balance and levels from the photo." : "Exposure and brightness only.")
                    .padding(.vertical, 26)
            }
        }
    }

    private func isActive(_ t: EditTool) -> Bool {
        switch t {
        case .slider(let k): return !m.recipe.isDefault(k)
        case .curve: return !m.recipe.isDefault("tone_curve")
        case .hsl: return !m.recipe.isDefault("hsl")
        case .mixer: return !m.recipe.isDefault("bw_mixer")
        case .splitColors: return m.recipe.num("split_shadow_sat") > 0 || m.recipe.num("split_highlight_sat") > 0
        case .auto, .autoLight: return false
        }
    }

    private func magnitude(_ t: EditTool) -> Double {
        if case .slider(let k) = t, let s = SliderSpec.all[k] { return s.magnitude(m.recipe.num(k)) }
        return isActive(t) ? 1 : 0
    }

    private var toolStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(m.category.tools, id: \.self) { t in
                        ToolButton(tool: t, selected: m.tool == t, magnitude: magnitude(t), active: isActive(t)) {
                            Haptics.tick()
                            switch t {
                            case .auto: m.tool = t; Task { await m.auto(toneOnly: false) }
                            case .autoLight: m.tool = t; Task { await m.auto(toneOnly: true) }
                            default: withAnimation(.easeOut(duration: 0.15)) { m.tool = t }
                            }
                            withAnimation { proxy.scrollTo(t, anchor: .center) }
                        }
                        .id(t)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(m.tool, anchor: .center) }
        }
    }

    private func categoryActive(_ c: EditCategory) -> Bool {
        switch c {
        case .looks: return m.recipe.lutName != nil || m.recipe.string("light_leak") != nil || m.recipe.string("film_border") != nil || m.recipe.bool("date_stamp")
        case .crop: return m.recipe.cropActive || m.recipe.rotation != 0
        default: return c.tools.contains { isActive($0) }
        }
    }

    private var categoryBar: some View {
        HStack(spacing: 0) {
            ForEach(EditCategory.allCases) { c in
                Button {
                    Haptics.tick()
                    withAnimation(.easeOut(duration: 0.18)) { m.category = c }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: c.icon).font(.system(size: 18))
                            .overlay(alignment: .topTrailing) {
                                if categoryActive(c) { Circle().fill(Theme.red).frame(width: 6, height: 6).offset(x: 5, y: -2) }
                            }
                        Text(c.rawValue.uppercased()).font(.custom("Helvetica Neue", size: 9).weight(.bold)).tracking(1.1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(m.category == c ? Theme.red : Color.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(m.category == c ? .isSelected : [])
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
    }

    // MARK: sheets + export

    @ViewBuilder private func sheetView(_ s: EditorSheet) -> some View {
        switch s {
        case .presets: PresetsSheet(m: m) { presetName = ""; namingPreset = true }
        case .copy: FieldsSheet(title: "Copy Edits", action: "Copy", keys: Recipe.copiable.map { $0.key }, preset: Set(m.recipe.activeFields)) { m.copy(fields: $0) }
        case .paste:
            let clip = EditClipboard.value ?? [:]
            FieldsSheet(title: "Paste Edits", action: "Paste", keys: Recipe.copiable.map { $0.key }.filter { clip[$0] != nil }, preset: Set(clip.keys)) { m.paste(fields: $0) }
        case .info: InfoSheet(api: m.api, item: m.item, recipe: m.recipe.json)
        case .albums: AlbumPicker(photoIDs: [m.item.id]) { m.toast = $0 }.environmentObject(app).preferredColorScheme(.dark)
        }
    }

    private func shareExport(web: Bool) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        await m.flushSave()
        guard let result = await m.export(web: web) else { return }
        let (data, name) = result
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            share = ShareFile(url: url)
        } catch { m.toast = error.localizedDescription }
    }

    private func syncToPhone() async {
        do {
            try await m.api.addToPhone([m.item.id], variant: "full")
            m.toast = "On its way to the phone album"
            Task { await app.sync(reason: "manual") }
        } catch { m.toast = error.localizedDescription }
    }
}

// MARK: - Sheets

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct PresetsSheet: View {
    @ObservedObject var m: EditorModel
    let saveNew: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Preset?
    @State private var newName = ""
    @State private var deleting: Preset?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { saveNew() } } label: {
                        Label("Save Current Edit as Preset…", systemImage: "plus")
                    }
                }
                Section {
                    if m.presets.isEmpty { Text("No presets yet.").foregroundStyle(.secondary) }
                    ForEach(m.presets) { p in
                        Button { m.applyPreset(p); dismiss() } label: {
                            HStack(spacing: 12) {
                                PresetIcon(shape: p.shape, color: p.color)
                                Text(p.name).foregroundStyle(.primary)
                                Spacer()
                                if p.id == m.presetID { Image(systemName: "link").foregroundStyle(Theme.red) }
                                if let n = p.linked_count, n > 0 { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
                            Button { newName = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }.tint(.gray)
                        }
                        .swipeActions(edge: .leading) {
                            Button { Task { await m.updatePreset(p) } } label: { Label("Update", systemImage: "arrow.triangle.2.circlepath") }.tint(Theme.red)
                        }
                    }
                } footer: {
                    Text("Tap to apply. Swipe right to replace a preset with this edit, left to rename or delete.")
                }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Rename preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { if let p = renaming { let n = newName; Task { await m.renamePreset(p, to: n) } } }
            }
            .confirmationDialog("Delete preset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let p = deleting { Task { await m.deletePreset(p) } } }
            } message: { Text("Photos keep their current look but are no longer linked.") }
        }
        .presentationDetents([.medium, .large])
        .task { if m.presets.isEmpty { await m.loadCatalogs() } }
    }
}

/// The web app's preset icon: a coloured shape.
struct PresetIcon: View {
    let shape: String?
    let color: String?

    var body: some View {
        let c = Hex.rgb(color ?? "#9a9488")
        let fill = Color(red: c.0, green: c.1, blue: c.2)
        Group {
            switch shape ?? "" {
            case "square": Rectangle().fill(fill)
            case "triangle": Image(systemName: "triangle.fill").resizable().foregroundStyle(fill)
            case "diamond": Rectangle().fill(fill).rotationEffect(.degrees(45)).scaleEffect(0.75)
            case "star": Star().fill(fill)
            case "hexagon": Image(systemName: "hexagon.fill").resizable().foregroundStyle(fill)
            default: Circle().fill(fill)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Pick which recipe fields to copy or paste.
struct FieldsSheet: View {
    let title: String
    let action: String
    let keys: [String]
    let preset: Set<String>
    let run: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var on: Set<String> = []

    private func label(_ k: String) -> String { Recipe.copiable.first { $0.key == k }?.label ?? k }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(keys, id: \.self) { k in
                        Toggle(label(k), isOn: Binding(get: { on.contains(k) }, set: { if $0 { on.insert(k) } else { on.remove(k) } }))
                            .tint(Theme.red)
                    }
                } header: {
                    HStack {
                        Button("All") { on = Set(keys) }
                        Spacer()
                        Button("None") { on = [] }
                    }
                    .textCase(nil)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action) { run(keys.filter { on.contains($0) }); dismiss() }.bold().disabled(on.isEmpty)
                }
            }
        }
        .onAppear { on = preset.intersection(keys) }
    }
}

struct InfoSheet: View {
    let api: API
    let item: PhotoItem
    let recipe: JSONValue
    @Environment(\.dismiss) private var dismiss
    @State private var exif: Exif?
    @State private var histo: Histogram?

    var body: some View {
        NavigationStack {
            List {
                if let histo {
                    Section("Histogram") {
                        HistogramView(h: histo).frame(maxWidth: .infinity)
                        HStack {
                            Text(String(format: "Shadows clipped %.2f%%", histo.clipped_low_pct ?? 0))
                            Spacer()
                            Text(String(format: "Highlights %.2f%%", histo.clipped_high_pct ?? 0))
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Camera") {
                    row("File", exif?.filename ?? item.filename)
                    row("Camera", [exif?.exif["make"] ?? nil, exif?.exif["model"] ?? nil].compactMap { $0 }.joined(separator: " "))
                    row("Lens", exif?.exif["lens_model"] ?? nil)
                    row("Focal length", exif?.exif["focal_length_mm"] ?? nil)
                    row("Aperture", exif?.exif["aperture"] ?? nil)
                    row("Shutter", exif?.exif["shutter"] ?? nil)
                    row("ISO", exif?.exif["iso"] ?? nil)
                    row("Taken", exif?.exif["datetime"] ?? nil)
                    row("Size", item.w.flatMap { w in item.h.map { "\(w) × \($0)" } })
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            exif = try? await api.exif(item.id)
            histo = try? await api.histogram(item.id, recipe: recipe)
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String?) -> some View {
        if let v, !v.isEmpty { LabeledContent(k, value: v) }
    }
}
