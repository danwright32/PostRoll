import Foundation

/// An observer that takes itself off the centre it registered with.
///
/// A notification centre is a long-lived shared host that holds what registers
/// with it unowned, so an observer added by something shorter-lived outlives it
/// and keeps firing into a value nobody holds any more (L86). Tying the
/// registration to an object means the removal cannot be forgotten: when the
/// thing holding this lets go, the observer goes with it.
final class NotificationSubscription {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter,
         name: Notification.Name,
         object: Any? = nil,
         using block: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        self.token = center.addObserver(forName: name, object: object,
                                        queue: nil, using: block)
    }

    deinit {
        center.removeObserver(token)
    }
}
