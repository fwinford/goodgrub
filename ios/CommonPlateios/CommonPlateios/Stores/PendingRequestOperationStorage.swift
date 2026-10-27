//
//  PendingRequestOperationStorage.swift
//  CommonPlateios
//
// Durable installation-local memory of unresolved W3-D1 request-create
// operations. These are identity tombstones, not request history or a
// generalized offline queue: each exists only so the exact logical create
// begun before app/process termination can be resumed and reconciled against
// authoritative backend truth after relaunch, and each is retired the moment
// its own operation authoritatively resolves.
//
// W4-D2: more than one can exist. An installation can hold one participant's
// unresolved operation while a different, confirmed participant is current;
// that participant's own create lifecycle must never overwrite or retire the
// first one. Entries are therefore kept per operation, and retiring one
// retires only that one.
import Foundation

/// W4-D2: the backend operation authority a create was sent to.
///
/// `origin` is where the create was sent (the normalized configured base URL).
/// `ledger` is the backend-issued identity of the operation ledger behind it
/// (`GET /api/request-operation/authority`), which changes when the database
/// behind the same URL is reset or replaced — something a URL alone cannot
/// show. Neither is a credential; both are safe to persist.
struct RequestOperationAuthorityIdentity: Equatable {
    let origin: String
    let ledger: String

    private static let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")

    /// The backend's ledger identity shape: a lowercase hyphenated UUID
    /// (`requestOperationAuthority.ts`).
    static func isValidLedger(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.unicodeScalars.allSatisfy(lowercaseHex.contains) }
    }

    var isUsable: Bool {
        !origin.isEmpty && Self.isValidLedger(ledger)
    }
}

/// W4-D2 stable recovery identity: the minimum needed to reconcile one exact
/// issued operation against the one authority that may have received it,
/// independent of whether the detailed request payload can still be decoded.
///
/// `participantIdentifier` binds the operation to the requester participant
/// without persisting a credential: it is the canonical participant id that
/// leads the verified authority credential
/// (`ParticipantAuthorityShape.participantIdentifier(ofAuthority:)`), never
/// the bearer authority itself. It authenticates nothing on its own; it only
/// lets a restored record be compared for exact participant equality.
///
/// `operationAuthority` is `nil` when the record never recorded a ledger
/// authority — every pre-D2 record, and the first D2 candidate's records,
/// which recorded only a URL. No backend can then be trusted to reconcile it.
struct PendingRequestOperationIdentity: Equatable {
    /// The recovery-envelope version this build writes. Versioned
    /// independently of `PendingRequestOperationRecord.payloadVersion`: the
    /// request payload may evolve without making identity unreadable.
    /// Version 1 recorded only an origin; version 2 adds the ledger.
    static let recoveryVersion = 2

    let operationId: String
    let participantIdentifier: String
    let operationAuthority: RequestOperationAuthorityIdentity?

    private static let operationIdCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )

    /// Mirrors the backend's own `[A-Za-z0-9._-]{1,128}` operation-identity
    /// shape (`createRequestRoute.ts`).
    static func isValidOperationId(_ value: String) -> Bool {
        (1...128).contains(value.unicodeScalars.count)
            && value.unicodeScalars.allSatisfy(operationIdCharacters.contains)
    }

    /// Whether this identity can name exactly one operation and participant.
    /// An identity that fails this was corrupted, so what it originally named
    /// is unknown — it is identity-unavailable, never "someone else's" and
    /// never provably unused.
    var isUsable: Bool {
        Self.isValidOperationId(operationId)
            && ParticipantAuthorityShape.isCanonicalParticipantIdentifier(participantIdentifier)
            && (operationAuthority?.isUsable ?? true)
    }
}

