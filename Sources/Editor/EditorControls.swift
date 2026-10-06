import SwiftUI
import UIKit

// MARK: - Ruler dial

/// The adjustment dial: drag the scale under a fixed red needle, like Photos.
/// Ticks click under the finger, the default value is a detent, double-tap resets.
struct Ruler: View {
    let spec: SliderSpec
    let value: Double
    var span: CGFloat = 480
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var start: Double?
    @State private var lastTick: Int?

    private let ticks = 40

    var body: some View {
        let lo = spec.pos(of: spec.min), hi = spec.pos(of: spec.max)
        let pos = spec.pos(of: value)
        let perUnit = span / CGFloat(max(hi - lo, 1e-9))
        let defPos = spec.pos(of: spec.def)
        Canvas { ctx, size in
            let mid = size.width / 2
            let cy = size.height / 2
            for i in 0...ticks {
                let p = lo + (hi - lo) * Double(i) / Double(ticks)
                let x = mid + CGFloat(p - pos) * perUnit
                guard x > -2, x < size.width + 2 else { continue }
                let major = i % 5 == 0
                let fade = 1 - min(1, abs(x - mid) / max(size.width / 2, 1)) * 0.8
                let h: CGFloat = major ? 18 : 10
                var path = Path()
                path.move(to: CGPoint(x: x, y: cy - h / 2))
                path.addLine(to: CGPoint(x: x, y: cy + h / 2))
                ctx.stroke(path, with: .color(.white.opacity(0.75 * fade)), lineWidth: major ? 1.5 : 1)
            }
            let dx = mid + CGFloat(defPos - pos) * perUnit
            if dx > 0 && dx < size.width {
                ctx.fill(Path(ellipseIn: CGRect(x: dx - 2.5, y: size.height - 6, width: 5, height: 5)), with: .color(.white.opacity(0.85)))
            }
            var needle = Path()
            needle.move(to: CGPoint(x: mid, y: 2))
            needle.addLine(to: CGPoint(x: mid, y: size.height - 9))
            ctx.stroke(needle, with: .color(Theme.red), lineWidth: 2)
        }
        .frame(height: 40)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if start == nil { start = pos }
                    var p = (start ?? pos) - Double(g.translation.width / perUnit)
                    p = min(hi, max(lo, p))
                    if abs(p - defPos) < (hi - lo) * 0.012 { p = defPos }
                    let tick = Int(((p - lo) / (hi - lo) * Double(ticks)).rounded())
                    if tick != lastTick {
                        if lastTick != nil { Haptics.tick() }
                        lastTick = tick
                    }
                    onChange(spec.value(at: p))
                }
                .onEnded { _ in
                    start = nil
                    lastTick = nil
                    onEnd()
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onChange(spec.def)
            onEnd()
            Haptics.arm()
        })
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

/// Label, value and dial for one recipe field.
struct SliderPanel: View {
    @ObservedObject var m: EditorModel
    let key: String

    var body: some View {
        if let spec = SliderSpec.all[key] {
            let v = m.recipe.num(key)
            VStack(spacing: 6) {
                HStack {
                    Text(spec.label.uppercased()).font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.4)
                    Spacer()
                    Text(spec.text(v)).font(.custom("Helvetica Neue", size: 13).weight(.medium)).monospacedDigit()
                        .foregroundStyle(m.recipe.isDefault(key) ? .secondary : Theme.red)
                }
                .padding(.horizontal, 20)
                Ruler(spec: spec, value: v, onChange: { m.set(key, $0) }, onEnd: { m.endGesture() })
            }
            .padding(.vertical, 8)
        }
    }
}

