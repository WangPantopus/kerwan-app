// AccessibilityCaptureService.swift
// Kerwan — Capture layer
//
// Tracks app/window focus via the macOS Accessibility API and NSWorkspace
// notifications. Produces RawEvents with source .appFocus (and optionally
// .slack) that feed into RawEventBuffer for AI classification.
//
// Threading model
// ───────────────
// • The service is @MainActor — NSWorkspace notifications arrive on the
//   main thread and all mutable state is main-thread-confined.
// • AX queries are raced against a 500 ms timeout on the cooperative pool
//   so that hung apps cannot stall the main thread.
// • Delegate calls are awaited across actor boundaries (safe via AnyActor).
//
// Debounce semantics
// ──────────────────
// Rapid round-trips (switch away then back within 2 s) discard the interim
// event and open a fresh event for the returning app.  This prevents brief
// accidental focus changes from polluting the timeline.

import AppKit
import ApplicationServices
import os

// MARK: - CaptureError

/// Errors thrown by the Accessibility capture subsystem.
public enum CaptureError: Error, LocalizedError, Sendable {
    /// An AX query did not return a result within the allowed window.
    case axQueryTimeout
    /// The Accessibility API returned an unexpected error code.
    case axError(AXError)
    /// Accessibility permission has not been granted.
    case permissionDenied
    /// Slack message scraping could not locate the message list element.
    case slackScrapingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .axQueryTimeout:
            return "Accessibility query timed out after 500 ms"
        case .axError(let code):
            return "AX API error \(code.rawValue)"
        case .permissionDenied:
            return "Accessibility permission not granted — visit System Settings › Privacy & Security"
        case .slackScrapingFailed(let reason):
            return "Slack scraping failed: \(reason)"
        }
    }
}

// MARK: - AccessibilityCaptureService

/// Tracks which app and window the user is focused on using the macOS
/// Accessibility API and NSWorkspace notifications.
///
/// ## Lifecycle
/// ```swift
/// let service = AccessibilityCaptureService(delegate: buffer, environment: .live(exclusionEngine: engine))
/// service.start()
/// // …
/// await service.stop()
/// ```
///
/// ## Events produced
/// - `.appFocus` — on every app/window-title change.
/// - `.slack`    — alongside `.appFocus` when Slack is active (optional, may fail gracefully).
@MainActor
public final class AccessibilityCaptureService {

    // MARK: - Environment

    /// All side-effecting dependencies, injectable for unit testing.
    ///
    /// In production use `Environment.live(exclusionEngine:)`.
    /// In tests supply a struct with closures that return canned responses.
    public struct Environment: @unchecked Sendable {

        // MARK: Workspace

        /// Notification center to observe. Default: `NSWorkspace.shared.notificationCenter`.
        var notificationCenter: NotificationCenter

        /// Returns the currently frontmost application, or nil when only the
        /// desktop has focus.
        var frontmostApplication: @Sendable () -> NSRunningApplication?

        // MARK: AX

        /// Queries the focused window title for a given PID.
        /// The closure is responsible for applying an internal timeout.
        var queryWindowTitle: @Sendable (_ pid: pid_t) async -> String?

        // MARK: Trust

        /// Returns whether the current process has Accessibility permission.
        var isProcessTrusted: @Sendable () -> Bool

        /// Triggers the system prompt for Accessibility access.
        var requestTrust: @Sendable () -> Bool

        // MARK: Policy

        /// Events shorter than this are dropped as noise. Default: 0.1 s.
        /// Set to 0 in tests to observe all events regardless of duration.
        var minimumEventDuration: TimeInterval

        /// Debounce window in seconds. Return to the same app within this
        /// interval to discard the interim event. Default: 2 s.
        var debounceInterval: TimeInterval

        /// Checks whether a produced event should be suppressed.
        var exclusionEngine: any ExclusionChecking

        // MARK: Production factory

        /// Constructs a live environment backed by real system APIs.
        public static func live(exclusionEngine: some ExclusionChecking) -> Environment {
            Environment(
                notificationCenter: NSWorkspace.shared.notificationCenter,
                frontmostApplication: { NSWorkspace.shared.frontmostApplication },
                queryWindowTitle: { pid in
                    await AccessibilityCaptureService.axWindowTitle(for: pid)
                },
                isProcessTrusted: { AXIsProcessTrusted() },
                requestTrust: {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
                        as CFDictionary
                    return AXIsProcessTrustedWithOptions(options)
                },
                minimumEventDuration: 0.1,
                debounceInterval: 2.0,
                exclusionEngine: exclusionEngine
            )
        }
    }

    // MARK: - Private state

    private let log = Logger(subsystem: "com.kerwan.app", category: "AccessibilityCaptureService")
    private let environment: Environment

    private weak var delegate: (any CaptureEventDelegate)?

