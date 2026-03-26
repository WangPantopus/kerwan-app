import SwiftUI
import os

// MARK: - SearchOverlayView

/// The SwiftUI content hosted inside `SearchOverlayWindow`.
///
/// Architecture:
/// - `state: SearchOverlayState` — owned by `SearchOverlayController`; provides
///   the query binding, selection index, and animation flag.
/// - `appState: AppState` — the global app state; provides `searchResults` and
///   `isSearching` which are populated by the AI intelligence workstream.
/// - `onOpenResult` — callback into the controller to open a result and dismiss.
///
/// Search flow:
/// 1. User types in the text field → `state.query` updates.
/// 2. `.task(id: state.query)` debounces 300 ms, then writes to
///    `appState.searchQuery` to trigger the search service.
/// 3. The search service (AI workstream) updates `appState.searchResults` and
///    `appState.isSearching`.
/// 4. Results render incrementally — keyword hits appear first, semantic
///    matches merge in as they arrive.
@MainActor
struct SearchOverlayView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "SearchOverlayView"
    )

    @Bindable var state: SearchOverlayState
    var appState: AppState
    let onOpenResult: (SearchResult) -> Void

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if showResultsArea {
                Divider()
                    .overlay(Color.primary.opacity(0.08))
                resultsArea
            }
        }
        // Material background + clip gives the rounded-window look.
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The window background is clear; this view provides the shadow-casting shape.
        // Scale + fade animation driven by SearchOverlayState.isAnimatedIn.
        .scaleEffect(state.isAnimatedIn ? 1.0 : 0.95)
        .opacity(state.isAnimatedIn ? 1.0 : 0.0)
        .animation(
            .spring(response: 0.25, dampingFraction: 0.86),
            value: state.isAnimatedIn
        )
        // Auto-focus the search field when the view appears.
        .onAppear { searchFieldFocused = true }
        // Debounced search dispatch.
        .task(id: state.query) {
            await debounceAndSearch()
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search interactions, clients, promises…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFieldFocused)
                .onSubmit {
                    if !appState.searchResults.isEmpty {
                        if let idx = state.selectedIndex {
                            onOpenResult(appState.searchResults[idx])
                        } else {
                            onOpenResult(appState.searchResults[0])
                        }
                    }
                }

            // Trailing accessory: spinner while searching, clear button otherwise.
            if appState.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            } else if !state.query.isEmpty {
                Button {
                    state.query = ""
                    appState.searchQuery = ""
                    appState.searchResults = []
                    appState.isSearching = false
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        // Minimum height so the bar never collapses.
        .frame(minHeight: 52)
    }

    // MARK: - Results area

    private var showResultsArea: Bool {
        !state.query.isEmpty || !appState.searchResults.isEmpty
    }

    private var resultsArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if appState.isSearching && appState.searchResults.isEmpty {
                        searchingRow
                    } else if appState.searchResults.isEmpty && !state.query.isEmpty {
                        noResultsRow
                    } else {
                        ForEach(Array(appState.searchResults.enumerated()), id: \.element.id) { idx, result in
                            OverlayResultRow(
                                result: result,
                                isSelected: state.selectedIndex == idx
                            ) {
                                state.selectedIndex = idx
                                onOpenResult(result)
                            } onHover: { hovering in
                                if hovering { state.selectedIndex = idx }
                            }
                            .id(result.id)

                            if idx < appState.searchResults.count - 1 {
                                Divider()
                                    .padding(.leading, 54)
                                    .overlay(Color.primary.opacity(0.06))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            // Grow up to 436 px; below that the window is exactly tall enough to fit.
            .frame(maxHeight: 436)
            // Scroll selected result into view when keyboard navigation moves it.
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard let idx = newIndex,
                      idx >= 0,
                      idx < appState.searchResults.count else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(appState.searchResults[idx].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Empty / loading rows

    private var searchingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Searching…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var noResultsRow: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No results for \u{201C}\(state.query)\u{201D}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Debounce + search dispatch

    /// Called by `.task(id: state.query)` — automatically cancelled and restarted
    /// whenever `state.query` changes, giving 300 ms debounce for free.
    private func debounceAndSearch() async {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            appState.searchQuery = ""
            appState.searchResults = []
            appState.isSearching = false
            state.selectedIndex = nil
            return
        }

        // Wait 300 ms. If the task is cancelled (new keystroke), this throws
        // CancellationError and the function returns without dispatching.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }

        // Reset selection whenever the query actually changes.
        state.selectedIndex = nil

        // Hand off to AppState. The AI intelligence workstream's search service
        // observes searchQuery, sets isSearching = true, runs FTS5 + sqlite-vec,
        // and populates searchResults incrementally.
        appState.searchQuery = query
        appState.isSearching = true

        Self.logger.debug("Search dispatched: \u{201C}\(query, privacy: .public)\u{201D}")
    }
}

// MARK: - OverlayResultRow

/// A single search result row.
///
/// Shows: type icon badge | title + snippet | metadata (relative date, type
/// pill, contact/client attribution, relevance sparkle for high-confidence hits).
struct OverlayResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            typeBadge
            contentStack
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering)
        }
        .onTapGesture { onTap() }
        // Smooth highlight transitions.
        .animation(.easeInOut(duration: 0.08), value: isSelected)
        .animation(.easeInOut(duration: 0.08), value: isHovered)
    }

    // MARK: - Type icon badge

    private var typeBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(result.type.tintColor.opacity(0.14))
                .frame(width: 34, height: 34)
            Image(systemName: result.type.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(result.type.tintColor)
        }
        .padding(.top, 1)   // optical alignment with text baseline
    }

    // MARK: - Content

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Title
            Text(result.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)

            // Snippet
            Text(result.snippet)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Metadata row
            metadataRow
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            // Relative timestamp
            Text(result.timestamp, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Type badge pill
            Text(result.type.badgeLabel)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(result.type.tintColor.opacity(0.12), in: Capsule())
                .foregroundStyle(result.type.tintColor)

            // Contact attribution
            if let name = result.contactName ?? result.clientName {
                Text("·")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // High-relevance indicator (top 15 %)
            if result.relevanceScore >= 0.85 {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.13)
        } else if isHovered {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }
}

// MARK: - SearchResultType display extensions

extension SearchResultType {
    var systemImage: String {
        switch self {
        case .interaction: return "bubble.left.and.bubble.right.fill"
        case .contact:     return "person.circle.fill"
        case .promise:     return "checkmark.seal.fill"
        case .workSession: return "clock.badge.checkmark.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .interaction: return .blue
        case .contact:     return .purple
        case .promise:     return .orange
        case .workSession: return .green
        }
    }

    var badgeLabel: String {
        switch self {
        case .interaction: return "Interaction"
        case .contact:     return "Contact"
        case .promise:     return "Promise"
        case .workSession: return "Session"
        }
    }
}
