//
//  RequestPostingLimitCopyTests.swift
//  CommonPlateiosTests
//
//  W3-R1 revised presentation contract: the backend rule these sentences
//  describe — three requests per normalized email per NYU/New York calendar
//  day, counted before the write, best-effort rather than transactional,
//  failing closed when the count cannot be read — is unchanged. What changed
//  is presentation: the standing policy notice that used to sit on the
//  ordinary form, unconditionally, before anything was typed, is gone. Only
//  the actual limit-reached recovery sentence remains, reached solely by a
//  real `REQUEST_LIMIT_REACHED` refusal.
//

import XCTest
@testable import CommonPlateios

final class RequestPostingLimitCopyTests: XCTestCase {

    // MARK: - The one accepted sentence

    func testLimitStateWordingIsExact() {
        XCTAssertEqual(
            RequestFoodView.postingLimitReachedNotice,
            "Daily request limit reached. Try again after midnight Eastern Time."
        )
    }

    /// The refusal the backend actually sends must render as the accepted
    /// limit-state sentence, not as the presentation enum's own description or
    /// the backend's internal message.
    func testBackendLimitRefusalRendersTheAcceptedLimitStateSentence() {
        let mapped = RequestCreatePresentationError.map(
            RequestServiceError.serverError(
                code: "REQUEST_LIMIT_REACHED",
                message: "You have reached the daily limit of 3 meal requests"
            )
        )

        XCTAssertEqual(mapped, .requestLimitReached)
        XCTAssertEqual(mapped.message, RequestFoodView.postingLimitReachedNotice)
    }

    /// "Tomorrow" was ambiguous for a student posting at 11 PM Pacific, whose
    /// allowance had already reset. The reset is a New York midnight, and the
    /// limit-state sentence now says so.
    func testTheLimitStateNamesTheRealResetRatherThanTomorrow() {
        let limitState = RequestFoodView.postingLimitReachedNotice

        XCTAssertTrue(limitState.contains("after midnight Eastern Time"))
        XCTAssertFalse(limitState.lowercased().contains("tomorrow"))
    }

    // MARK: - No API vocabulary reaches a student

    /// A meal-request allowance is a product rule. Describing it in API terms
    /// tells a student nothing they can act on and misnames what happened — the
    /// short per-IP throttle is a different refusal with different copy.
    func testNoPostingLimitCopyUsesAPIVocabulary() {
        let sentences = [
            RequestFoodView.postingLimitReachedNotice,
            RequestCreatePresentationError.requestLimitReached.message,
            RequestCreatePresentationError.rateLimited.message,
        ]

        for sentence in sentences {
            let lowercased = sentence.lowercased()
            for phrase in ["api limit", "rate limit", "quota", "429", "endpoint"] {
                XCTAssertFalse(
                    lowercased.contains(phrase),
                    "\(sentence) uses the API term \"\(phrase)\""
                )
            }
        }
    }

    /// The daily allowance and the per-IP throttle are separate refusals with
    /// separate corrections — wait a minute, versus wait until midnight — so
    /// they must not share a sentence.
    func testTheDailyLimitAndThePerIPThrottleStaySeparate() {
        XCTAssertNotEqual(
            RequestCreatePresentationError.requestLimitReached.message,
            RequestCreatePresentationError.rateLimited.message
        )
    }

    // MARK: - The standing quota notice is gone from ordinary presentation

    /// Faith's revised presentation contract removed the standing quota
    /// explanation from ordinary Request Food submission: a student who has
    /// not encountered the limit is no longer told about it. Only the actual
    /// limit-reached recovery sentence remains, and it is reached solely by a
    /// real backend refusal, never rendered unconditionally on the form.
    func testTheStandingQuotaNoticeIsNotOnTheOrdinaryForm() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("postingLimitPolicyNotice"))
        XCTAssertFalse(
            source.contains(#".accessibilityIdentifier("request-posting-limit-policy")"#)
        )
        XCTAssertFalse(
            source.contains("attempts to limit each email to 3 meal requests per day")
        )
    }

    /// Superseded wording, in one place so it cannot quietly return.
    func testSupersededPostingLimitWordingIsGone() throws {
        let source = try String(
            contentsOf: repositoryFile(
                "ios/CommonPlateios/CommonPlateios/Views/RequestFoodView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("three meal requests a day"))
        XCTAssertFalse(source.contains("Please try again tomorrow."))
        XCTAssertFalse(
            source.contains("CommonPlate attempts to limit each email to 3 meal requests per day (New York time).")
        )
    }

    // MARK: - Helpers

    /// Walks up from this file to the repository root, so the source-text
    /// assertions above read the real tracked file rather than a copy.
    private func repositoryFile(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CommonPlateiosTests
            .deletingLastPathComponent() // CommonPlateios
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "expected \(relativePath) at \(url.path)"
        )
        return url
    }
}
