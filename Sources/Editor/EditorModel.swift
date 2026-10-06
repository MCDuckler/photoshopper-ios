import SwiftUI
import Photos

enum EditCategory: String, CaseIterable, Identifiable {
    case light = "Light", color = "Color", effects = "Effects", looks = "Looks", crop = "Crop"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "paintpalette"
        case .effects: return "sparkles"
        case .looks: return "camera.filters"
        case .crop: return "crop.rotate"
        }
    }
    var tools: [EditTool] {
        var t: [EditTool] = []
        func sliders(_ keys: [String]) { for k in keys { t.append(.slider(k)) } }
        switch self {
        case .light:
            t.append(.auto)
            t.append(.autoLight)
            sliders(["exposure", "brightness", "highlights", "shadows", "whites", "blacks", "contrast"])
            t.append(.curve)
        case .color:
            sliders(["wb_temp", "wb_tint", "saturation", "vibrance"])
            t.append(.hsl)
            sliders(["bw_amount"])
            t.append(.mixer)
        case .effects:
            sliders(["dehaze", "sharpening", "vignette_amount", "vignette_midpoint", "vignette_feather", "vignette_roundness", "matte"])
            t.append(.splitColors)
            sliders(["split_shadow_sat", "split_highlight_sat", "split_balance",
                     "halation_amount", "halation_radius", "bloom_amount", "bloom_threshold", "bloom_radius",
                     "grain_amount", "grain_size", "grain_roughness"])
        case .looks, .crop:
            break
        }
        return t
    }
}

enum EditTool: Hashable {
    case slider(String), curve, hsl, mixer, splitColors, auto, autoLight

    var label: String {
        switch self {
        case .slider(let k): return SliderSpec.all[k]?.label ?? k
        case .curve: return "Curve"
        case .hsl: return "Color mix"
        case .mixer: return "B&W mix"
        case .splitColors: return "Split colors"
        case .auto: return "Auto"
        case .autoLight: return "Auto light"
        }
    }
    var icon: String {
        switch self {
        case .slider(let k): return SliderSpec.all[k]?.icon ?? "slider.horizontal.3"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .hsl: return "swatchpalette"
        case .mixer: return "slider.horizontal.3"
        case .splitColors: return "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .auto: return "wand.and.stars"
        case .autoLight: return "wand.and.rays"
        }
    }
}

enum SaveState { case saved, dirty, saving, queued }

/// One photo in the editor. Every change goes through `commit`: the Metal preview
/// redraws at once, the server render follows after a pause and fades in, and the
/// recipe autosaves. There is no Save button.
@MainActor
final class EditorModel: ObservableObject {
    let api: API
    @Published private(set) var item: PhotoItem
    let items: [PhotoItem]
    @Published private(set) var index: Int

    @Published var recipe = Recipe.fresh
    @Published private(set) var presetID: Int?
    @Published private(set) var save: SaveState = .saved
    @Published private(set) var loaded = false
    @Published private(set) var error: String?

    // pictures
    @Published private(set) var server: UIImage?          // authoritative render
    @Published private(set) var serverKey = ""            // display key it matches
    @Published private(set) var hq: UIImage?
    @Published private(set) var base: UIImage?            // unedited RAW preview
    @Published private(set) var rendering = false
    @Published private(set) var liveReady = false
    let renderer: PreviewRenderer? = PreviewRenderer.make()

    // tools
    @Published var category: EditCategory = .light { didSet { if category != oldValue { categoryChanged(from: oldValue) } } }
    @Published var tool: EditTool = .slider("exposure")
    @Published var hslBand: HueBand = .red
    @Published var cropAspect: CGFloat?      // nil = free
    @Published var zoom: CGFloat = 1

    // catalogs
    @Published private(set) var luts: [LutInfo] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var leaks: [OverlayInfo] = []
    @Published private(set) var borders: [OverlayInfo] = []
    @Published private(set) var presets: [Preset] = []
    @Published var histogram: Histogram?
    @Published var showHistogram = false { didSet { if showHistogram { scheduleHistogram() } } }
    @Published var rating: Int

    @Published var toast: String?

    private var history: [Recipe] = []
    private var histIdx = -1
    private var previewTask: Task<Void, Never>?
    private var hqTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var histTask: Task<Void, Never>?
    private var lutTask: Task<Void, Never>?

