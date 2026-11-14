import AppKit
import ApplicationServices

// Compile with the production driver. Capture events; never inject them into the desktop.
@main
struct MouseDriverChecks {
    static func main() {
        var events: [CGEvent] = []
        let driver = MouseDriver(permissionOverride: { true }, eventSink: { events.append($0) }, navigationOverride: {
            if $0 == .nextSpace { return NavigationShortcut(keyCode: 124, flags: 8_650_752) }
            return NavigationShortcut.resolve($0, preferences: [:])
        })
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        for shortcut: MouseCommand.Action in [.zoomIn, .zoomOut, .resetZoom, .nextSpace, .previousSpace, .missionControl, .appWindows] {
            events = []
            driver.perform(MouseCommand(shortcut))
            check(events.contains { $0.type == .keyDown }, "Shortcut must contain a key down")
            check(events.last?.type == .flagsChanged && events.last?.flags.isEmpty == true, "Shortcut must release all its modifiers")
            let modifiers = events.filter { $0.type == .flagsChanged }
            check(modifiers.count >= 2 && modifiers.count % 2 == 0, "Modifier presses and releases must be balanced")
            events = []
            driver.perform(MouseCommand(.leftClick))
            check(events.map(\.type) == [.leftMouseDown, .leftMouseUp], "Normal click must remain left click after shortcut")
            check(events.allSatisfy { $0.flags.isEmpty }, "Normal click must never inherit Control or Command")
        }
        events = []
        driver.perform(MouseCommand(.rightClick))
        check(events.map(\.type) == [.rightMouseDown, .rightMouseUp], "Right click keeps its explicit button")
        check(events.allSatisfy { $0.flags.isEmpty }, "Right click is unmodified")
        events = []
        driver.perform(MouseCommand(.doubleClick))
        check(events.count == 4 && events.allSatisfy { $0.type == .leftMouseDown || $0.type == .leftMouseUp }, "Double click uses left button twice")
        check(events.last?.getIntegerValueField(.mouseEventClickState) == 2, "Double click count")
        events = []
        driver.perform(MouseCommand(.dragStart))
        driver.release()
        check(events.map(\.type) == [.leftMouseDown, .leftMouseUp] && events.allSatisfy { $0.flags.isEmpty }, "Dragging uses unmodified left button")
        events = []
        driver.perform(MouseCommand(.scroll, y: 10))
        check(events.count == 1 && events[0].type == .scrollWheel && events[0].flags.isEmpty, "Scroll must not inherit shortcut modifiers")
        let blocked = MouseDriver(permissionOverride: { false }, eventSink: { _ in preconditionFailure("Blocked input was emitted") })
        blocked.perform(MouseCommand(.leftClick))
        print("Passed \(checks) mouse event regression checks; no events posted.")
    }
}
