//
//  ParticipantIdentityStorage.swift
//  CommonPlateios
//
// Installation-local memory of verified participant authority (W3-I1).
import Foundation
import Security

/// The complete identity the store consumes. The bearer authority exists in
/// this value only at the storage/store boundary and is never published.
struct ParticipantIdentityRecord: Codable, Equatable {
    let principal: String
    let authority: String
    let verifiedAt: Date
}

/// Canonical text shape of the backend's V1 authority credential. This is only
/// local shape validation: it does not and cannot authenticate the signature.
/// Participant existence, version, and signature validity remain backend truth.
enum ParticipantAuthorityShape {
    private static let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")

    /// The backend's canonical participant id: exactly 24 lowercase hex
    /// characters (`PARTICIPANT_ID_PATTERN` in `participantCredentials.ts`).
    /// Anything else names no participant.
    static func isCanonicalParticipantIdentifier(_ candidate: String) -> Bool {
        candidate.unicodeScalars.count == 24
            && candidate.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }

    /// The canonical participant id an authority credential leads with, or
    /// `nil` when its leading segment is not one. Local shape only: it proves
    /// nothing about the credential and is never itself a credential.
    static func participantIdentifier(ofAuthority authority: String) -> String? {
        guard let separator = authority.firstIndex(of: ".") else { return nil }
        let identifier = String(authority[authority.startIndex..<separator])
        return isCanonicalParticipantIdentifier(identifier) ? identifier : nil
    }

    static func isCanonical(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }

        let participantID = String(parts[0])
        guard isCanonicalParticipantIdentifier(participantID) else {
            return false
        }

        let versionText = String(parts[1])
        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        guard !versionText.isEmpty,
              versionText.first != "0",
              versionText.unicodeScalars.allSatisfy(asciiDigits.contains),
              let version = Int(versionText),
              (1...1_000_000).contains(version),
              String(version) == versionText else {
            return false
        }

        let signature = String(parts[2])
        let base64URLCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        // A SHA-256 digest is 32 bytes. Its unpadded base64url spelling is 43
        // characters, and the final character contains four data bits plus two
        // unused zero bits. Restricting that final character rejects alternate
        // non-canonical spellings of the same bytes without authenticating the
        // signature itself.
        let canonicalFinalCharacters = CharacterSet(charactersIn: "AEIMQUYcgkosw048")
        guard signature.count == 43,
              signature.unicodeScalars.allSatisfy(base64URLCharacters.contains),
              let finalScalar = signature.unicodeScalars.last else {
            return false
        }
        return canonicalFinalCharacters.contains(finalScalar)
    }
}

protocol ParticipantIdentityStorage {
    func loadValidIdentity() -> ParticipantIdentityRecord?
    @discardableResult func save(_ record: ParticipantIdentityRecord) -> Bool
    func clear()
    func deletionBinding(participantID: String) throws -> String
    func deleteCompletedIdentity(participantID: String, installationBinding: String) throws -> CompletedIdentityCleanup
}

enum CompletedIdentityCleanup { case removedOrAbsent, preservedForeign }

extension ParticipantIdentityStorage {
    func deletionBinding(participantID: String) throws -> String {
        throw ParticipantDeletionError.storageUnavailable
    }

    func deleteCompletedIdentity(participantID: String, installationBinding: String) throws -> CompletedIdentityCleanup {
        throw ParticipantDeletionError.storageUnavailable
    }
}

enum ParticipantAuthorityLoad {
    case absent
    case record(StoredParticipantAuthority)
    case unavailable
}

/// The Keychain half: the normalized principal, a random installation binding,
/// and the raw bearer.
/// Keeping the binding beside the credential prevents a surviving Keychain
/// item from being consumed by a later installation's new UserDefaults marker.
/// Keeping the principal here also prevents an editable UserDefaults marker
/// from relabeling valid bearer authority as a different participant.
struct StoredParticipantAuthority: Codable, Equatable {
    let principal: String
    let installationBinding: String
    let authority: String
}

protocol ParticipantAuthorityStorage {
    func load() -> StoredParticipantAuthority?
    @discardableResult func save(_ record: StoredParticipantAuthority) -> Bool
    func clear()
    func loadChecked() -> ParticipantAuthorityLoad
    func removeChecked() throws
}

extension ParticipantAuthorityStorage {
    func loadChecked() -> ParticipantAuthorityLoad { .unavailable }
    func removeChecked() throws { throw ParticipantDeletionError.storageUnavailable }
}

/// Raw authority storage. `AfterFirstUnlockThisDeviceOnly` keeps ordinary
/// launches usable while excluding backup/restore and device migration.
struct KeychainParticipantAuthorityStorage: ParticipantAuthorityStorage {
    private static let service = "org.commonplatenyu.participant"
    private static let account = "verified-participant-authority-v1"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() -> StoredParticipantAuthority? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let record = try? JSONDecoder().decode(StoredParticipantAuthority.self, from: data) else {
            return nil
        }
        return record
    }

    @discardableResult
    func save(_ record: StoredParticipantAuthority) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insertion = baseQuery
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    func loadChecked() -> ParticipantAuthorityLoad {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = result as? Data,
              let record = try? JSONDecoder().decode(StoredParticipantAuthority.self, from: data),
              ParticipantAuthorityShape.isCanonical(record.authority),
              UUID(uuidString: record.installationBinding) != nil else { return .unavailable }
        return .record(record)
    }

    func removeChecked() throws {
        let result = SecItemDelete(baseQuery as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound,
              case .absent = loadChecked() else { throw ParticipantDeletionError.storageUnavailable }
    }
}

