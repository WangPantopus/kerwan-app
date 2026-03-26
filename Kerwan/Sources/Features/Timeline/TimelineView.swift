import SwiftUI

// MARK: - TimelineView

/// Main Timeline view: reverse-chronological feed of all captured interactions,
/// grouped by date with infinite scroll and client/source/date-range filters.
@MainActor
struct TimelineView: View {

    @State private var viewModel    = TimelineViewModel()
    @State private var showJumpPicker = false
    @State private var jumpPickerDate = Date()

    var body: some View {
        VStack(spacing: 0) {
            TimelineFilterBar(viewModel: viewModel)

            Divider()

            ZStack {
                if viewModel.isLoading {
                    loadingState
                } else if viewModel.sections.isEmpty {
                    emptyState
                } else {
                    timelineList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Timeline")
        .toolbar { toolbarItems }
        // Initial load
        .task {
            async let clientLoad: Void = viewModel.loadAvailableClients()
            async let pageLoad: Void   = viewModel.loadInitial()
            _ = await (clientLoad, pageLoad)
        }
        // Reload when source filter changes (segmented control — instant feedback)
        .onChange(of: viewModel.sourceFilter) { _, _ in
            Task { await viewModel.applyFilters() }
        }
        // Reload when client filter changes
        .onChange(of: viewModel.selectedClientId) { _, _ in
            Task { await viewModel.applyFilters() }
        }
    }

    // MARK: - Timeline list

    private var timelineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                    ForEach(viewModel.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                InteractionRow(
                                    item:       item,
                                    isExpanded: viewModel.expandedInteractionId == item.id
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { viewModel.toggleExpanded(item.id) }

                                Divider()
                                    .padding(.leading, 56)
                            }
                        } header: {
                            TimelineSectionHeader(label: section.label)
                                .id(section.id)
                        }
                    }

                    // Pagination trigger: the ProgressView appears when scrolled
                    // to the bottom, its onAppear fires loadNextPage.
                    if viewModel.hasMore {
                        paginationFooter
                    } else if !viewModel.sections.isEmpty {
                        endOfFeedLabel
                    }
                }
            }
            // Jump-to-date: scroll to the section whose ID matches the selected date.
            .onChange(of: jumpPickerDate) { _, newDate in
                let sid = TimelineViewModel.sectionID(for: newDate)
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(sid, anchor: .top)
                }
            }
        }
    }

    // MARK: - Pagination footer

    private var paginationFooter: some View {
        HStack {
            Spacer()
            if viewModel.isLoadingMore {
                ProgressView()
                    .padding(.vertical, 16)
            } else {
                // Invisible trigger: onAppear fires when this comes into view.
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        Task { await viewModel.loadNextPage() }
                    }
            }
            Spacer()
        }
    }

    private var endOfFeedLabel: some View {
        Text("All interactions loaded")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading timeline…")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 44))
                .foregroundStyle(.quaternary)
            Text("No interactions found")
                .font(.title3.weight(.medium))
            Text("Try adjusting the filters or date range.")
                .foregroundStyle(.secondary)
            if viewModel.currentFilter.isActive {
                Button("Clear Filters") {
                    Task { await viewModel.resetFilters() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showJumpPicker.toggle()
            } label: {
                Label("Jump to Date", systemImage: "calendar.badge.clock")
            }
            .help("Jump to a specific date")
            .popover(isPresented: $showJumpPicker, arrowEdge: .top) {
                JumpToDatePopover(
                    date: $jumpPickerDate,
                    onJump: { showJumpPicker = false }
                )
            }
        }
    }
}

// MARK: - TimelineSectionHeader

private struct TimelineSectionHeader: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.bar)
    }
}

// MARK: - JumpToDatePopover

private struct JumpToDatePopover: View {
    @Binding var date: Date
    let onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump to Date")
                .font(.headline)
            DatePicker(
                "",
                selection: $date,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .frame(width: 280)
            Button("Jump") { onJump() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 312)
    }
}

// MARK: - Private helper so emptyState can access filter state

private extension TimelineViewModel {
    var currentFilter: TimelineFilter {
        TimelineFilter(
            source:    sourceFilter,
            clientId:  selectedClientId,
            dateStart: dateStart,
            dateEnd:   dateEnd
        )
    }
}
