import AppKit
import ApplicationServices
#if canImport(RemotePadCore)
import RemotePadCore
#endif

final class MouseDriver {
    private let source = CGEventSource(stateID: .privateState)
    private let permissionOverride: (() -> Bool)?
    private let eventSink: ((CGEvent) -> Void)?
    private let navigationOverride: ((MouseCommand.Action) -> NavigationShortcut?)?
    private var dragging = false
    private(set) var lastIssue: String?
    var permitted: Bool { permissionOverride?() ?? AXIsProcessTrusted() }

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
        case .scroll:
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: Int32(command.y.rounded()), wheel2: Int32(command.x.rounded()), wheel3: 0)
            event?.flags = []
            emit(event)
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
        case .previousSpace, .nextSpace, .missionControl, .appWindows:
            if let configured = navigationShortcut(command.action) {
                shortcut(CGKeyCode(configured.keyCode), flags: CGEventFlags(rawValue: configured.flags))
            } else {
                lastIssue = "Navigation shortcut disabled: check Keyboard → Mission Control"
            }
        }
    }

    func release() {
        guard dragging else { return }
        dragging = false
        post(.leftMouseUp, at: CGEvent(source: nil)?.location ?? .zero)
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
        var pressed: CGEventFlags = []
        for (flag, code) in modifiers where flags.contains(flag) {
            pressed.insert(flag)
            modifier(code, flags: pressed)
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        emit(down)
        emit(up)
        for (flag, code) in modifiers.reversed() where flags.contains(flag) {
            pressed.remove(flag)
            modifier(code, flags: pressed)
        }
    }

    private func modifier(_ key: CGKeyCode, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: !flags.isEmpty)
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
