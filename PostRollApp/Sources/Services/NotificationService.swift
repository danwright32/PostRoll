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

    // MARK: - Dock badge

    /// Call after every event list change. Badge = events awaiting review.
    func updateBadge(events: [Event]) {
        let count = events.filter {
            $0.stage == .ocrDone || $0.stage == .assetsGenerated
        }.count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
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
