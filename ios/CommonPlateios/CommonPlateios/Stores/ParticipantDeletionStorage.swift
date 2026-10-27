import Foundation
import Security

struct ParticipantDeletionContext: Codable, Equatable {
    let freezeID: String
    let participantID: String
    let identityBinding: String
    let origin: String
    var operationID: String?
    var namespace: String?
    var attestedLedger: String?

    var isValid: Bool {
        UUID(uuidString: freezeID) != nil &&
            ParticipantAuthorityShape.isCanonicalParticipantIdentifier(participantID) &&
            UUID(uuidString: identityBinding) != nil && !origin.isEmpty &&
            (operationID == nil || UUID(uuidString: operationID!) != nil) &&
            (namespace == nil || ParticipantDeletionStatus.isNamespaceBinding(namespace!)) &&
            (attestedLedger == nil || RequestOperationAuthorityIdentity.isValidLedger(attestedLedger!)) &&
            ((operationID == nil) == (namespace == nil)) &&
            (attestedLedger == nil || namespace != nil)
    }
}

struct ParticipantDeletionRecord: Codable, Equatable {
    enum Stage: String, Codable { case active, completing, completedCleanupPending }
    var context: ParticipantDeletionContext
    var stage: Stage
    var status: ParticipantDeletionStatus?
    var capability: String?

    var isValid: Bool {
        guard context.isValid else { return false }
        if stage == .completedCleanupPending {
            return context.operationID != nil && context.namespace != nil &&
                capability == nil && status == nil
        }
        if let status {
            guard context.operationID != nil, context.namespace != nil,
                  (try? status.validated(
                operationID: context.operationID, namespace: context.namespace
            )) != nil else { return false }
        } else if context.operationID != nil { return false }
        if stage == .completing {
            return status?.phase == .authorized && context.operationID != nil && capability?.isEmpty == false
        }
        return capability == nil || (status?.phase == .authorized && capability?.isEmpty == false)
    }

    var cleanupJournal: Self {
        Self(context: context, stage: .completedCleanupPending, status: nil, capability: nil)
    }
}

enum ParticipantDeletionRecordLoad {
    case absent
    case record(ParticipantDeletionRecord)
    case unavailable
}

protocol ParticipantDeletionSecureStorage {
    func load() -> ParticipantDeletionRecordLoad
    func save(_ record: ParticipantDeletionRecord) throws
    func remove() throws
}

struct KeychainParticipantDeletionStorage: ParticipantDeletionSecureStorage {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.commonplatenyu.participant.deletion",
            kSecAttrAccount as String: "operation-v1",
        ]
    }

    func load() -> ParticipantDeletionRecordLoad {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &value)
        if result == errSecItemNotFound { return .absent }
        guard result == errSecSuccess, let data = value as? Data,
              let record = try? JSONDecoder().decode(ParticipantDeletionRecord.self, from: data),
              record.isValid else { return .unavailable }
        return .record(record)
    }

    func save(_ record: ParticipantDeletionRecord) throws {
        guard record.isValid else { throw ParticipantDeletionError.storageUnavailable }
        let data = try JSONEncoder().encode(record)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw ParticipantDeletionError.storageUnavailable
            }
        } else if result != errSecSuccess {
            throw ParticipantDeletionError.storageUnavailable
        }
        guard case .record(let persisted) = load(), persisted == record else {
            throw ParticipantDeletionError.storageUnavailable
        }
    }

    func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound,
              case .absent = load() else { throw ParticipantDeletionError.storageUnavailable }
    }
}

struct ParticipantDeletionFreeze {
    static let key = "com.commonplate.participant.deletion.freeze.v1"
    let defaults: UserDefaults

    var isPresent: Bool { defaults.object(forKey: Self.key) != nil }

    func write(_ id: String) throws {
        guard !isPresent || defaults.string(forKey: Self.key) == id else {
            throw ParticipantDeletionError.storageUnavailable
        }
        defaults.set(id, forKey: Self.key)
        guard defaults.string(forKey: Self.key) == id else {
            throw ParticipantDeletionError.storageUnavailable
        }
    }

    func remove(_ id: String) throws {
        guard !isPresent || defaults.string(forKey: Self.key) == id else {
            throw ParticipantDeletionError.storageUnavailable
        }
        defaults.removeObject(forKey: Self.key)
        guard !isPresent else { throw ParticipantDeletionError.storageUnavailable }
    }
}
