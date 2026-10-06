import SwiftUI

// MARK: - Groups (what the inspector shows; the phone strip flattens them)

extension EditCategory {
    var groups: [(title: String, tools: [EditTool])] {
        func s(_ keys: [String]) -> [EditTool] { keys.map { EditTool.slider($0) } }
        switch self {
        case .light:
            return [("", [.auto, .autoLight]),
                    ("Tone", s(["exposure", "brightness", "highlights", "shadows", "whites", "blacks", "contrast"])),
                    ("Tone curve", [.curve])]
        case .color:
            return [("White balance", s(["wb_temp", "wb_tint"])),
                    ("Color", s(["saturation", "vibrance"])),
                    ("Color mix", [.hsl]),
                    ("Black & white", s(["bw_amount"]) + [.mixer])]
        case .effects:
            return [("Detail", s(["dehaze", "sharpening"])),
                    ("Vignette", s(["vignette_amount", "vignette_midpoint", "vignette_feather", "vignette_roundness"])),
                    ("Matte", s(["matte"])),
                    ("Split tone", [.splitColors] + s(["split_shadow_sat", "split_highlight_sat", "split_balance"])),
                    ("Halation", s(["halation_amount", "halation_radius"])),
                    ("Bloom", s(["bloom_amount", "bloom_threshold", "bloom_radius"])),
                    ("Grain", s(["grain_amount", "grain_size", "grain_roughness"]))]
        case .looks, .crop:
            return []
        }
    }
}

extension EditorModel {
    func isActive(_ t: EditTool) -> Bool {
        switch t {
        case .slider(let k): return !recipe.isDefault(k)
        case .curve: return !recipe.isDefault("tone_curve")
        case .hsl: return !recipe.isDefault("hsl")
        case .mixer: return !recipe.isDefault("bw_mixer")
        case .splitColors: return recipe.num("split_shadow_sat") > 0 || recipe.num("split_highlight_sat") > 0
        case .auto, .autoLight: return false
        }
    }

    func magnitude(_ t: EditTool) -> Double {
        if case .slider(let k) = t, let s = SliderSpec.all[k] { return s.magnitude(recipe.num(k)) }
        return isActive(t) ? 1 : 0
    }

    func categoryActive(_ c: EditCategory) -> Bool {
        switch c {
        case .looks: return recipe.lutName != nil || recipe.string("light_leak") != nil || recipe.string("film_border") != nil || recipe.bool("date_stamp")
        case .crop: return recipe.cropActive || recipe.rotation != 0
        default: return c.tools.contains { isActive($0) }
        }
    }

    func goTo(_ i: Int) async { await go(i - index) }
}

// MARK: - Panel slider (inspector rows)

/// Label, value and a track with the red fill growing from the default point.
/// Drag near the knob for fine control, anywhere else to jump; double-tap resets.
struct PanelSlider: View {
    let spec: SliderSpec
    let value: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var startPos: Double?
    @State private var relative = true
    @State private var snapped = false

    var body: some View {
        let lo = spec.pos(of: spec.min), hi = spec.pos(of: spec.max)
        let pos = spec.pos(of: value), def = spec.pos(of: spec.def)
        let span = max(hi - lo, 1e-9)
        let isDefault = abs(value - spec.def) < 1e-9
        VStack(spacing: 4) {
            HStack {
                Text(spec.label).font(.custom("Helvetica Neue", size: 13)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(spec.text(value)).font(.custom("Helvetica Neue", size: 13).weight(.medium)).monospacedDigit()
                    .foregroundStyle(isDefault ? .secondary : Theme.red)
            }
            GeometryReader { g in
                let w = max(g.size.width, 1)
                let x = CGFloat((pos - lo) / span) * w
                let dx = CGFloat((def - lo) / span) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: 3)
                    Rectangle().fill(Theme.red).frame(width: max(0, abs(x - dx)), height: 3).offset(x: min(x, dx))
                    if dx > 2 && dx < w - 2 {
                        Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1, height: 9).offset(x: dx - 0.5)
                    }
                    Circle().fill(Color.white).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .offset(x: x - 8)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if startPos == nil {
                                relative = abs(v.startLocation.x - x) < 28
                                startPos = relative ? pos : lo + Double(v.startLocation.x / w) * span
                            }
                            var p = (startPos ?? pos) + Double(v.translation.width / w) * span
                            p = min(hi, max(lo, p))
                            let near = abs(p - def) < span * 0.012
                            if near != snapped { snapped = near; if near { Haptics.tick() } }
                            if near { p = def }
                            onChange(spec.value(at: p))
                        }
                        .onEnded { _ in startPos = nil; snapped = false; onEnd() }
                )
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onChange(spec.def); onEnd(); Haptics.arm() }
        .accessibilityElement()
        .accessibilityLabel(spec.label)
        .accessibilityValue(spec.text(value))
        .accessibilityAdjustableAction { d in
            let step = (spec.max - spec.min) / 40
            let v = d == .increment ? min(spec.max, value + step) : max(spec.min, value - step)
            onChange(spec.value(at: spec.pos(of: v)))
            onEnd()
        }
    }
}

// MARK: - Inspector (regular width)

