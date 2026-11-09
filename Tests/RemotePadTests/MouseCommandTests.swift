import Foundation
import RemotePadCore

// Standalone checks also run on Macs with Command Line Tools and no XCTest SDK.
@main
struct ProtocolChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let actions = MouseCommand.Action.allCases
        for action in actions {
            let command = MouseCommand(action, x: -18.75, y: 23.5)
            check(MouseCommand.decode(try JSONEncoder().encode(command)) == command, "Round trip failed: \(action)")
        }
        let invalid = ["{}", "not json", #"{"action":"launch","x":0,"y":0}"#,
                       #"{"action":"move","x":2001,"y":0}"#,
                       #"{"action":"scroll","x":0,"y":-2001}"#,
                       #"{"action":"move","x":1e999,"y":0}"#]
        for text in invalid {
            check(MouseCommand.decode(Data(text.utf8)) == nil, "Accepted malformed input")
        }
        check(MouseCommand.decode(Data(repeating: 32, count: 513)) == nil, "Accepted oversized message")
        let boundary = MouseCommand(.move, x: -2000, y: 2000)
        check(MouseCommand.decode(try JSONEncoder().encode(boundary)) == boundary, "Rejected valid boundary")
        check(PeerNaming.displayName(String(repeating: "📱", count: 80)).utf8.count <= 63, "Name exceeds byte limit")
        check(!PeerNaming.displayName("").isEmpty, "Empty peer name")
        var zoom = ZoomAccumulator()
        check(zoom.consume(1.05) == 0, "Small pinch should accumulate")
        check(zoom.consume(1.15) == 1, "Accumulated pinch should zoom in")
        check(zoom.consume(0.75) == -1, "Pinch reversal should zoom out")
        check(zoom.consume(.infinity) == 0 && zoom.consume(0) == 0 && zoom.consume(-1) == 0, "Invalid pinch scale")
        check(TrackpadNavigation.action(x: 12, y: 20) == nil, "Short swipe should do nothing")
        check(TrackpadNavigation.action(x: -70, y: 10) == .nextSpace, "Left swipe")
        check(TrackpadNavigation.action(x: 70, y: 10) == .previousSpace, "Right swipe")
        check(TrackpadNavigation.action(x: 5, y: -70) == .missionControl, "Up swipe")
        check(TrackpadNavigation.action(x: 5, y: 70) == .appWindows, "Down swipe")
        check(TrackpadNavigation.action(x: .nan, y: 70) == nil, "Invalid swipe")
        let status = ReceiverStatus(mouseControlEnabled: false)
        check(ReceiverStatus.decode(try JSONEncoder().encode(status)) == status, "Permission feedback round trip")
        check(ReceiverStatus.decode(Data(#"{"kind":"receiverStatus","version":2,"mouseControlEnabled":true}"#.utf8)) == nil, "Reject unsupported status version")
        check(ReceiverStatus.decode(Data(#"{"kind":"command","version":1,"mouseControlEnabled":true}"#.utf8)) == nil, "Reject wrong message kind")
        check(ReceiverStatus.decode(Data(repeating: 32, count: 513)) == nil, "Reject oversized status")
        print("Passed \(checks) protocol checks.")
    }
}
