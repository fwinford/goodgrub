//
//  ScreenshotProposalService.swift
//  CommonPlateios
//
// Owns `POST /api/request/screenshot-proposal` endpoint knowledge (W4-S1),
// per `src/screenshotProposalRoute.ts`. Talks to the backend only through
// `APIClient`. Deliberately its own service, distinct vocabulary from
// `RequestService`: this can never call `createRequest`, and nothing it
// returns is itself a `Request` or a `CreateRequestPayload`.
import Foundation

enum ScreenshotProposalErrorCode {
    static let verificationRequired = "PARTICIPANT_VERIFICATION_REQUIRED"
    static let authorityInvalid = "PARTICIPANT_AUTHORITY_INVALID"
    static let verificationUnavailable = "PARTICIPANT_VERIFICATION_UNAVAILABLE"
    static let invalidImage = "INVALID_IMAGE"
    static let publicActionsPaused = "PUBLIC_ACTIONS_PAUSED"
    static let rateLimited = "RATE_LIMITED"
}

/// Product-safe, structured failure surface. Every case still leaves the
/// requester's manual form fully usable — none of these ever blocks or
/// mutates request creation.
enum ScreenshotProposalServiceError: Error {
    case verificationRequired
    case authorityInvalid
    case invalidImage
    /// Every other outcome — provider/network failure, timeout, malformed
    /// response, pause, rate limit, transport/decoding failure. All degrade
    /// identically for the requester: analysis is unavailable right now.
    case unavailable(underlying: Error)
    /// Requester Screenshot Assistance is excluded in this build. Thrown
    /// before any request is constructed or sent.
    case excluded
}

/// One screenshot of a Requester proposal request, exactly as the backend
/// route's contract takes it: normalized bytes plus that same image's own
/// independent on-device Vision OCR text (the backend's eligibility and
/// corroboration evidence). Assembled by the Requester external provider from
/// the shared ordered selection and the Requester workflow's derived evidence.
struct ScreenshotProposalImage {
    let data: Data
    let mimeType: String
    let localEvidenceText: String
    /// Privacy-safe derived relation evidence only. Raw Vision boxes never
    /// enter this DTO.
    let localTotalGeometry: ScreenshotTotalGeometryEvidence?

    init(
        data: Data,
        mimeType: String,
        localEvidenceText: String,
        localTotalGeometry: ScreenshotTotalGeometryEvidence? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.localEvidenceText = localEvidenceText
        self.localTotalGeometry = localTotalGeometry
    }
}

/// One selected screenshot and its own independent on-device evidence.
private struct ScreenshotImagePayload: Encodable {
    let imageBase64: String
    let mimeType: String
    /// On-device Apple Vision OCR transcription of this same image
    /// (`ScreenshotLocalTextRecognizer`) — a different engine than the
    /// OpenAI provider the backend calls. The backend's sole eligibility and
    /// meal-swipe-corroboration evidence source; this app never asks the
    /// provider to produce or confirm its own evidence. Sent per image, so
    /// the backend can decide each screenshot's eligibility independently.
    let localEvidenceText: String
    let localTotalGeometry: ScreenshotTotalGeometryEvidence?
}

/// W4-R4: 1 to 5 screenshots, which are evidence for ONE logical order
/// rather than several independent analyses.
private struct ScreenshotProposalRequestPayload: Encodable {
    let images: [ScreenshotImagePayload]
}

private struct ScreenshotProposalLocationDTO: Decodable {
    let name: String
    let address: String
}

private struct ScreenshotProposalFieldsDTO: Decodable {
    /// W4-R4.1 deterministic path as the backend's wire string. Decoded
    /// leniently: an absent or unrecognized value is simply no path proposal,
    /// never a decoding failure for the rest of the proposal.
    let menuPath: String?
    let selectedDiningSpot: ScreenshotProposalLocationDTO?
    /// W4-R4: one entry per distinct observed item, already deduplicated
    /// across overlapping screenshots by the backend.
    let mealItems: [MealItem]?
    let mealSwipes: Int?
    let estimatedDiningDollarsCents: Int?
    let diningDollarsOrderTotalCents: Int?
}

