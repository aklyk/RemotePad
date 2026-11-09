import AppKit
import MultipeerConnectivity
import Combine
#if canImport(RemotePadCore)
import RemotePadCore
#endif

final class MacReceiver: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    @Published var status = "Starting…"
    @Published var controller: String?
    @Published var pendingName: String?
    @Published var permission = false
    @Published var receivedCommands = 0
    @Published var lastAction = "Waiting for input"
    @Published var accepting = true
    let computerName = Host.current().localizedName ?? "My Mac"
    private let driver = MouseDriver()
    private var reserved = false
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var invitation: ((Bool, MCSession?) -> Void)?
    private var invitationTimeout: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var lastPacketAt = Date()

    override init() {
        super.init()
        let peer = MCPeerID(displayName: PeerNaming.displayName(computerName))
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["app": "RemotePad"], serviceType: "remotepad")
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        status = "Ready to pair"
        permission = driver.permitted
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let allowed = self.driver.permitted
            if self.permission != allowed {
                self.permission = allowed
                self.sendStatus()
            }
            // Release a held mouse button even if the network fails silently.
            if Date().timeIntervalSince(self.lastPacketAt) > 6 { self.driver.release() }
        }
    }

    func requestPermission() {
        driver.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func sendStatus() {
        guard !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(ReceiverStatus(mouseControlEnabled: permission)) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func answer(_ allow: Bool) {
        invitationTimeout?.cancel()
        let handler = invitation
        invitation = nil
        pendingName = nil
        if allow { reserved = true }
        handler?(allow, allow ? session : nil)
        if allow { status = "Connecting…" }
    }

    func disconnect() {
        answer(false)
        driver.release()
        session.disconnect()
        reserved = false
        controller = nil
        status = accepting ? "Ready to pair" : "Paused"
    }

    func setAccepting(_ value: Bool) {
        accepting = value
        if value { advertiser.startAdvertisingPeer(); status = "Ready to pair" }
        else { advertiser.stopAdvertisingPeer(); disconnect() }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard self.accepting, !self.reserved, self.controller == nil, self.invitation == nil,
                  self.session.connectedPeers.isEmpty else { invitationHandler(false, nil); return }
            self.invitation = invitationHandler
            self.pendingName = peerID.displayName
            let timeout = DispatchWorkItem { [weak self] in self?.answer(false) }
            self.invitationTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.status = "Discovery failed: \(error.localizedDescription)" }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.controller = peerID.displayName
                self.status = "Connected securely"
                self.receivedCommands = 0
                self.lastAction = "Waiting for input"
                self.lastPacketAt = Date()
                self.permission = self.driver.permitted
                self.sendStatus()
            case .notConnected:
                self.reserved = false
                self.driver.release()
                self.controller = nil
                self.status = self.accepting ? "Ready to pair" : "Paused"
            case .connecting: self.status = "Connecting…"
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let command = MouseCommand.decode(data) else { return }
        DispatchQueue.main.async {
            guard self.accepting, self.session.connectedPeers.contains(peerID) else { return }
            self.lastPacketAt = Date()
            if command.action == .heartbeat { self.sendStatus(); return }
            self.receivedCommands += 1
            self.lastAction = self.permission ? "Receiving input" : "Input blocked: enable Accessibility"
            self.driver.perform(command)
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
