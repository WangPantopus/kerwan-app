import AppKit
import SwiftUI
import UserNotifications
import os

/// Manages the floating `NSPanel` that displays pre-call briefings.
///
/// Observes `.kerwanBriefingReady` and shows a non-activating panel near the
/// top-right of the main screen. The panel:
/// - Does not steal keyboard focus (`nonactivatingPanel` style mask).
/// - Floats above all app windows (`.floating` window level).
/// - Appears on all Spaces (`canJoinAllSpaces`).
/// - Auto-dismisses 5 minutes after the meeting's start time.
/// - Dismisses immediately when the user taps "Dismiss".
/// - Tapping an attendee name navigates to their profile in the main window.
@MainActor
final class BriefingWindowController {

    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "BriefingWindowController"
    )

    // MARK: - State

    private var panel: NSPanel?
    private var autoDismissTask: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?

    weak var appDelegate: KerwanAppDelegate?

    // MARK: - Setup

    /// Call once from `applicationDidFinishLaunching`.
    func start(appDelegate: KerwanAppDelegate) {
        self.appDelegate = appDelegate

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .kerwanBriefingReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let briefing = notification.userInfo?[BriefingNotificationKey.briefing] as? PreCallBriefing
            else { return }
            Task { @MainActor in self.showBriefing(briefing) }
        }

        Self.logger.info("BriefingWindowController started")
    }

    func stop() {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        notificationObserver = nil
        dismiss()
    }

    // MARK: - Show

    func showBriefing(_ briefing: PreCallBriefing) {
        dismiss() // Replace any existing panel

        let rootView = BriefingPanelView(
            briefing: briefing,
            onDismiss: { [weak self] in self?.dismiss() },
            onSelectContact: { [weak self] contact in self?.openContact(contact) }
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]

        // Measure the ideal size before creating the window
        let fittingSize = hostingView.fittingSize
        let panelWidth:  CGFloat = 400
        let panelHeight: CGFloat = max(260, min(fittingSize.height, 420))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask:   [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.contentView                = hostingView
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility            = .hidden
        panel.isMovableByWindowBackground = true
        panel.level                      = .floating
        panel.collectionBehavior         = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed       = false
        panel.animationBehavior          = .utilityWindow

        // Position: top-right corner of the main screen, inset by 20 pt
        positionPanel(panel, width: panelWidth, height: panelHeight)

        self.panel = panel
        panel.orderFrontRegardless()

        Self.logger.info("Briefing panel shown for '\(briefing.event.title, privacy: .public)'")

        // Auto-dismiss 5 min after meeting start (or immediately if already past)
        let autoDismissAt = briefing.event.startDate.addingTimeInterval(5 * 60)
        let delay         = max(1, autoDismissAt.timeIntervalSinceNow)

        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            Self.logger.info("Briefing panel auto-dismissed after \(Int(delay))s")
            self?.dismiss()
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Navigation

    private func openContact(_ contact: Contact) {
        dismiss()
        appDelegate?.openMainWindow()
        // Small delay to let the window open before setting state
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.appDelegate?.appState.selectedContact = contact
        }
    }

    // MARK: - Helpers

    private func positionPanel(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 20
        let x = screen.visibleFrame.maxX - width  - margin
        let y = screen.visibleFrame.maxY - height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
