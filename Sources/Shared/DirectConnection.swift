import Foundation
import Network
import Security

public final class DirectConnection {
    public static let vpnPort: NWEndpoint.Port = 49373
    public static let usbPort: NWEndpoint.Port = 49374
    private static let maximumFrameSize = 1024
    private let connection: NWConnection
    private var closed = false
    public var onReady: (() -> Void)?
    public var onMessage: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public static func parameters(key: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let cipher = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(options, cipher)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        let secret = Data(key.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("RemotePad/direct/1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    public static func usbListener(key: String) throws -> NWListener {
        let options = parameters(key: key)
        options.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: usbPort)
        return try NWListener(using: options)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                if !self.closed { self.receiveHeader() }
            case .failed, .cancelled:
                self.close()
            default: break
            }
        }
        connection.start(queue: .main)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        let notify = onClose
        onClose = nil
        onMessage = nil
        onReady = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        notify?()
    }

    public func send(_ message: Data) {
        guard !closed, (1...Self.maximumFrameSize).contains(message.count) else { return }
        var length = UInt16(message.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(message)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func receiveHeader() {
        receive(2) { [weak self] header in
            guard let self else { return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard (1...Self.maximumFrameSize).contains(length) else { self.close(); return }
            self.receive(length) { [weak self] message in
                guard let self, let onMessage = self.onMessage else { return }
                onMessage(message)
                if self.onMessage != nil { self.receiveHeader() }
            }
        }
    }

    private func receive(_ count: Int, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard error == nil, let data, data.count == count else { self?.close(); return }
            completion(data)
        }
    }
}

public struct DirectPairingRequest: Codable {
    public let pairing: PairingRequest
    public let name: String

    public init(pairing: PairingRequest, name: String) {
        self.pairing = pairing
        self.name = PeerNaming.displayName(name)
    }

    public static func decode(_ data: Data) -> Self? {
        guard data.count <= 512, let request = try? JSONDecoder().decode(Self.self, from: data),
              request.pairing.kind == "pairingRequest", UUID(uuidString: request.pairing.phoneID) != nil,
              request.name == PeerNaming.displayName(request.name),
              !request.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return request
    }
}
