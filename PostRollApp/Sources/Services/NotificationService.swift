import AppKit
import UserNotifications

/// Handles macOS notifications and Dock badge for PostRoll background steps.
/// Badge count = events where a background process just finished and needs review.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private override init() { super.init() }

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Foreground delivery

    // Without this, macOS silently drops banners when PostRoll is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Step notifications

    func notifyOCRComplete(eventName: String) {
        send(
            title: "\(eventName): OCR Complete",
            body: "Review the extracted performers and program notes."
        )
    }

    func notifyGenerationComplete(eventName: String) {
        send(
            title: "\(eventName): Captions Ready",
            body: "Review your generated captions before exporting."
        )
    }

    func notifyRegenerationComplete(eventName: String, what: String) {
        send(
            title: "\(eventName): \(what) Regenerated",
            body: "Ready for review."
        )
    }

    func notifyExportComplete(eventName: String) {
        send(
            title: "\(eventName): Exported",
            body: "All assets are in your output folder."
        )
    }

    func notifyHandleLookupComplete(eventName: String, count: Int) {
        send(
            title: "\(eventName): Handle Lookup Done",
            body: count > 0
                ? "Found \(count) Instagram suggestion\(count == 1 ? "" : "s"). Verify and accept below."
                : "No Instagram accounts found for these performers."
        )
    }

    func notifyWebPerformersFetched(eventName: String, count: Int) {
        send(
            title: "\(eventName): Performers Fetched",
            body: "Found \(count) performer\(count == 1 ? "" : "s") from the event page."
        )
    }

    func notifyEnrichmentComplete(eventName: String) {
        send(
            title: "\(eventName): Enrichment Done",
            body: "Web research complete. Review the updated program data."
        )
    }

    // MARK: - Dock badge

    /// Show badge only when the app is in the background — the user doesn't
    /// need a badge while they're actively looking at the window.
    func updateBadge(events: [Event]) {
        guard !NSApplication.shared.isActive else {
            NSApplication.shared.dockTile.badgeLabel = nil
            return
        }
        let count = events.filter {
            $0.stage == .ocrDone || $0.stage == .assetsGenerated
        }.count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Clear on activate

    /// Remove all delivered notifications from Notification Center.
    /// Call when the app becomes active so banners don't linger.
    func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Private

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
