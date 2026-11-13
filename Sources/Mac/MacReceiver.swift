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
    @Published var rememberedPhones = UserDefaults.standard.stringArray(forKey: "trustedPhoneIDs")?.count ?? 0
    let computerName = Host.current().localizedName ?? "My Mac"
    private let driver = MouseDriver()
    private let macID = DeviceIdentity.identifier()
    private var pendingRequest: PairingRequest?
    private var pendingPeer: MCPeerID?
    private var grants: [MCPeerID: PairingGrant] = [:]
    private var approvedPeers: Set<MCPeerID> = []
    private var returningPhones: [MCPeerID: String] = [:]
    private var challenges: [MCPeerID: PairingChallenge] = [:]
    private var authenticationTimeouts: [MCPeerID: DispatchWorkItem] = [:]
    private var reserved = false
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var invitation: ((Bool, MCSession?) -> Void)?
    private var invitationTimeout: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var lastPacketAt = Date()

    override init() {
        super.init()
        let peer: MCPeerID
        if let data = UserDefaults.standard.data(forKey: "peerIdentity"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            peer = saved
        } else {
            peer = MCPeerID(displayName: PeerNaming.displayName(computerName))
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "peerIdentity")
            }
        }
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["app": "RemotePad", "id": macID], serviceType: "remotepad")
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
        let peers = session.connectedPeers.filter { approvedPeers.contains($0) }
        guard !peers.isEmpty,
              let data = try? JSONEncoder().encode(ReceiverStatus(mouseControlEnabled: permission)) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    func answer(_ allow: Bool) {
        invitationTimeout?.cancel()
        let handler = invitation
        if allow, let peer = pendingPeer { approvedPeers.insert(peer) }
        if allow, let request = pendingRequest, let peer = pendingPeer,
           let token = PairingKeychain.newToken(),
           PairingKeychain.save(Data(token.utf8), account: "phone." + request.phoneID) {
            var identifiers = Set(UserDefaults.standard.stringArray(forKey: "trustedPhoneIDs") ?? [])
            identifiers.insert(request.phoneID)
            UserDefaults.standard.set(Array(identifiers), forKey: "trustedPhoneIDs")
            rememberedPhones = identifiers.count
            grants[peer] = PairingGrant(macID: macID, name: computerName, token: token)
        }
        pendingRequest = nil
        pendingPeer = nil
        invitation = nil
        pendingName = nil
        if allow { reserved = true }
        handler?(allow, allow ? session : nil)
        if allow { status = "Connecting…" }
    }

    func forgetPhones() {
        disconnect()
        for identifier in UserDefaults.standard.stringArray(forKey: "trustedPhoneIDs") ?? [] {
            PairingKeychain.remove("phone." + identifier)
        }
        UserDefaults.standard.removeObject(forKey: "trustedPhoneIDs")
        rememberedPhones = 0
        grants.removeAll()
    }

    func disconnect() {
        answer(false)
        driver.release()
        session.disconnect()
        approvedPeers.removeAll()
        returningPhones.removeAll()
        challenges.removeAll()
        authenticationTimeouts.values.forEach { $0.cancel() }
        authenticationTimeouts.removeAll()
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
            let request = PairingRequest.decode(context)
            if let request, request.automatic, request.macID == self.macID,
               PairingKeychain.read("phone." + request.phoneID) != nil {
                // Transport is provisional: no input is accepted until the fresh challenge is verified.
                self.returningPhones[peerID] = request.phoneID
                self.reserved = true
                invitationHandler(true, self.session)
                self.status = "Verifying remembered iPhone…"
                return
            }
            // Revoked or expired automatic credentials never bypass approval or spam prompts.
            if request?.automatic == true { invitationHandler(false, nil); return }
            self.pendingRequest = request
            self.pendingPeer = peerID
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
                if let phoneID = self.returningPhones[peerID] {
                    guard let stored = PairingKeychain.read("phone." + phoneID),
                          let token = String(data: stored, encoding: .utf8) else { self.disconnect(); return }
                    let unsigned = PairingChallenge(macID: self.macID)
                    let challenge = PairingChallenge(macID: self.macID, nonce: unsigned.nonce,
                        serverProof: PairingSecrets.proof(token: token, challenge: unsigned, phoneID: phoneID, role: "mac"))
                    self.challenges[peerID] = challenge
                    if let data = try? JSONEncoder().encode(challenge) {
                        try? self.session.send(data, toPeers: [peerID], with: .reliable)
                    }
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, !self.approvedPeers.contains(peerID) else { return }
                        self.disconnect()
                    }
                    self.authenticationTimeouts[peerID] = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                } else if self.approvedPeers.contains(peerID) {
                    self.connectionReady(peerID)
                } else { self.disconnect() }
            case .notConnected:
                self.approvedPeers.remove(peerID)
                self.returningPhones.removeValue(forKey: peerID)
                self.challenges.removeValue(forKey: peerID)
                self.authenticationTimeouts.removeValue(forKey: peerID)?.cancel()
                self.grants.removeValue(forKey: peerID)
                self.reserved = false
                self.driver.release()
                self.controller = nil
                self.status = self.accepting ? "Ready to pair" : "Paused"
            case .connecting: self.status = "Connecting…"
            @unknown default: break
            }
        }
    }

    private func connectionReady(_ peer: MCPeerID) {
        controller = peer.displayName
        status = "Connected securely"
        receivedCommands = 0
        lastAction = "Waiting for input"
        lastPacketAt = Date()
        permission = driver.permitted
        sendStatus()
        if let grant = grants.removeValue(forKey: peer), let data = try? JSONEncoder().encode(grant) {
            try? session.send(data, toPeers: [peer], with: .reliable)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let proof = PairingProof.decode(data) {
            DispatchQueue.main.async {
                guard self.returningPhones[peerID] == proof.phoneID,
                      let challenge = self.challenges.removeValue(forKey: peerID),
                      let stored = PairingKeychain.read("phone." + proof.phoneID),
                      let token = String(data: stored, encoding: .utf8),
                      PairingSecrets.matches(proof.digest, PairingSecrets.proof(token: token, challenge: challenge, phoneID: proof.phoneID)) else { return }
                self.authenticationTimeouts.removeValue(forKey: peerID)?.cancel()
                self.returningPhones.removeValue(forKey: peerID)
                self.approvedPeers.insert(peerID)
                self.connectionReady(peerID)
            }
            return
        }
        guard let command = MouseCommand.decode(data) else { return }
        DispatchQueue.main.async {
            guard self.accepting, self.approvedPeers.contains(peerID), self.session.connectedPeers.contains(peerID) else { return }
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