/// A compact labelled dial for panels with several (colour mix, split tone…).
struct MiniRuler: View {
    let label: String
    let spec: SliderSpec
    let value: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(.custom("Helvetica Neue", size: 10).weight(.bold)).tracking(1.1)
                .frame(width: 78, alignment: .leading)
            Ruler(spec: spec, value: value, span: 300, onChange: onChange, onEnd: onEnd)
            Text(spec.text(value)).font(.custom("Helvetica Neue", size: 11)).monospacedDigit()
                .foregroundStyle(abs(value - spec.def) < 1e-9 ? .secondary : Theme.red)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Tool strip

struct ToolButton: View {
    let tool: EditTool
    let selected: Bool
    let magnitude: Double
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(selected ? Color.white : Color.white.opacity(0.08))
                if active {
                    Circle().trim(from: 0, to: max(0.05, magnitude))
                        .stroke(Theme.red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.5)
                }
                Image(systemName: tool.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Color.black : Color.white)
            }
            .frame(width: 48, height: 48)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Tone curve

struct CurveEditor: View {
    let ys: [Double]
    let onChange: ([Double]) -> Void
    let onEnd: () -> Void
    @State private var dragging: Int?

    private let xs = Recipe.identityCurve

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Canvas { ctx, _ in
                var grid = Path()
                for i in 1..<4 {
                    let x = w * CGFloat(i) / 4, y = h * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: h))
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: w, y: y))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
                ctx.stroke(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(.white.opacity(0.2)), lineWidth: 1)
                var diag = Path()
                diag.move(to: CGPoint(x: 0, y: h)); diag.addLine(to: CGPoint(x: w, y: 0))
                ctx.stroke(diag, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                var curve = Path()
                for i in 0..<5 {
                    let p = CGPoint(x: w * CGFloat(xs[i]), y: h * CGFloat(1 - ys[i]))
                    if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                }
                ctx.stroke(curve, with: .color(.white), lineWidth: 2)
                for i in 0..<5 {
                    let p = CGPoint(x: w * CGFloat(xs[i]), y: h * CGFloat(1 - ys[i]))
                    let r: CGFloat = dragging == i ? 8 : 6
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Theme.red))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragging == nil {
                            let lx = Double(v.startLocation.x / max(w, 1))
                            dragging = (0..<5).min { abs(xs[$0] - lx) < abs(xs[$1] - lx) }
                            Haptics.tick()
                        }
                        guard let i = dragging else { return }
                        var y = ys
                        y[i] = min(1, max(0, Double(1 - v.location.y / max(h, 1))))
                        onChange(y)
                    }
                    .onEnded { _ in dragging = nil; onEnd() }
            )
        }
        .frame(maxWidth: 340)
        .frame(height: 132)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

// MARK: - Colour bands

struct BandPicker: View {
    @Binding var band: HueBand
    let adjusted: (HueBand) -> Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HueBand.allCases) { b in
                let c = b.rgb
                Circle().fill(Color(red: c.0, green: c.1, blue: c.2))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white, lineWidth: band == b ? 2 : 0).padding(-4))
                    .overlay(alignment: .topTrailing) {
                        if adjusted(b) { Circle().fill(Color.white).frame(width: 5, height: 5).offset(x: 4, y: -4) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
                    .onTapGesture { band = b; Haptics.tick() }
                    .accessibilityLabel(b.name)
                    .accessibilityAddTraits(band == b ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
    }
}

private let unitSpec = SliderSpec(key: "_unit", label: "", icon: "", min: -1, max: 1, dp: 2)

struct HSLPanel: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        let v = m.recipe.nums("hsl")
        let i = m.hslBand.rawValue * 3
        VStack(spacing: 2) {
            BandPicker(band: $m.hslBand) { b in (0..<3).contains { j in abs(v[safe: b.rawValue * 3 + j] ?? 0) > 1e-4 } }
            MiniRuler(label: "Hue", spec: unitSpec, value: v[safe: i] ?? 0, onChange: { set(i, $0) }, onEnd: { m.endGesture() })
            MiniRuler(label: "Saturation", spec: unitSpec, value: v[safe: i + 1] ?? 0, onChange: { set(i + 1, $0) }, onEnd: { m.endGesture() })
            MiniRuler(label: "Luminance", spec: unitSpec, value: v[safe: i + 2] ?? 0, onChange: { set(i + 2, $0) }, onEnd: { m.endGesture() })
        }
        .padding(.vertical, 6)
    }

    private func set(_ j: Int, _ x: Double) {
        var v = m.recipe.nums("hsl")
        guard v.indices.contains(j), v[j] != x else { return }
        v[j] = x
        m.recipe.setNums("hsl", v)
        m.commit(history: false)
    }
}