/// Non-secret installation marker. UserDefaults is intentionally the other
/// half: it survives ordinary launches but is removed by uninstall. Restoration
/// requires this marker and the ThisDeviceOnly Keychain record to both exist and
/// carry the same random binding.
private struct ParticipantInstallationMarker: Codable, Equatable {
    let principal: String
    let installationBinding: String
    let verifiedAt: Date
}

struct UserDefaultsParticipantIdentityStorage: ParticipantIdentityStorage {
    static let key = "com.commonplate.participant.identity-binding"

    private let defaults: UserDefaults
    private let authorityStorage: ParticipantAuthorityStorage

    init(
        defaults: UserDefaults,
        authorityStorage: ParticipantAuthorityStorage = KeychainParticipantAuthorityStorage()
    ) {
        self.defaults = defaults
        self.authorityStorage = authorityStorage
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadValidIdentity() -> ParticipantIdentityRecord? {
        if ParticipantDeletionFreeze(defaults: defaults).isPresent {
            guard let data = defaults.data(forKey: Self.key),
                  let marker = try? Self.decoder.decode(ParticipantInstallationMarker.self, from: data),
                  case .record(let secured) = authorityStorage.loadChecked(),
                  secured.installationBinding == marker.installationBinding,
                  secured.principal == marker.principal else { return nil }
            return ParticipantIdentityRecord(
                principal: marker.principal, authority: secured.authority, verifiedAt: marker.verifiedAt
            )
        }
        guard defaults.object(forKey: Self.key) != nil else {
            // Expected after uninstall: a ThisDeviceOnly Keychain item may
            // survive locally, but without this installation's marker it is an
            // orphan and can never become authority for the new install.
            authorityStorage.clear()
            return nil
        }

        guard let markerData = defaults.data(forKey: Self.key),
              let marker = try? Self.decoder.decode(
                ParticipantInstallationMarker.self,
                from: markerData
              ),
              UUID(uuidString: marker.installationBinding)?.uuidString
                == marker.installationBinding,
              NYUEmailPolicy.normalize(marker.principal) == marker.principal,
              NYUEmailPolicy.isAllowed(marker.principal),
              let secured = authorityStorage.load(),
              secured.installationBinding == marker.installationBinding,
              secured.principal == marker.principal,
              ParticipantAuthorityShape.isCanonical(secured.authority) else {
            clear()
            return nil
        }

        return ParticipantIdentityRecord(
            principal: NYUEmailPolicy.normalize(marker.principal),
            authority: secured.authority,
            verifiedAt: marker.verifiedAt
        )
    }

    @discardableResult
    func save(_ record: ParticipantIdentityRecord) -> Bool {
        guard !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return false }
        let principal = NYUEmailPolicy.normalize(record.principal)
        guard NYUEmailPolicy.isAllowed(principal),
              ParticipantAuthorityShape.isCanonical(record.authority) else {
            clear()
            return false
        }

        let binding = UUID().uuidString
        let secured = StoredParticipantAuthority(
            principal: principal,
            installationBinding: binding,
            authority: record.authority
        )
        guard authorityStorage.save(secured) else {
            clear()
            return false
        }

        let marker = ParticipantInstallationMarker(
            principal: principal,
            installationBinding: binding,
            verifiedAt: record.verifiedAt
        )
        guard let markerData = try? Self.encoder.encode(marker) else {
            clear()
            return false
        }
        defaults.set(markerData, forKey: Self.key)
        return true
    }

    func clear() {
        guard !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        defaults.removeObject(forKey: Self.key)
        authorityStorage.clear()
    }

    func deletionBinding(participantID: String) throws -> String {
        guard let data = defaults.data(forKey: Self.key),
              let marker = try? Self.decoder.decode(ParticipantInstallationMarker.self, from: data),
              case .record(let secured) = authorityStorage.loadChecked(),
              secured.installationBinding == marker.installationBinding,
              secured.principal == marker.principal,
              ParticipantAuthorityShape.participantIdentifier(ofAuthority: secured.authority) == participantID else {
            throw ParticipantDeletionError.storageUnavailable
        }
        return secured.installationBinding
    }

    func deleteCompletedIdentity(participantID: String, installationBinding: String) throws -> CompletedIdentityCleanup {
        var marker: ParticipantInstallationMarker?
        if let stored = defaults.object(forKey: Self.key) {
            guard let data = stored as? Data,
                  let decoded = try? Self.decoder.decode(ParticipantInstallationMarker.self, from: data) else {
                throw ParticipantDeletionError.storageUnavailable
            }
            marker = decoded
            if decoded.installationBinding != installationBinding {
                guard case .record(let secured) = authorityStorage.loadChecked(),
                      secured.installationBinding == decoded.installationBinding,
                      secured.principal == decoded.principal,
                      let current = ParticipantAuthorityShape.participantIdentifier(ofAuthority: secured.authority),
                      current != participantID else { throw ParticipantDeletionError.identityChanged }
                return .preservedForeign
            }
        }
        switch authorityStorage.loadChecked() {
        case .unavailable:
            throw ParticipantDeletionError.storageUnavailable
        case .record(let secured):
            guard ParticipantAuthorityShape.participantIdentifier(ofAuthority: secured.authority) == participantID,
                  secured.installationBinding == installationBinding,
                  marker == nil || marker?.principal == secured.principal else {
                throw ParticipantDeletionError.identityChanged
            }
            try authorityStorage.removeChecked()
        case .absent:
            break
        }
        defaults.removeObject(forKey: Self.key)
        guard defaults.object(forKey: Self.key) == nil,
              case .absent = authorityStorage.loadChecked() else {
            throw ParticipantDeletionError.storageUnavailable
        }
        return .removedOrAbsent
    }
}
