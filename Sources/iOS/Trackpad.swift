import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
#if canImport(RemotePadCore)
import RemotePadCore
#endif

struct Trackpad: UIViewRepresentable {
    var sensitivity: Double
    var accelerationEnabled: Bool
    var naturalScrolling: Bool
    var pinchZoom: Bool
    var smartZoom: Bool
    var pageSwipes: Bool
    var threeFingerDrag: Bool
    var enhancedGestures: Bool
    var haptics: Bool
    @Binding var dragging: Bool
    var send: (MouseCommand) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TrackpadSurface()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        let move = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.move(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        coordinator.moveRecognizer = move
        let multi = MultiFingerGestureRecognizer(target: coordinator, action: #selector(Coordinator.multiFinger(_:)))
        multi.onFirstTouch = { [weak coordinator] in
            guard let coordinator, coordinator.parent.enhancedGestures else { return }
            coordinator.parent.send(MouseCommand(.stopScroll))
        }
        coordinator.multiRecognizer = multi
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 14
        coordinator.holdRecognizer = hold
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        tap.require(toFail: hold)
        let right = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.rightTap(_:)))
        right.numberOfTouchesRequired = 2
        let smartZoomTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.smartZoom(_:)))
        smartZoomTap.numberOfTouchesRequired = 2
        smartZoomTap.numberOfTapsRequired = 2
        smartZoomTap.isEnabled = smartZoom
        coordinator.smartZoomRecognizer = smartZoomTap
        right.require(toFail: smartZoomTap)
        tap.require(toFail: right)
        let lookUp = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.lookUp(_:)))
        lookUp.numberOfTouchesRequired = 3
        for recognizer: UIGestureRecognizer in [move, multi, hold, tap, double, right, smartZoomTap, lookUp] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Mac trackpad"
        view.accessibilityHint = "Slide one finger to move, two to scroll, or three or four to navigate."
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Left click", target: coordinator, selector: #selector(Coordinator.accessibleClick)),
            UIAccessibilityCustomAction(name: "Right click", target: coordinator, selector: #selector(Coordinator.accessibleRightClick))
        ]
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.multiRecognizer?.naturalScrolling = naturalScrolling
        coordinator.multiRecognizer?.pinchZoom = pinchZoom
        coordinator.multiRecognizer?.pageSwipes = pageSwipes
        coordinator.multiRecognizer?.threeFingerDrag = threeFingerDrag
        if let recognizer = coordinator.smartZoomRecognizer, recognizer.isEnabled != smartZoom {
            recognizer.isEnabled = smartZoom
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.finishInput() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: Trackpad
        weak var moveRecognizer: UIPanGestureRecognizer?
        weak var multiRecognizer: MultiFingerGestureRecognizer?
        weak var holdRecognizer: UILongPressGestureRecognizer?
        weak var smartZoomRecognizer: UITapGestureRecognizer?
        private enum DragSource { case hold, multiFinger }
        private var dragSource: DragSource?
        private var acceleration = PointerAcceleration()
        private var lastPointerTime: TimeInterval?
        private var fallbackZoom = ZoomAccumulator()
        private let feedback = UISelectionFeedbackGenerator()

        init(_ parent: Trackpad) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair = [gestureRecognizer, other]
            return pair.contains { $0 === moveRecognizer } &&
                   pair.contains { $0 === holdRecognizer || $0 === multiRecognizer }
        }

        @objc func move(_ gesture: UIPanGestureRecognizer) {
            defer { gesture.setTranslation(.zero, in: gesture.view) }
            guard gesture.state == .began || gesture.state == .changed,
                  gesture.numberOfTouches == 1, (multiRecognizer?.touchCount ?? 0) < 2 else { return }
            if gesture.state == .began {
                acceleration = PointerAcceleration()
                lastPointerTime = nil
            }
            movePointer(gesture.translation(in: gesture.view))
        }

        private func movePointer(_ delta: CGPoint) {
            guard delta != .zero else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = lastPointerTime.map { now - $0 } ?? (1.0 / 60)
            lastPointerTime = now
            let corrected = parent.accelerationEnabled ? acceleration.apply(to: delta, elapsed: elapsed) : delta
            let x = min(max(Double(corrected.x) * parent.sensitivity, -2000), 2000)
            let y = min(max(Double(corrected.y) * parent.sensitivity, -2000), 2000)
            parent.send(MouseCommand(.move, x: x, y: y))
        }

        @objc func multiFinger(_ gesture: MultiFingerGestureRecognizer) {
            for command in gesture.takeCommands() {
                switch command.action {
                case .dragStart:
                    beginDrag(.multiFinger)
                    acceleration = PointerAcceleration()
                    lastPointerTime = nil
                case .dragEnd:
                    endDrag(.multiFinger)
                case .move:
                    if dragSource == .multiFinger { movePointer(CGPoint(x: command.x, y: command.y)) }
                default:
                    if !parent.dragging { sendGesture(command) }
                }
            }
        }

        private func sendGesture(_ command: MouseCommand) {
            if !parent.enhancedGestures {
                switch command.action {
                case .magnifyStart: fallbackZoom = ZoomAccumulator(); return
                case .magnify:
                    let steps = fallbackZoom.consume(1 + command.x)
                    for _ in 0..<abs(steps) { parent.send(MouseCommand(steps > 0 ? .zoomIn : .zoomOut)) }
                    return
                case .smartZoom: parent.send(MouseCommand(.resetZoom)); return
                case .scroll, .previousSpace, .nextSpace, .missionControl, .appWindows: break
                default: return
                }
            }
            parent.send(command)
            switch command.action {
            case .previousSpace, .nextSpace, .missionControl, .appWindows, .showDesktop, .showApplications,
                 .notificationCenter, .previousPage, .nextPage, .smartZoom, .lookUp: tick()
            default: break
            }
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                if (multiRecognizer?.touchCount ?? 0) <= 1 { beginDrag(.hold) }
            case .ended, .cancelled, .failed: endDrag(.hold)
            default: break
            }
        }

        private func beginDrag(_ source: DragSource) {
            guard !parent.dragging else { return }
            dragSource = source
            parent.dragging = true
            parent.send(MouseCommand(.dragStart))
            tick()
        }

        private func endDrag(_ source: DragSource) {
            guard dragSource == source else { return }
            dragSource = nil
            parent.send(MouseCommand(.dragEnd))
            parent.dragging = false
            tick()
        }

        func finishInput() {
            if let dragSource { endDrag(dragSource) }
            if let multiRecognizer {
                multiRecognizer.finishMotion()
                multiFinger(multiRecognizer)
            }
            if parent.enhancedGestures { parent.send(MouseCommand(.stopScroll)) }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) { if !parent.dragging { parent.send(MouseCommand(.leftClick)) } }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) { if !parent.dragging { parent.send(MouseCommand(.doubleClick)) } }
        @objc func rightTap(_ gesture: UITapGestureRecognizer) { if !parent.dragging { parent.send(MouseCommand(.rightClick)) } }
        @objc func smartZoom(_ gesture: UITapGestureRecognizer) {
            if parent.smartZoom && !parent.dragging { sendGesture(MouseCommand(.smartZoom)) }
        }
        @objc func lookUp(_ gesture: UITapGestureRecognizer) { if !parent.dragging { sendGesture(MouseCommand(.lookUp)) } }
        @objc func accessibleClick() -> Bool { parent.send(MouseCommand(.leftClick)); return true }
        @objc func accessibleRightClick() -> Bool { parent.send(MouseCommand(.rightClick)); return true }
        private func tick() { if parent.haptics { feedback.selectionChanged() } }
    }
}

