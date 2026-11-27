import Foundation
import MultipeerConnectivity
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
        let phoneID = UUID().uuidString
        let macID = UUID().uuidString
        let token = String(repeating: "a", count: 64)
        let grant = PairingGrant(macID: macID, name: "Test Mac", token: token)
        check(PairingGrant.decode(try JSONEncoder().encode(grant)) == grant, "Remembered pairing round trip")
        check(PairingSecrets.matches(token, token), "Matching pairing secrets")
        check(!PairingSecrets.matches(token, String(repeating: "b", count: 64)), "Reject incorrect secret")
        check(!PairingSecrets.matches(nil, token), "Missing secret must not authorize")
        check(!PairingSecrets.matches("", ""), "Empty secrets must not authorize")
        check(!PairingSecrets.isValidToken(String(repeating: "z", count: 64)), "Reject malformed token")
        let request = PairingRequest(phoneID: phoneID, macID: macID, automatic: true)
        let requestData = try JSONEncoder().encode(request)
        check(PairingRequest.decode(requestData)?.phoneID == phoneID, "Pairing invitation round trip")
        check(!String(data: requestData, encoding: .utf8)!.contains(token), "Invitation must not disclose secret")
        check(PairingRequest.decode(Data(#"{"kind":"pairingRequest","phoneID":"bad","automatic":true}"#.utf8)) == nil, "Reject invalid phone identity")
        let directRequest = DirectPairingRequest(pairing: request, name: "Test iPhone")
        let directRequestData = try JSONEncoder().encode(directRequest)
        check(DirectPairingRequest.decode(directRequestData)?.pairing.phoneID == phoneID, "Direct pairing invitation round trip")
        let unsafeName = DirectPairingRequest(pairing: request, name: "Test\niPhone")
        check(DirectPairingRequest.decode(try JSONEncoder().encode(unsafeName)) == nil, "Reject control characters in direct pairing names")
        check(DirectPairingRequest.decode(Data(repeating: 32, count: 513)) == nil, "Reject oversized direct pairing invitation")
        let challenge = PairingChallenge(macID: macID)
        let proof = PairingSecrets.proof(token: token, challenge: challenge, phoneID: phoneID)
        check(PairingSecrets.matches(proof, PairingSecrets.proof(token: token, challenge: challenge, phoneID: phoneID)), "Verify returning phone")
        check(!PairingSecrets.matches(proof, PairingSecrets.proof(token: token, challenge: PairingChallenge(macID: macID), phoneID: phoneID)), "Challenge replay must fail")
        check(!PairingSecrets.matches(proof, PairingSecrets.proof(token: token, challenge: challenge, phoneID: UUID().uuidString)), "Proof is bound to phone")
        check(PairingProof.decode(try JSONEncoder().encode(PairingProof(phoneID: phoneID, digest: proof)))?.digest == proof, "Proof round trip")
        check(PairingGrant.decode(Data(repeating: 32, count: 1025)) == nil, "Reject oversized pairing grant")
        check(PairingKeychain.newToken().map(PairingSecrets.isValidToken) == true, "Secure random token format")
        check(!PairingSecrets.matches(proof, PairingSecrets.proof(token: token, challenge: challenge, phoneID: phoneID, role: "mac")), "Server proof cannot be reflected as client proof")
        let authenticatedChallenge = PairingChallenge(macID: macID, nonce: challenge.nonce,
            serverProof: PairingSecrets.proof(token: token, challenge: challenge, phoneID: phoneID, role: "mac"))
        check(PairingChallenge.decode(try JSONEncoder().encode(authenticatedChallenge))?.nonce == challenge.nonce, "Authenticated challenge round trip")
        check(PairingChallenge.decode(try JSONEncoder().encode(challenge)) == nil, "Reject challenge without server proof")
        let peer = MCPeerID(displayName: "Pairing identity test")
        let peerData = try NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true)
        let restoredPeer = try NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: peerData)
        check(restoredPeer == peer, "Peer identity survives relaunch")
        let fnControl: UInt64 = 8_650_752
        let customized: [String: Any] = ["81": ["enabled": true, "value": ["parameters": [65535, 124, fnControl]]]]
        check(NavigationShortcut.resolve(.nextSpace, preferences: customized) == NavigationShortcut(keyCode: 124, flags: fnControl), "Preserve configured Fn-Control shortcut")
        check(NavigationShortcut.resolve(.previousSpace, preferences: [:]) == NavigationShortcut(keyCode: 123, flags: 1 << 18), "Use default shortcut when no override exists")
        check(NavigationShortcut.resolve(.nextSpace, preferences: ["81": ["enabled": false]]) == nil, "Respect disabled shortcuts")
        check(NavigationShortcut.resolve(.nextSpace, preferences: ["81": ["enabled": true, "value": ["parameters": [1, 999, 1]]]]) == nil, "Reject invalid virtual key")
        check(NavigationShortcut.resolve(.leftClick, preferences: [:]) == nil, "Clicks cannot resolve to navigation keys")
        var stroke = NavigationStroke()
        check(stroke.consume(x: -20, y: 2) == nil, "No navigation before swipe threshold")
        check(stroke.consume(x: -50, y: 2) == .nextSpace, "Navigate while fingers are down")
        check(stroke.consume(x: -150, y: 2) == nil, "One space change per swipe")
        stroke = NavigationStroke()
        check(stroke.consume(x: 50, y: 2) == .previousSpace, "New swipe can navigate again")
        print("Passed \(checks) protocol checks.")
    }
}
