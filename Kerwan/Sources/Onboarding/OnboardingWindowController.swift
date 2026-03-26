import AppKit
import SwiftUI
import os

// MARK: - OnboardingWindowController

/// Owns and manages the first-launch onboarding window.
///
/// The window is a fixed-size (600 × 500) panel with a title bar, centred on
/// the primary screen. It hosts `OnboardingView` via `NSHostingView`.
///
/// **Lifecycle:**
/// `KerwanAppDelegate` creates this object at launch and calls `showIfNeeded()`.
/// When the user taps "Open Kerwan" on the final step, `OnboardingViewModel`
/// posts `.kerwanOnboardingCompleted`; this controller observes that notification,
/// closes the window, and triggers the main window + capture start via the
/// delegate callback.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "OnboardingWindowController"
    )

    // MARK: - State

    private(set) var vm: OnboardingViewModel
    private var window: NSWindow?

    /// Called when the user finishes (or re-finishes) onboarding.
    var onComplete: (() -> Void)?

    // MARK: - Init

    /// Explicit initialiser avoids a Swift 5.10 LLVM IR-generation crash
    /// (SmallVector overflow in DIExpression) that occurs when a complex
    /// `@Observable` class is instantiated as a stored-property default value.
    override init() {
        vm = OnboardingViewModel()
        super.init()
    }

    // MARK: - Public API

    /// Shows the onboarding window if onboarding has not been completed yet.
    /// Safe to call on every launch; no-ops if already done.
    func showIfNeeded() {
        guard !OnboardingViewModel.isCompleted else {
            Self.logger.debug("Onboarding already completed — skipping")
            return
        }
        show()
    }

    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.logger.info("Onboarding window shown (step=\(self.vm.currentStep.rawValue, privacy: .public))")
    }

    // MARK: - Window construction

    private func buildWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to Kerwan"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let rootView = OnboardingView(vm: vm)
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = .preferredContentSize
        panel.contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onboardingCompleted),
            name: .kerwanOnboardingCompleted,
            object: nil
        )

        self.window = panel
    }

    // MARK: - Completion handler

    @objc private func onboardingCompleted() {
        Self.logger.info("Onboarding completed — closing window")
        window?.orderOut(nil)
        onComplete?()
    }

    // MARK: - NSWindowDelegate

    /// Prevent the user from accidentally abandoning onboarding mid-way by
    /// sending them directly to step 1 if they close from a middle step.
    nonisolated func windowWillClose(_ notification: Notification) {
        // Intentionally do nothing — the window will be re-opened by showIfNeeded()
        // on next launch, resuming from the persisted step.
        MainActor.assumeIsolated {
            Self.logger.debug("Onboarding window closed (will resume on next launch)")
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by `OnboardingViewModel.complete()` when the user taps
    /// "Open Kerwan" on the final onboarding step.
    static let kerwanOnboardingCompleted = Notification.Name("com.kerwan.app.onboardingCompleted")
}
