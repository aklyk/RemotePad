import UIKit
import MultipeerConnectivity
import Combine
#if canImport(RemotePadCore)
import RemotePadCore
#endif

struct NearbyMac: Identifiable {
    let peer: MCPeerID
    let macID: String?
    var id: MCPeerID { peer }
}

final class PhoneConnection: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    @Published var macs: [NearbyMac] = []
    @Published var connectedName: String?
    @Published var status = "Looking for your Mac…"
    @Published var connecting = false
    @Published var dragging = false
    @Published var mouseControlEnabled: Bool?
    @Published var rememberedMacName: String?
    @Published var autoReconnect: Bool = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect")
            if autoReconnect { manuallyDisconnected = false; retryCount = 0; tryReconnect() }
            else { retryWork?.cancel() }
        }
    }
    private let phoneID = DeviceIdentity.identifier()
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!
    private var timeout: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var active = true
    private var manuallyDisconnected = false
    private var targetPeer: MCPeerID?
    private var pendingMacID: String?
    private var automaticAttempt = false
    private var remembered: PairingGrant?

    override init() {
        super.init()
        let peer: MCPeerID
        if let data = UserDefaults.standard.data(forKey: "peerIdentity"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) { peer = saved }
        else {
            peer = MCPeerID(displayName: PeerNaming.displayName(UIDevice.current.name))
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "peerIdentity")
            }
        }
        if let data = PairingKeychain.read("rememberedMac") { remembered = PairingGrant.decode(data) }
        rememberedMacName = remembered?.name
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "remotepad")
        browser.delegate = self
        browser.startBrowsingForPeers()
    }

    func connect(_ mac: NearbyMac) {
        manuallyDisconnected = false
        retryCount = 0
        invite(mac, automatic: false)
    }

    private func invite(_ mac: NearbyMac, automatic: Bool) {
        guard active, !connecting, connectedName == nil else { return }
        retryWork?.cancel()
        targetPeer = mac.peer
        automaticAttempt = automatic
        pendingMacID = mac.macID
        connecting = true
        status = automatic ? "Reconnecting to \(mac.peer.displayName)…" : "Approve the connection on \(mac.peer.displayName)"
        let request = PairingRequest(phoneID: phoneID, macID: mac.macID, automatic: automatic)
        browser.invitePeer(mac.peer, to: session, withContext: try? JSONEncoder().encode(request), timeout: 30)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connecting else { return }
            self.endSession()
            self.status = "Connection timed out. Tap your Mac to pair again."
            if automatic { self.scheduleReconnect() }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 32, execute: work)
    }

    func releaseDrag() {
        let wasDragging = dragging
        dragging = false
        if wasDragging { send(MouseCommand(.dragEnd)) }
    }

    private func endSession() {
        releaseDrag()
        timeout?.cancel()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        mouseControlEnabled = nil
        targetPeer = nil
        pendingMacID = nil
        connectedName = nil
        connecting = false
        session.disconnect()
    }

    func disconnect() {
        manuallyDisconnected = true
        retryWork?.cancel()
        endSession()
        status = "Disconnected. Tap a Mac to connect."
    }

    func suspend() {
        active = false
        retryWork?.cancel()
        browser.stopBrowsingForPeers()
        macs = []
        endSession()
        status = autoReconnect && remembered != nil ? "Will reconnect when you return" : "Choose your Mac to connect"
    }

    func resume() {
        guard !active else { tryReconnect(); return }
        active = true
        manuallyDisconnected = false
        retryCount = 0
        browser.startBrowsingForPeers()
        status = remembered != nil && autoReconnect ? "Looking for your remembered Mac…" : "Looking for your Mac…"
        tryReconnect()
    }

    func forgetMac() {
        disconnect()
        PairingKeychain.remove("rememberedMac")
        remembered = nil
        rememberedMacName = nil
        status = "Pairing forgotten. Select a Mac to pair again."
    }

    private func tryReconnect() {
        guard active, autoReconnect, !manuallyDisconnected, retryCount < 3,
              !connecting, connectedName == nil, let remembered,
              let mac = macs.first(where: { $0.macID == remembered.macID }) else { return }
        invite(mac, automatic: true)
    }

    private func scheduleReconnect() {
        guard active, autoReconnect, !manuallyDisconnected, remembered != nil else { return }
        retryWork?.cancel()
        retryCount += 1
        guard retryCount < 3 else {
            status = "Auto-connect paused. Tap your Mac to approve pairing again."
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.tryReconnect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount * 2), execute: work)
    }

    func refresh() {
        retryCount = 0
        manuallyDisconnected = false
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
        do { try session.send(data, toPeers: session.connectedPeers, with: .reliable) }
        catch {
            // Clear before closing so a failed drag release cannot recurse.
            dragging = false
            endSession()
            status = "Connection lost. Reconnecting…"
            scheduleReconnect()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["app"] == "RemotePad" else { return }
        DispatchQueue.main.async {
            if !self.macs.contains(where: { $0.peer == peerID }) {
                self.macs.append(NearbyMac(peer: peerID, macID: info?["id"]))
                self.macs.sort { $0.peer.displayName.localizedCaseInsensitiveCompare($1.peer.displayName) == .orderedAscending }
            }
            self.tryReconnect()
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
            guard peerID == self.targetPeer else { return }
            switch state {
            case .connected:
                self.status = "Verifying connection…"
                // Keep the invitation timeout until authenticated receiver feedback arrives.
            case .notConnected:
                let shouldRetry = self.automaticAttempt || self.connectedName != nil
                self.timeout?.cancel()
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = nil
                self.mouseControlEnabled = nil
                self.connectedName = nil
                self.connecting = false
                self.dragging = false
                self.targetPeer = nil
                self.pendingMacID = nil
                self.status = "Disconnected. Tap your Mac to reconnect."
                if shouldRetry { self.scheduleReconnect() }
            case .connecting: self.connecting = true
            @unknown default: break
            }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        DispatchQueue.main.async {
            guard peer == self.targetPeer, self.session.connectedPeers.contains(peer) else { return }
            if let challenge = PairingChallenge.decode(data), let remembered = self.remembered,
               challenge.macID == remembered.macID, challenge.macID == self.pendingMacID,
               PairingSecrets.matches(challenge.serverProof,
                   PairingSecrets.proof(token: remembered.token, challenge: challenge, phoneID: self.phoneID, role: "mac")) {
                let proof = PairingProof(phoneID: self.phoneID, digest: PairingSecrets.proof(token: remembered.token, challenge: challenge, phoneID: self.phoneID))
                if let encoded = try? JSONEncoder().encode(proof) {
                    try? self.session.send(encoded, toPeers: [peer], with: .reliable)
                }
                return
            }
            if let grant = PairingGrant.decode(data), grant.macID == self.pendingMacID {
                if PairingKeychain.save(data, account: "rememberedMac") {
                    self.remembered = grant
                    self.rememberedMacName = grant.name
                }
                return
            }
            guard let status = ReceiverStatus.decode(data) else { return }
            let newlyConnected = self.connectedName == nil
            self.timeout?.cancel()
            self.connectedName = peer.displayName
            self.connecting = false
            self.mouseControlEnabled = status.mouseControlEnabled
            self.status = "Connected securely"
            self.retryCount = 0
            if newlyConnected {
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.send(MouseCommand(.heartbeat))
                }
            }
        }
    }
    func session(_ session: MCSession, didReceive: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