struct MixerPanel: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        let v = m.recipe.nums("bw_mixer")
        let i = m.hslBand.rawValue
        VStack(spacing: 4) {
            BandPicker(band: $m.hslBand) { b in abs(v[safe: b.rawValue] ?? 0) > 1e-4 }
            MiniRuler(label: m.hslBand.name + " grey", spec: unitSpec, value: v[safe: i] ?? 0, onChange: { set(i, $0) }, onEnd: { m.endGesture() })
            if m.recipe.num("bw_amount") <= 0 {
                Theme.meta("Turn up Black & white to hear the mixer.").padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private func set(_ j: Int, _ x: Double) {
        var v = m.recipe.nums("bw_mixer")
        guard v.indices.contains(j), v[j] != x else { return }
        v[j] = x
        m.recipe.setNums("bw_mixer", v)
        m.commit(history: false)
    }
}

struct SplitPanel: View {
    @ObservedObject var m: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 24) {
                ColorPicker(selection: color("split_shadow_hex"), supportsOpacity: false) {
                    Text("SHADOWS").font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.2)
                }
                ColorPicker(selection: color("split_highlight_hex"), supportsOpacity: false) {
                    Text("HIGHLIGHTS").font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.2)
                }
            }
            .padding(.horizontal, 20)
            Theme.meta("Strength and balance are the next three dials.")
        }
        .padding(.vertical, 14)
    }

    private func color(_ key: String) -> Binding<Color> {
        Binding(
            get: { let c = Hex.rgb(m.recipe.string(key)); return Color(red: c.0, green: c.1, blue: c.2) },
            set: { new in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(new).getRed(&r, green: &g, blue: &b, alpha: &a)
                let hex = Hex.string(Double(r), Double(g), Double(b))
                guard hex != m.recipe.string(key) else { return }
                m.recipe.setString(key, hex)
                // A colour is only visible with some strength; give it a start.
                let sat = key == "split_shadow_hex" ? "split_shadow_sat" : "split_highlight_sat"
                if m.recipe.num(sat) == 0 { m.recipe.set(sat, 0.3) }
                m.commit()
            })
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Crop

enum CropHandle { case move, tl, tr, bl, br, t, b, l, r }

enum CropMath {
    static let minSide: CGFloat = 0.05

    /// Port of the web editor's computeCrop: drag `h` by (dx, dy) in normalised units.
    /// `rel` locks width/height in normalised units (nil = free).
    static func drag(_ h: CropHandle, dx: CGFloat, dy: CGFloat, from c0: CGRect, rel: CGFloat?) -> CGRect {
        func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { min(max(v, a), b) }
        if h == .move {
            return CGRect(x: clamp(c0.minX + dx, 0, 1 - c0.width), y: clamp(c0.minY + dy, 0, 1 - c0.height), width: c0.width, height: c0.height)
        }
        var L = c0.minX, T = c0.minY, R = c0.maxX, B = c0.maxY
        let hasL = [.tl, .bl, .l].contains(h), hasR = [.tr, .br, .r].contains(h)
        let hasT = [.tl, .tr, .t].contains(h), hasB = [.bl, .br, .b].contains(h)
        if hasL { L = clamp(c0.minX + dx, 0, R - minSide) }
        if hasR { R = clamp(R + dx, L + minSide, 1) }
        if hasT { T = clamp(c0.minY + dy, 0, B - minSide) }
        if hasB { B = clamp(B + dy, T + minSide, 1) }
        var w = R - L, hh = B - T
        guard let rel else { return CGRect(x: L, y: T, width: w, height: hh) }
        let corner = (hasL || hasR) && (hasT || hasB)
        if corner {
            let ax = hasL ? R : L, ay = hasT ? B : T
            if w / hh > rel { w = hh * rel } else { hh = w / rel }
            if hasL { L = ax - w } else { R = ax + w }
            if hasT { T = ay - hh } else { B = ay + hh }
        } else if hasL || hasR {
            hh = w / rel
            let cy = c0.midY
            T = cy - hh / 2; B = cy + hh / 2
        } else {
            w = hh * rel
            let cx = c0.midX
            L = cx - w / 2; R = cx + w / 2
        }
        if L < 0 { R -= L; L = 0 }
        if T < 0 { B -= T; T = 0 }
        if R > 1 { L -= R - 1; R = 1 }
        if B > 1 { T -= B - 1; B = 1 }
        w = R - L; hh = B - T
        if w > 1 { hh /= w; w = 1 }
        if hh > 1 { w /= hh; hh = 1 }
        return CGRect(x: clamp(L, 0, 1 - w), y: clamp(T, 0, 1 - hh), width: w, height: hh)
    }
}

/// Crop box over the whole (rotated) photo: corners and edges resize, inside moves.
struct CropOverlay: View {
    let crop: CGRect
    let rel: CGFloat?
    let onChange: (CGRect) -> Void
    let onEnd: () -> Void
    @State private var start: CGRect?
    @State private var handle: CropHandle?

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            let r = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H)
            Canvas { ctx, size in
                var scrim = Path(CGRect(origin: .zero, size: size))
                scrim.addRect(r)
                ctx.fill(scrim, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(r), with: .color(.white), lineWidth: 1.2)
                var thirds = Path()
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    thirds.move(to: CGPoint(x: x, y: r.minY)); thirds.addLine(to: CGPoint(x: x, y: r.maxY))
                    thirds.move(to: CGPoint(x: r.minX, y: y)); thirds.addLine(to: CGPoint(x: r.maxX, y: y))
                }
                ctx.stroke(thirds, with: .color(.white.opacity(handle == nil ? 0.35 : 0.7)), lineWidth: 0.6)
                let k: CGFloat = min(22, r.width / 3, r.height / 3)
                var corners = Path()
                for (p, sx, sy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                    (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                    corners.move(to: CGPoint(x: p.x + k * CGFloat(sx), y: p.y))
                    corners.addLine(to: p)
                    corners.addLine(to: CGPoint(x: p.x, y: p.y + k * CGFloat(sy)))
                }
                ctx.stroke(corners, with: .color(.white), lineWidth: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if start == nil {
                            start = crop
                            handle = hit(v.startLocation, r)
                            Haptics.tick()
                        }
                        guard let s = start, let h = handle else { return }
                        onChange(CropMath.drag(h, dx: v.translation.width / max(W, 1), dy: v.translation.height / max(H, 1), from: s, rel: rel))
                    }
                    .onEnded { _ in start = nil; handle = nil; onEnd() }
            )
        }
    }

    private func hit(_ p: CGPoint, _ r: CGRect) -> CropHandle {
        let reach: CGFloat = 34
        func near(_ a: CGPoint) -> Bool { hypot(p.x - a.x, p.y - a.y) < reach }
        if near(CGPoint(x: r.minX, y: r.minY)) { return .tl }
        if near(CGPoint(x: r.maxX, y: r.minY)) { return .tr }
        if near(CGPoint(x: r.minX, y: r.maxY)) { return .bl }
        if near(CGPoint(x: r.maxX, y: r.maxY)) { return .br }
        let inX = p.x > r.minX - reach && p.x < r.maxX + reach, inY = p.y > r.minY - reach && p.y < r.maxY + reach
        if inX && abs(p.y - r.minY) < reach * 0.7 { return .t }
        if inX && abs(p.y - r.maxY) < reach * 0.7 { return .b }
        if inY && abs(p.x - r.minX) < reach * 0.7 { return .l }
        if inY && abs(p.x - r.maxX) < reach * 0.7 { return .r }
        return .move
    }
}