struct EditorInspector: View {
    @ObservedObject var m: EditorModel
    let openPresets: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            categoryRow
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if m.showHistogram, let h = m.histogram {
                        HistogramView(h: h).frame(maxWidth: .infinity).padding(.top, 12)
                    }
                    content
                }
                .padding(.vertical, 10)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 350)
        .background(Color(white: 0.075))
    }

    private var categoryRow: some View {
        HStack(spacing: 0) {
            ForEach(EditCategory.allCases) { c in
                Button {
                    Haptics.tick()
                    withAnimation(.easeOut(duration: 0.15)) { m.category = c }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: c.icon).font(.system(size: 17))
                            .overlay(alignment: .topTrailing) {
                                if m.categoryActive(c) { Circle().fill(Theme.red).frame(width: 5, height: 5).offset(x: 4, y: -2) }
                            }
                        Text(c.rawValue.uppercased()).font(.custom("Helvetica Neue", size: 8).weight(.bold)).tracking(0.9)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(m.category == c ? Theme.red : Color.white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(m.category == c ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch m.category {
        case .looks:
            presetsRow
            LooksPanel(m: m, wide: true)
        case .crop:
            CropPanel(m: m, wide: true)
        default:
            ForEach(Array(m.category.groups.enumerated()), id: \.offset) { _, g in
                if !g.title.isEmpty {
                    HStack {
                        Text(g.title.uppercased()).font(.custom("Helvetica Neue", size: 10).weight(.bold)).tracking(1.4)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        if g.tools.contains(where: { m.isActive($0) }) {
                            Button("Reset") { reset(g.tools) }
                                .font(.custom("Helvetica Neue", size: 11).weight(.medium)).foregroundStyle(Theme.red)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                }
                ForEach(g.tools, id: \.self) { t in item(t) }
            }
        }
    }

    @ViewBuilder private func item(_ t: EditTool) -> some View {
        switch t {
        case .slider(let k):
            if let spec = SliderSpec.all[k] {
                PanelSlider(spec: spec, value: m.recipe.num(k), onChange: { m.set(k, $0) }, onEnd: { m.endGesture() })
            }
        case .curve:
            CurveEditor(ys: m.recipe.nums("tone_curve"), onChange: { m.recipe.setNums("tone_curve", $0); m.commit(history: false) }, onEnd: { m.endGesture() })
                .padding(.horizontal, -4)
        case .hsl: HSLPanel(m: m)
        case .mixer: MixerPanel(m: m)
        case .splitColors: SplitPanel(m: m)
        case .auto:
            HStack(spacing: 10) {
                autoButton("Auto", icon: "wand.and.stars") { await m.auto(toneOnly: false) }
                autoButton("Auto light", icon: "wand.and.rays") { await m.auto(toneOnly: true) }
            }
            .padding(.horizontal, 16).padding(.top, 6)
        case .autoLight:
            EmptyView()
        }
    }

    private func autoButton(_ title: String, icon: String, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            Label(title, systemImage: icon)
                .font(.custom("Helvetica Neue", size: 12).weight(.bold))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(Pressable())
    }

    private var presetsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PRESETS").font(.custom("Helvetica Neue", size: 10).weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button("Manage") { openPresets() }.font(.custom("Helvetica Neue", size: 11).weight(.medium)).foregroundStyle(Theme.red)
            }
            .padding(.horizontal, 16)
            if m.presets.isEmpty {
                Theme.meta("Save an edit as a preset from the ⋯ menu.").padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(m.presets) { p in
                            Button { m.applyPreset(p) } label: {
                                HStack(spacing: 6) {
                                    PresetIcon(shape: p.shape, color: p.color)
                                    Text(p.name).font(.custom("Helvetica Neue", size: 12).weight(.medium)).lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(p.id == m.presetID ? Theme.red : Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(Pressable())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.top, 8)
    }

    private func reset(_ tools: [EditTool]) {
        for t in tools {
            switch t {
            case .slider(let k): if let d = Recipe.defaults[k] { m.recipe.raw[k] = d }
            case .curve: m.recipe.setNums("tone_curve", Recipe.identityCurve)
            case .hsl: m.recipe.raw["hsl"] = Recipe.defaults["hsl"]
            case .mixer: m.recipe.raw["bw_mixer"] = Recipe.defaults["bw_mixer"]
            case .splitColors: m.recipe.set("split_shadow_sat", 0); m.recipe.set("split_highlight_sat", 0)
            default: break
            }
        }
        m.commit()
        Haptics.tick()
    }
}

// MARK: - Filmstrip

struct Filmstrip: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(m.items.enumerated()), id: \.element.id) { i, p in
                        RemoteImage(request: m.api.thumb(p))
                            .frame(width: 64, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(i == m.index ? Theme.red : Color.clear, lineWidth: 2))
                            .opacity(p.rating < 0 ? 0.4 : 1)
                            .onTapGesture { if i != m.index { Task { await m.goTo(i) } } }
                            .id(p.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 60)
            .onAppear { proxy.scrollTo(m.item.id, anchor: .center) }
            .onChange(of: m.index) { _, _ in withAnimation { proxy.scrollTo(m.item.id, anchor: .center) } }
        }
    }
}

/// Five stars for the top bar on wide screens.
struct RatingStars: View {
    let rating: Int
    let rate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { rate(rating == -1 ? 0 : -1) } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(rating == -1 ? Theme.red : .white.opacity(0.35))
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel("Reject")
            ForEach(1...5, id: \.self) { n in
                Button { rate(rating == n ? 0 : n) } label: {
                    Image(systemName: rating >= n ? "star.fill" : "star").font(.system(size: 14))
                        .foregroundStyle(rating >= n ? Theme.red : .white.opacity(0.35))
                        .frame(width: 22, height: 22)
                }
                .accessibilityLabel("\(n) stars")
            }
        }
        .buttonStyle(.plain)
    }
}
