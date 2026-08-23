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

    // MARK: - When work does not finish

    /// A run that stopped because something went wrong (#863).
    ///
    /// Every notification above this is a completion. The failure paths said
    /// nothing at all, on purpose: a failed run is not a completion and there
    /// was no other sentence to send. With the window closed that made a dead
    /// run, a running one and a finished one produce exactly the same evidence,
    /// which is none, and the one that needs doing something about was the one
    /// that said least (L11).
    ///
    /// Silent while PostRoll is frontmost, the same rule the badge already
    /// follows: the screen is showing the failure and a banner over it is the
    /// noise that teaches him to wave banners away (L36). The case this exists
    /// for is the one where he is not looking.
    func notifyWorkFailed(work: String, eventName: String, reason: String?) {
        guard !NSApplication.shared.isActive else { return }
        let announcement = WorkOutcome.failed(work: work, eventName: eventName, reason: reason)
        send(title: announcement.title, body: announcement.body)
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

    // MARK: - Work in flight (#863)

    /// Which trackers have something running, and for how long.
    private var activity = WorkActivity()

    /// What the Dock is currently being told, so a tick that changes nothing
    /// does not redraw the tile once a second for the whole of a long run.
    private var shownWork: DockWork = .idle

    /// One tracker's answer to "is anything of yours running".
    ///
    /// Called from `JobTracker` on every transition and on every tick, because
    /// that is the one place every manager's work passes through. Before this,
    /// closing the window left a generation running with no window, no progress
    /// and nothing in the Dock saying so, and the only way to tell it was
    /// happening was to open the window again (#863).
    func reportWork(_ owner: AnyObject, runningFor seconds: Int?) {
        activity.report(owner, runningFor: seconds)
        activity.forgetOwnersThatWentAway()

        let now = activity.state
        guard now != shownWork else { return }
        shownWork = now
        showWork(now)
    }

    /// What the Dock says while work is running.
    ///
    /// Deliberately NOT the badge. The badge counts work that has FINISHED and
    /// not been looked at, and one number meaning two things is a number that
    /// says neither (L118). This is a separate mark, and it carries the elapsed
    /// time so it is a still alive signal rather than a working one.
    ///
    /// Compiled out of the test bundle for the same reason `send` is: a test
    /// bundle has no real app to own a Dock tile.
    #if POSTROLL_TESTS
    private func showWork(_ work: DockWork) {}
    #else
    private func showWork(_ work: DockWork) {
        switch work {
        case .idle:
            NSApplication.shared.dockTile.contentView = nil
        case .working(let seconds):
            let tile = NSApplication.shared.dockTile
            tile.contentView = WorkingDockTile(seconds: seconds)
        }
        NSApplication.shared.dockTile.display()
    }
    #endif

    // MARK: - Clear on activate

    /// Remove all delivered notifications from Notification Center.
    /// Call when the app becomes active so banners don't linger.
    func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Private

    /// Posting a notification needs a real app bundle, and a test bundle is not
    /// one: `UNUserNotificationCenter.current()` raises rather than failing, so
    /// any test that reaches a manager which reports its own completion dies
    /// inside AppKit with a message about a bundle proxy (#707).
    ///
    /// Compiled only into the test bundle, the same way every other seam here
    /// is, so the shipping app cannot end up silently not notifying.
    #if POSTROLL_TESTS
    private func send(title: String, body: String) {
        pendingCount += 1
    }
    #else
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
    #endif
}