private struct ScreenshotProposalResponseDTO: Decodable {
    let eligible: Bool
    let proposal: ScreenshotProposalFieldsDTO
}

struct ScreenshotProposalService {
    let client: APIClient
    private let availability: RequesterScreenshotAssistanceAvailability

    init(availability: RequesterScreenshotAssistanceAvailability, client: APIClient) {
        self.availability = availability
        self.client = client
    }

    static let routePath = "/api/request/screenshot-proposal"

    /// Finite bound tighter than `URLSession`'s 60s default: an analysis
    /// attempt must resolve or fail well inside the requester's patience, and
    /// the backend's own bound (`PROVIDER_TIMEOUT_MS`,
    /// `screenshotProposalRoute.ts`) is shorter still.
    static let requestTimeoutInterval: TimeInterval = 25

    /// Sends the normalized screenshots for one logical order (W4-R4: 1 to
    /// 5 of them). Each image's bytes and evidence are whatever local
    /// normalization and OCR already produced — this call performs no further
    /// transformation. Nothing here retries: a failed attempt is reported as
    /// such, never silently resent.
    func requestProposal(
        images: [ScreenshotProposalImage],
        authority: String
    ) async throws -> ScreenshotProposalOutcome {
        try Task.checkCancellation()
        guard availability.isAvailable else {
            throw ScreenshotProposalServiceError.excluded
        }

        do {
            let response: ScreenshotProposalResponseDTO = try await client.send(
                path: Self.routePath,
                method: .post,
                body: ScreenshotProposalRequestPayload(
                    images: images.map {
                        ScreenshotImagePayload(
                            imageBase64: $0.data.base64EncodedString(),
                            mimeType: $0.mimeType,
                            localEvidenceText: $0.localEvidenceText,
                            localTotalGeometry: $0.localTotalGeometry
                        )
                    }
                ),
                headers: [RequestService.participantAuthorityHeader: authority],
                timeoutInterval: Self.requestTimeoutInterval
            )
            return ScreenshotProposalOutcome(
                eligible: response.eligible,
                proposal: Self.mapProposal(response.proposal)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIClientError {
            throw Self.translate(error)
        } catch {
            throw ScreenshotProposalServiceError.unavailable(underlying: error)
        }
    }

    /// A wire-proposed location is only ever applied by name lookup against
    /// the bundled catalog (`SupportedVendorCatalog.diningSpots`) — never
    /// trusted as an ad hoc `DiningSpot` value — so an applied proposal can
    /// only ever be one of the same catalog entries the picker itself offers.
    private static func mapProposal(_ dto: ScreenshotProposalFieldsDTO) -> ScreenshotProposal {
        let spot = dto.selectedDiningSpot.flatMap { locationDTO in
            SupportedVendorCatalog.diningSpots.first { $0.name == locationDTO.name }
        }
        return ScreenshotProposal(
            menuPath: dto.menuPath
                .flatMap(RequestMenuPathWire.init(rawValue:))
                .map(\.domainMenuPath),
            selectedDiningSpot: spot,
            mealItems: dto.mealItems,
            mealSwipes: dto.mealSwipes,
            estimatedDiningDollarsCents: dto.estimatedDiningDollarsCents,
            diningDollarsOrderTotalCents: dto.diningDollarsOrderTotalCents
        )
    }

    private static func translate(_ error: APIClientError) -> ScreenshotProposalServiceError {
        switch error {
        case .apiError(let code, _):
            switch code {
            case ScreenshotProposalErrorCode.verificationRequired:
                return .verificationRequired
            case ScreenshotProposalErrorCode.authorityInvalid:
                return .authorityInvalid
            case ScreenshotProposalErrorCode.invalidImage:
                return .invalidImage
            default:
                return .unavailable(underlying: error)
            }
        case .unexpectedStatus, .transport, .decoding, .encoding, .invalidURL:
            return .unavailable(underlying: error)
        }
    }
}
