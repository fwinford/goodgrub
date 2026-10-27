import Foundation
import XCTest
@testable import CommonPlateios

@MainActor
final class PlacedOrderContinuationTests: XCTestCase {
    private let authority = "64c0000000000000000000a1.1.credential"
    private let principal = "64c0000000000000000000a1"

    override func tearDown() {
        PlacedOrderContinuationURLProtocol.reset()
        super.tearDown()
    }

    func testReadinessUsesServerAnchorAndMonotonicElapsedTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = request(id: "r1", createdAt: now)
        let order = PlacedOrder(
            request: request,
            orderNumber: "1234",
            etaText: "15 minutes",
            placedAt: now,
            estimatedReadyAt: now.addingTimeInterval(900),
            serverNow: now,
            monotonicReadAt: 100
        )

        XCTAssertFalse(order.shouldConfirmPickup(at: 999))
        XCTAssertEqual(order.secondsUntilPickupAttention(at: 100), 900)
        XCTAssertTrue(order.shouldConfirmPickup(at: 1_000))

        let unknownEstimate = PlacedOrder(
            request: request,
            orderNumber: "1234",
            etaText: nil,
            placedAt: now,
            estimatedReadyAt: nil,
            serverNow: now,
            monotonicReadAt: 100
        )
        XCTAssertFalse(unknownEstimate.shouldConfirmPickup(at: 100_000))
        XCTAssertNil(unknownEstimate.secondsUntilPickupAttention(at: 100_000))
    }

    func testHomeCombinesAllPlacedAndOngoingRequestsOnceNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let ongoing = [
            request(id: "ongoing-old", createdAt: base),
            request(id: "overlap", createdAt: base.addingTimeInterval(20))
        ]
        let placed = [
            placedOrder(id: "placed-new", createdAt: base.addingTimeInterval(30)),
            placedOrder(id: "overlap", createdAt: base.addingTimeInterval(20)),
            placedOrder(id: "placed-middle", createdAt: base.addingTimeInterval(10))
        ]

        XCTAssertEqual(
            HomeExchangeView.combinedOwnRequests(ongoing, placedOrders: placed).map(\.id),
            ["placed-new", "overlap", "placed-middle", "ongoing-old"]
        )
    }

    func testR5PreviewScalingAndSeeAllCountUseTheCombinedPlacedSet() {
        let requests = (0..<4).map {
            request(id: "r\($0)", createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double($0)))
        }
        let empty = HomeExchangeView.ownRequestsPreview([])
        XCTAssertEqual(empty.cards.map(\.id), [])
        XCTAssertNil(empty.seeAllCount)

        let one = HomeExchangeView.ownRequestsPreview(Array(requests.prefix(1)))
        XCTAssertEqual(one.cards.map(\.id), ["r0"])
        XCTAssertNil(one.seeAllCount)

        let two = HomeExchangeView.ownRequestsPreview(Array(requests.prefix(2)))
        XCTAssertEqual(two.cards.map(\.id), ["r0", "r1"])
        XCTAssertNil(two.seeAllCount)

        let three = HomeExchangeView.ownRequestsPreview(Array(requests.prefix(3)))
        XCTAssertEqual(three.cards.map(\.id), ["r0", "r1"])
        XCTAssertEqual(three.seeAllCount, 3)
        XCTAssertEqual(HomeExchangeView.seeAllOwnRequestsAccessibilityLabel(count: 3), "See all 3 requests")

        let four = HomeExchangeView.ownRequestsPreview(requests)
        XCTAssertEqual(four.cards.map(\.id), ["r0", "r1"])
        XCTAssertEqual(four.seeAllCount, 4)
    }

    func testMapsDestinationsAreLimitedToAppleMapsVerifiedCatalogAddresses() throws {
        let verified: [(String, String)] = [
            ("Peet's Coffee at Kimmel", "Kimmel Center, 60 Washington Sq S, 2nd Floor"),
            ("Palladium", "Palladium Hall, 140 E 14th St"),
            ("Upstein - Vedge Craft & Smoothie Lab", "Weinstein Hall, 5 University Pl #11"),
            ("Upstein - Shareables, Cluckstein, Slidestein & Taqueria", "Weinstein Hall, 5 University Pl #11"),
            ("True Burger at UHall", "U-Hall, 110 E. 14th"),
            ("Cafe 370", "BROOKLYN - 370 Jay St")
        ]
        for (name, address) in verified {
            let destination = try XCTUnwrap(
                R3MapsDestination(diningSpot: DiningSpot(name: name, address: address))
            )
            XCTAssertEqual(destination.query, "\(name), \(address)")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(destination.appleMapsURL), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "q" })?.value,
                destination.query
            )
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(destination.googleMapsURL), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "q" })?.value,
                destination.query
            )
            XCTAssertTrue(try XCTUnwrap(destination.googleMapsURL)
                .absoluteString.hasPrefix("comgooglemaps://?q="))
        }
        let dunkin = try XCTUnwrap(R3MapsDestination(diningSpot: DiningSpot(
            name: "Dunkin' at U-Hall",
            address: "U-Hall, 108 E 14th St"
        )))
        XCTAssertEqual(dunkin.query, "Dunkin' at U-Hall, 110 E 14th St, New York, NY")
        let flavorLab = try XCTUnwrap(R3MapsDestination(diningSpot: DiningSpot(
            name: "Flavor Lab by NYU Eats",
            address: "Jasper Kane Cafe"
        )))
        XCTAssertEqual(flavorLab.query, "Flavor Lab by NYU Eats, 327 Jay St, Brooklyn, NY")
        XCTAssertEqual(
            R3MapsDestination.displayAddress(for: DiningSpot(name: "Crave NYU", address: "John A. Paulson Center, 6th Floor")),
            "181 Mercer St"
        )
        XCTAssertNil(R3MapsDestination(diningSpot: DiningSpot(
            name: "Palladium",
            address: "140 E 14th St"
        )))
    }

    func testSuccessfulPickupRemovesOnlyTheActivePlacementAndShowsHomeAcknowledgement() async throws {
        let storage = InMemoryPendingPlacedPickupStorage()
        let store = makeStore(storage: storage)
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: listResponse(ids: ["r1", "r2"])
        ))
        await store.fetchPlacedOrders()
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: pickupResponse(requestID: "r1")
        ))

        let result = await store.confirmPlacedOrderPickup(requestID: "r1")

        XCTAssertEqual(result, .confirmed)
        XCTAssertEqual(store.placedOrders.map(\.id), ["r2"])
        XCTAssertTrue(store.hasPickupConfirmationNotice)
        XCTAssertEqual(storage.load(), .records([]))
        let mutation = PlacedOrderContinuationURLProtocol.capturedRequests.filter {
            $0.path == "/api/participant/placed-orders/r1/pickup-confirmation"
        }
        let posted = try XCTUnwrap(mutation.first)
        XCTAssertEqual(mutation.count, 1)
        XCTAssertEqual(posted.method, "POST")
        XCTAssertNil(posted.body)
        XCTAssertEqual(posted.headers[RequestService.participantAuthorityHeader], authority)
    }

    func testListFailsClosedWhenAPlacedRowViolatesTheOrderNumberInvariant() async {
        let store = makeStore(storage: InMemoryPendingPlacedPickupStorage())
        var broken = placedOrderObject(id: "r2")
        broken["orderNumber"] = NSNull()
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: json([
                "orders": [placedOrderObject(id: "r1"), broken, placedOrderObject(id: "r3")],
                "serverNow": timestamp
            ])
        ))

        let outcome = await store.fetchPlacedOrders()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(store.placedOrders.isEmpty)
        XCTAssertNotNil(store.placedOrdersError)
    }

    func testListDefensivelyRejectsMalformedOrderNumberStrings() async {
        for malformed in ["", "ORDER", "12-34", String(repeating: "1", count: 51)] {
            let store = makeStore(storage: InMemoryPendingPlacedPickupStorage())
            var broken = placedOrderObject(id: "r1")
            broken["orderNumber"] = malformed
            PlacedOrderContinuationURLProtocol.enqueue(.response(
                statusCode: 200,
                data: json(["orders": [broken], "serverNow": timestamp])
            ))

            let outcome = await store.fetchPlacedOrders()

            XCTAssertEqual(outcome, .didNotSucceed, "accepted malformed value: \(malformed)")
            XCTAssertTrue(store.placedOrders.isEmpty)
            XCTAssertNotNil(store.placedOrdersError)
        }
    }

    func testListStillFailsClosedOnAnOwnershipViolation() async {
        let store = makeStore(storage: InMemoryPendingPlacedPickupStorage())
        var foreign = placedOrderObject(id: "r2")
        foreign["isOwnRequest"] = false
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: json([
                "orders": [placedOrderObject(id: "r1"), foreign],
                "serverNow": timestamp
            ])
        ))

        let outcome = await store.fetchPlacedOrders()

        XCTAssertEqual(outcome, .didNotSucceed)
        XCTAssertTrue(store.placedOrders.isEmpty)
        XCTAssertNotNil(store.placedOrdersError)
    }

    func testLostMutationResponseReconcilesConfirmedStateWithoutAnotherPost() async {
        let storage = InMemoryPendingPlacedPickupStorage()
        let store = makeStore(storage: storage)
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: listResponse(ids: ["r1"])
        ))
        await store.fetchPlacedOrders()
        PlacedOrderContinuationURLProtocol.enqueue(.failure(.networkConnectionLost))

        let firstResult = await store.confirmPlacedOrderPickup(requestID: "r1")

        XCTAssertEqual(firstResult, .unresolved)
        XCTAssertTrue(store.isPickupRecoveryNeeded(requestID: "r1"))
        XCTAssertEqual(storage.load(), .records([
            PendingPlacedPickup(requestID: "r1", participantPrincipal: principal)
        ]))

        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: detailResponse(id: "r1", pickupStatus: "confirmed")
        ))
        let retryResult = await store.confirmPlacedOrderPickup(
            requestID: "r1",
            userInitiatedRetry: true
        )

        XCTAssertEqual(retryResult, .confirmed)
        XCTAssertTrue(store.hasPickupConfirmationNotice)
        XCTAssertFalse(store.isPickupRecoveryNeeded(requestID: "r1"))
        XCTAssertEqual(
            PlacedOrderContinuationURLProtocol.capturedRequests.filter { $0.method == "POST" }.count,
            1
        )
    }

    func testTryAgainReadsPendingStateBeforeItsUserInitiatedMutation() async {
        let store = makeStore()
        PlacedOrderContinuationURLProtocol.enqueue(.failure(.timedOut))
        let firstResult = await store.confirmPlacedOrderPickup(requestID: "r1")
        XCTAssertEqual(firstResult, .unresolved)

        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: detailResponse(id: "r1", pickupStatus: "pending")
        ))
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: pickupResponse(requestID: "r1")
        ))
        let retryResult = await store.confirmPlacedOrderPickup(
            requestID: "r1",
            userInitiatedRetry: true
        )
        XCTAssertEqual(retryResult, .confirmed)

        let requests = PlacedOrderContinuationURLProtocol.capturedRequests
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "POST"])
        XCTAssertTrue(requests[1].path.hasSuffix("/r1"))
        XCTAssertEqual(requests[2].path, "/api/participant/placed-orders/r1/pickup-confirmation")
    }

    func testTryAgainDoesNotMutateWhenAuthoritativeReadFails() async {
        let storage = InMemoryPendingPlacedPickupStorage()
        let store = makeStore(storage: storage)
        PlacedOrderContinuationURLProtocol.enqueue(.failure(.networkConnectionLost))
        let firstResult = await store.confirmPlacedOrderPickup(requestID: "r1")
        XCTAssertEqual(firstResult, .unresolved)
        PlacedOrderContinuationURLProtocol.enqueue(.failure(.timedOut))

        let retryResult = await store.confirmPlacedOrderPickup(
            requestID: "r1",
            userInitiatedRetry: true
        )
        XCTAssertEqual(retryResult, .unresolved)

        XCTAssertTrue(store.isPickupRecoveryNeeded(requestID: "r1"))
        XCTAssertEqual(storage.load(), .records([
            PendingPlacedPickup(requestID: "r1", participantPrincipal: principal)
        ]))
        XCTAssertEqual(PlacedOrderContinuationURLProtocol.capturedRequests.map(\.method), ["POST", "GET"])
    }

    func testRelaunchReconciliationIsReadOnlyAndKeepsPendingPickupForTryAgain() async {
        let storage = InMemoryPendingPlacedPickupStorage()
        let record = PendingPlacedPickup(requestID: "r1", participantPrincipal: principal)
        XCTAssertTrue(storage.save(record))
        let store = makeStore(storage: storage)
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: detailResponse(id: "r1", pickupStatus: "pending")
        ))

        await store.reconcilePendingPlacedPickupIfNeeded()

        XCTAssertTrue(store.isPickupRecoveryNeeded(requestID: "r1"))
        XCTAssertEqual(storage.load(), .records([record]))
        XCTAssertEqual(PlacedOrderContinuationURLProtocol.capturedRequests.map(\.method), ["GET"])
    }

    func testChangedPrincipalCannotReplayOrRetainAnotherPrincipalsPendingPickup() async {
        let storage = InMemoryPendingPlacedPickupStorage()
        let oldRecord = PendingPlacedPickup(requestID: "r1", participantPrincipal: principal)
        XCTAssertTrue(storage.save(oldRecord))
        let store = makeStore(storage: storage, currentPrincipal: "different-principal")

        await store.reconcilePendingPlacedPickupIfNeeded()

        XCTAssertEqual(storage.load(), .records([]))
        XCTAssertTrue(PlacedOrderContinuationURLProtocol.capturedRequests.isEmpty)
    }

    func testIdentityReplacementRetiresPendingPickupBeforeAnyR3DataWasLoaded() {
        let storage = InMemoryPendingPlacedPickupStorage()
        XCTAssertTrue(storage.save(PendingPlacedPickup(
            requestID: "r1",
            participantPrincipal: principal
        )))
        let store = makeStore(storage: storage, currentPrincipal: "different-principal")

        store.invalidateRequestDataIfIdentityReplaced()

        XCTAssertEqual(storage.load(), .records([]))
        XCTAssertTrue(PlacedOrderContinuationURLProtocol.capturedRequests.isEmpty)
    }

    func testIdentityRetirementHidesPlacementButPreservesSamePrincipalRecoveryRecord() async {
        let storage = InMemoryPendingPlacedPickupStorage()
        let identity = PlacedOrderContinuationIdentityBox(
            authority: authority,
            principal: principal
        )
        let store = makeStore(
            storage: storage,
            authorityProvider: { identity.authority },
            principalProvider: { identity.principal }
        )
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: listResponse(ids: ["r1"])
        ))
        await store.fetchPlacedOrders()
        let record = PendingPlacedPickup(requestID: "r1", participantPrincipal: principal)
        XCTAssertTrue(storage.save(record))

        identity.authority = nil
        identity.principal = nil
        store.invalidateRequestDataIfIdentityReplaced()

        XCTAssertTrue(store.placedOrders.isEmpty)
        XCTAssertEqual(storage.load(), .records([record]))
    }

    func testDurableStorageContainsOnlyRequestIDAndPrincipal() throws {
        let suiteName = "PlacedOrderContinuationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsPendingPlacedPickupStorage(defaults: defaults)
        let record = PendingPlacedPickup(requestID: "r1", participantPrincipal: principal)

        XCTAssertTrue(storage.save(record))

        guard case .records(let records) = storage.load() else {
            return XCTFail("the saved pickup record must be readable")
        }
        XCTAssertEqual(records, [record])
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsPendingPlacedPickupStorage.key))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        XCTAssertEqual(Set(object[0].keys), ["requestID", "participantPrincipal"])
        XCTAssertTrue(storage.clear(record))
        XCTAssertEqual(storage.load(), .records([]))
    }

    func testDetailReconstructionKeepsPlacedStateAndOnlyAllowlistedRequesterData() async throws {
        let store = makeStore()
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: detailResponse(id: "r1", pickupStatus: "pending")
        ))

        let detail = try await store.fetchPlacedOrder(id: "r1")

        XCTAssertEqual(detail.request.id, "r1")
        XCTAssertEqual(detail.request.status, .placed)
        XCTAssertEqual(detail.placedOrder.orderNumber, "70154321")
        XCTAssertEqual(detail.placedOrder.etaText, "15 minutes")
        XCTAssertEqual(detail.placedOrder.estimatedReadyAt, date("2026-10-19T17:15:00.000Z"))
        XCTAssertEqual(detail.pickupConfirmation, .pending)
        XCTAssertEqual(detail.contactHelperEmail, "helper@example.edu")
        let captured = try XCTUnwrap(PlacedOrderContinuationURLProtocol.capturedRequests.first)
        XCTAssertEqual(captured.path, "/api/participant/placed-orders/r1")
        XCTAssertEqual(captured.headers[RequestService.participantAuthorityHeader], authority)
    }

    func testEvidenceIsFetchedOnDemandAsUncachedRawImageData() async throws {
        let store = makeStore()
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: Data([0xff, 0xd8, 0xff, 0xd9]),
            headers: ["Content-Type": "image/jpeg", "Cache-Control": "private, no-store"]
        ))

        let evidence = try await store.fetchPlacedOrderEvidence(requestID: "r1")
        let captured = try XCTUnwrap(PlacedOrderContinuationURLProtocol.capturedRequests.first)

        XCTAssertEqual(evidence.data, Data([0xff, 0xd8, 0xff, 0xd9]))
        XCTAssertEqual(evidence.mimeType, "image/jpeg")
        XCTAssertEqual(captured.method, "GET")
        XCTAssertEqual(captured.headers[RequestService.participantAuthorityHeader], authority)
        XCTAssertEqual(captured.headers["accept"], "image/jpeg,image/png")
        XCTAssertEqual(captured.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRequesterNotificationResolvesExactR3TruthBeforeRouting() async throws {
        let id = "64c0000000000000000000a1"
        let store = makeStore()
        let router = HelperNotificationRouter()
        router.handleUserActedOnNotification(userInfo: [
            "type": "requester-order-placed", "requestId": id
        ])
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200, data: detailResponse(id: id, pickupStatus: "pending")
        ))
        let path = await RequesterFulfillmentNotificationRouteDriver.routeIfNeeded(router: router, resolver: store)
        XCTAssertEqual(path, [.placedOrder(requestID: id)])
        let read = try XCTUnwrap(PlacedOrderContinuationURLProtocol.capturedRequests.last)
        XCTAssertEqual(read.path, "/api/participant/placed-orders/\(id)")
        XCTAssertEqual(read.headers[RequestService.participantAuthorityHeader], authority)
    }

    func testRequesterNotificationConfirmedInaccessibleAndOutageTruthStayDistinct() async throws {
        let id = "64c0000000000000000000a1"
        for status in ["confirmed", "inaccessible", "outage"] {
            PlacedOrderContinuationURLProtocol.reset()
            let store = makeStore()
            if status == "confirmed" {
                PlacedOrderContinuationURLProtocol.enqueue(.response(
                    statusCode: 200, data: detailResponse(id: id, pickupStatus: "confirmed")
                ))
            } else if status == "inaccessible" {
                PlacedOrderContinuationURLProtocol.enqueue(.response(
                    statusCode: 404,
                    data: Data(#"{"error":{"code":"PLACED_ORDER_NOT_FOUND","message":"Unavailable","fields":null}}"#.utf8)
                ))
            } else {
                PlacedOrderContinuationURLProtocol.enqueue(.failure(.cannotConnectToHost))
            }
            let outcome = try await store.resolveRequesterFulfillmentNotification(requestID: id)
            XCTAssertEqual(outcome, status == "outage" ? .temporarilyUnavailable : .unavailable)
            XCTAssertTrue(store.placedOrders.isEmpty)
        }
    }

    func testEvidenceCannotEnterConfiguredURLCacheWhenResponseOmitsNoStore() async throws {
        let cache = URLCache(memoryCapacity: 128_000, diskCapacity: 1_000_000, diskPath: "r3-evidence")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlacedOrderContinuationURLProtocol.self]
        configuration.urlCache = cache
        let service = RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        let imageData = Data([0xff, 0xd8, 0xff, 0xd9])
        PlacedOrderContinuationURLProtocol.enqueue(.response(
            statusCode: 200,
            data: imageData,
            headers: [
                "Content-Type": "image/jpeg",
                "Cache-Control": "public, max-age=3600"
            ],
            cacheStoragePolicy: .allowed
        ))

        let evidence = try await service.fetchPlacedOrderEvidence(
            requestID: "r1",
            participantAuthority: authority
        )
        let request = URLRequest(url: URL(string:
            "https://commonplate.test/api/participant/placed-orders/r1/evidence"
        )!)

        XCTAssertEqual(evidence.data, imageData)
        XCTAssertNil(cache.cachedResponse(for: request))
        XCTAssertEqual(PlacedOrderContinuationURLProtocol.capturedRequests.first?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testDetailHasNoMissingEvidenceCopyAndPickupRecoveryStaysInline() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/PlacedOrderDetailView.swift")
        XCTAssertTrue(source.contains("We couldn’t confirm your pickup."))
        XCTAssertTrue(source.contains("Text(isRetry ? \"Try Again\" : \"I picked it up\")"))
        XCTAssertTrue(source.contains(".fullScreenCover(isPresented: $isShowingEvidence)"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("order confirmation unavailable"))
        XCTAssertFalse(source.contains("ShareLink"))
        XCTAssertFalse(source.contains("UIActivityViewController"))
    }

    func testDetailRetiresCachedPrivateStateAndStaleReadsOnIdentityChange() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/PlacedOrderDetailView.swift")
        guard let identityChange = source.range(of: ".onChange(of: identityStore.identity)"),
              let identityHandlingEnd = source.range(
                of: ".onDisappear",
                range: identityChange.upperBound..<source.endIndex
              ) else {
            return XCTFail("the detail must observe participant identity changes")
        }
        let identityHandling = source[identityChange.lowerBound..<identityHandlingEnd.lowerBound]
        XCTAssertTrue(identityHandling.contains("loadGeneration += 1"))
        XCTAssertTrue(identityHandling.contains("detail = nil"))
        XCTAssertTrue(identityHandling.contains("evidenceData = nil"))
        XCTAssertTrue(source.contains("guard generation == loadGeneration else { return }"))
    }

    func testExactPlacedOrderRouteResolvesByRequestIDAndR5PlacedConflictUsesIt() throws {
        let routeSource = try fileSource("ios/CommonPlateios/CommonPlateios/Navigation/AppRoute.swift")
        let contentSource = try fileSource("ios/CommonPlateios/CommonPlateios/ContentView.swift")
        let ownerDetailSource = try fileSource("ios/CommonPlateios/CommonPlateios/Views/OwnerRequestDetailView.swift")

        XCTAssertTrue(routeSource.contains("case placedOrder(requestID: String)"))
        XCTAssertTrue(contentSource.contains("case .placedOrder(let requestID):"))
        XCTAssertTrue(ownerDetailSource.contains(".placedOrder(requestID: owner.id)"))
    }

    func testPickupAcknowledgementUsesTheR5HomeNoticePosition() throws {
        let source = try fileSource("ios/CommonPlateios/CommonPlateios/Views/HomeExchangeView.swift")
        guard let ownRequests = source.range(of: "ownRequestsSection"),
              let notice = source.range(of: "pickupConfirmationNotice", range: ownRequests.upperBound..<source.endIndex),
              let heading = source.range(of: "boardHeadingRow", range: notice.upperBound..<source.endIndex) else {
            return XCTFail("expected the pickup acknowledgement between Your Requests and Needs help")
        }
        XCTAssertLessThan(ownRequests.lowerBound, notice.lowerBound)
        XCTAssertLessThan(notice.lowerBound, heading.lowerBound)
        XCTAssertTrue(source.contains("VStack(alignment: .leading, spacing: 19)"))
        XCTAssertTrue(source.contains("Pickup confirmed. Enjoy your meal!"))
    }

    // MARK: - Fixtures

    private func makeStore(
        storage: PendingPlacedPickupStorage? = nil,
        currentPrincipal: String? = nil,
        authorityProvider: (() -> String?)? = nil,
        principalProvider: (() -> String?)? = nil
    ) -> RequestStore {
        let pickupStorage = storage ?? InMemoryPendingPlacedPickupStorage()
        let currentAuthority = authorityProvider ?? { self.authority }
        let currentPrincipalProvider = principalProvider ?? { currentPrincipal ?? self.principal }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlacedOrderContinuationURLProtocol.self]
        let service = RequestService(client: APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://commonplate.test")!),
            session: URLSession(configuration: configuration)
        ))
        return RequestStore(
            service: service,
            installationCredentialProvider: { "test-installation" },
            participantAuthorityProvider: currentAuthority,
            participantAuthorityRejected: {},
            participantPrincipalProvider: currentPrincipalProvider,
            pendingPlacedPickupStorage: pickupStorage
        )
    }

    private func request(id: String, createdAt: Date = Date()) -> FoodRequest {
        FoodRequest(
            id: id,
            diningSpot: DiningSpot(name: "Crave NYU", address: "60 Washington Sq S"),
            foodDescription: "Rice bowl",
            pickupWindowText: "ASAP",
            mealSwipes: 2,
            windowStart: nil,
            windowEnd: nil,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(86_400),
            status: .placed,
            ownership: .own
        )
    }

    private func placedOrder(id: String, createdAt: Date = Date()) -> PlacedOrder {
        PlacedOrder(
            request: request(id: id, createdAt: createdAt),
            orderNumber: "70154321",
            etaText: "15 minutes",
            placedAt: createdAt,
            estimatedReadyAt: createdAt.addingTimeInterval(900),
            serverNow: createdAt,
            monotonicReadAt: 100
        )
    }

    private func pickupResponse(requestID: String) -> Data {
        json([
            "requestId": requestID,
            "pickupConfirmation": [
                "status": "confirmed",
                "confirmedAt": timestamp
            ]
        ])
    }

    private func listResponse(ids: [String]) -> Data {
        json([
            "orders": ids.map { placedOrderObject(id: $0) },
            "serverNow": timestamp
        ])
    }

    private func detailResponse(id: String, pickupStatus: String) -> Data {
        json([
            "order": placedOrderObject(
                id: id,
                pickupStatus: pickupStatus,
                contactHelperEmail: "helper@example.edu"
            ),
            "serverNow": timestamp
        ])
    }

    private func placedOrderObject(
        id: String,
        pickupStatus: String? = nil,
        contactHelperEmail: String? = nil
    ) -> [String: Any] {
        var order: [String: Any] = [
            "id": id,
            "vendor": "Crave NYU",
            "food": "Rice bowl",
            "pickupWindowText": "ASAP",
            "mealSwipes": 2,
            "menuPath": "meal-exchange",
            "mealItems": [],
            "orderDetails": NSNull(),
            "estimatedDiningDollarsCents": NSNull(),
            "windowStart": NSNull(),
            "windowEnd": NSNull(),
            "status": "placed",
            "createdAt": timestamp,
            "expiresAt": "2026-10-20T17:00:00.000Z",
            "isOwnRequest": true,
            "orderNumber": "70154321",
            "etaText": "15 minutes",
            "placedAt": timestamp,
            "estimatedReadyAt": "2026-10-19T17:15:00.000Z"
        ]
        if let pickupStatus {
            order["pickupConfirmation"] = [
                "status": pickupStatus,
                "confirmedAt": pickupStatus == "confirmed" ? timestamp : NSNull()
            ] as [String: Any]
        }
        if let contactHelperEmail {
            order["contactHelperEmail"] = contactHelperEmail
        }
        return order
    }

    private var timestamp: String { "2026-10-19T17:00:00.000Z" }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func fileSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private final class PlacedOrderContinuationIdentityBox {
    var authority: String?
    var principal: String?

    init(authority: String?, principal: String?) {
        self.authority = authority
        self.principal = principal
    }
}

