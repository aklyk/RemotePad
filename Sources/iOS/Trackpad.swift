import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
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
        let twoFinger = TwoFingerGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFinger(_:)))
        twoFinger.naturalScrolling = naturalScrolling
        coordinator.twoFingerRecognizer = twoFinger
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 14
        coordinator.holdRecognizer = hold
        let spaces = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.threeFingerSwipe(_:)))
        spaces.minimumNumberOfTouches = 3
        spaces.maximumNumberOfTouches = 3
        coordinator.spacesRecognizer = spaces
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
        for recognizer: UIGestureRecognizer in [move, twoFinger, hold, spaces, tap, double, right, reset] {
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
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.twoFingerRecognizer?.naturalScrolling = naturalScrolling
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.endHold() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: Trackpad
        weak var moveRecognizer: UIPanGestureRecognizer?
        weak var twoFingerRecognizer: TwoFingerGestureRecognizer?
        weak var holdRecognizer: UILongPressGestureRecognizer?
        weak var spacesRecognizer: UIPanGestureRecognizer?
        private var navigationStroke = NavigationStroke()
        private var isNavigating: Bool {
            spacesRecognizer?.state == .began || spacesRecognizer?.state == .changed
        }
        private var ownsDrag = false
        private let feedback = UISelectionFeedbackGenerator()

        init(_ parent: Trackpad) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair = [gestureRecognizer, other]
            // A second finger may have started scrolling before the third lands.
            // Let navigation recognize, then suppress lower-finger actions below.
            if pair.contains(where: { $0 === spacesRecognizer }) { return true }
            return pair.contains { $0 === moveRecognizer } &&
                   pair.contains { $0 === holdRecognizer || $0 === twoFingerRecognizer }
        }
        @objc func move(_ gesture: UIPanGestureRecognizer) {
            defer { gesture.setTranslation(.zero, in: gesture.view) }
            guard gesture.state == .began || gesture.state == .changed,
                  gesture.numberOfTouches == 1, !isNavigating else { return }
            let delta = gesture.translation(in: gesture.view)
            guard delta != .zero else { return }
            parent.send(MouseCommand(.move, x: bounded(Double(delta.x) * parent.sensitivity), y: bounded(Double(delta.y) * parent.sensitivity)))
        }
        @objc func twoFinger(_ gesture: TwoFingerGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed,
                  !parent.dragging, !isNavigating else { return }
            gesture.commands.forEach(parent.send)
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
            if gesture.state == .began {
                navigationStroke = NavigationStroke()
                endHold()
            }
            guard gesture.state == .began || gesture.state == .changed,
                  gesture.numberOfTouches == 3, !parent.dragging else { return }
            let delta = gesture.translation(in: gesture.view)
            guard let action = navigationStroke.consume(x: Double(delta.x), y: Double(delta.y)) else { return }
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

final class TwoFingerGestureRecognizer: UIGestureRecognizer {
    var naturalScrolling = true
    private(set) var commands: [MouseCommand] = []
    private var activeTouches: Set<UITouch> = []
    private var motion: TwoFingerMotion?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        activeTouches.formUnion(touches)
        if activeTouches.count > 2 {
            state = state == .possible ? .failed : .cancelled
        } else if let (center, span) = measurement {
            motion = TwoFingerMotion(center: center, span: span)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let (center, span) = measurement, var motion else { return }
        commands = motion.consume(center: center, span: span, naturalScrolling: naturalScrolling)
        self.motion = motion
        if motion.mode != .undecided { state = state == .possible ? .began : .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        activeTouches.subtract(touches)
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll()
        commands.removeAll()
        motion = nil
    }

    private var measurement: (CGPoint, Double)? {
        guard activeTouches.count == 2, let view else { return nil }
        let locations = activeTouches.map { $0.location(in: view) }
        let first = locations[0], second = locations[1]
        let center = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        return (center, hypot(Double(first.x - second.x), Double(first.y - second.y)))
    }
}