    var canUndo: Bool { histIdx > 0 }
    var canRedo: Bool { histIdx >= 0 && histIdx < history.count - 1 }
    var cropping: Bool { category == .crop }
    var hasPrev: Bool { index > 0 }
    var hasNext: Bool { index < items.count - 1 }

    /// The long edge of server previews: enough for this screen, and the size the web
    /// editor uses on a phone so both share the server's preview cache.
    let previewEdge: Int

    init(api: API, items: [PhotoItem], index: Int) {
        self.api = api
        self.items = items
        self.index = index
        self.item = items[index]
        self.rating = items[index].rating
        self.previewEdge = UIScreen.main.nativeBounds.width > 1400 ? 2048 : 1400
    }

    // MARK: loading

    func load() async {
        loaded = false
        error = nil
        recipe = .fresh
        presetID = nil
        history = []; histIdx = -1
        server = ImageLoader.shared.cached(api.preview(item))
        serverKey = ""
        hq = nil
        base = nil
        liveReady = false
        let id = item.id
        Task { await api.prepare(id) }

        async let saved = try? api.edit(id)
        async let baseImg = ImageLoader.shared.image(api.basePreview(id))
        if server == nil { server = await ImageLoader.shared.image(api.preview(item)) }
        if let found = await saved {
            recipe = Recipe(server: found.recipe)
            presetID = found.presetID
        }
        guard item.id == id else { return }
        base = await baseImg
        if let base, let r = renderer, r.setImage(base) { liveReady = true }
        await syncLut()
        loaded = true
        pushHistory()
        refreshServer(delay: 0)
        if catalogsEmpty { await loadCatalogs() }
    }

    private var catalogsEmpty: Bool { luts.isEmpty && presets.isEmpty }

    func loadCatalogs() async {
        async let l = try? api.luts()
        async let f = try? api.favoriteLuts()
        async let lk = try? api.overlays("leaks")
        async let bd = try? api.overlays("borders")
        async let p = try? api.presets()
        luts = await l ?? []
        favorites = await f ?? []
        leaks = await lk ?? []
        borders = await bd ?? []
        presets = await p ?? []
    }

    func go(_ delta: Int) async {
        let j = index + delta
        guard items.indices.contains(j) else { return }
        await flushSave()
        index = j
        item = items[j]
        rating = item.rating
        zoom = 1
        await load()
    }

    // MARK: change funnel

    /// Shown frame: the crop tool works on the whole (rotated) photo.
    var displayRecipe: Recipe {
        guard cropping else { return recipe }
        var r = recipe
        r.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        return r
    }

    var displayKey: String { String(decoding: displayRecipe.json.data, as: UTF8.self) }

    var sourceAspect: CGFloat {
        if let b = base, b.size.height > 0 { return b.size.width / b.size.height }
        return item.aspect
    }

    var frameAspect: CGFloat { displayRecipe.outputAspect(source: sourceAspect) }

    /// True while the GPU preview is ahead of the server render.
    var showLive: Bool { liveReady && serverKey != displayKey }

    func shaderInputs(original: Bool) -> (params: [Float], curve: [Float]) {
        PreviewParams.make(displayRecipe, aspect: Float(sourceAspect), lutSize: renderer?.lutN ?? 0, showOriginal: original, fullFrame: cropping)
    }

    /// Call after any change to `recipe`. `history: true` records an undo step now
    /// (taps); sliders record on release via `endGesture`.
    func commit(history: Bool = true, keepPreset: Bool = false) {
        if !keepPreset { presetID = nil }
        hq = nil
        save = .dirty
        if recipe.lutName != renderer?.lutName { lutTask?.cancel(); lutTask = Task { await syncLut() } }
        refreshServer(delay: 0.18)
        scheduleSave()
        if history { pushHistory() }
    }

    func endGesture() { pushHistory() }

    func set(_ key: String, _ v: Double) {
        guard recipe.num(key) != v else { return }
        recipe.set(key, v)
        commit(history: false)
    }

    private func categoryChanged(from old: EditCategory) {
        if old == .crop || category == .crop {
            zoom = 1
            refreshServer(delay: 0)
        }
        if let first = category.tools.first(where: { if case .slider = $0 { return true }; return false }) { tool = first }
    }

    // MARK: server preview

