import Foundation

public struct MouseCommand: Codable, Equatable {
    public enum Action: String, Codable, CaseIterable {
        case move, scroll, leftClick, rightClick, doubleClick, dragStart, dragEnd, heartbeat
        case zoomIn, zoomOut, resetZoom, previousSpace, nextSpace, missionControl, appWindows
    }
    public let action: Action
    public let x: Double
    public let y: Double

    public init(_ action: Action, x: Double = 0, y: Double = 0) {
        self.action = action
        self.x = x
        self.y = y
    }

    public static func decode(_ data: Data) -> MouseCommand? {
        guard data.count <= 512,
              let command = try? JSONDecoder().decode(Self.self, from: data),
              command.x.isFinite, command.y.isFinite,
              abs(command.x) <= 2000, abs(command.y) <= 2000 else { return nil }
        return command
    }
}

public enum PeerNaming {
    // Multipeer Connectivity limits display names to 63 UTF-8 bytes.
    public static func displayName(_ original: String) -> String {
        var name = String(original.prefix(63))
        while name.utf8.count > 63 { name.removeLast() }
        return name.isEmpty ? "RemotePad device" : name
    }
}

/// Converts continuous pinch scale changes into discrete application zoom steps.
public struct ZoomAccumulator {
    private var remainder = 0.0
    public init() {}
    public mutating func consume(_ relativeScale: Double) -> Int {
        guard relativeScale.isFinite, relativeScale > 0 else { return 0 }
        let threshold = log(1.18)
        remainder += log(min(max(relativeScale, 0.5), 2))
        let steps = min(max(Int(remainder / threshold), -4), 4)
        remainder -= Double(steps) * threshold
        return steps
    }
}

public enum TrackpadNavigation {
    public static func action(x: Double, y: Double) -> MouseCommand.Action? {
        guard x.isFinite, y.isFinite, max(abs(x), abs(y)) >= 45 else { return nil }
        if abs(x) > abs(y) { return x < 0 ? .nextSpace : .previousSpace }
        return y < 0 ? .missionControl : .appWindows
    }
}

/// Receiver feedback is separate from commands and is size/version checked.
public struct ReceiverStatus: Codable, Equatable {
    public let kind: String
    public let version: Int
    public let mouseControlEnabled: Bool

    public init(mouseControlEnabled: Bool) {
        self.kind = "receiverStatus"
        self.version = 1
        self.mouseControlEnabled = mouseControlEnabled
    }

    public static func decode(_ data: Data) -> ReceiverStatus? {
        guard data.count <= 512,
              let status = try? JSONDecoder().decode(Self.self, from: data),
              status.kind == "receiverStatus", status.version == 1 else { return nil }
        return status
    }
}