    /// The currently open (in-progress) event — has no `endedAt`.
    private var currentEvent: RawEvent?

    /// PID of the app whose window is currently being tracked.
    private var currentPID: pid_t?

    /// Most-recently observed window title for the current app.
    private var currentWindowTitle: String?

    /// Debounce table: maps app name → (closed event, time it was closed).
    ///
    /// An entry is alive while there is still a chance the user will return
    /// within the debounce window. Entries are pruned on every activation.
    private var recentlyClosed: [String: (event: RawEvent, closedAt: Date)] = [:]

    /// Runs the 5-second window-title polling loop.
    private var pollingTask: Task<Void, Never>?

    /// NSNotificationCenter token for `NSWorkspace.didActivateApplicationNotification`.
    private var activationToken: NSObjectProtocol?

    /// `true` between `start()` and the matching `stop()`.
    public private(set) var isRunning = false

    // MARK: - Init / deinit

    /// Creates an `AccessibilityCaptureService`.
    ///
    /// - Parameters:
    ///   - delegate: The actor that receives captured events (typically `RawEventBuffer`).
    ///   - environment: Injectable dependencies. Pass `.live(exclusionEngine:)` in production.
    public init(
        delegate: some CaptureEventDelegate,
        environment: Environment
    ) {
        self.delegate = delegate
        self.environment = environment
    }