    func refreshServer(delay: Double) {
        previewTask?.cancel()
        let key = displayKey
        let body = displayRecipe.json
        let id = item.id
        let edge = previewEdge
        previewTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            if Task.isCancelled { return }
            rendering = true
            defer { if !Task.isCancelled { rendering = false } }
            do {
                let img = try await api.previewEdit(id, recipe: body, longEdge: edge)
                guard !Task.isCancelled, id == item.id, key == displayKey else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    server = img
                    serverKey = key
                }
                if showHistogram { scheduleHistogram() }
                if zoom > 1.4 { scheduleHQ() }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    toast = "Preview: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Sharper render while zoomed in.
    func scheduleHQ() {
        hqTask?.cancel()
        guard zoom > 1.4, !cropping else { hq = nil; return }
        let edge = min(4096, Int(Double(previewEdge) * Double(zoom)))
        let key = displayKey, body = displayRecipe.json, id = item.id
        hqTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard let img = try? await api.previewEdit(id, recipe: body, longEdge: edge),
                  !Task.isCancelled, key == displayKey, id == item.id else { return }
            hq = img
        }
    }

    private func scheduleHistogram() {
        histTask?.cancel()
        let body = recipe.json, id = item.id
        histTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            if let h = try? await api.histogram(id, recipe: body), !Task.isCancelled { histogram = h }
        }
    }

    private func syncLut() async {
        guard let r = renderer else { return }
        let want = recipe.lutName
        if want == r.lutName { return }
        guard let want else { r.setLut(name: nil, png: nil); objectWillChange.send(); return }
        let png = await ImageLoader.shared.image(api.lutImage(want))
        guard recipe.lutName == want else { return }
        r.setLut(name: want, png: png)
        objectWillChange.send()
    }

    // MARK: saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await saveNow()
        }
    }

    func flushSave() async {
        guard save == .dirty else { return }
        saveTask?.cancel()
        await saveNow()
    }

    private func saveNow() async {
        let id = item.id, body = recipe.json, preset = presetID
        save = .saving
        do {
            let at = try await api.putEdit(id, recipe: body, presetID: preset)
            if id == item.id, save == .saving { save = .saved }
            Outbox.shared.announce(.edited(id, true, at))
        } catch {
            Outbox.shared.edit(id, recipe: body, presetID: preset)
            if id == item.id { save = .queued }
        }
    }

    func revert() async {
        saveTask?.cancel()
        recipe = .fresh
        presetID = nil
        let id = item.id
        do { try await api.deleteEdit(id); Outbox.shared.announce(.edited(id, false, 0)) }
        catch { Outbox.shared.editDelete(id) }
        save = .saved
        pushHistory()
        if renderer?.lutName != nil { await syncLut() }
        refreshServer(delay: 0)
        toast = "Back to the original"
    }

    // MARK: history

    private func pushHistory() {
        if histIdx >= 0, histIdx < history.count, history[histIdx] == recipe { return }
        if histIdx < history.count - 1 { history.removeSubrange((histIdx + 1)...) }
        history.append(recipe)
        if history.count > 50 { history.removeFirst(history.count - 50) }
        histIdx = history.count - 1
        objectWillChange.send()
    }

    func undo() {
        guard canUndo else { return }
        histIdx -= 1
        recipe = history[histIdx]
        commit(history: false)
    }

    func redo() {
        guard canRedo else { return }
        histIdx += 1
        recipe = history[histIdx]
        commit(history: false)
    }

    // MARK: actions

    func auto(toneOnly: Bool) async {
        do {
            let s = try await api.auto(item.id, toneOnly: toneOnly)
            guard !s.isEmpty else { toast = "Nothing to suggest"; return }
            for (k, v) in s where toneOnly ? (k == "exposure" || k == "brightness") : true { recipe.raw[k] = v }
            commit()
            if toneOnly {
                toast = String(format: "Auto light · exposure %+.2f · brightness %+.2f", recipe.num("exposure"), recipe.num("brightness"))
            } else { toast = "Auto applied" }
            Haptics.success()
        } catch { toast = error.localizedDescription }
    }

    func rate(_ r: Int) {
        rating = r
        Outbox.shared.rate([item.id], r)
        Haptics.tick()
    }

    func applyPreset(_ p: Preset) {
        var r = Recipe.fresh
        for (k, v) in p.recipe.object ?? [:] where k != "export" { r.raw[k] = v }
        if let ex = recipe.raw["export"] { r.raw["export"] = ex }
        recipe = r
        presetID = p.id
        commit(keepPreset: true)
        toast = "Applied \(p.name)"
        Haptics.success()
    }

    func savePreset(named name: String) async {
        do {
            let p = try await api.createPreset(name: name, recipe: recipe.json)
            presets = (try? await api.presets()) ?? presets + [p]
            presetID = p.id
            save = .dirty
            await saveNow()
            toast = "Saved preset “\(name)”"
        } catch { toast = error.localizedDescription }
    }

    func updatePreset(_ p: Preset) async {
        do {
            try await api.updatePreset(p.id, recipe: recipe.json)
            presets = (try? await api.presets()) ?? presets
            presetID = p.id
            save = .dirty
            await saveNow()
            toast = "Updated \(p.name)"
        } catch { toast = error.localizedDescription }
    }

    func renamePreset(_ p: Preset, to name: String) async {
        do { try await api.updatePreset(p.id, name: name); presets = (try? await api.presets()) ?? presets }
        catch { toast = error.localizedDescription }
    }

    func deletePreset(_ p: Preset) async {
        do {
            try await api.deletePreset(p.id)
            presets.removeAll { $0.id == p.id }
            if presetID == p.id { presetID = nil }
        } catch { toast = error.localizedDescription }
    }

    func copy(fields: [String]) {
        var out: [String: JSONValue] = [:]
        for k in fields { out[k] = recipe.raw[k] ?? Recipe.defaults[k] ?? .null }
        EditClipboard.value = out
        toast = "Copied \(fields.count) setting\(fields.count == 1 ? "" : "s")"
    }

    func paste(fields: [String]) {
        guard let clip = EditClipboard.value else { toast = "Nothing copied yet"; return }
        for k in fields { if let v = clip[k] { recipe.raw[k] = v } }
        commit()
        toast = "Pasted \(fields.count) setting\(fields.count == 1 ? "" : "s")"
    }

    func toggleFavorite(_ lut: String) async {
        let on = !favorites.contains(lut)
        do {
            try await api.setFavorite(lut, on)
            if on { favorites.insert(lut) } else { favorites.remove(lut) }
            Haptics.tick()
        } catch { toast = error.localizedDescription }
    }

    // MARK: crop

    func rotate() {
        // Rotating swaps the frame's sides; keep the crop centred and in bounds.
        let c = recipe.crop
        recipe.rotation = recipe.rotation + 90
        recipe.crop = CGRect(x: 1 - c.maxY, y: c.minX, width: c.height, height: c.width)
        if let a = cropAspect { snapCrop(to: 1 / a) ; cropAspect = 1 / a }
        commit()
        Haptics.tick()
    }

    func resetCrop() {
        recipe.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let a = cropAspect { snapCrop(to: a) }
        commit()
    }

    /// Fit the crop to `aspect` (width / height of the result), centred on the current crop.
    func snapCrop(to aspect: CGFloat) {
        let frame = recipe.rotation % 180 == 0 ? sourceAspect : 1 / sourceAspect
        let rel = aspect / max(frame, 0.01)
        let c = recipe.crop
        var w = c.width, h = c.height
        if w / h > rel { w = h * rel } else { h = w / rel }
        if w > 1 { h /= w; w = 1 }
        if h > 1 { w /= h; h = 1 }
        let cx = c.midX, cy = c.midY
        recipe.crop = CGRect(x: min(max(cx - w / 2, 0), 1 - w), y: min(max(cy - h / 2, 0), 1 - h), width: w, height: h)
    }

    // MARK: export

    func export(web: Bool) async -> (Data, String)? {
        toast = web ? "Rendering web size…" : "Rendering full quality…"
        do { return try await api.render(item.id, recipe: recipe.json, web: web) }
        catch { toast = "Export failed: \(error.localizedDescription)"; return nil }
    }

    func saveToPhotos(web: Bool) async {
        guard let result = await export(web: web) else { return }
        let data = result.0
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { toast = "No permission to add photos"; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            toast = "Saved to Photos"
            Haptics.success()
        } catch { toast = error.localizedDescription }
    }
}
