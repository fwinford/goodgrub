//
//  ScreenshotQualification.swift
//  CommonPlateios
//
// W4-S3: local capability versus qualification, and the fail-closed
// qualification identity. Availability is a runtime fact about the device;
// qualification is CommonPlate's shipped evidence for one EXACT combination.
// The two are independent: a model can be available and still unqualified, and
// nothing that is merely available is ever invoked.
//
// A qualification binds ALL of:
//
//   workflow (schema id + schema version + validator version)
//   × provider (id + prompt/model/provider-strategy version + distribution)
//   × evidence/input strategy
//   × implementation fingerprint (mechanically derived at build time)
//   × supported OS major.minor band
//   × supported device class
//
// The human-readable schema/validator/strategy version labels are diagnostics.
// Qualification safety does NOT depend on anyone remembering to bump them: the
// implementation fingerprint is a SHA-256 the build derives from the bytes of
// every qualification-relevant source input (see
// `ScreenshotQualificationFingerprint`), so any change to that implementation is
// a different key with no human step.
//
// Any material change to one of those is a different key and therefore
// unqualified. Unknown or later OS versions, unlisted devices, and unlisted
// strategies are not qualified. This file knows no workflow's fields.
import Foundation

// MARK: - Availability and capability

/// Why the local model cannot run at all right now. Runtime availability only.
enum ScreenshotLocalUnavailableReason: Equatable {
    case osTooOld
    case deviceNotEligible
    case modelNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unknown
}

enum ScreenshotLocalAvailability: Equatable {
    case available
    case unavailable(ScreenshotLocalUnavailableReason)
}

/// Whether CommonPlate has shipped-qualification evidence for this exact
/// combination. Independent of availability.
enum ScreenshotLocalQualification: Equatable {
    case qualified
    case notQualified
}

struct ScreenshotLocalCapability: Equatable {
    let availability: ScreenshotLocalAvailability
    let qualification: ScreenshotLocalQualification

    /// A local attempt runs only when the model is available AND this
    /// combination is qualified.
    var permitsLocalAttempt: Bool {
        availability == .available && qualification == .qualified
    }
}

// MARK: - Identity

/// The workflow/schema a qualification applies to. A qualification never
/// transfers between workflows, schema versions, or validator versions.
struct ScreenshotWorkflowIdentity: Hashable {
    let schemaID: String
    let schemaVersion: Int
    /// A human-readable label for the deterministic validator this schema's
    /// output must pass. Diagnostic only: a validator change invalidates
    /// qualification through the implementation fingerprint, whether or not
    /// anyone bumps this.
    let validatorVersion: Int
}

/// One provider path. `strategyVersion` is a human-readable label for whatever
/// prompt, model instruction, or provider strategy shapes its output. It is
/// diagnostic only: a change to that implementation invalidates qualification
/// through the implementation fingerprint, whether or not it is bumped.
struct ScreenshotProviderIdentity: Hashable {
    enum Distribution: Hashable {
        /// A provider that can be part of the shipped app.
        case shipping
        /// A test, debug, or conformance provider. It can never be qualified
        /// by a production registry, whatever entries that registry holds.
        case nonShipping
    }

    let id: String
    let strategyVersion: String
    let distribution: Distribution

    static func shipping(id: String, strategyVersion: String) -> ScreenshotProviderIdentity {
        ScreenshotProviderIdentity(id: id, strategyVersion: strategyVersion, distribution: .shipping)
    }

    static func nonShipping(id: String, strategyVersion: String) -> ScreenshotProviderIdentity {
        ScreenshotProviderIdentity(id: id, strategyVersion: strategyVersion, distribution: .nonShipping)
    }
}

/// How a provider path is given the screenshots — the evidence-derivation
/// class. It is part of qualification identity, and no qualification transfers
/// between modes. It also states the independence fact deterministic authority
/// depends on: whether the provider's own input and any corroborating runtime
/// Vision OCR evidence are the same derivation.
enum ScreenshotInputMode: String, Hashable, CaseIterable {
    /// Runtime Vision OCR text, flattened, is what the provider reads.
    case ocrFlattenedText = "ocr-flattened-text"
    /// Runtime Vision OCR text plus its geometry/grouping.
    case ocrLayoutAware = "ocr-layout-aware"
    /// The pixels themselves, independently of runtime OCR.
    case directImageMultimodal = "direct-image-multimodal"