    deinit {
        // Synchronous cleanup. Callers should await stop() before releasing.
        pollingTask?.cancel()
        if let token = activationToken {
            environment.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Public API

    /// Starts capturing app-focus events.
    ///
    /// If accessibility permission is not granted the service logs a warning
    /// and triggers the system prompt. Capture continues and will succeed
    /// automatically once the user grants access and the next switch occurs.
    public func start() {
        guard !isRunning else {
            log.warning("start() called while already running — ignored")
            return
        }

        if !environment.isProcessTrusted() {
            log.warning("Accessibility permission not granted; requesting via system prompt")
            _ = environment.requestTrust()
        }

        isRunning = true
        registerNotifications()
        startPolling()

        // Capture whatever is already focused so we don't lose the first event.
        if let app = environment.frontmostApplication() {
            Task { @MainActor [weak self] in
                await self?.handleActivation(
                    appName: app.localizedName ?? "Unknown",
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier ?? ""
                )
            }
        }

        log.info("AccessibilityCaptureService started")
    }

    /// Stops the service and finalizes any open event.
    ///
    /// Safe to call multiple times.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        pollingTask?.cancel()
        pollingTask = nil

        if let token = activationToken {
            environment.notificationCenter.removeObserver(token)
            activationToken = nil
        }

        if let open = currentEvent {
            await emitIfAllowed(open.closed())
            currentEvent = nil
            currentPID = nil
            currentWindowTitle = nil
        }

        log.info("AccessibilityCaptureService stopped")
    }

    /// Shows the macOS system dialog requesting Accessibility access.
    /// No-op when the process is already trusted.
    public func requestAccessibilityPermission() {
        guard !environment.isProcessTrusted() else { return }
        _ = environment.requestTrust()
    }

    // MARK: - Notification registration

    private func registerNotifications() {
        activationToken = environment.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleActivation(
                    appName: app.localizedName ?? "Unknown",
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier ?? ""
                )
            }
        }
    }

    // MARK: - App activation handler

    /// Core handler for every app-focus change.
    ///
    /// Accessible internally so tests can exercise the business logic directly
    /// without needing to post real `NSWorkspace` notifications.
    ///
    /// - Parameters:
    ///   - appName: Localized display name of the newly focused app.
    ///   - pid:     Unix process identifier.
    ///   - bundleID: Bundle identifier (empty string when unavailable).
    internal func handleActivation(appName: String, pid: pid_t, bundleID: String) async {
        guard isRunning else { return }
        let now = Date()

        // ── Ignore duplicate notifications for the same app ───────────────────
        if let open = currentEvent, open.sourceApp == appName {
            log.debug("Duplicate activation '\(appName)' — ignored")
            return
        }

        // ── Debounce: returning to a recently-closed app ───────────────────────
        // If the user switched away and is back within the debounce window,
        // discard the interim event and open a fresh event for this app.
        // This prevents brief accidental focus changes from polluting the timeline.
        if let (_, closedAt) = recentlyClosed[appName],
           now.timeIntervalSince(closedAt) < environment.debounceInterval
        {
            let gap = now.timeIntervalSince(closedAt)
            log.debug("Debounce: '\(appName)' returned after \(String(format: "%.3f", gap))s — discarding interim")

            // Discard the current (interim) event without emitting it.
            currentEvent = nil
            currentPID = nil
            currentWindowTitle = nil
            recentlyClosed.removeValue(forKey: appName)

            // Fall through to open a fresh event for the returning app below.
        } else {
            // ── Normal switch: close and emit the previous event ───────────────
            if let previous = currentEvent {
                let closed = previous.closed(at: now)
                if let name = previous.sourceApp {
                    recentlyClosed[name] = (closed, now)
                }
                await emitIfAllowed(closed)
                currentEvent = nil
            }
        }

        // Prune stale debounce entries
        recentlyClosed = recentlyClosed.filter {
            now.timeIntervalSince($0.value.closedAt) < environment.debounceInterval
        }

        // ── Query window title (races against 500 ms timeout) ─────────────────
        let windowTitle = await environment.queryWindowTitle(pid)

        // If AX suddenly starts returning nil where it previously worked,
        // the user may have revoked Accessibility permission.
        if windowTitle == nil && environment.isProcessTrusted() {
            log.warning("AX returned nil title for '\(appName)' (pid \(pid)) — app may not expose it")
        }

        currentPID = pid
        currentWindowTitle = windowTitle

        // ── Open new event ─────────────────────────────────────────────────────
        let metadata = AppFocusMetadata(
            bundleIdentifier: bundleID,
            windowTitle: windowTitle,
            pid: Int32(pid)
        )
        currentEvent = RawEvent(
            source: .appFocus,
            sourceApp: appName,
            startedAt: now,
            metadataJSON: metadata.jsonString
        )

        log.debug("App activated: '\(appName)' pid=\(pid) title='\(windowTitle ?? "<none>")'")

        // ── Optional Slack scraping ────────────────────────────────────────────
        if bundleID == "com.tinyspeck.slackmacgap" {
            await scrapeSlackIfPossible(pid: pid, appName: appName)
        }
    }

    // MARK: - Window-title polling

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                guard !Task.isCancelled else { break }
                await self?.pollTitleChange()
            }
        }
    }

    /// Checks whether the focused window title has changed.
    ///
    /// Called every 5 seconds to detect tab and document switches within the
    /// same app (which do not generate activation notifications).
    ///
    /// Accessible internally for direct testing.
    internal func pollTitleChange() async {
        guard isRunning,
              let pid = currentPID,
              let openEvent = currentEvent
        else { return }

        let now = Date()
        let newTitle = await environment.queryWindowTitle(pid)

        let changed: Bool
        switch (currentWindowTitle, newTitle) {
        case (.none, .none):         changed = false
        case (.some(let a), .some(let b)): changed = a != b
        default:                     changed = true   // nil↔non-nil transition
        }

        guard changed else { return }

        log.debug("Title changed for '\(openEvent.sourceApp ?? "?")': '\(self.currentWindowTitle ?? "<nil>")' → '\(newTitle ?? "<nil>")'")

        await emitIfAllowed(openEvent.closed(at: now))

        // Open a new event for the same app with the updated title.
        let bundleID = AppFocusMetadata.decode(from: openEvent.metadataJSON ?? "")?.bundleIdentifier ?? ""
        currentEvent = RawEvent(
            source: .appFocus,
            sourceApp: openEvent.sourceApp,
            startedAt: now,
            metadataJSON: AppFocusMetadata(
                bundleIdentifier: bundleID,
                windowTitle: newTitle,
                pid: Int32(pid)
            ).jsonString
        )
        currentWindowTitle = newTitle
    }

    // MARK: - Slack scraping (optional / experimental)

    /// Attempts to scrape visible Slack messages via the accessibility tree.
    ///
    /// All failures are caught and logged; they never propagate to the caller.
    /// The implementation is fragile and Slack-version-dependent by design.
    private func scrapeSlackIfPossible(pid: pid_t, appName: String) async {
        let result: Result<[SlackMessage], Error> = await Task.detached(priority: .utility) {
            Result { try AccessibilityCaptureService.extractSlackMessages(pid: pid) }
        }.value

        switch result {
        case .success(let messages) where !messages.isEmpty:
            let channel = currentWindowTitle.map { stripSlackWindowSuffix($0) }
            let meta = SlackCaptureMetadata(channel: channel, messages: messages)
            let event = RawEvent(
                source: .slack,
                sourceApp: appName,
                startedAt: Date(),
                endedAt: Date(),
                metadataJSON: meta.jsonString
            )
            await emitIfAllowed(event)

        case .success:
            break  // No visible messages — not an error

        case .failure(let error):
            log.info("Slack scraping skipped: \(error.localizedDescription)")
        }
    }

    // MARK: - Emission gate

    private func emitIfAllowed(_ event: RawEvent) async {
        guard let delegate else { return }

        if let duration = event.durationSeconds,
           duration < environment.minimumEventDuration
        {
            log.debug("Dropping short event (\(String(format: "%.3f", duration))s) for '\(event.sourceApp ?? "?")'")
            return
        }

        if environment.exclusionEngine.shouldExclude(event) {
            log.debug("ExclusionEngine blocked event: source=\(event.source.rawValue) app='\(event.sourceApp ?? "")'")
            return
        }

        await delegate.didCapture([event])
    }
}

