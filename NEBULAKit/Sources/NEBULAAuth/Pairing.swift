import CryptoKit
import Foundation
import NEBULACore
import NEBULANetwork

/// The NEBULA server this app is paired with (no secrets: the gateway address, the device id, the pinned server key).
public struct ServerProfile: Codable, Sendable, Equatable {
    public var gatewayURL: URL
    public var deviceID: String
    public var serverKey: String  // base64 X9.63 P-256
    public var serverFingerprint: String
    public var deviceName: String
    public var pairedAt: Date
    public var approved: Bool

    static let account = "server.profile"

    public static func load() -> ServerProfile? {
        guard let d = try? Keychain.get(account) else { return nil }
        return try? JSONDecoder().decode(ServerProfile.self, from: d)
    }

    public func save() throws {
        try Keychain.set(try JSONEncoder().encode(self), account: Self.account, protection: .afterFirstUnlock)
    }

    public static func clear() { Keychain.delete(account) }
}

/// A scanned / pasted pairing link: nebula://pair?v=1&u=<gateway>&p=<pairing id>&c=<one-time code>&f=<fingerprint>
public struct PairingOffer: Sendable, Equatable {
    public var gatewayURL: URL
    public var pairingID: String
    public var code: String
    public var fingerprint: String

    public init?(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), comps.scheme == "nebula", comps.host == "pair" else {
            return nil
        }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["v"] == "1", let u = q["u"], let gw = URL(string: u), Self.allowedScheme(gw), gw.host() != nil,
              let p = q["p"], p.range(of: "^pr_[0-9a-f]{16}$", options: .regularExpression) != nil,
              let c = q["c"], (16...64).contains(c.count),
              let f = q["f"], f.range(of: "^[0-9a-f]{20}$", options: .regularExpression) != nil else { return nil }
        gatewayURL = gw
        pairingID = p
        code = c
        fingerprint = f
    }
}

extension PairingOffer {
    /// HTTPS always. DEBUG builds additionally accept plain http to a loopback test server (NEBULA_v1's
    /// scripts/test_instance.py);
    /// Release builds never do.
    static func allowedScheme(_ u: URL) -> Bool {
        if u.scheme == "https" { return true }
        #if DEBUG
        return u.scheme == "http" && ["127.0.0.1", "localhost"].contains(u.host() ?? "")
        #else
        return false
        #endif
    }
}

public enum PairingError: Error, LocalizedError, Sendable, Equatable {
    case invalidLink
    case serverMismatch
    case expired
    case rejected
    case incompatibleServer(api: Int)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLink: return String(localized: "This is not a valid NEBULA pairing code.")
        case .serverMismatch:
            return String(localized: "The server did not prove its identity with the key from the pairing code. Pairing was stopped for your security.")
        case .expired: return String(localized: "The pairing code has expired or was already used. Show a new one on your Mac.")
        case .rejected: return String(localized: "Pairing was rejected on the Mac.")
        case .incompatibleServer(let api):
            return String(localized: "This NEBULA server is not compatible with this app (server protocol \(api), the app supports \(PairingService.supportedAPI.lowerBound)–\(PairingService.supportedAPI.upperBound)). Update the app or the server.")
        case .api(let s): return s
        }
    }
}

private struct Hello: Codable, Sendable { var service: String; var version: String; var api: Int; var serverFingerprint: String }
private struct ClaimBody: Codable, Sendable {
    var pairingId, code, name, platform, model, appVersion, identityKey, confirmKey, keyProtection: String
    var identitySignature, confirmSignature: String
}
private struct ClaimResult: Codable, Sendable {
    var deviceId, status, verificationCode, serverKey, serverFingerprint, serverSignature: String
}

/// Pairing flow: verify the server, create device keys, prove possession, claim the offer, verify the server's answer.
public struct PairingService: Sendable {
    public struct Claimed: Sendable {
        public let profile: ServerProfile
        public let verificationCode: String
    }