/// The exact durable state D1/D2 needs to resume one unresolved create after
/// app/process termination — nothing more — as this build writes it.
///
/// `payload` is the exact `CreateRequestPayload` that was about to be sent,
/// frozen verbatim — enough to resubmit the identical payload under the same
/// `operationId` if the original transmission never reached the backend at
/// all. No unrelated request history, no raw credential, no claim token.
///
/// W4-R4 replaced a field-by-field mirror of the create fields with the
/// payload itself. The mirror had to be widened by hand for every new create
/// field, and a field someone forgot to add would have been silently dropped
/// from replay — reconstructing a *different* payload for the same logical
/// operation, which is exactly what W3-D1 exists to prevent. Freezing the
/// payload makes exact-payload identity structural instead of maintained:
/// whatever was submitted is what is replayed, including every structured
/// meal entry and the exact Dining Dollar cents.
///
/// `installationCredential` is deliberately excluded (see the encoding in
/// `RequestStore.createRequest`): it is store-owned installation identity
/// rather than request content, and it is re-supplied from the live provider
/// at replay time, so nothing credential-shaped is written to disk here.
///
/// W4-D2 layout: the identity fields and `recoveryVersion` sit at the top
/// level beside a separately versioned `payload`, so a payload this build
/// cannot decode never hides the identity.
struct PendingRequestOperationRecord: Equatable, Encodable {
    /// The request-payload version this build writes and can replay.
    static let payloadVersion = 1

    let operationId: String
    let participantIdentifier: String
    let operationAuthority: RequestOperationAuthorityIdentity
    let payload: CreateRequestPayload

    var identity: PendingRequestOperationIdentity {
        PendingRequestOperationIdentity(
            operationId: operationId,
            participantIdentifier: participantIdentifier,
            operationAuthority: operationAuthority
        )
    }

    private enum CodingKeys: String, CodingKey {
        case recoveryVersion, operationId, participantIdentifier
        case authorityOrigin, authorityLedger
        case payloadVersion, payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PendingRequestOperationIdentity.recoveryVersion, forKey: .recoveryVersion)
        try container.encode(operationId, forKey: .operationId)
        try container.encode(participantIdentifier, forKey: .participantIdentifier)
        try container.encode(operationAuthority.origin, forKey: .authorityOrigin)
        try container.encode(operationAuthority.ledger, forKey: .authorityLedger)
        try container.encode(Self.payloadVersion, forKey: .payloadVersion)
        try container.encode(payload, forKey: .payload)
    }
}

/// The exact pre-R4 create body, kept verbatim so a pending operation begun
/// by a pre-R4 build can still be restored as precisely what that build
/// submitted — never translated into the R4 structured shape. The pre-R4
/// record carried no menu path, no per-swipe meal entries, and no Dining
/// Dollar estimate, so any such translation would have to invent them.
///
/// Field names and order match the pre-R4 `CreateRequestPayload` exactly.
/// W4-D2: a pre-R4 record also predates recorded operation authority, so it
/// is never replayed (see `RequestStore.reconcilePendingCreateOperationIfNeeded`).
struct LegacyCreateRequestPayload: Encodable, Equatable {
    let vendor: String
    let food: String
    let pickupName: String
    let timing: RequestTimingWire
    let windowStart: Date?
    let mealSwipes: Int
    var installationCredential: String? = nil
}

/// A pending operation persisted by a pre-R4 build: the flat record shape
/// that build wrote (`operationId`, `participantIdentifier`, then the create
/// fields at top level, with `windowStart` omitted when absent). Decodes only
/// the payload half; identity is decoded separately.
private struct LegacyPayloadEnvelope: Decodable {
    let payload: LegacyCreateRequestPayload

    private enum CodingKeys: String, CodingKey {
        case vendor, food, pickupName, timing, windowStart, mealSwipes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payload = LegacyCreateRequestPayload(
            vendor: try container.decode(String.self, forKey: .vendor),
            food: try container.decode(String.self, forKey: .food),
            pickupName: try container.decode(String.self, forKey: .pickupName),
            timing: try container.decode(RequestTimingWire.self, forKey: .timing),
            windowStart: try container.decodeIfPresent(Date.self, forKey: .windowStart),
            mealSwipes: try container.decode(Int.self, forKey: .mealSwipes)
        )
    }
}

