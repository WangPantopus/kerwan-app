import SwiftUI
import os

/// A compact floating window for entering manual notes.
///
/// Opened via "Quick Note…" in the menu bar (⌘⇧N). The user types a note,
/// presses Return or clicks "Save", and the text is written to storage as a
/// `manualNote` `RawEvent` via `AppLifecycle.saveManualNote(text:appState:)`.
///
/// The window uses `.hiddenTitleBar` and a fixed intrinsic size. It focuses the
/// text field automatically on appear and dismisses itself after a successful save.
struct QuickNoteView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "QuickNoteView"
    )

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// The lifecycle actor used to forward the save to storage.
    let lifecycle: AppLifecycle

    @State private var noteText: String = ""
    @State private var isSaving: Bool = false
    @State private var didSave: Bool = false

    /// True once the note has been saved; drives the brief confirmation flash.
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "pencil.and.scribble")
                    .foregroundStyle(.secondary)
                Text("Quick Note")
                    .font(.headline)
                Spacer()
                if didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .transition(.opacity.combined(with: .scale))
                }
            }

            // Text field
            TextField("Type a note and press Return…", text: $noteText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3, reservesSpace: true)
                .focused($isTextFieldFocused)
                .onSubmit { saveNote() }
                .disabled(isSaving)

            // Action row
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveNote()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 400, idealWidth: 440)
        .onAppear {
            isTextFieldFocused = true
        }
    }

    // MARK: - Save action

    private func saveNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }

        isSaving = true
        let lifecycle = lifecycle
        let appState = appState
        Self.logger.info("Saving quick note (\(trimmed.count, privacy: .public) chars)")

        Task {
            await lifecycle.saveManualNote(text: trimmed, appState: appState)
            await MainActor.run {
                isSaving = false
                withAnimation(.easeInOut(duration: 0.2)) {
                    didSave = true
                }
            }
            // Show the checkmark briefly, then close.
            try? await Task.sleep(for: .milliseconds(700))
            await MainActor.run { dismiss() }
        }
    }
}
