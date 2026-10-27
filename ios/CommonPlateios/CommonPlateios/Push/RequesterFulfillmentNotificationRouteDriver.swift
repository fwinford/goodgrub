import Foundation

enum RequesterFulfillmentNotificationResolution: Equatable {
    case placedOrder
    case unavailable
    case temporarilyUnavailable
}

@MainActor
protocol RequesterFulfillmentNotificationResolving: AnyObject {
    func resolveRequesterFulfillmentNotification(requestID: String) async throws -> RequesterFulfillmentNotificationResolution
    func reportRequestUnavailableFromNotification(requestID: String)
    func reportRequestTemporarilyUnavailableFromNotification(requestID: String)
}

extension RequestStore: RequesterFulfillmentNotificationResolving {
    func resolveRequesterFulfillmentNotification(
        requestID: String
    ) async throws -> RequesterFulfillmentNotificationResolution {
        do {
            let detail = try await fetchPlacedOrder(id: requestID)
            return detail.pickupConfirmation == .pending ? .placedOrder : .unavailable
        } catch is CancellationError {
            throw CancellationError()
        } catch RequestServiceError.serverError(let code, _) where code == "PLACED_ORDER_NOT_FOUND" {
            return .unavailable
        } catch {
            if RequestReadClassification(error) == .authorityInvalid ||
                RequestReadClassification(error) == .authorityRequired {
                return .unavailable
            }
            return .temporarilyUnavailable
        }
    }
}

@MainActor
enum RequesterFulfillmentNotificationRouteDriver {
    static func routeIfNeeded(
        router: HelperNotificationRouter,
        resolver: some RequesterFulfillmentNotificationResolving
    ) async -> [AppRoute]? {
        guard let intent = router.pendingRequesterFulfillmentIntent else { return nil }
        let resolution: RequesterFulfillmentNotificationResolution
        do {
            resolution = try await resolver.resolveRequesterFulfillmentNotification(requestID: intent.requestID)
        } catch {
            // Only cancellation escapes the resolver; an interrupted attempt
            // keeps the captured intent for the next scene readiness signal.
            return nil
        }
        guard !Task.isCancelled, router.pendingRequesterFulfillmentIntent == intent else { return nil }
        router.markRequesterFulfillmentIntentHandled(tapSequence: intent.tapSequence)
        guard intent.tapSequence == router.latestTapSequence else { return nil }
        switch resolution {
        case .placedOrder:
            return AppRoute.afterRequesterFulfillmentNotification(requestID: intent.requestID)
        case .unavailable:
            resolver.reportRequestUnavailableFromNotification(requestID: intent.requestID)
        case .temporarilyUnavailable:
            resolver.reportRequestTemporarilyUnavailableFromNotification(requestID: intent.requestID)
        }
        return []
    }
}