/// The identity half of any stored record shape. Reads only its own keys, so
/// nothing about the payload can make it fail.
private struct IdentityEnvelope: Decodable {
    let recoveryVersion: Int?
    let operationId: String
    let participantIdentifier: String
    /// Version 1's origin-only authority.
    let operationAuthority: String?
    let authorityOrigin: String?
    let authorityLedger: String?
}

/// The payload half of a pre-D2 R4 record or a W4-D2 record.
private struct CurrentPayloadEnvelope: Decodable {
    let payloadVersion: Int?
    let payload: CreateRequestPayload
}

/// The request payload a restored record carries, if this build can read it.
enum RestoredPendingRequestPayload: Equatable {
    /// The current `CreateRequestPayload` (an R4 record or a W4-D2 record).
    case current(CreateRequestPayload)
    /// A pre-R4 build's exact flat body.
    case legacy(LegacyCreateRequestPayload)
    /// Something is stored but this build cannot decode it. Never
    /// reconstructed or guessed at.
    case unreadable
}

/// One restored pending operation: its stable identity, and separately its
/// payload.
struct RestoredPendingRequestOperation: Equatable {
    let identity: PendingRequestOperationIdentity
    let payload: RestoredPendingRequestPayload
}

/// One durable entry. `identityUnavailable` means something is persisted whose
/// identity — including whose operation it is — cannot be read, so an
/// operation may exist server-side for anyone on this installation. It is
/// distinct from a restored entry whose payload is unreadable, which can still
/// be reconciled by identity.
enum PendingRequestOperationEntry: Equatable {
    case restored(RestoredPendingRequestOperation)
    case identityUnavailable
}

/// A single-entry summary of what storage holds, for inspection and tests.
/// Recovery never uses it: it reads every entry (`restoreAll()`).
enum PendingRequestOperationRestoration: Equatable {
    case absent
    case restored(RestoredPendingRequestOperation)
    case identityUnavailable
}

protocol PendingRequestOperationStorage: AnyObject {
    /// Every durable entry, in no meaningful order. The authoritative read
    /// `RequestStore` recovers from.
    func restoreAll() -> [PendingRequestOperationEntry]
    /// Adds `record` beside whatever else is stored. Returns `false` — and
    /// changes nothing — when it cannot be stored without disturbing entries
    /// already there.
    @discardableResult func save(_ record: PendingRequestOperationRecord) -> Bool
    /// Retires exactly the readable entry for `operationId`, and nothing else.
    /// An entry whose identity cannot be read is never matched.
    func clear(operationId: String)
}

extension PendingRequestOperationStorage {
    /// `absent` when nothing is stored, `identityUnavailable` when any entry's
    /// identity is unreadable, otherwise one restored entry.
    func restore() -> PendingRequestOperationRestoration {
        let entries = restoreAll()
        if entries.contains(.identityUnavailable) {
            return .identityUnavailable
        }
        guard case .restored(let restored)? = entries.first else {
            return .absent
        }
        return .restored(restored)
    }

    /// The current-representation record, if storage holds exactly that one
    /// entry. Inspection only.
    func load() -> PendingRequestOperationRecord? {
        let records = loadAll()
        return restoreAll().count == 1 ? records.first : nil
    }

    /// Every current-representation record storage holds. Inspection only.
    func loadAll() -> [PendingRequestOperationRecord] {
        restoreAll().compactMap { entry in
            guard case .restored(let restored) = entry,
                  case .current(let payload) = restored.payload,
                  let authority = restored.identity.operationAuthority else {
                return nil
            }
            return PendingRequestOperationRecord(
                operationId: restored.identity.operationId,
                participantIdentifier: restored.identity.participantIdentifier,
                operationAuthority: authority,
                payload: payload
            )
        }
    }
}