    /// The gateway protocol level (`api` of `GET /api/app/hello`) this build speaks. It is the wire contract between
    /// the apps and the server, not the product version: the server reports `version` ("1.0.0") for display only, and a
    /// 1.x server keeps `api` unchanged until the app protocol changes in an incompatible way.
    public static let supportedAPI = 4...4

    public static func isCompatible(api: Int) -> Bool { supportedAPI.contains(api) }

    let keys: DeviceKeys

    public init(keys: DeviceKeys) { self.keys = keys }

    public func claim(_ offer: PairingOffer, deviceName: String, platform: String, model: String,
                      appVersion: String) async throws -> Claimed {
        let api = APIClient(baseURL: offer.gatewayURL, tokens: nil)
        let hello: Hello
        do { hello = try await api.publicGet("/api/app/hello") } catch let e as APIError {
            throw PairingError.api(e.message)
        }
        guard hello.service == "nebula", hello.serverFingerprint == offer.fingerprint else {
            throw PairingError.serverMismatch
        }
        // only after the server proved who it is: refuse a protocol this app cannot speak, before any key is created
        guard Self.isCompatible(api: hello.api) else { throw PairingError.incompatibleServer(api: hello.api) }
        let (ik, ck, protection) = try keys.create()
        let proof = Data(["nebula-app-pair/v1", offer.pairingID, ik, ck].joined(separator: "\n").utf8)
        let idSig = try keys.signWithIdentity(proof)
        // the confirm key needs the owner: Face ID / Touch ID / passcode once, at pairing
        let ctx = try await OwnerPresence.evaluate(reason: String(localized: "Confirm pairing with NEBULA"))
        let cfSig = try keys.confirm({ _ in proof }, withSecret: false, context: ctx).signature
        let body = ClaimBody(pairingId: offer.pairingID, code: offer.code, name: deviceName, platform: platform,
                             model: model, appVersion: appVersion, identityKey: ik, confirmKey: ck,
                             keyProtection: protection.rawValue, identitySignature: idSig, confirmSignature: cfSig)
        let r: ClaimResult
        do { r = try await api.publicPost("/api/app/pair/claim", body: body) } catch let e as APIError {
            keys.destroy()
            if e.code == "pairing_expired" { throw PairingError.expired }
            throw PairingError.api(e.message)
        }
        // the answer must come from the server whose fingerprint was on the owner's screen
        let ack = Data(["nebula-app-pair-ack/v1", offer.pairingID, r.deviceId,
                        DeviceKeys.sha256Hex(Data(ik.utf8))].joined(separator: "\n").utf8)
        guard Self.fingerprint(of: r.serverKey) == offer.fingerprint, r.serverFingerprint == offer.fingerprint,
              Self.verify(serverKey: r.serverKey, payload: ack, signature: r.serverSignature) else {
            keys.destroy()
            throw PairingError.serverMismatch
        }
        let profile = ServerProfile(gatewayURL: offer.gatewayURL, deviceID: r.deviceId, serverKey: r.serverKey,
                                    serverFingerprint: r.serverFingerprint, deviceName: deviceName, pairedAt: Date(),
                                    approved: false)
        try profile.save()
        return Claimed(profile: profile, verificationCode: r.verificationCode)
    }

    public static func fingerprint(of serverKeyB64: String) -> String? {
        guard let raw = Data(base64Encoded: serverKeyB64) else { return nil }
        return String(DeviceKeys.sha256Hex(raw).prefix(20))
    }

    public static func verify(serverKey: String, payload: Data, signature: String) -> Bool {
        guard let raw = Data(base64Encoded: serverKey), let sig = Data(base64Encoded: signature),
              let key = try? P256.Signing.PublicKey(x963Representation: raw),
              let s = try? P256.Signing.ECDSASignature(derRepresentation: sig) else { return false }
        return key.isValidSignature(s, for: payload)
    }
}