struct CropPanel: View {
    @ObservedObject var m: EditorModel

    private let aspects: [(String, CGFloat?)] = [("Free", nil), ("Original", -1), ("Square", 1), ("3:2", 1.5), ("2:3", 2.0 / 3), ("4:5", 0.8), ("5:4", 1.25), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(aspects.indices, id: \.self) { i in
                        let a = aspects[i]
                        let on = isOn(a.1)
                        Button {
                            pick(a.1)
                        } label: {
                            Text(a.0.uppercased()).font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.1)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(on ? Color.white : Color.white.opacity(0.08), in: Capsule())
                                .foregroundStyle(on ? Color.black : Color.white)
                        }
                        .buttonStyle(Pressable())
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack(spacing: 28) {
                Button { m.rotate() } label: { Label("Rotate", systemImage: "rotate.right") }
                Button { m.resetCrop(); Haptics.tick() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .disabled(!m.recipe.cropActive && m.recipe.rotation == 0)
            }
            .font(.custom("Helvetica Neue", size: 13).weight(.medium))
            .foregroundStyle(.white)
        }
        .padding(.vertical, 12)
    }

    private var originalAspect: CGFloat { m.recipe.rotation % 180 == 0 ? m.sourceAspect : 1 / m.sourceAspect }

    private func isOn(_ a: CGFloat?) -> Bool {
        guard let a else { return m.cropAspect == nil }
        guard let cur = m.cropAspect else { return false }
        return abs((a < 0 ? originalAspect : a) - cur) < 0.001
    }