/// The app's real durable storage. UserDefaults, matching the existing
/// non-secret-marker pattern (`UserDefaultsParticipantIdentityStorage`,
/// `UserDefaultsPushInstallationStorage`): nothing persisted here is a
/// credential — `participantIdentifier` is a non-secret identity segment, the
/// authority is a non-secret origin and ledger identifier, and every other
/// field is ordinary request content the requester themselves entered.
///
/// Two keys. `collectionKey` holds this build's entries as an array of
/// independently encoded records, so one entry that cannot be read never
/// makes another unreadable. `singleRecordKey` is where earlier builds kept
/// their one record; it is read as one more entry and never rewritten, and
/// only retired when that exact readable operation resolves.
final class UserDefaultsPendingRequestOperationStorage: PendingRequestOperationStorage {
    static let singleRecordKey = "com.commonplate.request.pending-create-operation"
    static let collectionKey = "com.commonplate.request.pending-create-operations.v1"

    private let defaults: UserDefaults
    private let localPresentation: ParticipantLocalPresentationStorage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        localPresentation = ParticipantLocalPresentationStorage(defaults: defaults)
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

    func restoreAll() -> [PendingRequestOperationEntry] {
        var entries: [PendingRequestOperationEntry] = []
        if defaults.bool(forKey: ParticipantDeletionCleanup.createUnavailableKey) {
            entries.append(.identityUnavailable)
        }
        if let stored = defaults.object(forKey: Self.singleRecordKey) {
            entries.append(Self.restoreEntry(stored))
        }
        if let stored = defaults.object(forKey: Self.collectionKey) {
            guard let elements = stored as? [Any] else {
                // The container itself is unreadable, so how many operations
                // it held — and whose — is unknown.
                entries.append(.identityUnavailable)
                return entries
            }
            entries.append(contentsOf: elements.map(Self.restoreEntry))
        }
        return entries
    }