    /// `true` when the provider's input is derived from the same runtime Vision
    /// OCR that a workflow may use as corroborating evidence, so its proposal
    /// and that evidence are NOT independent. What a workflow then permits is
    /// that workflow's own policy (for Requester, see `RequesterOrderPolicy`);
    /// this fact is workflow-neutral.
    var consumesRuntimeOCREvidence: Bool {
        switch self {
        case .ocrFlattenedText, .ocrLayoutAware: return true
        case .directImageMultimodal: return false
        }
    }
}

// MARK: - Device and OS

struct ScreenshotOSVersion: Hashable, Comparable {
    let major: Int
    let minor: Int

    static func < (lhs: ScreenshotOSVersion, rhs: ScreenshotOSVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

/// The device/OS facts a qualification is keyed on.
struct ScreenshotDeviceEnvironment: Equatable {
    let osVersion: ScreenshotOSVersion
    /// Hardware model identifier (e.g. `iPhone17,1`). The simulator reports the
    /// fixed value below, which no qualification entry may use: simulator or
    /// unit proof alone never qualifies a path.
    let modelIdentifier: String

    static let simulatorModelIdentifier = "simulator"

    static var current: ScreenshotDeviceEnvironment {
        #if targetEnvironment(simulator)
        let identifier = simulatorModelIdentifier
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ScreenshotDeviceEnvironment(
            osVersion: ScreenshotOSVersion(major: version.majorVersion, minor: version.minorVersion),
            modelIdentifier: identifier
        )
    }
}

// MARK: - Qualification

/// The exact combination a qualification claim is about.
struct ScreenshotQualificationKey: Hashable {
    let workflow: ScreenshotWorkflowIdentity
    let provider: ScreenshotProviderIdentity
    let inputMode: ScreenshotInputMode
    /// The build-derived fingerprint of the qualification-relevant
    /// implementation the claim was made against. An entry pins a literal
    /// value; the runtime supplies only `ScreenshotQualificationFingerprint.current`.
    /// A different, unknown, or empty value is a different key: not qualified.
    let implementationFingerprint: String
}

/// One shipping-qualified combination: a key, the explicit OS major.minor band
/// it was qualified on, and the device classes it was qualified on.
struct ScreenshotQualificationEntry: Equatable {
    let key: ScreenshotQualificationKey
    let osBand: ClosedRange<ScreenshotOSVersion>
    let deviceModelIdentifiers: Set<String>
}

/// The closed list of qualified local combinations. Anything not listed —
/// unknown workflow, provider, strategy, validator, OS version, or device — is
/// `notQualified`, and `notQualified` grants no remote permission.
struct ScreenshotQualificationRegistry: Equatable {
    let entries: [ScreenshotQualificationEntry]
    /// Only a registry built by `injectedForTesting` admits providers whose
    /// identity is `.nonShipping`. Production never does.
    let admitsNonShippingProviders: Bool

    private init(entries: [ScreenshotQualificationEntry], admitsNonShippingProviders: Bool) {
        self.entries = entries
        self.admitsNonShippingProviders = admitsNonShippingProviders
    }

    /// The shipping constructor. An entry naming a `.nonShipping` provider is
    /// dropped, so a test, debug, or conformance provider cannot be qualified
    /// into a shipped registry even by mistake.
    init(shippingEntries entries: [ScreenshotQualificationEntry]) {
        self.init(
            entries: entries.filter { $0.key.provider.distribution == .shipping },
            admitsNonShippingProviders: false
        )
    }

    /// A registry for tests and conformance proof only. It is the ONLY way to
    /// qualify a `.nonShipping` provider, and nothing in the app target may
    /// call it (`ScreenshotAssistanceBoundaryTests` scans for that).
    static func injectedForTesting(entries: [ScreenshotQualificationEntry]) -> ScreenshotQualificationRegistry {
        ScreenshotQualificationRegistry(entries: entries, admitsNonShippingProviders: true)
    }

    func qualification(
        for key: ScreenshotQualificationKey,
        environment: ScreenshotDeviceEnvironment
    ) -> ScreenshotLocalQualification {
        guard environment.modelIdentifier != ScreenshotDeviceEnvironment.simulatorModelIdentifier else {
            return .notQualified
        }
        guard key.provider.distribution == .shipping || admitsNonShippingProviders else {
            return .notQualified
        }
        let isQualified = entries.contains { entry in
            entry.key == key
                && entry.osBand.contains(environment.osVersion)
                && entry.deviceModelIdentifiers.contains(environment.modelIdentifier)
        }
        return isQualified ? .qualified : .notQualified
    }
}
