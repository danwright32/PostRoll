import XCTest

/// #1486 (L1017): a subscription delivers on the main queue unless told not to.
///
/// It subscribed with `queue: nil`, so an observer ran on whichever thread
/// posted, and one notification here is posted off main. Its only observer
/// hopped to the main actor itself; the next one need not, and would then touch
/// main-actor state from a background thread.
final class NotificationSubscriptionTests: XCTestCase {

    private let ping = Notification.Name("NotificationSubscriptionTests.ping")

    func testAPostFromABackgroundThreadIsDeliveredOnMain() {
        let center = NotificationCenter()
        let delivered = expectation(description: "delivered")
        let onMain = LockedFlag()
        let subscription = NotificationSubscription(center: center, name: ping) { _ in
            onMain.set(Thread.isMainThread)
            delivered.fulfill()
        }
        DispatchQueue.global().async { center.post(name: self.ping, object: nil) }
        wait(for: [delivered], timeout: 5)
        XCTAssertTrue(onMain.value, "the observer ran off the main thread")
        withExtendedLifetime(subscription) {}
    }

    func testACallerCanStillAskForThePostingThread() {
        let center = NotificationCenter()
        let delivered = expectation(description: "delivered")
        let onMain = LockedFlag()
        let subscription = NotificationSubscription(center: center, name: ping,
                                                    queue: nil) { _ in
            onMain.set(Thread.isMainThread)
            delivered.fulfill()
        }
        DispatchQueue.global().async { center.post(name: self.ping, object: nil) }
        wait(for: [delivered], timeout: 5)
        XCTAssertFalse(onMain.value, "an explicit nil queue was not honoured")
        withExtendedLifetime(subscription) {}
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ newValue: Bool) { lock.lock(); flag = newValue; lock.unlock() }
}
