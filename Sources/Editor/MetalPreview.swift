import SwiftUI
import MetalKit
import UIKit

/// Flat parameter block for Preview.metal — indices must match the #defines there.
enum PreviewParams {
    static let exposure = 0, brightness = 1, contrast = 2, temp = 3, tint = 4
    static let highlights = 5, shadows = 6, whites = 7, blacks = 8
    static let saturation = 9, vibrance = 10, dehaze = 11, matte = 12, bw = 13
    static let splitBalance = 14, vigAmount = 15, vigFeather = 16, vigMid = 17, vigRound = 18
    static let srcAspect = 19, lutAmount = 20, lutN = 21
    static let useCurve = 22, useLut = 23, useHsl = 24, useMixer = 25, rotation = 26, original = 27
    static let splitSh = 28, splitHi = 31, crop = 34, hsl = 38, mixer = 62
    static let count = 72

    /// Recipe → shader inputs. `fullFrame` drops the crop (the crop tool shows the whole photo).
    static func make(_ r: Recipe, aspect: Float, lutSize: Int, showOriginal: Bool, fullFrame: Bool) -> (params: [Float], curve: [Float]) {
        var p = [Float](repeating: 0, count: count)
        func f(_ k: String) -> Float { Float(r.num(k)) }
        p[exposure] = f("exposure"); p[brightness] = f("brightness"); p[contrast] = f("contrast")
        p[temp] = (f("wb_temp") - 5500) / 5500; p[tint] = f("wb_tint")
        p[highlights] = f("highlights"); p[shadows] = f("shadows"); p[whites] = f("whites"); p[blacks] = f("blacks")
        p[saturation] = f("saturation"); p[vibrance] = f("vibrance"); p[dehaze] = f("dehaze")
        p[matte] = f("matte"); p[bw] = f("bw_amount")
        p[splitBalance] = f("split_balance")
        p[vigAmount] = f("vignette_amount"); p[vigFeather] = f("vignette_feather"); p[vigMid] = f("vignette_midpoint"); p[vigRound] = f("vignette_roundness")
        p[srcAspect] = aspect
        p[lutAmount] = Float(r.lutAmount)
        p[lutN] = Float(lutSize)
        p[useLut] = r.lutName != nil && lutSize > 1 && r.lutAmount > 0.001 ? 1 : 0
        p[rotation] = Float(r.rotation)
        p[original] = showOriginal ? 1 : 0

        let sh = Hex.rgb(r.string("split_shadow_hex")), shs = r.num("split_shadow_sat")
        let hi = Hex.rgb(r.string("split_highlight_hex")), his = r.num("split_highlight_sat")
        if shs > 0 { p[splitSh] = Float((sh.0 - 0.5) * shs); p[splitSh + 1] = Float((sh.1 - 0.5) * shs); p[splitSh + 2] = Float((sh.2 - 0.5) * shs) }
        if his > 0 { p[splitHi] = Float((hi.0 - 0.5) * his); p[splitHi + 1] = Float((hi.1 - 0.5) * his); p[splitHi + 2] = Float((hi.2 - 0.5) * his) }

        let c = fullFrame || showOriginal ? CGRect(x: 0, y: 0, width: 1, height: 1) : r.crop
        p[crop] = Float(c.minX); p[crop + 1] = Float(c.minY); p[crop + 2] = Float(c.width); p[crop + 3] = Float(c.height)
        if showOriginal { p[rotation] = 0 }

        let hslV = r.nums("hsl")
        if hslV.contains(where: { abs($0) > 1e-4 }) {
            p[useHsl] = 1
            for (i, v) in hslV.prefix(24).enumerated() { p[hsl + i] = Float(v) }
        }
        let mix = r.nums("bw_mixer")
        if mix.contains(where: { abs($0) > 1e-4 }) {
            p[useMixer] = 1
            for (i, v) in mix.prefix(8).enumerated() { p[mixer + i] = Float(v) }
        }

        // Tone curve → 256 entries, linear between the five anchors (np.interp).
        var curve = (0..<256).map { Float($0) / 255 }
        let ys = r.nums("tone_curve").map { min(1, max(0, $0)) }
        if ys.count == 5, zip(ys, Recipe.identityCurve).contains(where: { abs($0 - $1) >= 1e-4 }) {
            p[useCurve] = 1
            let xs = Recipe.identityCurve
            curve = (0..<256).map { i in
                let t = Double(i) / 255
                var s = 0
                while s < 3 && t > xs[s + 1] { s += 1 }
                let a = (t - xs[s]) / (xs[s + 1] - xs[s])
                return Float(ys[s] * (1 - a) + ys[s + 1] * a)
            }
        }
        return (p, curve)
    }
}

