import SwiftUI
import os

/// The global search window (⌘⇧R).
///
/// Provides a search bar that dispatches queries to `AppState` and renders
/// a results list. Full semantic (sqlite-vec) + keyword (FTS5) search is
/// implemented in the AI intelligence workstream; this view owns the UI shell.
struct GlobalSearchView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "GlobalSearchView"
    )

    @Environment(AppState.self) private var appState

    /// Local binding for the search bar text, synced to `appState.searchQuery`.
    @State private var localQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search interactions, contacts, promises…", text: $localQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onChange(of: localQuery) { _, query in
                        appState.searchQuery = query
                    }
                if appState.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else if !localQuery.isEmpty {
                    Button {
                        localQuery = ""
                        appState.searchQuery = ""
                        appState.searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Results
            if appState.searchResults.isEmpty && !localQuery.isEmpty && !appState.isSearching {
                emptyResultsView
            } else if appState.searchResults.isEmpty && localQuery.isEmpty {
                promptView
            } else {
                resultsList
            }
        }
        .onAppear {
            localQuery = appState.searchQuery
            isSearchFocused = true
        }
    }

    // MARK: - Subviews

    private var resultsList: some View {
        List(appState.searchResults) { result in
            SearchResultRow(result: result)
        }
        .listStyle(.plain)
    }

    private var emptyResultsView: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "magnifyingglass",
            description: Text("No matches found for \u{201C}\(localQuery)\u{201D}.")
        )
    }

    private var promptView: some View {
        ContentUnavailableView(
            "Search Kerwan",
            systemImage: "magnifyingglass",
            description: Text("Search across interactions, contacts, promises, and work sessions.")
        )
    }
}

// MARK: - Result Row

/// A single row in the global search results list.
private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: result.type.systemImage)
                    .foregroundStyle(result.type.tintColor)
                    .frame(width: 16)
                Text(result.title)
                    .fontWeight(.medium)
                Spacer()
                Text(result.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(result.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let contact = result.contactName {
                Text(contact)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// SearchResultType display helpers are defined in SearchOverlayView.swift.
