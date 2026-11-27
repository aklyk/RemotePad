import AppKit
import MultipeerConnectivity
import Combine
import Network
import OSLog
#if canImport(RemotePadCore)
import RemotePadCore
#endif

final class MacReceiver: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    @Published var status = "Starting…"
    @Published var controller: String?
    @Published var pendingName: String?
    @Published var permission = false
    @Published private(set) var receivedCommands = 0
    @Published var lastAction = "Waiting for input"
    @Published var accepting = true
    @Published var rememberedPhones = UserDefaults.standard.stringArray(forKey: "trustedPhoneIDs")?.count ?? 0
    @Published private(set) var vpnEnabled = UserDefaults.standard.bool(forKey: "allowVPN")
    @Published private(set) var vpnStatus: String?
    @Published private(set) var usbEnabled = false
    @Published private(set) var usbStatus: String?
    @Published private(set) var directKeyAvailable = false
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
    private var terminationObserver: NSObjectProtocol?
    private var lastPacketAt = Date()
    private var commandCount = 0
    private enum DirectStage {
        case connecting, awaitingApproval(DirectPairingRequest), verifying(PairingChallenge, phoneID: String), approved
    }
    private var vpnListener: NWListener?
    private var usbProxy: Process?
    private var usbProbe: DirectConnection?
    private var usbProbeTimeout: DispatchWorkItem?
    private var direct: DirectConnection?
    private var directOverUSB = false
    private var directStage = DirectStage.connecting
    private var directPhoneName = ""
    private var directTimeout: DispatchWorkItem?
    private let directKeyAccount = "directAccessKey"

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
        updateRememberedCount()
        directKeyAvailable = PairingKeychain.read(directKeyAccount) != nil
        startVPN()
        status = "Ready to pair"
        permission = driver.permitted
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.receivedCommands != self.commandCount { self.receivedCommands = self.commandCount }
            let allowed = self.driver.permitted
            if self.permission != allowed {
                self.permission = allowed
                self.sendStatus()
            }
            // Release a held mouse button even if the network fails silently.
            if Date().timeIntervalSince(self.lastPacketAt) > 6 { self.driver.release() }
            if case .approved = self.directStage, Date().timeIntervalSince(self.lastPacketAt) > 10 {
                self.direct?.close()
            }
            self.tryUSB()
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                      object: nil, queue: .main) { [weak self] _ in
            self?.shutDown()
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        permissionTimer?.invalidate()
        if let usbProxy, usbProxy.isRunning { usbProxy.terminate() }
    }

    func requestPermission() {
        driver.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func sendStatus() {
        guard let data = try? JSONEncoder().encode(ReceiverStatus(mouseControlEnabled: permission, trackpadGestures: true)) else { return }
        if case .approved = directStage { direct?.send(data) }
        let peers = session.connectedPeers.filter { approvedPeers.contains($0) }
        guard !peers.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    func answer(_ allow: Bool) {
        if case .awaitingApproval(let request) = directStage {
            answerDirect(allow, request: request)
            return
        }
        invitationTimeout?.cancel()
        let handler = invitation
        if allow, let peer = pendingPeer { approvedPeers.insert(peer) }
        if allow, let request = pendingRequest, let peer = pendingPeer {
            grants[peer] = issueGrant(for: request.phoneID, direct: false)
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
        stopUSB()
        disconnect()
        stopVPN()
        for direct in [false, true] {
            let list = trustedList(direct: direct)
            for identifier in UserDefaults.standard.stringArray(forKey: list) ?? [] {
                PairingKeychain.remove(phoneAccount(identifier, direct: direct))
            }
            UserDefaults.standard.removeObject(forKey: list)
        }
        PairingKeychain.remove(directKeyAccount)
        directKeyAvailable = false
        updateRememberedCount()
        grants.removeAll()
        startVPN()
    }

    func disconnect() {
        direct?.close()
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

    func shutDown() {
        stopUSB()
        stopVPN()
        disconnect()
    }

    func setAccepting(_ value: Bool) {
        accepting = value
        if value {
            advertiser.startAdvertisingPeer()
            startVPN()
            status = "Ready to pair"
        } else {
            advertiser.stopAdvertisingPeer()
            stopVPN()
            stopUSB()
            disconnect()
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard self.availableForController else { invitationHandler(false, nil); return }
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
            guard self.approvedPeers.contains(peerID) || self.returningPhones[peerID] != nil else { return }
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
        beginControl(peer.displayName)
        if let grant = grants.removeValue(forKey: peer), let data = try? JSONEncoder().encode(grant) {
            try? session.send(data, toPeers: [peer], with: .reliable)
        }
    }

    private func beginControl(_ name: String) {
        controller = name
        status = "Connected securely"
        commandCount = 0
        receivedCommands = 0
        lastAction = "Waiting for input"
        lastPacketAt = Date()
        permission = driver.permitted
        sendStatus()
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
            self.handleCommand(command)
        }
    }

    private func handleCommand(_ command: MouseCommand) {
        lastPacketAt = Date()
        if command.action == .heartbeat { sendStatus(); return }
        if command.action == .stopScroll { driver.perform(command); return }
        commandCount += 1
        driver.perform(command)
        if NavigationShortcut.identifier(for: command.action) != nil {
            let result = !permission ? "accessibility-blocked" : driver.lastIssue ?? "sent"
            Self.gestureLog.notice("Navigation \(command.action.rawValue, privacy: .public): \(result, privacy: .public)")
        }
        let action: String
        if let issue = driver.lastIssue { action = issue }
        else if !permission { action = "Input blocked: enable Accessibility" }
        else if let gesture = Self.gestureNames[command.action] { action = gesture }
        else {
            switch command.action {
            case .move, .leftClick, .rightClick, .doubleClick, .dragStart: action = "Receiving input"
            default: return
            }
        }
        if lastAction != action { lastAction = action }
    }

    private static let gestureLog = Logger(subsystem: "com.remotepad.mac", category: "Gestures")
    private static let gestureNames: [MouseCommand.Action: String] = [
        .nextSpace: "Next desktop space", .previousSpace: "Previous desktop space",
        .missionControl: "Mission Control", .appWindows: "Application windows", .showDesktop: "Show Desktop",
        .showApplications: "Apps", .lookUp: "Look Up", .notificationCenter: "Notification Center",
        .previousPage: "Previous page", .nextPage: "Next page", .smartZoom: "Smart Zoom",
        .scroll: "Scrolling", .magnify: "Pinch to zoom", .rotate: "Rotate"
    ]

    private var availableForController: Bool {
        accepting && direct == nil && !reserved && controller == nil && invitation == nil && session.connectedPeers.isEmpty
    }

    private func trustedList(direct: Bool) -> String {
        direct ? "trustedDirectPhoneIDs" : "trustedPhoneIDs"
    }

    private func phoneAccount(_ id: String, direct: Bool) -> String {
        (direct ? "directPhone." : "phone.") + id
    }

    private func updateRememberedCount() {
        rememberedPhones = [false, true].reduce(0) { count, direct in
            count + (UserDefaults.standard.stringArray(forKey: trustedList(direct: direct))?.count ?? 0)
        }
    }

    private func issueGrant(for phoneID: String, direct: Bool) -> PairingGrant? {
        guard let token = PairingKeychain.newToken(),
              PairingKeychain.save(Data(token.utf8), account: phoneAccount(phoneID, direct: direct)) else { return nil }
        let list = trustedList(direct: direct)
        var ids = Set(UserDefaults.standard.stringArray(forKey: list) ?? [])
        ids.insert(phoneID)
        UserDefaults.standard.set(Array(ids), forKey: list)
        updateRememberedCount()
        return PairingGrant(macID: macID, name: direct ? PeerNaming.displayName(computerName) : computerName, token: token)
    }

    private func directKey() -> String? {
        guard let data = PairingKeychain.read(directKeyAccount),
              let key = String(data: data, encoding: .utf8), PairingSecrets.isValidToken(key) else { return nil }
        return key
    }

    private func prepareDirectKey() -> String? {
        if let key = directKey() { return key }
        guard let key = PairingKeychain.newToken(),
              PairingKeychain.save(Data(key.utf8), account: directKeyAccount) else { return nil }
        directKeyAvailable = true
        return key
    }

    func copyDirectKey() {
        guard let key = directKey() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    func setVPNEnabled(_ enabled: Bool) {
        vpnEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "allowVPN")
        if enabled { startVPN() }
        else { stopVPN() }
    }

    private func startVPN() {
        guard accepting, vpnEnabled, vpnListener == nil else { return }
        guard let key = prepareDirectKey() else {
            vpnStatus = "Could not save the connection key in Keychain."
            return
        }
        do {
            let listener = try NWListener(using: DirectConnection.parameters(key: key), on: DirectConnection.vpnPort)
            vpnListener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.vpnListener === listener else { return }
                switch state {
                case .ready:
                    self.vpnStatus = "Listening on TCP port \(DirectConnection.vpnPort.rawValue)."
                case .failed(let error):
                    self.stopVPN()
                    self.vpnStatus = "Could not open the VPN listener: \(error.localizedDescription)"
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.vpnListener === listener else { connection.cancel(); return }
                self.startDirect(connection, overUSB: false)
            }
            listener.start(queue: .main)
        } catch {
            vpnStatus = "Could not open the VPN listener: \(error.localizedDescription)"
        }
    }

    private func stopVPN() {
        if !directOverUSB { direct?.close() }
        vpnListener?.cancel()
        vpnListener = nil
        vpnStatus = nil
    }

    func startUSB() {
        guard accepting, usbProxy == nil else { return }
        guard let iproxy = ["/opt/homebrew/bin/iproxy", "/usr/local/bin/iproxy"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            usbStatus = "Install the USB helper with: brew install libusbmuxd"
            return
        }
        guard prepareDirectKey() != nil else {
            usbStatus = "Could not save the connection key in Keychain."
            return
        }
        let proxy = Process()
        if let relay = Bundle.main.url(forAuxiliaryExecutable: "RemotePadUSBRelay") {
            proxy.executableURL = relay
            proxy.arguments = [String(Self.usbProxyPort.rawValue), String(DirectConnection.usbPort.rawValue)]
        } else {
            proxy.executableURL = URL(fileURLWithPath: iproxy)
            proxy.arguments = ["--local", "--source", "127.0.0.1", "\(Self.usbProxyPort.rawValue):\(DirectConnection.usbPort.rawValue)"]
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "USBMUXD_SOCKET_ADDRESS")
        proxy.environment = environment
        proxy.standardOutput = FileHandle.nullDevice
        proxy.standardError = FileHandle.nullDevice
        proxy.terminationHandler = { [weak self] stopped in
            DispatchQueue.main.async {
                guard let self, self.usbProxy === stopped else { return }
                self.stopUSB()
                self.usbStatus = "The USB helper stopped. Check that local TCP port \(Self.usbProxyPort.rawValue) is free and try again."
            }
        }
        do {
            try proxy.run()
            usbProxy = proxy
            usbEnabled = true
            usbStatus = "Waiting for RemotePad on the connected iPhone."
            tryUSB()
        } catch {
            usbStatus = "Could not start the USB helper: \(error.localizedDescription)"
        }
    }

    private static let usbProxyPort: NWEndpoint.Port = 49375

    func stopUSB() {
        usbProbe?.close()
        if directOverUSB { direct?.close() }
        let proxy = usbProxy
        usbProxy = nil
        if let proxy, proxy.isRunning { proxy.terminate() }
        usbEnabled = false
        usbStatus = nil
    }

    private func tryUSB() {
        guard usbProxy?.isRunning == true, usbProbe == nil, availableForController, let key = directKey() else { return }
        let connection = NWConnection(host: "127.0.0.1", port: Self.usbProxyPort,
                                      using: DirectConnection.parameters(key: key, usb: true))
        let candidate = DirectConnection(connection)
        usbProbe = candidate
        candidate.onClose = { [weak self] in self?.clearUSBProbe() }
        candidate.onReady = { [weak self, weak candidate] in
            guard let self, let candidate, self.usbProbe === candidate else { return }
            self.clearUSBProbe()
            guard self.availableForController else { candidate.close(); return }
            self.acceptDirect(candidate, overUSB: true)
        }
        let timeout = DispatchWorkItem { [weak candidate] in candidate?.close() }
        usbProbeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        candidate.start()
    }

    private func clearUSBProbe() {
        usbProbeTimeout?.cancel()
        usbProbeTimeout = nil
        usbProbe = nil
    }

    private func startDirect(_ connection: NWConnection, overUSB: Bool) {
        guard availableForController else { connection.cancel(); return }
        let link = DirectConnection(connection)
        acceptDirect(link, overUSB: overUSB)
        link.start()
    }

    private func acceptDirect(_ link: DirectConnection, overUSB: Bool) {
        direct = link
        directOverUSB = overUSB
        directStage = .connecting
        link.onMessage = { [weak self] message in self?.receiveDirect(message) }
        link.onClose = { [weak self] in
            guard let self else { return }
            self.directTimeout?.cancel()
            self.direct = nil
            self.directStage = .connecting
            self.directOverUSB = false
            self.pendingName = nil
            self.controller = nil
            self.driver.release()
            self.status = self.accepting ? "Ready to pair" : "Paused"
            if overUSB, self.usbEnabled { self.usbStatus = "Waiting for RemotePad on the connected iPhone." }
        }
        setDirectTimeout(5)
    }

    private func setDirectTimeout(_ seconds: Double) {
        directTimeout?.cancel()
        let work = DispatchWorkItem { [weak direct] in direct?.close() }
        directTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func receiveDirect(_ message: Data) {
        switch directStage {
        case .connecting:
            guard let request = DirectPairingRequest.decode(message) else { direct?.close(); return }
            directPhoneName = request.name
            if directOverUSB { usbStatus = "iPhone found over USB." }
            if request.pairing.automatic {
                authenticateDirect(request.pairing)
            } else {
                directStage = .awaitingApproval(request)
                pendingName = request.name
                setDirectTimeout(25)
                NSApp.activate(ignoringOtherApps: true)
            }
        case .awaitingApproval:
            direct?.close()
        case .verifying(let challenge, let phoneID):
            guard let proof = PairingProof.decode(message), proof.phoneID == phoneID,
                  let token = directPhoneToken(phoneID),
                  PairingSecrets.matches(proof.digest, PairingSecrets.proof(token: token, challenge: challenge, phoneID: phoneID))
            else { direct?.close(); return }
            approveDirect()
        case .approved:
            guard let command = MouseCommand.decode(message) else { return }
            handleCommand(command)
        }
    }

    private func directPhoneToken(_ id: String) -> String? {
        PairingKeychain.read(phoneAccount(id, direct: true)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func authenticateDirect(_ request: PairingRequest) {
        guard request.macID == macID, let token = directPhoneToken(request.phoneID) else { direct?.close(); return }
        let unsigned = PairingChallenge(macID: macID)
        let challenge = PairingChallenge(macID: macID, nonce: unsigned.nonce,
            serverProof: PairingSecrets.proof(token: token, challenge: unsigned, phoneID: request.phoneID, role: "mac"))
        guard let data = try? JSONEncoder().encode(challenge) else { direct?.close(); return }
        directStage = .verifying(challenge, phoneID: request.phoneID)
        setDirectTimeout(5)
        direct?.send(data)
    }

    private func answerDirect(_ allow: Bool, request: DirectPairingRequest) {
        guard allow else { direct?.close(); return }
        if let grant = issueGrant(for: request.pairing.phoneID, direct: true),
           let data = try? JSONEncoder().encode(grant) { direct?.send(data) }
        approveDirect()
    }

    private func approveDirect() {
        directTimeout?.cancel()
        pendingName = nil
        directStage = .approved
        beginControl(directPhoneName)
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