// MARK: - AX query helpers (nonisolated, safe to call from any thread)

extension AccessibilityCaptureService {

    /// Races the synchronous AX window-title lookup against a 500 ms timeout.
    ///
    /// Returns `nil` on timeout, permission denial, or when the app has no
    /// focused window (e.g. Finder with only the desktop visible).
    static func axWindowTitle(for pid: pid_t) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask(priority: .utility) {
                AccessibilityCaptureService.syncAxWindowTitle(for: pid)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return nil  // timeout sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Blocking synchronous AX query.  Must not be called on the main thread.
    ///
    /// Returns `nil` if:
    /// - The process is not trusted (permission revoked or never granted)
    /// - The app does not expose a focused window
    /// - The window does not expose a title attribute
    private nonisolated static func syncAxWindowTitle(for pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)

        var windowRef: AnyObject?
        let windowErr = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        // Common non-error results: .noValue (no window), .apiDisabled (no permission)
        guard windowErr == .success, let rawWindow = windowRef else { return nil }

        // Confirm the returned CF object is an AXUIElement before casting
        guard CFGetTypeID(rawWindow as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        let window = rawWindow as! AXUIElement // swiftlint:disable:this force_cast — type-ID verified above

        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success else { return nil }

        return titleRef as? String
    }
}

// MARK: - Slack accessibility scraper (nonisolated)

extension AccessibilityCaptureService {

    /// Extracts up to 10 recent Slack messages from the app's accessibility tree.
    ///
    /// - Parameter pid: Process identifier of the Slack process.
    /// - Throws: `CaptureError.slackScrapingFailed` if the message list cannot
    ///   be located.
    /// - Note: Slack's AX tree structure changes between app versions. All
    ///   callers should treat failures as expected and handle them gracefully.
    nonisolated static func extractSlackMessages(pid: pid_t) throws -> [SlackMessage] {
        let app = AXUIElementCreateApplication(pid)

        guard let messageList = findAXMessageList(in: app, remainingDepth: 12) else {
            throw CaptureError.slackScrapingFailed("Could not locate message list element in AX tree")
        }

        var childCount: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(
            messageList,
            kAXChildrenAttribute as CFString,
            &childCount
        ) == .success, childCount > 0 else { return [] }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            messageList,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
        let children = childrenRef as? [AXUIElement]
        else { return [] }

        return children.suffix(10).compactMap { extractSlackMessageElement($0) }
    }

    /// Depth-first search for an AXList element that resembles a message feed.
    ///
    /// Accepts lists described as a "conversation" or "message", or any list
    /// with more than 4 children (heuristic for the message area).
    private nonisolated static func findAXMessageList(
        in element: AXUIElement,
        remainingDepth: Int
    ) -> AXUIElement? {
        guard remainingDepth > 0 else { return nil }

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)

        if (roleRef as? String) == (kAXListRole as String) {
            var descRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
            let desc = (descRef as? String ?? "").lowercased()

            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)

            if desc.contains("message") || desc.contains("conversation") || count > 4 {
                return element
            }
        }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
        let children = childrenRef as? [AXUIElement]
        else { return nil }

        for child in children {
            if let found = findAXMessageList(in: child, remainingDepth: remainingDepth - 1) {
                return found
            }
        }
        return nil
    }

    /// Extracts a `SlackMessage` from a single message AX element.
    ///
    /// Slack message elements typically contain AXStaticText children:
    /// the first is the sender name, subsequent ones form the message body.
    private nonisolated static func extractSlackMessageElement(_ element: AXUIElement) -> SlackMessage? {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
        let children = childrenRef as? [AXUIElement]
        else {
            // Fallback: some Slack versions flatten messages to a single value
            var valueRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
               let text = valueRef as? String, !text.isEmpty
            { return SlackMessage(sender: nil, text: text) }
            return nil
        }

        var texts: [String] = []
        for child in children {
            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == (kAXStaticTextRole as String) else { continue }

            var valueRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef)
            if let text = valueRef as? String, !text.isEmpty { texts.append(text) }
        }

        guard !texts.isEmpty else { return nil }
        return texts.count >= 2
            ? SlackMessage(sender: texts[0], text: texts.dropFirst().joined(separator: " "))
            : SlackMessage(sender: nil, text: texts[0])
    }
}

// MARK: - Private helpers

/// Strips Slack's " — Slack" or " | Slack" window-title suffixes.
private func stripSlackWindowSuffix(_ title: String) -> String {
    for suffix in [" — Slack", " | Slack", " - Slack"] {
        if title.hasSuffix(suffix) { return String(title.dropLast(suffix.count)) }
    }
    return title
}