/// Owns the GPU objects; draws on demand.
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var image: MTLTexture?
    private var lut: MTLTexture
    private(set) var lutN = 0
    private(set) var lutName: String?
    var params = [Float](repeating: 0, count: PreviewParams.count)
    var curve = (0..<256).map { Float($0) / 255 }
    var hasImage: Bool { image != nil }

    /// Nil when Metal or the compiled shader is missing — the editor then shows server renders only.
    static func make() -> PreviewRenderer? {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let lib = d.makeDefaultLibrary(),
              let vf = lib.makeFunction(name: "p3k_vertex"), let ff = lib.makeFunction(name: "p3k_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? d.makeRenderPipelineState(descriptor: desc), let dummy = Self.volume(d, n: 2, bytes: [UInt8](repeating: 255, count: 32)) else { return nil }
        return PreviewRenderer(device: d, queue: q, pipeline: p, lut: dummy)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState, lut: MTLTexture) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.lut = lut
    }

    /// The RAW preview as raw sRGB-encoded bytes (the shader does its own colour math).
    func setImage(_ ui: UIImage) -> Bool {
        guard let rgba = RGBA(ui) else { return false }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: rgba.w, height: rgba.h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return false }
        rgba.bytes.withUnsafeBytes { buf in
            t.replace(region: MTLRegionMake2D(0, 0, rgba.w, rgba.h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: rgba.w * 4)
        }
        image = t
        return true
    }

    /// A HaldCLUT PNG (n² × n² … n³ pixels) as an n×n×n volume. Raster order is the
    /// volume order (index = b·n² + g·n + r), so the bytes copy straight in.
    func setLut(name: String?, png: UIImage?) {
        guard let name, let png, let rgba = RGBA(png) else { lutName = nil; lutN = 0; return }
        let total = rgba.w * rgba.h
        let n = Int(round(cbrt(Double(total))))
        guard n > 1, n * n * n == total, let v = Self.volume(device, n: n, bytes: rgba.bytes) else { lutName = nil; lutN = 0; return }
        lut = v
        lutN = n
        lutName = name
    }

    private static func volume(_ d: MTLDevice, n: Int, bytes: [UInt8]) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba8Unorm
        desc.width = n; desc.height = n; desc.depth = n
        desc.usage = .shaderRead
        guard let t = d.makeTexture(descriptor: desc), bytes.count >= n * n * n * 4 else { return nil }
        bytes.withUnsafeBytes { buf in
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                      withBytes: buf.baseAddress!, bytesPerRow: n * 4, bytesPerImage: n * n * 4)
        }
        return t
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        guard let image, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(image, index: 0)
        enc.setFragmentTexture(lut, index: 1)
        params.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        curve.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

/// Decoded 8-bit RGBA in sRGB, orientation applied.
struct RGBA {
    let w: Int
    let h: Int
    let bytes: [UInt8]

    init?(_ ui: UIImage) {
        let size = ui.size
        let scale = ui.scale
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            // UIKit drawing honours imageOrientation; flip the CG context to UIKit's top-left origin.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            ui.draw(in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            UIGraphicsPopContext()
            return true
        }
        guard ok else { return nil }
        self.w = w
        self.h = h
        self.bytes = bytes
    }
}

/// SwiftUI host for the renderer. Redraws when `params`/`curve` change.
struct MetalPreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer
    let params: [Float]
    let curve: [Float]

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.isOpaque = false
        v.backgroundColor = .clear
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.delegate = renderer
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        renderer.params = params
        renderer.curve = curve
        v.setNeedsDisplay()
    }
}
