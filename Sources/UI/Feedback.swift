import SwiftUI
import UIKit

/// Haptics with one switch (Settings › Review › Haptics).
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let select = UISelectionFeedbackGenerator()
    private static let note = UINotificationFeedbackGenerator()

    static var on: Bool { UserDefaults.standard.object(forKey: "reviewHaptics") as? Bool ?? true }

    static func prepare() { guard on else { return }; medium.prepare(); select.prepare() }
    static func tick() { guard on else { return }; select.selectionChanged() }
    static func arm() { guard on else { return }; medium.impactOccurred(intensity: 0.8) }
    static func disarm() { guard on else { return }; light.impactOccurred(intensity: 0.5) }
    static func keep() { guard on else { return }; rigid.impactOccurred() }
    static func reject() { guard on else { return }; soft.impactOccurred(intensity: 1) }
    static func skip() { guard on else { return }; light.impactOccurred(intensity: 0.6) }
    static func lift() { guard on else { return }; medium.impactOccurred() }
    static func success() { guard on else { return }; note.notificationOccurred(.success) }
    static func warn() { guard on else { return }; note.notificationOccurred(.warning) }
}

/// Black-on-white (white-on-black in dark mode) caption that fades after a moment.
struct ToastModifier: ViewModifier {
    @Binding var text: String?
    var bottom: CGFloat = 20

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text.uppercased())
                    .font(.custom("Helvetica Neue", size: 11).weight(.medium)).tracking(1.2)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.primary).foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.bottom, bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation(.easeOut(duration: 0.2)) { if self.text == text { self.text = nil } }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: text)
    }
}

extension View {
    func toast(_ text: Binding<String?>, bottom: CGFloat = 20) -> some View { modifier(ToastModifier(text: text, bottom: bottom)) }
}

// MARK: - Particle burst (Core Animation emitter: red stars + ink squares)

enum BurstKind { case keep, reject, skip, file }

struct BurstToken: Equatable {
    var n = 0
    var kind: BurstKind = .keep
    var strength = 1
    var at: CGPoint = .zero      // in the burst view's own coordinates
}

struct BurstView: UIViewRepresentable {
    let token: BurstToken

    func makeUIView(context: Context) -> BurstHost { BurstHost() }
    func updateUIView(_ v: BurstHost, context: Context) {
        guard token.n != v.lastN else { return }
        v.lastN = token.n
        guard token.n > 0, UserDefaults.standard.object(forKey: "reviewEffects") as? Bool ?? true else { return }
        v.fire(token)
    }
}

final class BurstHost: UIView {
    var lastN = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let red = UIColor(red: 0xE4 / 255, green: 0, blue: 0x2B / 255, alpha: 1)

    private static let star: CGImage? = {
        let size: CGFloat = 32
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            let p = UIBezierPath()
            let c = CGPoint(x: size / 2, y: size / 2), outer = size / 2, inner = outer * 0.46
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let rad: CGFloat = i % 2 == 0 ? outer : inner
                let pt = CGPoint(x: c.x + rad * CoreGraphics.cos(a), y: c.y + rad * CoreGraphics.sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.close()
            UIColor.white.setFill()
            p.fill()
        }.cgImage
    }()

    private static let square: CGImage? = {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.cgImage
    }()

    func fire(_ t: BurstToken) {
        let e = CAEmitterLayer()
        e.frame = bounds
        e.emitterPosition = t.at == .zero ? CGPoint(x: bounds.midX, y: bounds.midY * 0.9) : t.at
        e.emitterShape = .point
        e.renderMode = .unordered
        let ink = traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black

        func cell(_ img: CGImage?, _ color: UIColor, rate: Float, v: CGFloat, range: CGFloat, lon: CGFloat, scale: CGFloat, life: Float, g: CGFloat) -> CAEmitterCell {
            let c = CAEmitterCell()
            c.contents = img
            c.color = color.cgColor
            c.birthRate = rate
            c.lifetime = life
            c.lifetimeRange = life * 0.35
            c.velocity = v
            c.velocityRange = v * 0.45
            c.emissionLongitude = lon
            c.emissionRange = range
            c.yAcceleration = g
            c.spin = 3
            c.spinRange = 10
            c.scale = scale
            c.scaleRange = scale * 0.5
            c.alphaSpeed = -1 / life
            return c
        }
        let k = Float(max(1, t.strength))
        switch t.kind {
        case .keep:
            e.emitterCells = [
                cell(Self.star, Self.red, rate: 260 + 50 * k, v: 420, range: .pi * 0.45, lon: -.pi / 2, scale: 0.36, life: 1.2, g: 900),
                cell(Self.square, ink, rate: 90 + 20 * k, v: 380, range: .pi * 0.5, lon: -.pi / 2, scale: 0.45, life: 1.1, g: 900),
                cell(Self.square, .systemGray, rate: 60, v: 320, range: .pi * 0.5, lon: -.pi / 2, scale: 0.4, life: 1.0, g: 900),
            ]
        case .file:
            e.emitterCells = [cell(Self.star, Self.red, rate: 220, v: 260, range: .pi * 2, lon: 0, scale: 0.3, life: 0.8, g: 500)]
        case .reject:
            e.emitterCells = [cell(Self.square, Self.red, rate: 160, v: 260, range: .pi * 2, lon: 0, scale: 0.42, life: 0.6, g: 760)]
        case .skip:
            e.emitterCells = [cell(Self.square, .systemGray, rate: 110, v: 200, range: .pi * 0.25, lon: -.pi / 2, scale: 0.36, life: 0.8, g: 240)]
        }
        e.beginTime = CACurrentMediaTime()
        layer.addSublayer(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { e.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { e.removeFromSuperlayer() }
    }
}
