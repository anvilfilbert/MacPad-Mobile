import PhonePadCore
import SwiftUI

private struct RecoveryDiscardCandidate: Identifiable {
    let item: RecoveryItemSummary

    var id: DocumentID {
        item.documentID
    }
}

private enum PhonePadSaveAsPresentationError: Error, LocalizedError {
    case missingPreparation

    var errorDescription: String? {
        switch self {
        case .missingPreparation:
            return "Save As configuration is no longer available. Choose Save and try again."
        }
    }
}

struct PhonePadRootView: View {
    @ObservedObject private var model: PhonePadAppModel
    @State private var editorTransitionController: PhonePadEditorTransitionController
    @State private var recoveryIsPresented: Bool
    @State private var discardCandidate: RecoveryDiscardCandidate?
    @State private var saveAsIsPresented: Bool
    @State private var saveAsFileName: String
    @State private var saveAsEncoding: TextFileEncoding
    @State private var preparedNewFileSave: PreparedNewFileSave?
    @State private var folderPickerIsPresented: Bool
    @State private var saveAsValidationError: String?

    init(model: PhonePadAppModel) {
        self.model = model
        editorTransitionController = PhonePadEditorTransitionController()
        recoveryIsPresented = false
        discardCandidate = nil
        saveAsIsPresented = false
        saveAsFileName = "Untitled.txt"
        saveAsEncoding = .utf8
        preparedNewFileSave = nil
        folderPickerIsPresented = false
        saveAsValidationError = nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabStrip
                Divider()
                PhonePadTextEditor(
                    text: Binding(
                        get: { model.activeText },
                        set: { model.editActiveDocument(text: $0) }
                    ),
                    transitionController: editorTransitionController
                )
                .disabled(model.fileMutationDisabled)
            }
            .navigationTitle(model.state.activeTab.document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    actionMenu
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phonepad.root")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let recoveryError = model.recoveryError {
                Text(recoveryError)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red)
                    .accessibilityIdentifier("phonepad.recovery-error")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            fileSaveFeedback
        }
        .sheet(isPresented: $recoveryIsPresented) {
            recoverySheet
        }
        .sheet(isPresented: $saveAsIsPresented) {
            saveAsSheet
        }
        .task {
            await model.refreshRecoveryItems()
        }
    }

    private var actionMenu: some View {
        Menu {
            Button {
                presentSaveAs()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("phonepad.action-menu.save")

            Button {
                recoveryIsPresented = true
            } label: {
                Label("Document Recovery", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("phonepad.action-menu.document-recovery")
            .disabled(model.recoveryItems.isEmpty && model.recoveryCatalogError == nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 44)

                if !model.recoveryItems.isEmpty {
                    Text(model.recoveryItems.count, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("phonepad.recovery-count-badge")
                }
            }
        }
        .accessibilityIdentifier("phonepad.action-menu")
        .accessibilityLabel("Actions")
        .accessibilityValue(actionMenuAccessibilityValue)
        .disabled(model.fileMutationDisabled)
    }

    private var saveAsSheet: some View {
        NavigationStack {
            Form {
                Section("New File") {
                    TextField("File Name", text: $saveAsFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.fileMutationDisabled)
                        .accessibilityIdentifier("phonepad.save-as.filename")

                    Picker("Encoding", selection: $saveAsEncoding) {
                        Text("UTF-8")
                            .tag(TextFileEncoding.utf8)
                            .accessibilityIdentifier("phonepad.save-as.encoding.utf8")
                    }
                    .pickerStyle(.menu)
                    .disabled(model.fileMutationDisabled)
                    .accessibilityIdentifier("phonepad.save-as.encoding")
                }

                if let saveAsValidationError {
                    Section {
                        Text(saveAsValidationError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("phonepad.save-as.validation-error")
                    }
                }

                if let fileSaveError = model.fileSaveError {
                    Section {
                        Text(fileSaveError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("phonepad.save-as.error")

                        if model.fileSaveCleanupRequired {
                            Button("Retry Cleanup") {
                                retrySaveCleanupFromSheet()
                            }
                            .accessibilityIdentifier(
                                "phonepad.save-as.retry-cleanup"
                            )
                        }
                    }
                    .accessibilityIdentifier("phonepad.save-as.cleanup-required")
                }

                if model.fileSaveInProgress {
                    Section {
                        ProgressView("Saving File")
                            .accessibilityIdentifier("phonepad.save-as.progress")
                    }
                }
            }
            .disabled(model.fileSaveInProgress)
            .navigationTitle("Save As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        cancelSaveAs()
                    }
                    .disabled(model.fileMutationDisabled)
                    .accessibilityIdentifier("phonepad.save-as.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose Folder") {
                        chooseSaveFolder()
                    }
                    .disabled(model.fileMutationDisabled)
                    .accessibilityIdentifier("phonepad.save-as.choose-folder")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.save-as.sheet")
        .interactiveDismissDisabled(model.fileMutationDisabled)
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $folderPickerIsPresented) {
            PhonePadFolderPicker(
                onSelection: selectSaveFolder,
                onCancellation: cancelFolderPicker,
                onFailure: failFolderPicker
            )
            .accessibilityIdentifier("phonepad.save-as.folder-picker")
        }
    }

    @ViewBuilder
    private var fileSaveFeedback: some View {
        if !saveAsIsPresented, model.fileSaveCleanupRequired,
           let fileSaveError = model.fileSaveError {
            cleanupRequiredFeedbackBanner(message: fileSaveError)
        } else if !saveAsIsPresented,
           let fileSaveError = model.fileSaveError {
            fileSaveFeedbackBanner(
                message: fileSaveError,
                color: .red,
                messageIdentifier: "phonepad.save.error"
            )
        } else if let fileSaveNotice = model.fileSaveNotice {
            fileSaveFeedbackBanner(
                message: fileSaveNotice,
                color: .orange,
                messageIdentifier: "phonepad.save.notice"
            )
        }
    }

    private func cleanupRequiredFeedbackBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .accessibilityIdentifier("phonepad.save.error")

            Button("Retry Cleanup") {
                retrySaveCleanupFromBanner()
            }
            .disabled(model.fileSaveInProgress)
            .accessibilityIdentifier("phonepad.save.retry-cleanup")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.red)
    }

    private func fileSaveFeedbackBanner(
        message: String,
        color: Color,
        messageIdentifier: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(messageIdentifier)

            Button {
                model.clearFileSaveFeedback()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("phonepad.file-save-feedback.dismiss")
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(color)
    }

    private func presentSaveAs() {
        model.clearFileSaveFeedback()
        do {
            try editorTransitionController.commitMarkedText()
        } catch {
            model.reportFileSaveTransitionError(error)
            return
        }

        saveAsFileName = suggestedFileName()
        saveAsEncoding = .utf8
        preparedNewFileSave = nil
        saveAsValidationError = nil
        saveAsIsPresented = true
    }

    private func suggestedFileName() -> String {
        let title = model.state.activeTab.document.title
        if title.lowercased().hasSuffix(".txt") {
            return title
        }
        return title + ".txt"
    }

    private func chooseSaveFolder() {
        model.clearFileSaveFeedback()
        do {
            preparedNewFileSave = try model.prepareNewDocumentSave(
                fileName: saveAsFileName,
                encoding: saveAsEncoding
            )
            saveAsValidationError = nil
            folderPickerIsPresented = true
        } catch {
            preparedNewFileSave = nil
            saveAsValidationError = error.localizedDescription
        }
    }

    private func selectSaveFolder(_ selectedFolderURL: URL) {
        folderPickerIsPresented = false
        guard let preparedNewFileSave else {
            model.reportFileSaveTransitionError(
                PhonePadSaveAsPresentationError.missingPreparation
            )
            return
        }

        Task { @MainActor in
            let saved = await model.saveNewDocument(
                preparation: preparedNewFileSave,
                selectedFolderURL: selectedFolderURL
            )
            guard saved else {
                return
            }
            self.preparedNewFileSave = nil
            saveAsValidationError = nil
            saveAsIsPresented = false
        }
    }

    private func cancelFolderPicker() {
        folderPickerIsPresented = false
    }

    private func failFolderPicker(_ error: Error) {
        folderPickerIsPresented = false
        model.reportFileSaveTransitionError(error)
    }

    private func cancelSaveAs() {
        model.clearFileSaveFeedback()
        preparedNewFileSave = nil
        saveAsValidationError = nil
        folderPickerIsPresented = false
        saveAsIsPresented = false
    }

    private func retrySaveCleanupFromSheet() {
        Task { @MainActor in
            let cleanupCompleted = await model.retryFileSaveCleanup()
            guard cleanupCompleted else {
                return
            }
            preparedNewFileSave = nil
            saveAsValidationError = nil
            saveAsIsPresented = false
        }
    }

    private func retrySaveCleanupFromBanner() {
        Task { @MainActor in
            _ = await model.retryFileSaveCleanup()
        }
    }

    private var recoverySheet: some View {
        NavigationStack {
            Group {
                if model.recoveryItems.isEmpty {
                    ContentUnavailableView(
                        "No Preserved Work",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    List(model.recoveryItems, id: \.documentID) { item in
                        recoveryRow(item)
                    }
                }
            }
            .navigationTitle("Document Recovery")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        recoveryIsPresented = false
                    }
                    .accessibilityIdentifier("phonepad.recovery.done")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let recoveryCatalogError = model.recoveryCatalogError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recoveryCatalogError)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("phonepad.recovery-catalog-error")
                        Button("Retry") {
                            Task { @MainActor in
                                await model.refreshRecoveryItems()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("phonepad.recovery.retry")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.recovery.sheet")
        .sheet(item: $discardCandidate) { candidate in
            discardConfirmationSheet(candidate)
        }
    }

    private func recoveryRow(_ item: RecoveryItemSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            Text(recoveryLastEditedText(item.lastEdited))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(recoveryStatusText(item.status))
                .font(.subheadline)
                .foregroundStyle(recoveryStatusColor(item.status))

            HStack {
                if item.status == .recoverable {
                    Button("Recover") {
                        Task { @MainActor in
                            do {
                                try editorTransitionController.commitMarkedText()
                            } catch {
                                model.reportRecoveryTransitionError(error)
                                return
                            }
                            let recovered = await model.recoverRecovery(
                                documentID: item.documentID
                            )
                            if recovered {
                                recoveryIsPresented = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activeRecoveryAction != nil)
                    .accessibilityIdentifier(
                        recoveryIdentifier(
                            prefix: "phonepad.recovery.recover",
                            documentID: item.documentID
                        )
                    )
                }

                if item.status == .unavailable {
                    Button("Retry") {
                        Task { @MainActor in
                            await model.refreshRecoveryItems()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activeRecoveryAction != nil)
                    .accessibilityIdentifier(
                        recoveryIdentifier(
                            prefix: "phonepad.recovery.retry",
                            documentID: item.documentID
                        )
                    )
                }

                Button("Discard Recovery", role: .destructive) {
                    discardCandidate = RecoveryDiscardCandidate(item: item)
                }
                .buttonStyle(.bordered)
                .disabled(model.activeRecoveryAction != nil)
                .accessibilityIdentifier(
                    recoveryIdentifier(
                        prefix: "phonepad.recovery.discard",
                        documentID: item.documentID
                    )
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            recoveryIdentifier(
                prefix: "phonepad.recovery.item",
                documentID: item.documentID
            )
        )
    }

    private func discardConfirmationSheet(
        _ candidate: RecoveryDiscardCandidate
    ) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Discard Recovery?", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)

                Text("Permanently remove preserved work for \(candidate.item.title)?")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Discard Recovery", role: .destructive) {
                    Task { @MainActor in
                        _ = await model.discardRecovery(
                            documentID: candidate.item.documentID
                        )
                        discardCandidate = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
                .disabled(model.activeRecoveryAction != nil)
                .accessibilityIdentifier(
                    recoveryIdentifier(
                        prefix: "phonepad.recovery.discard-confirm",
                        documentID: candidate.item.documentID
                    )
                )

                Button("Cancel", role: .cancel) {
                    discardCandidate = nil
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(model.activeRecoveryAction != nil)
                .accessibilityIdentifier(
                    recoveryIdentifier(
                        prefix: "phonepad.recovery.discard-cancel",
                        documentID: candidate.item.documentID
                    )
                )
            }
            .padding()
            .navigationTitle("Confirm Discard")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            recoveryIdentifier(
                prefix: "phonepad.recovery.discard-confirmation",
                documentID: candidate.item.documentID
            )
        )
        .interactiveDismissDisabled(model.activeRecoveryAction != nil)
        .presentationDetents([.medium])
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.state.tabs, id: \.id) { tab in
                    Text(tab.document.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("phonepad.tab.item")
                        .accessibilityLabel(tab.document.title)
                        .accessibilityValue(
                            recoveryStateAccessibilityValue(tab.document.recoveryState)
                        )
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("phonepad.tab-strip")
    }

    private func recoveryLastEditedText(_ lastEdited: RecoveryItemLastEdited) -> String {
        switch lastEdited {
        case let .available(date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case .unavailable:
            return "Last edited unavailable"
        }
    }

    private func recoveryStatusText(_ status: RecoveryItemStatus) -> String {
        switch status {
        case .recoverable:
            return "Unsaved"
        case .unavailable:
            return "Recovery temporarily unavailable"
        case .corrupt:
            return "Corrupt recovery data"
        case let .unsupportedVersion(version):
            return "Requires support for recovery version \(version)"
        }
    }

    private func recoveryStatusColor(_ status: RecoveryItemStatus) -> Color {
        switch status {
        case .recoverable:
            return .secondary
        case .unavailable, .corrupt, .unsupportedVersion:
            return .red
        }
    }

    private func recoveryIdentifier(
        prefix: String,
        documentID: DocumentID
    ) -> String {
        prefix + "." + documentID.rawValue.uuidString.lowercased()
    }

    private var actionMenuAccessibilityValue: String {
        if !model.recoveryItems.isEmpty {
            return "\(model.recoveryItems.count) preserved work items"
        }
        if model.recoveryCatalogError != nil {
            return "Document Recovery needs attention"
        }
        return "No preserved work"
    }

    private func recoveryStateAccessibilityValue(
        _ recoveryState: DocumentRecoveryState
    ) -> String {
        switch recoveryState {
        case .clean:
            return "Clean"
        case .checkpointPending:
            return "Protecting edits"
        case .protectedUnsaved:
            return "Edits protected"
        }
    }
}
