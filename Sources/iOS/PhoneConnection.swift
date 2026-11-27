import UIKit
import MultipeerConnectivity
import Combine
import Network
#if canImport(RemotePadCore)
import RemotePadCore
#endif

struct NearbyMac: Identifiable {
    let peer: MCPeerID
    let macID: String?
    var id: MCPeerID { peer }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case nearby, zeroTier, netBird, usb
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nearby: return "Nearby"
        case .zeroTier: return "ZeroTier"
        case .netBird: return "NetBird"
        case .usb: return "USB"
        }
    }
}

final class PhoneConnection: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    @Published var macs: [NearbyMac] = []
    @Published var connectedName: String?
    @Published var status = "Looking for your Mac…"
    @Published var connecting = false
    @Published var dragging = false
    @Published var mouseControlEnabled: Bool?
    @Published var rememberedMacName: String?
    @Published private(set) var mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .nearby
    @Published var vpnAddress = "" {
        didSet { if mode == .zeroTier || mode == .netBird { UserDefaults.standard.set(vpnAddress, forKey: vpnAddressKey) } }
    }
    @Published var zeroTierNetworkID = UserDefaults.standard.string(forKey: "zeroTierNetworkID") ?? "" {
        didSet { UserDefaults.standard.set(zeroTierNetworkID, forKey: "zeroTierNetworkID") }
    }
    @Published private(set) var hasDirectKey = false
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
    private var directListener: NWListener?
    private var direct: DirectConnection?
    private struct DirectAttempt {
        let key: String
        let phoneID: String
        let remembered: PairingGrant?
        var started = false
        var verified = false
        var grant: PairingGrant?
    }
    private var directAttempt: DirectAttempt?
    private var lastDirectStatusAt = Date()
    private var vpnAddressKey: String { "vpnAddress." + mode.rawValue }
    private var grantAccount: String { mode == .nearby ? "rememberedMac" : "rememberedMac." + mode.rawValue }
    private var directKeyAccount: String { "directAccessKey." + mode.rawValue }

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
        loadMode()
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "remotepad")
        browser.delegate = self
        if mode == .nearby { browser.startBrowsingForPeers() }
    }

    private func loadMode() {
        remembered = PairingKeychain.read(grantAccount).flatMap(PairingGrant.decode)
        rememberedMacName = remembered?.name
        hasDirectKey = mode != .nearby && savedDirectKey() != nil
        if mode == .zeroTier || mode == .netBird { vpnAddress = UserDefaults.standard.string(forKey: vpnAddressKey) ?? "" }
        status = readyStatus
    }

    private var readyStatus: String {
        switch mode {
        case .nearby: return "Looking for your Mac…"
        case .usb: return "Connect your iPhone with a USB data cable."
        default: return "Connect using your Mac’s \(mode.label) address."
        }
    }

    func selectMode(_ newMode: ConnectionMode) {
        guard mode != newMode else { return }
        disconnect()
        browser.stopBrowsingForPeers()
        macs = []
        mode = newMode
        UserDefaults.standard.set(mode.rawValue, forKey: "connectionMode")
        loadMode()
        manuallyDisconnected = false
        retryCount = 0
        if mode == .nearby { browser.startBrowsingForPeers() }
        tryReconnect()
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
        directAttempt = nil
        let link = direct
        direct = nil
        link?.close()
        directListener?.cancel()
        directListener = nil
        session.disconnect()
    }

    func disconnect() {
        manuallyDisconnected = true
        retryWork?.cancel()
        endSession()
        status = mode == .nearby ? "Disconnected. Tap a Mac to connect." : readyStatus
    }

    func suspend() {
        active = false
        retryWork?.cancel()
        browser.stopBrowsingForPeers()
        macs = []
        endSession()
        status = autoReconnect && remembered != nil ? "Will reconnect when you return" : readyStatus
    }

    func resume() {
        guard !active else { tryReconnect(); return }
        active = true
        manuallyDisconnected = false
        retryCount = 0
        if mode == .nearby { browser.startBrowsingForPeers() }
        status = readyStatus
        tryReconnect()
    }

    func forgetMac() {
        disconnect()
        PairingKeychain.remove(grantAccount)
        if mode != .nearby { PairingKeychain.remove(directKeyAccount); hasDirectKey = false }
        remembered = nil
        rememberedMacName = nil
        status = "Pairing forgotten. Connect to your Mac to pair again."
    }

    private func tryReconnect() {
        guard active, autoReconnect, !manuallyDisconnected, retryCount < 3,
              !connecting, connectedName == nil, let remembered else { return }
        if mode == .nearby {
            guard let mac = macs.first(where: { $0.macID == remembered.macID }) else { return }
            invite(mac, automatic: true)
        } else {
            _ = connectDirect()
        }
    }

    private func scheduleReconnect() {
        guard active, autoReconnect, !manuallyDisconnected, remembered != nil else { return }
        retryWork?.cancel()
        retryCount += 1
        guard retryCount < 3 else {
            status = "Auto-connect paused. Connect again to approve a new pairing."
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
        guard let data = try? JSONEncoder().encode(command) else { return }
        if mode != .nearby {
            if connectedName != nil { direct?.send(data) }
            return
        }
        guard !session.connectedPeers.isEmpty else { return }
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
            guard self.mode == .nearby, self.active else { return }
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
        DispatchQueue.main.async {
            guard self.mode == .nearby, self.active else { return }
            self.status = "Discovery unavailable. Enable Local Network access in Settings. \(error.localizedDescription)"
        }
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
            self.finishConnection(name: peer.displayName, receiver: status)
        }
    }

    private func finishConnection(name: String, receiver: ReceiverStatus) {
        let newlyConnected = connectedName == nil
        timeout?.cancel()
        connectedName = name
        connecting = false
        mouseControlEnabled = receiver.mouseControlEnabled
        status = "Connected securely"
        retryCount = 0
        lastDirectStatusAt = Date()
        if newlyConnected {
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.direct != nil, Date().timeIntervalSince(self.lastDirectStatusAt) > 8 {
                    self.direct?.close()
                } else {
                    self.send(MouseCommand(.heartbeat))
                }
            }
        }
    }

    private func savedDirectKey() -> String? {
        PairingKeychain.read(directKeyAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func connectDirect(keyInput: String = "", manual: Bool = false) -> Bool {
        guard mode != .nearby, active, !connecting, connectedName == nil else { return false }
        let input = keyInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let savedKey = savedDirectKey()
        guard let key = input.isEmpty ? savedKey : input, PairingSecrets.isValidToken(key) else {
            status = "Copy the connection key from RemotePad on your Mac."
            return false
        }
        var connection: NWConnection?
        if mode != .usb {
            guard let host = Self.host(from: vpnAddress) else {
                status = "Enter the Mac’s IP address or DNS name without a port or URL."
                return false
            }
            connection = NWConnection(host: host, port: DirectConnection.vpnPort, using: DirectConnection.parameters(key: key))
        }
        if manual {
            retryWork?.cancel()
            retryCount = 0
            manuallyDisconnected = false
        }
        let phoneID = DeviceIdentity.identifier(key: "deviceID." + mode.rawValue)
        directAttempt = DirectAttempt(key: key, phoneID: phoneID, remembered: input.isEmpty || input == savedKey ? remembered : nil)
        connecting = true
        if let connection {
            status = "Connecting over \(mode.label)…"
            setDirectTimeout(12)
            startDirect(connection)
        } else {
            startUSBListener(key: key)
        }
        return true
    }

    private static func host(from input: String) -> NWEndpoint.Host? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
        if let v4 = IPv4Address(ip) { return .ipv4(v4) }
        if let v6 = IPv6Address(ip) { return .ipv6(v6) }
        guard address.utf8.count <= 253,
              address.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$"#,
                            options: .regularExpression) != nil else { return nil }
        return .name(address, nil)
    }

    private func startUSBListener(key: String) {
        let parameters = DirectConnection.parameters(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: DirectConnection.usbPort)
        do {
            let listener = try NWListener(using: parameters, on: DirectConnection.usbPort)
            directListener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.directListener === listener else { return }
                switch state {
                case .ready:
                    self.status = "Waiting for the Mac. Click Start USB in RemotePad on the Mac."
                case .failed:
                    self.directFailed("Could not start USB mode. Cancel and try again.", retry: false)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.directListener === listener, self.direct == nil else {
                    connection.cancel()
                    return
                }
                self.startDirect(connection)
                self.setDirectTimeout(5)
            }
            listener.start(queue: .main)
        } catch {
            directFailed("Could not start USB mode. Try again.", retry: false)
        }
    }

    private func setDirectTimeout(_ seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.direct?.close() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func startDirect(_ connection: NWConnection) {
        let link = DirectConnection(connection)
        direct = link
        link.onReady = { [weak self, weak link] in
            guard let self, let link, let attempt = self.directAttempt else { return }
            self.directAttempt?.started = true
            let request = PairingRequest(phoneID: attempt.phoneID, macID: attempt.remembered?.macID,
                                         automatic: attempt.remembered != nil)
            let hello = DirectPairingRequest(pairing: request, name: UIDevice.current.name)
            guard let data = try? JSONEncoder().encode(hello) else { link.close(); return }
            link.send(data)
            self.status = request.automatic ? "Verifying your remembered Mac…" : "Approve the connection on your Mac."
            self.setDirectTimeout(request.automatic ? 8 : 28)
        }
        link.onMessage = { [weak self] data in self?.receiveDirect(data) }
        link.onClose = { [weak self, weak link] in
            guard let self, let link, self.direct === link, let attempt = self.directAttempt else { return }
            if self.mode == .usb, !attempt.started {
                self.direct = nil
                self.timeout?.cancel()
                return
            }
            let hint = attempt.started
                ? "Connection ended. If pairing was revoked, forget this Mac in Settings and pair again."
                : "Could not connect. Check the VPN, Mac address, connection key, and Mac settings."
            self.directFailed(hint, retry: attempt.remembered != nil || self.connectedName != nil)
        }
        link.start()
    }

    private func directFailed(_ hint: String, retry: Bool) {
        dragging = false
        endSession()
        status = hint
        if retry { scheduleReconnect() }
    }

    private func receiveDirect(_ data: Data) {
        guard let attempt = directAttempt else { return }
        if let remembered = attempt.remembered, !attempt.verified, let challenge = PairingChallenge.decode(data),
           challenge.macID == remembered.macID, PairingSecrets.matches(challenge.serverProof,
               PairingSecrets.proof(token: remembered.token, challenge: challenge, phoneID: attempt.phoneID, role: "mac")) {
            let proof = PairingProof(phoneID: attempt.phoneID, digest: PairingSecrets.proof(
                token: remembered.token, challenge: challenge, phoneID: attempt.phoneID))
            guard let encoded = try? JSONEncoder().encode(proof) else { direct?.close(); return }
            directAttempt?.verified = true
            direct?.send(encoded)
            return
        }
        if attempt.remembered == nil, connectedName == nil, let grant = PairingGrant.decode(data) {
            directAttempt?.grant = grant
            return
        }
        guard let receiver = ReceiverStatus.decode(data), attempt.remembered == nil || attempt.verified else {
            direct?.close()
            return
        }
        if connectedName == nil, attempt.remembered == nil {
            let saved = PairingKeychain.save(Data(attempt.key.utf8), account: directKeyAccount)
            hasDirectKey = saved || hasDirectKey
            if saved {
                PairingKeychain.remove(grantAccount)
                remembered = nil
                if let grant = attempt.grant, let encoded = try? JSONEncoder().encode(grant),
                   PairingKeychain.save(encoded, account: grantAccount) { remembered = grant }
                rememberedMacName = remembered?.name
            }
        }
        finishConnection(name: (attempt.remembered ?? attempt.grant)?.name ?? "Mac", receiver: receiver)
    }
    func session(_ session: MCSession, didReceive: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
