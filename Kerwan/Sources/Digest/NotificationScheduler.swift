import Foundation
import UserNotifications
import AppKit
import os

// MARK: - NotificationScheduler

/// Manages macOS `UNUserNotificationCenter` for Kerwan digest and reminder
/// notifications.
///
/// Responsibilities:
/// - Requesting the alert/sound/badge authorisation on first launch.
/// - Registering notification categories with "Open Kerwan" and "Dismiss" actions.
/// - Scheduling repeating `UNCalendarNotificationTrigger` entries as a safety-net
///   (fires even when the app is closed, showing a generic prompt to open Kerwan).
/// - Delivering rich immediate notifications (with AI-generated body) when the
///   app IS running and `DigestGenerator` finishes.
/// - Handling notification response actions on the delegate callbacks.
///
/// `NotificationScheduler` is `@MainActor` because `UNUserNotificationCenter`
/// dispatches delegate callbacks on the main queue, and it holds a weak reference
/// to `KerwanAppDelegate` which is also main-actor-bound.
@MainActor
final class NotificationScheduler: NSObject {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "NotificationScheduler"
    )

    // MARK: - Constants

    private enum ID {
        static let dailyCalendar  = "com.kerwan.digest.daily.calendar"
        static let weeklyCalendar = "com.kerwan.digest.weekly.calendar"
        static let dailyImmediate = "com.kerwan.digest.daily.immediate"
        static let weeklyImmediate = "com.kerwan.digest.weekly.immediate"
    }

    private enum Category {
        static let digest = "KERWAN_DIGEST"
    }

    private enum Action {
        static let open    = "OPEN_KERWAN"
        static let dismiss = "DISMISS"
    }

    // MARK: - Dependencies

    weak var appDelegate: KerwanAppDelegate?

    // MARK: - Setup

    /// Call once from `applicationDidFinishLaunching`. Sets self as the
    /// `UNUserNotificationCenter` delegate and registers action categories.
    func setup(appDelegate: KerwanAppDelegate) {
        self.appDelegate = appDelegate
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: Action.open,
            title: "Open Kerwan",
            options: .foreground
        )
        let dismissAction = UNNotificationAction(
            identifier: Action.dismiss,
            title: "Dismiss",
            options: .destructive
        )
        let digestCategory = UNNotificationCategory(
            identifier: Category.digest,
            actions: [openAction, dismissAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Daily Digest ready",
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([digestCategory])
    }

    // MARK: - Permission

    /// Requests alert, sound, and badge authorisation.
    /// Returns `true` if the user granted permission (or had already done so).
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            Self.logger.info("Notification permission: \(granted ? "granted" : "denied", privacy: .public)")
            return granted
        } catch {
            Self.logger.error("Permission request error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Calendar triggers (safety-net, generic content)

    /// Schedules a repeating daily reminder at the given 24h time string ("HH:mm").
    /// This fires even if the app is not running and shows a generic "check your
    /// digest" banner. When the app IS running, `deliverDigestNotification` fires
    /// first with richer AI-generated content.
    func scheduleDailyReminder(timeString: String) async {
        let (hour, minute) = parseTime(timeString)

        var comps = DateComponents()
        comps.hour   = hour
        comps.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let content = UNMutableNotificationContent()
        content.title    = "Daily Digest ready"
        content.body     = "Open Kerwan to review your day and billing queue."
        content.sound    = .default
        content.categoryIdentifier = Category.digest

        let request = UNNotificationRequest(
            identifier: ID.dailyCalendar,
            content: content,
            trigger: trigger
        )
        await addRequest(request)
        Self.logger.info("Daily calendar trigger scheduled at \(timeString, privacy: .public)")
    }

    /// Schedules a repeating weekly reminder on `weekday` (1=Sun … 7=Sat, default 6=Fri).
    func scheduleWeeklyReminder(timeString: String, weekday: Int = 6) async {
        let (hour, minute) = parseTime(timeString)

        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour    = hour
        comps.minute  = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let content = UNMutableNotificationContent()
        content.title    = "Weekly Digest ready"
        content.body     = "Open Kerwan for your weekly billing and relationship summary."
        content.sound    = .default
        content.categoryIdentifier = Category.digest

        let request = UNNotificationRequest(
            identifier: ID.weeklyCalendar,
            content: content,
            trigger: trigger
        )
        await addRequest(request)
        Self.logger.info("Weekly calendar trigger scheduled (weekday \(weekday, privacy: .public) at \(timeString, privacy: .public))")
    }

    /// Cancels all scheduled digest notifications (call when digest time changes).
    func cancelDigestNotifications() async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [ID.dailyCalendar, ID.weeklyCalendar]
        )
        Self.logger.info("Digest calendar notifications cancelled")
    }

    /// Replaces both calendar triggers with new ones for the given time string.
    func reschedule(digestTime: String) async {
        await cancelDigestNotifications()
        await scheduleDailyReminder(timeString: digestTime)
        await scheduleWeeklyReminder(timeString: digestTime)
    }

    // MARK: - Immediate delivery (rich AI content)

    /// Delivers an immediate notification with AI-generated content.
    /// Called by `DigestGenerator` right after a digest is saved.
    /// Because `UNCalendarNotificationTrigger` fires at the same time,
    /// the immediate notification replaces the pending generic banner.
    func deliverDigestNotification(title: String, body: String, kind: DigestKind) async {
        let identifier = kind == .daily ? ID.dailyImmediate : ID.weeklyImmediate

        // Remove the generic calendar trigger for this session so it doesn't
        // fire in addition to the rich immediate one.
        let calendarId = kind == .daily ? ID.dailyCalendar : ID.weeklyCalendar
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [calendarId]
        )

        let content = UNMutableNotificationContent()
        content.title    = title
        content.body     = body
        content.sound    = .default
        content.categoryIdentifier = Category.digest
        content.interruptionLevel  = .timeSensitive

        // Re-schedule the calendar trigger for tomorrow/next-week.
        // (The caller is responsible for calling reschedule after delivery.)

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // nil = deliver immediately
        )
        await addRequest(request)
        Self.logger.info("Delivered \(kind.rawValue, privacy: .public) digest notification")
    }

    // MARK: - Helpers

    private func addRequest(_ request: UNNotificationRequest) async {
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("Failed to add notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func parseTime(_ timeString: String) -> (hour: Int, minute: Int) {
        let parts = timeString.split(separator: ":").compactMap { Int($0) }
        return (parts.count > 0 ? parts[0] : 9, parts.count > 1 ? parts[1] : 0)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationScheduler: UNUserNotificationCenterDelegate {

    /// Called when a notification is about to be presented while the app is
    /// in the foreground. Show alert + sound (skip badge — we manage that
    /// through AppState).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handles taps on the notification banner and its action buttons.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let actionId = response.actionIdentifier

        Task { @MainActor in
            switch actionId {
            case Action.open, UNNotificationDefaultActionIdentifier:
                // Tap on banner or "Open Kerwan" — bring the main window forward
                // and navigate to the Today tab.
                Self.logger.info("Notification tapped — opening main window")
                appDelegate?.openMainWindow()
                NotificationCenter.default.post(
                    name: .kerwanShowToday,
                    object: nil
                )
            case Action.dismiss, UNNotificationDismissActionIdentifier:
                Self.logger.debug("Digest notification dismissed")
            default:
                break
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted by `NotificationScheduler` when the user taps "Open Kerwan"
    /// on a digest notification. `ContentView` observes this and switches the
    /// sidebar selection to `.today`.
    static let kerwanShowToday = Notification.Name("com.kerwan.app.showToday")
}
