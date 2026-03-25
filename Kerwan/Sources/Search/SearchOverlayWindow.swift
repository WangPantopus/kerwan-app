import AppKit

/// A borderless, floating NSWindow that hosts the global search overlay.
///
/// Visual characteristics:
/// - `.borderless` style mask so there is no title bar or chrome
/// - `.floating` window level so it appears above normal application windows
/// - Transparent background — the hosted SwiftUI view provides `.ultraThinMaterial`
/// - `hasShadow = true` for depth; the shadow shape tracks the hosted view's
///   rounded rectangle because the window background is clear
///
/// Key routing:
/// `SearchOverlayWindow` intercepts arrow keys, Return, and Escape before they
/// reach the text field's default handlers. Regular printable keys and the Tab
/// key are forwarded to the responder chain so the text field receives them.
final class SearchOverlayWindow: NSWindow {

    // MARK: - Callbacks set by SearchOverlayController

    /// Called when the user presses Escape.
    var onEscape: (() -> Void)?
    /// Called when the user presses the Up arrow.
    var onMoveUp: (() -> Void)?
    /// Called when the user presses the Down arrow.
    var onMoveDown: (() -> Void)?
    /// Called when the user presses Return or numpad Enter.
    var onConfirm: (() -> Void)?

    // MARK: - Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 64),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        level                = .floating
        backgroundColor      = .clear
        isOpaque             = false
        hasShadow            = true
        isMovableByWindowBackground = false
        isRestorable         = false

        // Exclude from the Window menu, Exposé, and the app switcher thumbnail.
        collectionBehavior   = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        // Dismiss when the user switches to another app or clicks another window.
        hidesOnDeactivate    = false   // handled manually in SearchOverlayController
    }

    // MARK: - Key window support

    /// A borderless window must override this to accept keyboard focus.
    override var canBecomeKey: Bool  { true  }
    /// The search overlay should never become the main (title-bar-highlighted) window.
    override var canBecomeMain: Bool { false }

    // MARK: - Keyboard routing

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:      // Escape
            onEscape?()
        case 126:     // Up arrow
            onMoveUp?()
        case 125:     // Down arrow
            onMoveDown?()
        case 36, 76:  // Return / numpad Enter
            onConfirm?()
        default:
            // Everything else (printable characters, Delete, Tab …) goes to the
            // text field through the normal responder chain.
            super.keyDown(with: event)
        }
    }
}
