import SwiftUI

/// Data tab — shows database file size, lets the user export a backup via
/// `NSSavePanel`, delete data older than a chosen date, or wipe everything.
struct DataSettingsTab: View {
    @Bindable var vm: SettingsViewModel

    var body: some View {
        Form {
            storageSection
            exportSection
            deleteSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete All Data?",
            isPresented: $vm.isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                vm.deleteAllData()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently remove all captured events, work sessions, and client data. This action cannot be undone.")
        }
    }

    // MARK: - Storage info

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Database size") {
                Text(formattedSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            Button {
                vm.exportDatabase()
            } label: {
                if vm.isExporting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Exporting…")
                    }
                } else {
                    Label("Export Database…", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(vm.isExporting)
        } footer: {
            Text("Creates an encrypted copy of your Kerwan database that you can import on another Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Section {
            DatePicker(
                "Delete data before",
                selection: $vm.deleteBeforeDate,
                displayedComponents: .date
            )

            Button {
                vm.deleteDataBefore()
            } label: {
                Label("Delete Old Data", systemImage: "trash")
            }
            .foregroundStyle(.red)

            Button(role: .destructive) {
                vm.isConfirmingDeleteAll = true
            } label: {
                Label("Delete All Data…", systemImage: "trash.fill")
            }
        } header: {
            Text("Data Retention")
        } footer: {
            Text("Deleted data cannot be recovered. Export a backup before deleting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var formattedSize: String {
        let bytes = vm.databaseFileSizeBytes
        if bytes < 1_024 {
            return "\(bytes) B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1f KB", Double(bytes) / 1_024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
    }
}
