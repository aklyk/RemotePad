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
        for navigation: MouseCommand.Action in [.nextSpace, .previousSpace, .missionControl, .appWindows] {
            events = []
            driver.perform(MouseCommand(navigation))
            let expected: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            check(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                  "Arrow navigation presses and releases only the actual modifier")
            check(events[0].flags == .maskControl && events[3].flags.isEmpty, "Control edges bracket navigation")
            check(events[1].flags == expected && events[2].flags == expected, "Navigation arrows have hardware key flags")
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
        events = []
        driver.perform(MouseCommand(.scrollStart))
        driver.perform(MouseCommand(.scroll, x: 5, y: 10))
        driver.perform(MouseCommand(.scrollEnd, y: 400))
        driver.perform(MouseCommand(.stopScroll))
        check(events.map { $0.getIntegerValueField(CGEventField(rawValue: 99)!) } == [1, 2, 4, 0, 0],
              "Scroll has begin, change and end phases")
        check(events.map { $0.getIntegerValueField(CGEventField(rawValue: 123)!) } == [0, 0, 0, 1, 3],
              "Momentum starts on lift and stops on a new touch")
        events = []
        driver.perform(MouseCommand(.magnifyStart))
        driver.perform(MouseCommand(.magnify, x: 0.2))
        driver.perform(MouseCommand(.magnifyEnd))
        driver.perform(MouseCommand(.rotateStart))
        driver.perform(MouseCommand(.rotate, x: 18))
        driver.release()
        driver.perform(MouseCommand(.smartZoom))
        let cocoa = events.compactMap(NSEvent.init(cgEvent:))
        check(cocoa.map(\.type) == [.magnify, .magnify, .magnify, .rotate, .rotate, .rotate, .smartMagnify],
              "AppKit recognizes generated trackpad events")
        check(cocoa.count == 7 && abs(cocoa[1].magnification - 0.2) < 0.01 && abs(cocoa[4].rotation - 18) < 0.01,
              "AppKit receives the pinch and rotation deltas")
        check(cocoa.count == 7 && cocoa[2].phase == .ended && cocoa[5].phase == .ended,
              "Ending input releases in-progress gestures")
        let blocked = MouseDriver(permissionOverride: { false }, eventSink: { _ in preconditionFailure("Blocked input was emitted") })
        blocked.perform(MouseCommand(.leftClick))
        print("Passed \(checks) mouse event regression checks; no events posted.")
    }
}
