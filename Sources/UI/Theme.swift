import SwiftUI

/// The white cube: Helvetica, uppercase tracking on labels, hairlines, one red.
enum Theme {
    static let red = Color(red: 0xE4 / 255, green: 0x00 / 255, blue: 0x2B / 255)
    static let hair = Color.primary.opacity(0.12)
    static let soft = Color.secondary

    static func label(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.custom("Helvetica Neue", size: 11).weight(.bold))
            .tracking(1.6)
    }
    static func meta(_ s: String) -> some View {
        Text(s)
            .font(.custom("Helvetica Neue", size: 12))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct Star: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2, inner = outer * 0.46
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
            let rad: CGFloat = i % 2 == 0 ? outer : inner
            let pt = CGPoint(x: c.x + rad * CoreGraphics.cos(a), y: c.y + rad * CoreGraphics.sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hair).frame(height: 1) }
}

struct TextButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.custom("Helvetica Neue", size: 12).weight(primary ? .bold : .medium))
                .tracking(1.2)
                .padding(.vertical, 12).padding(.horizontal, 16)
                .frame(maxWidth: primary ? .infinity : nil)
                .foregroundStyle(primary ? Color.white : Theme.red)
                .background(primary ? Theme.red : Color.clear)
                .overlay(Rectangle().stroke(primary ? Color.clear : Theme.red, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
