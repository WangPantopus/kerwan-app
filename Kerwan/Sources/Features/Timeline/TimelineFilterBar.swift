import SwiftUI

// MARK: - TimelineFilterBar

/// Horizontal filter controls pinned above the timeline list.
///
/// Changing the source or client filter triggers an immediate reload.
/// Date-range changes are staged in the ViewModel and applied when the
/// user clicks "Apply" — this avoids refetching on every date picker step.
@MainActor
struct TimelineFilterBar: View {

    @Bindable var viewModel: TimelineViewModel

    /// Local staging area for the date range — written to viewModel only on Apply.
    @State private var pendingStart: Date? = nil
    @State private var pendingEnd:   Date? = nil
    @State private var useDateRange  = false

    var body: some View {
        HStack(spacing: 0) {
            // ── Source filter (segmented) ───────────────────────────────
            Picker("Source", selection: $viewModel.sourceFilter) {
                ForEach(TimelineSourceFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            .fixedSize()

            filterDivider

            // ── Client picker ───────────────────────────────────────────
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Picker("Client", selection: $viewModel.selectedClientId) {
                    Text("All Clients").tag(EntityID?.none)
                    ForEach(viewModel.availableClients) { client in
                        Text(client.name).tag(EntityID?.some(client.id))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 180)
            }

            filterDivider

            // ── Date range ──────────────────────────────────────────────
            dateRangeControls

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Sync pending dates from viewModel when filters are reset externally.
        .onChange(of: viewModel.dateStart) { _, v in
            pendingStart  = v
            useDateRange  = v != nil || pendingEnd != nil
        }
        .onChange(of: viewModel.dateEnd) { _, v in
            pendingEnd    = v
            useDateRange  = pendingStart != nil || v != nil
        }
    }

    // MARK: - Date range controls

    @ViewBuilder
    private var dateRangeControls: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $useDateRange.animation()) {
                Label("Date range", systemImage: "calendar")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .help("Filter by date range")

            if useDateRange {
                compactDatePicker("From", selection: $pendingStart, upperBound: pendingEnd)
                Text("–").foregroundStyle(.tertiary).font(.footnote)
                compactDatePicker("To",   selection: $pendingEnd,   lowerBound: pendingStart)

                Button("Apply") {
                    viewModel.dateStart = pendingStart
                    viewModel.dateEnd   = pendingEnd
                    Task { await viewModel.applyFilters() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if viewModel.dateStart != nil || viewModel.dateEnd != nil {
                    Button {
                        useDateRange      = false
                        pendingStart      = nil
                        pendingEnd        = nil
                        viewModel.dateStart = nil
                        viewModel.dateEnd   = nil
                        Task { await viewModel.applyFilters() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear date range")
                }
            }
        }
    }

    // MARK: - Compact optional date picker

    /// A `DatePicker` that binds to an optional date, showing "(any)" when nil.
    @ViewBuilder
    private func compactDatePicker(
        _ label: String,
        selection: Binding<Date?>,
        lowerBound: Date? = nil,
        upperBound: Date? = nil
    ) -> some View {
        let displayDate = Binding<Date>(
            get:  { selection.wrappedValue ?? Date() },
            set:  { selection.wrappedValue = $0 }
        )

        Group {
            if let lower = lowerBound, let upper = upperBound {
                DatePicker(label, selection: displayDate, in: lower...upper,
                           displayedComponents: .date)
            } else if let lower = lowerBound {
                DatePicker(label, selection: displayDate, in: lower...,
                           displayedComponents: .date)
            } else if let upper = upperBound {
                DatePicker(label, selection: displayDate, in: ...upper,
                           displayedComponents: .date)
            } else {
                DatePicker(label, selection: displayDate,
                           in: ...Date(),
                           displayedComponents: .date)
            }
        }
        .labelsHidden()
        .datePickerStyle(.compact)
        .frame(width: 110)
    }

    // MARK: - Helpers

    private var filterDivider: some View {
        Divider()
            .frame(height: 20)
            .padding(.horizontal, 12)
    }
}