private final class TrackpadSurface: UIView {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
}

final class MultiFingerGestureRecognizer: UIGestureRecognizer {
    var naturalScrolling = true
    var pinchZoom = false
    var pageSwipes = false
    var threeFingerDrag = false
    var onFirstTouch: (() -> Void)?
    var touchCount: Int { activeTouches.count }
    private var commands: [MouseCommand] = []
    private var activeTouches: [UITouch] = []
    private var twoFingers: TwoFingerMotion?
    private var manyFingers: ManyFingerMotion?
    private var scrollVelocity = CGPoint.zero
    private var lastScrollTime: TimeInterval?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if activeTouches.isEmpty { onFirstTouch?() }
        finishMotion()
        activeTouches.append(contentsOf: touches)
        if touchCount > 4 {
            finishRecognition()
            return
        }
        if let sample = measurement {
            if touchCount == 2 {
                let startsOnEdge = sample.center.x >= (view?.bounds.maxX ?? .infinity) - 48
                twoFingers = TwoFingerMotion(center: sample.center, span: sample.span, angle: sample.angle,
                    notificationEdge: startsOnEdge, pageSwipes: pageSwipes, pinchZoom: pinchZoom)
            } else {
                manyFingers = ManyFingerMotion(fingers: touchCount, center: sample.center,
                    span: sample.span, threeFingerDrag: threeFingerDrag)
            }
        }
        if !commands.isEmpty && state != .possible { state = .changed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let sample = measurement else { return }
        if var motion = twoFingers {
            let next = motion.consume(center: sample.center, span: sample.span, angle: sample.angle,
                                      naturalScrolling: naturalScrolling)
            twoFingers = motion
            if let scroll = next.last, scroll.action == .scroll { estimateVelocity(scroll, at: event.timestamp) }
            commands.append(contentsOf: next)
        } else if var motion = manyFingers {
            commands.append(contentsOf: motion.consume(center: sample.center, span: sample.span))
            manyFingers = motion
        }
        if !commands.isEmpty { state = state == .possible ? .began : .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        let stillMoving = lastScrollTime.map { event.timestamp - $0 < 0.075 } ?? false
        finishMotion(velocity: stillMoving ? scrollVelocity : .zero)
        finishRecognition()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finishMotion()
        finishRecognition()
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll(keepingCapacity: true)
        commands.removeAll(keepingCapacity: true)
        twoFingers = nil
        manyFingers = nil
        lastScrollTime = nil
        scrollVelocity = .zero
    }

    func takeCommands() -> [MouseCommand] {
        defer { commands.removeAll(keepingCapacity: true) }
        return commands
    }

    func finishMotion(velocity: CGPoint = .zero) {
        if let twoFingers { commands.append(contentsOf: twoFingers.end(velocity: velocity)) }
        if let manyFingers { commands.append(contentsOf: manyFingers.end()) }
        twoFingers = nil
        manyFingers = nil
        lastScrollTime = nil
        scrollVelocity = .zero
    }

    private func finishRecognition() {
        state = state == .possible ? .failed : .ended
    }

    private func estimateVelocity(_ scroll: MouseCommand, at timestamp: TimeInterval) {
        defer { lastScrollTime = timestamp }
        guard let lastScrollTime else { return }
        let interval = min(max(timestamp - lastScrollTime, 1.0 / 240), 0.08)
        scrollVelocity.x += (scroll.x / interval - scrollVelocity.x) * 0.35
        scrollVelocity.y += (scroll.y / interval - scrollVelocity.y) * 0.35
        scrollVelocity.x = min(max(scrollVelocity.x, -2000), 2000)
        scrollVelocity.y = min(max(scrollVelocity.y, -2000), 2000)
    }

    private var measurement: (center: CGPoint, span: Double, angle: Double)? {
        guard (2...4).contains(touchCount), let view else { return nil }
        let points = activeTouches.map { $0.location(in: view) }
        let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(touchCount),
                             y: points.reduce(0) { $0 + $1.y } / CGFloat(touchCount))
        let span = points.reduce(0) { $0 + hypot($1.x - center.x, $1.y - center.y) } * 2 / CGFloat(touchCount)
        let angle = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
        return (center, Double(span), Double(angle))
    }
}
