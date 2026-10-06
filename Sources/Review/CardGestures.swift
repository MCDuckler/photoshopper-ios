import SwiftUI
import UIKit

/// The deck card's touch surface. UIKit recognizers instead of SwiftUI gestures
/// because the three interactions must hand off cleanly:
///  - pan (moves at once) swipes the card,
///  - press-and-hold without moving lifts it for filing, then tracks the finger,
///  - pinch / double-tap zoom, and while zoomed a pan moves the photo instead.
struct CardGestures: UIViewRepresentable {
    var zoomed: Bool
    var onPan: (CGSize) -> Void = { _ in }
    var onPanEnd: (CGSize, CGSize) -> Void = { _, _ in }      // translation, velocity
    var onHold: (CGPoint) -> Void = { _ in }                  // window coordinates
    var onHoldMove: (CGPoint) -> Void = { _ in }
    var onHoldEnd: (CGPoint, Bool) -> Void = { _, _ in }      // point, cancelled
    var onPinch: (CGFloat, Bool) -> Void = { _, _ in }        // scale since start, ended
    var onDoubleTap: (CGPoint) -> Void = { _ in }              // in the card's coordinates

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = c

        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.32
        hold.allowableMovement = 12
        hold.delegate = c

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = c

        let dbl = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        dbl.delegate = c

        [pan, hold, pinch, dbl].forEach(v.addGestureRecognizer)
        c.panR = pan
        c.holdR = hold
        c.pinchR = pinch
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CardGestures
        weak var panR: UIPanGestureRecognizer?
        weak var holdR: UILongPressGestureRecognizer?
        weak var pinchR: UIPinchGestureRecognizer?

        init(_ p: CardGestures) { parent = p }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view), v = g.velocity(in: g.view)
            switch g.state {
            case .changed: parent.onPan(CGSize(width: t.x, height: t.y))
            case .ended, .cancelled, .failed: parent.onPanEnd(CGSize(width: t.x, height: t.y), CGSize(width: v.x, height: v.y))
            default: break
            }
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: nil)
            switch g.state {
            case .began: parent.onHold(p)
            case .changed: parent.onHoldMove(p)
            case .ended: parent.onHoldEnd(p, false)
            case .cancelled, .failed: parent.onHoldEnd(p, true)
            default: break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began, .changed: parent.onPinch(g.scale, false)
            case .ended, .cancelled, .failed: parent.onPinch(g.scale, true)
            default: break
            }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            parent.onDoubleTap(g.location(in: g.view))
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g === holdR { return !parent.zoomed }
            return true
        }

        // Pinch and pan run together (zoom while panning the photo).
        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            let pair: Set<ObjectIdentifier> = [ObjectIdentifier(a), ObjectIdentifier(b)]
            if let p = pinchR, let q = panR, pair == [ObjectIdentifier(p), ObjectIdentifier(q)] { return true }
            return false
        }
    }
}
