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

/// Fires at the threshold while fingers are still down, once per swipe.
public struct NavigationStroke {
    private var fired = false
    public init() {}
    public mutating func consume(x: Double, y: Double) -> MouseCommand.Action? {
        guard !fired, let action = TrackpadNavigation.action(x: x, y: y) else { return nil }
        fired = true
        return action
    }
}

public struct NavigationShortcut: Equatable {
    public let keyCode: UInt16
    public let flags: UInt64
    public init(keyCode: UInt16, flags: UInt64) { self.keyCode = keyCode; self.flags = flags }
    public static func identifier(for action: MouseCommand.Action) -> String? {
        switch action {
        case .previousSpace: return "79"
        case .nextSpace: return "81"
        case .missionControl: return "32"
        case .appWindows: return "33"
        default: return nil
        }
    }
    public static func resolve(_ action: MouseCommand.Action, preferences: [String: Any]) -> NavigationShortcut? {
        guard let identifier = identifier(for: action) else { return nil }
        let defaultKeys: [String: UInt16] = ["79": 123, "81": 124, "32": 126, "33": 125]
        let fallback = NavigationShortcut(keyCode: defaultKeys[identifier]!, flags: 1 << 18)
        guard let entry = preferences[identifier] as? [String: Any] else { return fallback }
        if let enabled = entry["enabled"] as? NSNumber, !enabled.boolValue { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
              parameters[1].intValue >= 0, parameters[1].intValue <= 127,
              parameters[2].int64Value >= 0, parameters[2].uint64Value <= UInt64(UInt32.max) else { return nil }
        return NavigationShortcut(keyCode: parameters[1].uint16Value, flags: parameters[2].uint64Value)
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

public struct PairingRequest: Codable {
    public let kind: String
    public let phoneID: String
    public let macID: String?
    public let automatic: Bool
    public init(phoneID: String, macID: String? = nil, automatic: Bool = false) {
        kind = "pairingRequest"
        self.phoneID = phoneID; self.macID = macID; self.automatic = automatic
    }
    public static func decode(_ data: Data?) -> Self? {
        guard let data, data.count <= 512, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.kind == "pairingRequest", UUID(uuidString: value.phoneID) != nil else { return nil }
        return value
    }
}

public struct PairingGrant: Codable, Equatable {
    public let kind: String
    public let macID: String
    public let name: String
    public let token: String
    public init(macID: String, name: String, token: String) {
        kind = "pairingGrant"; self.macID = macID; self.name = name; self.token = token
    }
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= 1024, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.kind == "pairingGrant", UUID(uuidString: value.macID) != nil,
              PairingSecrets.isValidToken(value.token) else { return nil }
        return value
    }
}

// Pairing credentials never go into UserDefaults or the repository.
public enum PairingSecrets {
    public static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func matches(_ provided: String?, _ stored: String?) -> Bool {
        guard let provided, let stored, isValidToken(provided), isValidToken(stored) else { return false }
        return zip(provided.utf8, stored.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

import Security

public enum PairingKeychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.remotepad") + ".pairing"
    public static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    @discardableResult public static func save(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    public static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
    public static func newToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DeviceIdentity {
    public static func identifier(defaults: UserDefaults = .standard, key: String = "deviceID") -> String {
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }
}

import CryptoKit

public struct PairingChallenge: Codable {
    public let kind: String
    public let nonce: String
    public let macID: String
    public let serverProof: String
    public init(macID: String, nonce: String = UUID().uuidString, serverProof: String = "") {
        kind = "pairingChallenge"; self.nonce = nonce; self.macID = macID; self.serverProof = serverProof
    }
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= 512, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.kind == "pairingChallenge", UUID(uuidString: value.nonce) != nil,
              UUID(uuidString: value.macID) != nil, PairingSecrets.isValidToken(value.serverProof) else { return nil }
        return value
    }
}
public struct PairingProof: Codable {
    public let kind: String
    public let phoneID: String
    public let digest: String
    public init(phoneID: String, digest: String) { kind = "pairingProof"; self.phoneID = phoneID; self.digest = digest }
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= 512, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.kind == "pairingProof", UUID(uuidString: value.phoneID) != nil,
              PairingSecrets.isValidToken(value.digest) else { return nil }
        return value
    }
}
extension PairingSecrets {
    public static func proof(token: String, challenge: PairingChallenge, phoneID: String, role: String = "phone") -> String {
        let data = Data((role + "|" + challenge.nonce + "|" + challenge.macID + "|" + phoneID).utf8)
        return HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
}
