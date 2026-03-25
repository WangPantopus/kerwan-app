import SwiftUI

/// The set of top-level navigation destinations in the Kerwan main window sidebar.
///
/// `SidebarItem` is the canonical navigation type for the main window. It replaces
/// the earlier `NavigationItem` stub. Values are persisted via `@SceneStorage`
/// (raw `String` representation) so the selected section survives window closes.
///
/// `AppState.selectedSidebarItem` holds the programmatically-requested selection
/// (e.g., from a menu bar action); `ContentView` syncs it to `@SceneStorage`.
public enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today
    case clients
    case reviewQueue
    case billing
    case timeline
    case settings

    public var id: String { rawValue }

    // MARK: - Display

    /// Human-readable label used in the sidebar and window title.
    var title: String {
        switch self {
        case .today:       return "Today"
        case .clients:     return "Clients"
        case .reviewQueue: return "Review Queue"
        case .billing:     return "Billing"
        case .timeline:    return "Timeline"
        case .settings:    return "Settings"
        }
    }

    /// SF Symbol name for the sidebar icon.
    var systemImage: String {
        switch self {
        case .today:       return "sun.max"
        case .clients:     return "person.2"
        case .reviewQueue: return "checkmark.circle"
        case .billing:     return "dollarsign.circle"
        case .timeline:    return "clock"
        case .settings:    return "gear"
        }
    }

    // MARK: - Keyboard shortcuts (⌘1 … ⌘6)

    /// The digit character used with ⌘ to jump to this section.
    var keyEquivalent: Character {
        switch self {
        case .today:       return "1"
        case .clients:     return "2"
        case .reviewQueue: return "3"
        case .billing:     return "4"
        case .timeline:    return "5"
        case .settings:    return "6"
        }
    }

    // MARK: - Badge support

    /// Whether this item renders a live badge count when non-zero.
    var supportsBadge: Bool {
        switch self {
        case .reviewQueue, .billing: return true
        default: return false
        }
    }
}

// MARK: - Legacy bridge

/// `NavigationItem` is kept as a `typealias` so any call sites that have not yet
/// migrated compile without changes. New code should use `SidebarItem` directly.
typealias NavigationItem = SidebarItem
