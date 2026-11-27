import AppKit
import ApplicationServices
#if canImport(RemotePadCore)
import RemotePadCore
#endif

final class MouseDriver {
    private let source = CGEventSource(stateID: .privateState)
    private let keyboardSource = CGEventSource(stateID: .hidSystemState)
    private let permissionOverride: (() -> Bool)?
    private let eventSink: ((CGEvent) -> Void)?
    private let navigationOverride: ((MouseCommand.Action) -> NavigationShortcut?)?
    private var dragging = false
    private var scrolling = false
    private var activeGesture: TrackpadGesture?
    private var momentum: Timer?
    private var momentumVelocity = CGPoint.zero
    private(set) var lastIssue: String?
    var permitted: Bool { permissionOverride?() ?? AXIsProcessTrusted() }

    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }
    private enum MomentumPhase: Int64 { case none, began, changed, ended }
    private enum TrackpadGesture: Int64 { case rotate = 5, magnify = 8, smartZoom = 22 }

    init(permissionOverride: (() -> Bool)? = nil, eventSink: ((CGEvent) -> Void)? = nil,
         navigationOverride: ((MouseCommand.Action) -> NavigationShortcut?)? = nil) {
        self.permissionOverride = permissionOverride
        self.eventSink = eventSink
        self.navigationOverride = navigationOverride
    }

    private func emit(_ event: CGEvent?) {
        guard let event else { return }
        if let eventSink { eventSink(event) }
        else { event.post(tap: .cghidEventTap) }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func perform(_ command: MouseCommand) {
        lastIssue = nil
        guard permitted, let location = CGEvent(source: nil)?.location else { return }
        switch command.action {
        case .heartbeat: break
        case .move:
            let desired = CGPoint(x: location.x + command.x, y: location.y + command.y)
            // CGEvent uses a top-left origin; NSScreen uses a bottom-left origin.
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            let screens = NSScreen.screens.map { screen -> CGRect in
                let f = screen.frame
                return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            }
            let target = screens.map { rect in
                CGPoint(x: min(max(desired.x, rect.minX), rect.maxX - 1),
                        y: min(max(desired.y, rect.minY), rect.maxY - 1))
            }.min { hypot($0.x - desired.x, $0.y - desired.y) < hypot($1.x - desired.x, $1.y - desired.y) } ?? location
            post(dragging ? .leftMouseDragged : .mouseMoved, at: target)
        case .scrollStart:
            finishScroll(at: location)
            stopMomentum(at: location)
            scrolling = true
            scroll(at: location, phase: .began)
        case .scroll:
            scroll(at: location, delta: CGPoint(x: command.x, y: command.y), phase: scrolling ? .changed : nil)
        case .scrollEnd:
            guard scrolling else { return }
            finishScroll(at: location)
            startMomentum(velocity: CGPoint(x: command.x, y: command.y), at: location)
        case .stopScroll: stopMomentum(at: location)
        case .leftClick: click(at: location, right: false)
        case .rightClick: click(at: location, right: true)
        case .doubleClick:
            click(at: location, right: false)
            click(at: location, right: false, count: 2)
        case .dragStart:
            guard !dragging else { return }
            dragging = true
            post(.leftMouseDown, at: location)
        case .dragEnd: release()
        case .zoomIn: shortcut(24, flags: .maskCommand) // Command + equals
        case .zoomOut: shortcut(27, flags: .maskCommand)
        case .resetZoom: shortcut(29, flags: .maskCommand)
        case .magnifyStart: beginGesture(.magnify, at: location)
        case .rotateStart: beginGesture(.rotate, at: location)
        case .magnify, .rotate:
            let gesture: TrackpadGesture = command.action == .magnify ? .magnify : .rotate
            guard activeGesture == gesture else { return }
            let range: ClosedRange<Double> = gesture == .magnify ? -0.5...1 : -180...180
            emitGesture(gesture, at: location, phase: .changed, delta: min(max(command.x, range.lowerBound), range.upperBound))
        case .magnifyEnd, .rotateEnd:
            if activeGesture == (command.action == .magnifyEnd ? .magnify : .rotate) { finishGesture(at: location) }
        case .smartZoom: emitGesture(.smartZoom, at: location)
        case .lookUp: shortcut(2, flags: [.maskControl, .maskCommand])
        case .previousPage: shortcut(33, flags: .maskCommand)
        case .nextPage: shortcut(30, flags: .maskCommand)
        case .showApplications:
            let launchpad = "/System/Applications/Launchpad.app"
            if eventSink == nil, FileManager.default.fileExists(atPath: launchpad) {
                NSWorkspace.shared.open(URL(fileURLWithPath: launchpad))
            } else {
                shortcut(0, flags: [.maskSecondaryFn, .maskShift])
            }
        case .previousSpace, .nextSpace, .missionControl, .appWindows, .notificationCenter, .showDesktop:
            if let configured = navigationShortcut(command.action) {
                shortcut(CGKeyCode(configured.keyCode), flags: CGEventFlags(rawValue: configured.flags))
            } else {
                lastIssue = "Shortcut disabled in Mac Keyboard Shortcuts"
            }
        }
    }

    func release() {
        guard dragging || scrolling || momentum != nil || activeGesture != nil else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        if dragging {
            dragging = false
            post(.leftMouseUp, at: location)
        }
        finishScroll(at: location)
        stopMomentum(at: location)
        finishGesture(at: location)
    }

    private func scroll(at location: CGPoint, delta: CGPoint = .zero, phase: Phase? = nil,
                        momentum: MomentumPhase = .none) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(delta.y.rounded()), wheel2: Int32(delta.x.rounded()), wheel3: 0) else { return }
        event.location = location
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta.y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta.x)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta.y)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: delta.x)
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase?.rawValue ?? 0)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: momentum.rawValue)
        emit(event)
    }

    private func finishScroll(at location: CGPoint) {
        guard scrolling else { return }
        scrolling = false
        scroll(at: location, phase: .ended)
    }

    private func startMomentum(velocity: CGPoint, at location: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 100 else { return }
        stopMomentum(at: location)
        momentumVelocity = velocity
        let interval = 1.0 / 60
        scroll(at: location, delta: CGPoint(x: velocity.x * interval, y: velocity.y * interval), momentum: .began)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.momentumVelocity.x *= 0.91
            self.momentumVelocity.y *= 0.91
            guard self.permitted, hypot(self.momentumVelocity.x, self.momentumVelocity.y) > 24 else {
                self.stopMomentum(at: location)
                return
            }
            self.scroll(at: location, delta: CGPoint(x: self.momentumVelocity.x * interval,
                                                   y: self.momentumVelocity.y * interval), momentum: .changed)
        }
        momentum = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMomentum(at location: CGPoint) {
        guard let momentum else { return }
        momentum.invalidate()
        self.momentum = nil
        scroll(at: location, momentum: .ended)
    }

    private func beginGesture(_ gesture: TrackpadGesture, at location: CGPoint) {
        finishGesture(at: location)
        stopMomentum(at: location)
        activeGesture = gesture
        emitGesture(gesture, at: location, phase: .began)
    }

    private func finishGesture(at location: CGPoint) {
        guard let activeGesture else { return }
        self.activeGesture = nil
        emitGesture(activeGesture, at: location, phase: .ended)
    }

    private func emitGesture(_ gesture: TrackpadGesture, at location: CGPoint, phase: Phase? = nil, delta: Double = 0) {
        guard let event = CGEvent(source: source) else { return }
        // Quartz exposes posting, but the AppKit gesture fields are not declared in the public SDK.
        // 55 selects the gesture event, 110 its HID subtype, and 132 its phase.
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: gesture.rawValue)
        if let phase { event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase.rawValue) }
        if gesture != .smartZoom {
            let valueField: UInt32 = gesture == .magnify ? 113 : 114
            event.setDoubleValueField(CGEventField(rawValue: valueField)!, value: delta)
        }
        event.location = location
        event.flags = []
        emit(event)
    }

    private func navigationShortcut(_ action: MouseCommand.Action) -> NavigationShortcut? {
        if let navigationOverride { return navigationOverride(action) }
        let preferences = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
        return NavigationShortcut.resolve(action, preferences: preferences)
    }

    private func shortcut(_ key: CGKeyCode, flags: CGEventFlags) {
        guard !dragging else { return }
        // Explicit press/release events prevent Control/Command from leaking into later input.
        let modifiers: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58),
            (.maskShift, 56), (.maskCommand, 55), (.maskSecondaryFn, 63)]
        // Arrow events carry both flags even when the Fn key itself isn't held.
        // WindowServer uses those flags when matching desktop navigation shortcuts.
        let arrowFlags: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        let arrowKey = (123...126).contains(key)
        let keyFlags = arrowKey ? flags.union(arrowFlags) : flags
        let heldFlags = arrowKey ? flags.subtracting(arrowFlags) : flags
        var pressed: CGEventFlags = []
        for (flag, code) in modifiers where heldFlags.contains(flag) {
            pressed.insert(flag)
            modifier(code, flags: pressed)
        }
        let down = CGEvent(keyboardEventSource: keyboardSource, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: keyboardSource, virtualKey: key, keyDown: false)
        down?.flags = keyFlags
        up?.flags = keyFlags
        emit(down)
        emit(up)
        for (flag, code) in modifiers.reversed() where heldFlags.contains(flag) {
            pressed.remove(flag)
            modifier(code, flags: pressed)
        }
    }

    private func modifier(_ key: CGKeyCode, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: key, keyDown: !flags.isEmpty)
        event?.type = .flagsChanged
        event?.flags = flags
        emit(event)
    }

    private func click(at point: CGPoint, right: Bool, count: Int64 = 1) {
        guard !dragging else { return }
        post(right ? .rightMouseDown : .leftMouseDown, at: point, count: count)
        post(right ? .rightMouseUp : .leftMouseUp, at: point, count: count)
    }

    private func post(_ type: CGEventType, at point: CGPoint, count: Int64 = 1) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                            mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left)
        // The trackpad's clicks are always plain clicks, even after a navigation shortcut.
        event?.flags = []
        event?.setIntegerValueField(.mouseEventClickState, value: count)
        emit(event)
    }
}