    @discardableResult
    func save(_ record: PendingRequestOperationRecord) -> Bool {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return false }
        guard let data = try? Self.encoder.encode(record) else { return false }
        var elements: [Any] = []
        if let stored = defaults.object(forKey: Self.collectionKey) {
            // An unreadable container is evidence, not free space: it is never
            // replaced to make room.
            guard let existing = stored as? [Any] else { return false }
            elements = existing.filter { Self.readableOperationId(of: $0) != record.operationId }
        }
        elements.append(data)
        defaults.set(elements, forKey: Self.collectionKey)
        return true
    }

    func clear(operationId: String) {
        guard localPresentation.isCurrent, !ParticipantDeletionFreeze(defaults: defaults).isPresent else { return }
        if let stored = defaults.object(forKey: Self.singleRecordKey),
           Self.readableOperationId(of: stored) == operationId {
            defaults.removeObject(forKey: Self.singleRecordKey)
        }
        guard let elements = defaults.object(forKey: Self.collectionKey) as? [Any] else {
            return
        }
        let remaining = elements.filter { Self.readableOperationId(of: $0) != operationId }
        guard remaining.count != elements.count else { return }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.collectionKey)
        } else {
            defaults.set(remaining, forKey: Self.collectionKey)
        }
    }

    private static func readableOperationId(of stored: Any) -> String? {
        guard case .restored(let restored) = restoreEntry(stored) else { return nil }
        return restored.identity.operationId
    }

    /// Decodes identity first and on its own, then the payload.
    ///
    /// Identity: version 2 must carry a complete ledger authority; version 1
    /// (origin only) is readable identity with no trusted authority; a record
    /// without `recoveryVersion` predates W4-D2 (pre-R4 flat or R4 nested)
    /// and has no recorded authority. Any other version, a mix of these
    /// layouts, a noncanonical participant id, or a malformed operation id or
    /// authority is unavailable identity, never guessed at.
    ///
    /// Payload: a record with a `payload` key is read as the current
    /// `CreateRequestPayload` (and, for a versioned record, only at this
    /// build's `payloadVersion`); a record without one is read as a pre-R4
    /// flat body. A record never has its payload retried as the other
    /// representation.
    static func restoreEntry(_ stored: Any) -> PendingRequestOperationEntry {
        guard let data = stored as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = try? decoder.decode(IdentityEnvelope.self, from: data) else {
            return .identityUnavailable
        }

        let hasOriginOnlyAuthority = object["operationAuthority"] != nil
        let hasLedgerAuthority = object["authorityOrigin"] != nil || object["authorityLedger"] != nil
        let authority: RequestOperationAuthorityIdentity?
        switch envelope.recoveryVersion {
        case .some(PendingRequestOperationIdentity.recoveryVersion):
            guard !hasOriginOnlyAuthority,
                  let origin = envelope.authorityOrigin,
                  let ledger = envelope.authorityLedger else {
                return .identityUnavailable
            }
            authority = RequestOperationAuthorityIdentity(origin: origin, ledger: ledger)
        case .some(1):
            guard !hasLedgerAuthority, envelope.operationAuthority?.isEmpty == false else {
                return .identityUnavailable
            }
            authority = nil
        case .some:
            return .identityUnavailable
        case .none:
            guard !hasOriginOnlyAuthority, !hasLedgerAuthority else {
                return .identityUnavailable
            }
            authority = nil
        }

        let identity = PendingRequestOperationIdentity(
            operationId: envelope.operationId,
            participantIdentifier: envelope.participantIdentifier,
            operationAuthority: authority
        )
        guard identity.isUsable else {
            return .identityUnavailable
        }

        return .restored(RestoredPendingRequestOperation(
            identity: identity,
            payload: restorePayload(
                from: data,
                hasPayloadKey: object["payload"] != nil,
                isVersioned: envelope.recoveryVersion != nil
            )
        ))
    }

    private static func restorePayload(
        from data: Data,
        hasPayloadKey: Bool,
        isVersioned: Bool
    ) -> RestoredPendingRequestPayload {
        if hasPayloadKey {
            guard let envelope = try? decoder.decode(CurrentPayloadEnvelope.self, from: data) else {
                return .unreadable
            }
            if isVersioned, envelope.payloadVersion != PendingRequestOperationRecord.payloadVersion {
                return .unreadable
            }
            if !isVersioned, envelope.payloadVersion != nil {
                return .unreadable
            }
            return .current(envelope.payload)
        }
        guard !isVersioned,
              let legacy = try? decoder.decode(LegacyPayloadEnvelope.self, from: data) else {
            return .unreadable
        }
        return .legacy(legacy.payload)
    }
}

/// Process-lifetime default for `RequestStore.init`, matching the existing
/// `reservationWarningScheduler` precedent of a safe no-op default rather than
/// requiring every existing call site (including every pre-D1 test) to supply
/// one. Real durability across process termination requires the caller —
/// `ContentView`, for the real app — to pass
/// `UserDefaultsPendingRequestOperationStorage` explicitly.
final class InMemoryPendingRequestOperationStorage: PendingRequestOperationStorage {
    private var records: [PendingRequestOperationRecord] = []

    func restoreAll() -> [PendingRequestOperationEntry] {
        records.map { record in
            guard record.identity.isUsable else { return .identityUnavailable }
            return .restored(RestoredPendingRequestOperation(
                identity: record.identity,
                payload: .current(record.payload)
            ))
        }
    }

    @discardableResult
    func save(_ record: PendingRequestOperationRecord) -> Bool {
        records.removeAll { $0.operationId == record.operationId }
        records.append(record)
        return true
    }

    func clear(operationId: String) {
        records.removeAll { $0.operationId == operationId }
    }
}