    private func pick(_ a: CGFloat?) {
        Haptics.tick()
        guard let a else { m.cropAspect = nil; return }
        let target = a < 0 ? originalAspect : a
        m.cropAspect = target
        m.snapCrop(to: target)
        m.commit()
    }
}

// MARK: - Looks

struct LooksPanel: View {
    @ObservedObject var m: EditorModel
    @State private var section = 0
    @State private var group = "All"

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $section) {
                Text("Looks").tag(0)
                Text("Leaks").tag(1)
                Text("Borders").tag(2)
                Text("Date").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            switch section {
            case 0: lutSection
            case 1: overlaySection(kind: "leaks", key: "light_leak", items: m.leaks)
            case 2: overlaySection(kind: "borders", key: "film_border", items: m.borders)
            default: dateSection
            }
        }
        .padding(.top, 8)
    }

    // LUTs

    private var groups: [String] {
        var seen: [String] = []
        for l in m.luts {
            let top = (l.folder ?? "").split(separator: "/").first.map(String.init) ?? ""
            if !top.isEmpty && !seen.contains(top) { seen.append(top) }
        }
        return ["All", "★"] + seen
    }

    private var shown: [LutInfo] {
        switch group {
        case "All": return m.luts
        case "★": return m.luts.filter { m.favorites.contains($0.name) }
        default: return m.luts.filter { ($0.folder ?? "").hasPrefix(group) }
        }
    }

    @ViewBuilder private var lutSection: some View {
        if m.recipe.lutName != nil {
            MiniRuler(label: "Amount", spec: SliderSpec(key: "_lut", label: "Amount", icon: "", min: 0, max: 1, dp: 2), value: m.recipe.lutAmount,
                      onChange: { v in m.recipe.lutAmount = v; m.commit(history: false) }, onEnd: { m.endGesture() })
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groups, id: \.self) { g in
                    Button { group = g } label: {
                        Text(g.uppercased()).font(.custom("Helvetica Neue", size: 10).weight(.bold)).tracking(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(group == g ? Color.white : Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(group == g ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    Thumb(title: "None", request: nil, selected: m.recipe.lutName == nil) {
                        m.recipe.lutName = nil; m.commit(); Haptics.tick()
                    }
                    ForEach(shown) { l in
                        Thumb(title: l.label, request: m.api.lutSwatch(m.item.id, lut: l.name), selected: m.recipe.lutName == l.name,
                              star: m.favorites.contains(l.name)) {
                            if m.recipe.lutName == l.name { return }
                            m.recipe.lutName = l.name
                            if m.recipe.lutAmount <= 0 { m.recipe.lutAmount = 1 }
                            m.commit()
                            Haptics.tick()
                        }
                        .id(l.name)
                        .contextMenu {
                            Button { Task { await m.toggleFavorite(l.name) } } label: {
                                Label(m.favorites.contains(l.name) ? "Remove from favourites" : "Add to favourites", systemImage: "star")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 96)
            .onAppear { if let n = m.recipe.lutName { proxy.scrollTo(n, anchor: .center) } }
        }
    }

    // Leaks / borders

    @ViewBuilder private func overlaySection(kind: String, key: String, items: [OverlayInfo]) -> some View {
        if kind == "leaks" && m.recipe.string("light_leak") != nil, let spec = SliderSpec.all["light_leak_amount"] {
            MiniRuler(label: "Amount", spec: spec, value: m.recipe.num("light_leak_amount"),
                      onChange: { m.set("light_leak_amount", $0) }, onEnd: { m.endGesture() })
        }
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                Thumb(title: "None", request: nil, selected: m.recipe.string(key) == nil) {
                    m.recipe.setString(key, nil); m.commit(); Haptics.tick()
                }
                ForEach(items) { it in
                    Thumb(title: it.label, request: m.api.overlayImage(kind, it.name), selected: m.recipe.string(key) == it.name) {
                        m.recipe.setString(key, it.name); m.commit(); Haptics.tick()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 96)
        if items.isEmpty { Theme.meta("None on the server.") }
    }

    private var dateSection: some View {
        VStack(spacing: 12) {
            Toggle(isOn: Binding(get: { m.recipe.bool("date_stamp") }, set: { m.recipe.setBool("date_stamp", $0); m.commit() })) {
                Text("DATE STAMP").font(.custom("Helvetica Neue", size: 11).weight(.bold)).tracking(1.2)
            }
            .tint(Theme.red)
            TextField("Text (empty = date from the camera)", text: Binding(
                get: { m.recipe.string("date_stamp_text") ?? "" },
                set: { v in
                    let t = String(v.prefix(24))
                    m.recipe.setString("date_stamp_text", t.isEmpty ? nil : t)
                    m.commit(history: false)
                }))
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit { m.endGesture() }
                .disabled(!m.recipe.bool("date_stamp"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// One swatch in a horizontal strip.
struct Thumb: View {
    let title: String
    let request: URLRequest?
    let selected: Bool
    var star = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if let request { RemoteImage(request: request) } else {
                        Color.white.opacity(0.08)
                        Image(systemName: "circle.slash").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Theme.red : Color.clear, lineWidth: 2.5))
                .overlay(alignment: .topTrailing) {
                    if star { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.red).padding(4) }
                }
                Text(title).font(.custom("Helvetica Neue", size: 10)).lineLimit(1).frame(width: 66)
                    .foregroundStyle(selected ? Theme.red : .white)
            }
        }
        .buttonStyle(Pressable())
    }
}

// MARK: - Histogram

struct HistogramView: View {
    let h: Histogram

    var body: some View {
        Canvas { ctx, size in
            let peak = max(1, ([h.r, h.g, h.b, h.luma].flatMap { $0 }.max() ?? 1))
            func area(_ a: [Double], _ c: Color) {
                guard a.count > 1 else { return }
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in a.enumerated() {
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(a.count - 1), y: size.height * (1 - CGFloat(v / peak))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(c))
            }
            area(h.r, Color.red.opacity(0.5))
            area(h.g, Color.green.opacity(0.5))
            area(h.b, Color.blue.opacity(0.5))
            area(h.luma, Color.white.opacity(0.4))
        }
        .frame(width: 140, height: 64)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
