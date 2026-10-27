//
//  RemoteNotificationRegistrarTimeoutTests.swift
//  CommonPlateiosTests
//
// Focused coverage for the real `UIKitRemoteNotificationRegistrar` — the
// bounded timeout race and the app-delegate callback bridge it implements.
// `PushSubscriptionStoreTests` covers how the store reacts to what this class
// returns; this file covers whether this class itself behaves correctly,
// using `isAwaitingCallback` to synchronize with the real continuation
// instead of racing it with sleeps.
import XCTest
@testable import CommonPlateios

@MainActor
final class RemoteNotificationRegistrarTimeoutTests: XCTestCase {
    func testTimesOutWhenNoCallbackArrivesWithinTheBound() async {
        let registrar = UIKitRemoteNotificationRegistrar()
        let start = ContinuousClock.now

        do {
            _ = try await registrar.registerAndAwaitToken(timeout: .milliseconds(50))
            XCTFail("expected a timeout")
        } catch let error as RemoteNotificationRegistrationError {
            guard case .timedOut = error else {
                XCTFail("expected .timedOut, got \(error)")
                return
            }
        } catch {
            XCTFail("expected RemoteNotificationRegistrationError, got \(error)")
        }

        // Bounded well above the configured timeout but far below a hang, so
        // a regression that stops racing the timeout — and waits forever
        // instead — fails this test instead of hanging the suite.
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testReturnsTheNormalizedTokenWhenTheAppDelegateCallbackArrivesFirst() async throws {
        let registrar = UIKitRemoteNotificationRegistrar()
        let resultTask = Task { try await registrar.registerAndAwaitToken(timeout: .seconds(10)) }

        await waitUntilAwaitingCallback(registrar)
        registrar.received(deviceToken: Data([0x00, 0x0F, 0xAB]))

        let token = try await resultTask.value
        XCTAssertEqual(token, "000fab")
    }

    func testThrowsASystemErrorWhenTheAppDelegateReportsRegistrationFailure() async {
        let registrar = UIKitRemoteNotificationRegistrar()
        let resultTask = Task { try await registrar.registerAndAwaitToken(timeout: .seconds(10)) }

        await waitUntilAwaitingCallback(registrar)
        registrar.failed(error: URLError(.notConnectedToInternet))

        do {
            _ = try await resultTask.value
            XCTFail("expected a thrown error")
        } catch let error as RemoteNotificationRegistrationError {
            guard case .system = error else {
                XCTFail("expected .system, got \(error)")
                return
            }
        } catch {
            XCTFail("expected RemoteNotificationRegistrationError, got \(error)")
        }
    }

    private func waitUntilAwaitingCallback(
        _ registrar: UIKitRemoteNotificationRegistrar,
        timeoutIterations: Int = 500
    ) async {
        for _ in 0..<timeoutIterations {
            if registrar.isAwaitingCallback { return }
            await Task.yield()
        }
        XCTFail("registrar never began awaiting a callback")
    }
}
