import XCTest
@testable import CommonPlateios

@MainActor
final class RequesterFulfillmentRouteDriverTests: XCTestCase {
    func testCurrentR3TruthOpensExactOrderAndRetiresOnce() async {
        let router = tappedRouter()
        let resolver = Resolver(.placedOrder)
        let path = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
        XCTAssertEqual(path, [.placedOrder(requestID: "64c0000000000000000000a1")])
        let replay = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
        XCTAssertNil(replay)
        XCTAssertEqual(resolver.ids, ["64c0000000000000000000a1"])
    }

    func testInaccessibleAndUnknownTruthReturnHomeWithDistinctNotices() async {
        for outcome: RequesterFulfillmentNotificationResolution in [.unavailable, .temporarilyUnavailable] {
            let router = tappedRouter()
            let resolver = Resolver(outcome)
            let path = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
            XCTAssertEqual(path, [])
            XCTAssertEqual(resolver.unavailable, outcome == .unavailable ? 1 : 0)
            XCTAssertEqual(resolver.temporary, outcome == .temporarilyUnavailable ? 1 : 0)
            XCTAssertNil(router.pendingRequesterFulfillmentIntent)
        }
    }

    func testNewerTapDuringReadDiscardsOldOutcomeAndNotice() async {
        let router = tappedRouter()
        let resolver = Resolver(.temporarilyUnavailable)
        resolver.duringRead = {
            router.handleUserActedOnNotification(userInfo: [
                "type": "new-request", "requestId": "newer"
            ])
        }
        let path = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
        XCTAssertNil(path)
        XCTAssertEqual(resolver.temporary, 0)
    }

    func testInterruptedColdLaunchLeavesTapForNextReadinessSignal() async {
        let router = tappedRouter()
        let resolver = Resolver(.placedOrder)
        resolver.cancelRead = true
        let interrupted = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
        XCTAssertNil(interrupted)
        XCTAssertNotNil(router.pendingRequesterFulfillmentIntent)
        resolver.cancelRead = false
        let retried = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(router: router, resolver: resolver)
        XCTAssertEqual(retried, [.placedOrder(requestID: "64c0000000000000000000a1")])
    }

    private func tappedRouter() -> HelperNotificationRouter {
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": "64c0000000000000000000a1"
        ])
        return router
    }

    private final class Resolver: RequesterFulfillmentNotificationResolving {
        let result: RequesterFulfillmentNotificationResolution
        var ids: [String] = []
        var unavailable = 0
        var temporary = 0
        var cancelRead = false
        var duringRead: () -> Void = {}

        init(_ result: RequesterFulfillmentNotificationResolution) { self.result = result }
        func resolveRequesterFulfillmentNotification(requestID: String) async throws -> RequesterFulfillmentNotificationResolution {
            ids.append(requestID)
            duringRead()
            if cancelRead { throw CancellationError() }
            return result
        }
        func reportRequestUnavailableFromNotification(requestID: String) { unavailable += 1 }
        func reportRequestTemporarilyUnavailableFromNotification(requestID: String) { temporary += 1 }
    }
}