private final class PlacedOrderContinuationURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
        let error: URLError.Code?
        let cacheStoragePolicy: URLCache.StoragePolicy

        static func response(
            statusCode: Int,
            data: Data,
            headers: [String: String] = ["Content-Type": "application/json"],
            cacheStoragePolicy: URLCache.StoragePolicy = .notAllowed
        ) -> Stub {
            Stub(
                statusCode: statusCode,
                data: data,
                headers: headers,
                error: nil,
                cacheStoragePolicy: cacheStoragePolicy
            )
        }

        static func failure(_ error: URLError.Code) -> Stub {
            Stub(
                statusCode: 0,
                data: Data(),
                headers: [:],
                error: error,
                cacheStoragePolicy: .notAllowed
            )
        }
    }

    struct Captured {
        let path: String
        let method: String
        let headers: [String: String]
        let cachePolicy: URLRequest.CachePolicy
        let body: Data?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [Stub] = []
    private nonisolated(unsafe) static var captured: [Captured] = []

    static func enqueue(_ stub: Stub) {
        lock.lock()
        defer { lock.unlock() }
        stubs.append(stub)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
        captured.removeAll()
    }

    static var capturedRequests: [Captured] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private static func take(_ request: URLRequest) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        captured.append(Captured(
            path: request.url?.path ?? "",
            method: request.httpMethod ?? "",
            headers: (request.allHTTPHeaderFields ?? [:]).reduce(into: [:]) {
                $0[$1.key.lowercased()] = $1.value
            },
            cachePolicy: request.cachePolicy,
            body: request.httpBody
        ))
        return stubs.isEmpty ? nil : stubs.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "commonplate.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.take(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: stub.cacheStoragePolicy)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
