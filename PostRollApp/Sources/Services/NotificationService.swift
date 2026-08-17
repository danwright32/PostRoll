import AppKit
import UserNotifications

/// Deletes program-image copies that PostRoll wrote into its own `programs/`
/// folder, under the data root. Refuses to touch URLs outside that folder so a
/// user's source files (e.g. originals in ~/Downloads) are never deleted.
///
/// Named off `AppPaths` rather than spelled out, because the code has always
/// read the live path and a comment naming a fixed one goes stale silently: it
/// said ~/Documents/PostRoll/programs long after the data moved to Application
/// Support (#648, same class as #101).
enum ProgramImageCleanup {
    static func delete(urls: [URL]) {
        let programsDir = AppPaths.programsDir.standardizedFileURL.path
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(programsDir + "/") else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// Handles macOS notifications and Dock badge for PostRoll background steps.
/// Badge count = events where a background process just finished and needs review.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private override init() { super.init() }

    /// Count of completed background processes that the user hasn't acknowledged
    /// yet (by activating the app). Reset to 0 on `clearBadge()`.
    private var pendingCount: Int = 0

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

    /// Increment the unacknowledged-process count and refresh the dock badge.
    /// If the app is currently active the badge stays hidden — the user is
    /// already looking, so the count starts accumulating from 0 again.
    func incrementBadge() {
        guard !NSApplication.shared.isActive else { return }
        pendingCount += 1
        NSApplication.shared.dockTile.badgeLabel = "\(pendingCount)"
    }

    /// Clear the badge and reset the pending count. Called when the app
    /// becomes active — the user has now seen whatever finished.
    func clearBadge() {
        pendingCount = 0
        NSApplication.shared.dockTile.badgeLabel = nil
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
        incrementBadge()
    }
}
