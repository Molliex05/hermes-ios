import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The iPhone's key for approving a Noriven email send (docs/noriven-courriel-contrat.md). Made in the Secure Enclave: the
/// private key never leaves it, every signature asks for Face ID, and adding a face to Face ID voids it (a new key must
/// then be registered). Only an opaque handle that this Secure Enclave alone can use is kept in the keychain. Maxime
/// registers the public key in Noriven's Dashboard; without a signature from it, the server sends nothing.
enum ApprovalKey {
    private static let service = "org.hermesios.approval-key", account = "noriven-email"

    struct Public: Equatable {
        /// SPKI DER, base64: what the Dashboard asks for.
        let spki: String
        /// SHA-256 of the SPKI, hex: the `key_id` of each approval.
        let keyID: String
        /// The first 8 characters of `keyID`, grouped: to compare with what the Dashboard shows.
        var shortCode: String { String(keyID.prefix(4)) + " " + String(keyID.dropFirst(4).prefix(4)) }
    }

    enum Failure: LocalizedError {
        case unavailable, missing, cancelled
        var errorDescription: String? {
            switch self {
            case .unavailable: "Cet iPhone ne peut pas créer de clé d’approbation (Face ID et un code sont requis)."
            case .missing: "Aucune clé d’approbation sur cet iPhone : crée-la dans Réglages › Courriels Noriven, puis ajoute-la au Dashboard."
            case .cancelled: "Envoi annulé."
            }
        }
    }

    static var current: Public? { (try? stored(context: nil)).map { publicPart(of: $0) } }

    /// A new key, replacing the old one (which then stops working everywhere).
    @discardableResult
    static func create() throws -> Public {
        guard SecureEnclave.isAvailable,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil),
              let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else { throw Failure.unavailable }
        remove()
        var item = query()
        item[kSecValueData as String] = key.dataRepresentation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        return publicPart(of: key)
    }

    static func remove() { SecItemDelete(query() as CFDictionary) }

    /// The signed approval for one draft, as the server expects it. Asks for Face ID.
    static func approve(draftID: String, fingerprint: String, reason: String) throws -> JSONValue {
        let context = LAContext()
        context.localizedReason = reason
        guard let key = try stored(context: context) else { throw Failure.missing }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unavailable }
        let nonce = Data(bytes).base64EncodedString(), signedAt = Int(Date().timeIntervalSince1970)
        let message = SendApproval.message(draftID: draftID, fingerprint: fingerprint, signedAt: signedAt, nonce: nonce)
        let signature: P256.Signing.ECDSASignature
        do { signature = try key.signature(for: message) }
        catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) { throw Failure.cancelled }
        catch { throw Failure.cancelled }                       // a refused or interrupted Face ID never sends
        return .object(["key_id": .string(publicPart(of: key).keyID), "signed_at": .number(Double(signedAt)),
                        "nonce": .string(nonce), "signature": .string(signature.derRepresentation.base64EncodedString())])
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func stored(context: LAContext?) throws -> SecureEnclave.P256.Signing.PrivateKey? {
        var q = query()
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: context)
    }

    private static func publicPart(of key: SecureEnclave.P256.Signing.PrivateKey) -> Public {
        let der = key.publicKey.derRepresentation
        return Public(spki: der.base64EncodedString(), keyID: SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
    }
}
