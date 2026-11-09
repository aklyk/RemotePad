import UIKit
import MultipeerConnectivity
import Combine
#if canImport(RemotePadCore)
import RemotePadCore
#endif

struct NearbyMac: Identifiable {
    let peer: MCPeerID
    var id: MCPeerID { peer }
}

final class PhoneConnection: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    @Published var macs: [NearbyMac] = []
    @Published var connectedName: String?
    @Published var status = "Looking for your Mac…"
    @Published var connecting = false
    @Published var dragging = false
    @Published var mouseControlEnabled: Bool?
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!
    private var timeout: DispatchWorkItem?
    private var heartbeatTimer: Timer?

    override init() {
        super.init()
        let peer = MCPeerID(displayName: PeerNaming.displayName(UIDevice.current.name))
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "remotepad")
        browser.delegate = self
        browser.startBrowsingForPeers()
    }

    func connect(_ mac: NearbyMac) {
        guard !connecting, connectedName == nil else { return }
        connecting = true
        status = "Approve the connection on \(mac.peer.displayName)"
        browser.invitePeer(mac.peer, to: session, withContext: nil, timeout: 30)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectedName == nil else { return }
            self.session.disconnect()
            self.connecting = false
            self.status = "Connection wasn’t approved. Try again with the Mac app open."
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 32, execute: work)
    }

    func disconnect() {
        let releaseDrag = dragging
        dragging = false
        if releaseDrag { send(MouseCommand(.dragEnd)) }
        timeout?.cancel()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        mouseControlEnabled = nil
        session.disconnect()
        connectedName = nil
        connecting = false
        status = "Choose your Mac to connect"
    }

    func refresh() {
        browser.stopBrowsingForPeers()
        macs = []
        browser.startBrowsingForPeers()
        status = "Looking for your Mac…"
    }

    func toggleDrag() {
        guard connectedName != nil else { return }
        dragging.toggle()
        send(MouseCommand(dragging ? .dragStart : .dragEnd))
    }

    func send(_ command: MouseCommand) {
        guard !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(command) else { return }
        do {
            // Ordered delivery keeps a click after its preceding pointer movement.
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            disconnect()
            status = "Connection lost. Reconnect to your Mac."
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["app"] == "RemotePad" else { return }
        DispatchQueue.main.async {
            if !self.macs.contains(where: { $0.peer == peerID }) {
                self.macs.append(NearbyMac(peer: peerID))
                self.macs.sort { $0.peer.displayName.localizedCaseInsensitiveCompare($1.peer.displayName) == .orderedAscending }
            }
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.macs.removeAll { $0.peer == peerID } }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.status = "Discovery unavailable. Enable Local Network access in Settings. \(error.localizedDescription)" }
    }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.timeout?.cancel()
                self.connectedName = peerID.displayName
                self.connecting = false
                self.status = "Connected securely"
                self.mouseControlEnabled = nil
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.send(MouseCommand(.heartbeat))
                }
                self.send(MouseCommand(.heartbeat))
            case .notConnected:
                self.timeout?.cancel()
                self.connectedName = nil
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = nil
                self.mouseControlEnabled = nil
                self.connecting = false
                self.dragging = false
                self.status = "Disconnected. Select your Mac to reconnect."
            case .connecting: self.connecting = true
            @unknown default: break
            }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        guard let status = ReceiverStatus.decode(data) else { return }
        DispatchQueue.main.async {
            guard self.connectedName != nil, self.session.connectedPeers.contains(peer) else { return }
            self.mouseControlEnabled = status.mouseControlEnabled
        }
    }
    func session(_ session: MCSession, didReceive: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
