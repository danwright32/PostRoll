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

    /// Delivered on the main queue unless `queue` says otherwise (#1486).
    ///
    /// A post runs its observers on the posting thread when no queue is given,
    /// and work moved off main posts from off main (L1017). An observer that
    /// touched main-actor state from there would race the UI, so main is the
    /// default and a caller that genuinely wants the posting thread passes nil.
    init(center: NotificationCenter,
         name: Notification.Name,
         object: Any? = nil,
         queue: OperationQueue? = .main,
         using block: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        self.token = center.addObserver(forName: name, object: object,
                                        queue: queue, using: block)
    }

    deinit {
        center.removeObserver(token)
    }
}
