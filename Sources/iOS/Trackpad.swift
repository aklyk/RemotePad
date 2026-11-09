import SwiftUI
import UIKit
#if canImport(RemotePadCore)
import RemotePadCore
#endif

struct Trackpad: UIViewRepresentable {
    var sensitivity: Double
    var naturalScrolling: Bool
    var haptics: Bool
    @Binding var dragging: Bool
    var send: (MouseCommand) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        let move = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.move(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        coordinator.moveRecognizer = move
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        coordinator.scrollRecognizer = scroll
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        coordinator.pinchRecognizer = pinch
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 14
        coordinator.holdRecognizer = hold
        let spaces = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.threeFingerSwipe(_:)))
        spaces.minimumNumberOfTouches = 3
        spaces.maximumNumberOfTouches = 3
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        tap.require(toFail: hold)
        let right = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.rightTap(_:)))
        right.numberOfTouchesRequired = 2
        let reset = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.resetZoom(_:)))
        reset.numberOfTouchesRequired = 2
        reset.numberOfTapsRequired = 2
        right.require(toFail: reset)
        tap.require(toFail: right)
        for recognizer in [move, scroll, pinch, hold, spaces, tap, double, right, reset] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Mac trackpad"
        view.accessibilityHint = "Move with one finger, scroll with two, pinch to zoom, hold to drag, or swipe with three fingers to navigate spaces."
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Left click", target: coordinator, selector: #selector(Coordinator.accessibleClick)),
            UIAccessibilityCustomAction(name: "Right click", target: coordinator, selector: #selector(Coordinator.accessibleRightClick))
        ]
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.endHold() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: Trackpad
        weak var moveRecognizer: UIPanGestureRecognizer?
        weak var scrollRecognizer: UIPanGestureRecognizer?
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        weak var holdRecognizer: UILongPressGestureRecognizer?
        private var ownsDrag = false
        private var pinchConsumed = false
        private var lastPinchScale = 1.0
        private var zoom = ZoomAccumulator()
        private let feedback = UISelectionFeedbackGenerator()

        init(_ parent: Trackpad) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair = [gestureRecognizer, other]
            return (pair.contains { $0 === holdRecognizer } && pair.contains { $0 === moveRecognizer }) ||
                   (pair.contains { $0 === pinchRecognizer } && pair.contains { $0 === scrollRecognizer })
        }
        @objc func move(_ gesture: UIPanGestureRecognizer) {
            defer { gesture.setTranslation(.zero, in: gesture.view) }
            guard gesture.state == .changed else { return }
            let delta = gesture.translation(in: gesture.view)
            parent.send(MouseCommand(.move, x: bounded(Double(delta.x) * parent.sensitivity), y: bounded(Double(delta.y) * parent.sensitivity)))
        }
        @objc func scroll(_ gesture: UIPanGestureRecognizer) {
            defer { gesture.setTranslation(.zero, in: gesture.view) }
            if gesture.state == .began {
                pinchConsumed = pinchRecognizer?.state == .began || pinchRecognizer?.state == .changed
            }
            guard gesture.state == .changed, !parent.dragging, !pinchConsumed,
                  pinchRecognizer?.state != .began, pinchRecognizer?.state != .changed else { return }
            let delta = gesture.translation(in: gesture.view)
            let direction = parent.naturalScrolling ? 2.0 : -2.0
            parent.send(MouseCommand(.scroll, x: bounded(Double(delta.x) * direction), y: bounded(Double(delta.y) * direction)))
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard !parent.dragging else { return }
            if gesture.state == .began {
                pinchConsumed = true
                lastPinchScale = 1
                zoom = ZoomAccumulator()
            }
            guard gesture.state == .began || gesture.state == .changed else { return }
            let scale = Double(gesture.scale)
            let steps = zoom.consume(scale / lastPinchScale)
            lastPinchScale = scale
            for _ in 0..<abs(steps) { parent.send(MouseCommand(steps > 0 ? .zoomIn : .zoomOut)) }
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard !parent.dragging else { return }
                ownsDrag = true
                parent.dragging = true
                parent.send(MouseCommand(.dragStart))
                tick()
            case .ended, .cancelled, .failed: endHold()
            default: break
            }
        }
        func endHold() {
            guard ownsDrag else { return }
            ownsDrag = false
            parent.send(MouseCommand(.dragEnd))
            parent.dragging = false
            tick()
        }
        @objc func threeFingerSwipe(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, !parent.dragging else { return }
            let delta = gesture.translation(in: gesture.view)
            guard let action = TrackpadNavigation.action(x: Double(delta.x), y: Double(delta.y)) else { return }
            parent.send(MouseCommand(action))
            tick()
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) { if !parent.dragging { parent.send(MouseCommand(.leftClick)) } }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) { if !parent.dragging { parent.send(MouseCommand(.doubleClick)) } }
        @objc func rightTap(_ gesture: UITapGestureRecognizer) { if !parent.dragging { parent.send(MouseCommand(.rightClick)) } }
        @objc func resetZoom(_ gesture: UITapGestureRecognizer) {
            if !parent.dragging { parent.send(MouseCommand(.resetZoom)); tick() }
        }
        @objc func accessibleClick() -> Bool { parent.send(MouseCommand(.leftClick)); return true }
        @objc func accessibleRightClick() -> Bool { parent.send(MouseCommand(.rightClick)); return true }
        private func tick() { if parent.haptics { feedback.selectionChanged() } }
        private func bounded(_ value: Double) -> Double { min(max(value, -2000), 2000) }
    }
}
