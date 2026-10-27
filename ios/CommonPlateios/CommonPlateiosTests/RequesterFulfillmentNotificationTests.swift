//
//  RequesterFulfillmentNotificationTests.swift
//  CommonPlateiosTests
//
// Focused coverage for requester-fulfillment payload parsing, tap authority,
// and its exact W4-R3 placed-order destination.
import Foundation
import XCTest
@testable import CommonPlateios

final class RequesterFulfillmentNotificationPayloadParsingTests: XCTestCase {
    func testParsesTheRequestIdFromAWellFormedPayload() {
        XCTAssertEqual(
            RequesterFulfillmentNotificationPayloadParser.parse(userInfo: [
                "type": "requester-order-placed",
                "requestId": "64c0000000000000000000a1"
            ]),
            RequesterFulfillmentNotificationPayload(requestID: "64c0000000000000000000a1")
        )
    }

    func testRejectsAnUnrelatedNotificationType() {
        XCTAssertNil(RequesterFulfillmentNotificationPayloadParser.parse(userInfo: [
            "type": "new-request",
            "requestId": "abc123"
        ]))
    }

    func testRejectsMissingEmptyAndNonStringRequestIds() {
        for userInfo: [AnyHashable: Any] in [
            ["type": "requester-order-placed"],
            ["type": "requester-order-placed", "requestId": ""],
            ["type": "requester-order-placed", "requestId": 123],
            ["type": "requester-order-placed", "requestId": "../private"],
            ["type": "requester-order-placed", "requestId": "                        "],
            ["type": "requester-order-placed", "requestId": "gggggggggggggggggggggggg"]
        ] {
            XCTAssertNil(RequesterFulfillmentNotificationPayloadParser.parse(userInfo: userInfo))
        }
    }
}

@MainActor
final class RequesterFulfillmentNotificationRouterTests: XCTestCase {
    private let payloadType = "requester-order-placed"

    func testCapturesTheRequestIdAndItsTapSequence() throws {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: [
            "type": payloadType,
            "requestId": "64c0000000000000000000a1"
        ])

        let intent = try XCTUnwrap(router.pendingRequesterFulfillmentIntent)
        XCTAssertEqual(intent.requestID, "64c0000000000000000000a1")
        XCTAssertEqual(intent.tapSequence, router.latestTapSequence)
        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, 1)
    }

    func testMalformedPayloadDoesNotCreateOrAdvanceAnIntent() {
        let router = HelperNotificationRouter()

        router.handleUserActedOnNotification(userInfo: ["type": payloadType])

        XCTAssertNil(router.pendingRequesterFulfillmentIntent)
        XCTAssertEqual(router.latestTapSequence, 0)
        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, 0)
    }

    func testRetiringTheAppliedIntentIsExactlyOnceAndDoesNotAdvanceGeneration() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": payloadType,
            "requestId": "64c0000000000000000000a1"
        ])
        let intent = try XCTUnwrap(router.pendingRequesterFulfillmentIntent)
        let generation = router.requesterFulfillmentRoutingGeneration

        router.markRequesterFulfillmentIntentHandled(tapSequence: intent.tapSequence)
        router.markRequesterFulfillmentIntentHandled(tapSequence: intent.tapSequence)

        XCTAssertNil(router.pendingRequesterFulfillmentIntent)
        XCTAssertEqual(router.requesterFulfillmentRoutingGeneration, generation)
    }

    func testRetiringAnOlderIntentCannotClearANewerRequesterTap() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": payloadType,
            "requestId": "64c0000000000000000000a1"
        ])
        let older = try XCTUnwrap(router.pendingRequesterFulfillmentIntent)
        router.handleUserActedOnNotification(userInfo: [
            "type": payloadType,
            "requestId": "64c0000000000000000000b2"
        ])

        router.markRequesterFulfillmentIntentHandled(tapSequence: older.tapSequence)

        XCTAssertEqual(router.pendingRequesterFulfillmentIntent?.requestID, "64c0000000000000000000b2")
    }

    func testAnyLaterNavigationTapSupersedesTheRequesterTap() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": payloadType,
            "requestId": "64c0000000000000000000a1"
        ])
        let requesterTap = try XCTUnwrap(router.pendingRequesterFulfillmentIntent)

        router.handleUserActedOnNotification(userInfo: [
            "type": "reservation-warning",
            "requestId": "request-456"
        ])

        XCTAssertFalse(TapAuthorityFence.isStillAuthoritative(
            capturedSequence: requesterTap.tapSequence,
            currentSequence: router.latestTapSequence
        ))
    }

    func testRequesterTapSupersedesAnOlderHelperTap() throws {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "new-request",
            "requestId": "request-456"
        ])
        let helperTap = try XCTUnwrap(router.pendingHelperIntent)

        router.handleUserActedOnNotification(userInfo: [
            "type": payloadType,
            "requestId": "64c0000000000000000000a1"
        ])

        XCTAssertFalse(TapAuthorityFence.isStillAuthoritative(
            capturedSequence: helperTap.tapSequence,
            currentSequence: router.latestTapSequence
        ))
        XCTAssertEqual(router.pendingRequesterFulfillmentIntent?.requestID, "64c0000000000000000000a1")
    }
}

final class RequesterFulfillmentNotificationDestinationTests: XCTestCase {
    func testRoutesToTheExactR3PlacedOrderAndNoOtherDestination() {
        XCTAssertEqual(
            AppRoute.afterRequesterFulfillmentNotification(requestID: "order-123"),
            [.placedOrder(requestID: "order-123")]
        )
    }
}
