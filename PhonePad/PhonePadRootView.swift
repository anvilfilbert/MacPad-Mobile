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

private enum PhonePadSaveAsPresentationOrigin: Equatable {
    case explicit
    case fileConflict
    case tabClose(DocumentID)
}

private enum PhonePadFileAction {
    case open
    case save

    var errorIdentifier: String {
        switch self {
        case .open:
            return "phonepad.open.error"
        case .save:
            return "phonepad.save.error"
        }
    }

    var progressIdentifier: String {
        switch self {
        case .open:
            return "phonepad.open.progress"
        case .save:
            return "phonepad.save.progress"
        }
    }

    var progressLabel: String {
        switch self {
        case .open:
            return "Opening File"
        case .save:
            return "Saving File"
        }
    }
}

struct PhonePadRootView: View {
    @EnvironmentObject private var externalOpenSceneDelegate:
        PhonePadExternalOpenSceneDelegate
    @ObservedObject private var model: PhonePadAppModel
    @State private var editorTransitionController: PhonePadEditorTransitionController
    @State private var recoveryIsPresented: Bool
    @State private var discardCandidate: RecoveryDiscardCandidate?
    @State private var saveAsIsPresented: Bool
    @State private var saveAsFileName: String
    @State private var saveAsEncoding: TextFileEncoding
    @State private var preparedSaveAs: PreparedSaveAs?
    @State private var folderPickerIsPresented: Bool
    @State private var saveAsValidationError: String?
    @State private var saveAsPresentationOrigin: PhonePadSaveAsPresentationOrigin
    @State private var filePickerIsPresented: Bool
    @State private var fileAction: PhonePadFileAction?
    @State private var externalOpenIntakeStarted: Bool
    @State private var initialRecoveryRefreshFinished: Bool

    init(model: PhonePadAppModel) {
        self.model = model
        editorTransitionController = PhonePadEditorTransitionController()
        recoveryIsPresented = false
        discardCandidate = nil
        saveAsIsPresented = false
        saveAsFileName = "Untitled.txt"
        saveAsEncoding = .utf8
        preparedSaveAs = nil
        folderPickerIsPresented = false
        saveAsValidationError = nil
        saveAsPresentationOrigin = .explicit
        filePickerIsPresented = false
        fileAction = nil
        externalOpenIntakeStarted = false
        initialRecoveryRefreshFinished = false
    }

    var body: some View {
        let activeDocumentID = model.state.activeTab.document.id
        NavigationStack {
            VStack(spacing: 0) {
                PhonePadTabStrip(
                    tabs: model.state.tabs,
                    activeTabID: model.state.activeTabID,
                    interactionDisabled: model.fileMutationDisabled,
                    onSelect: selectTab,
                    onMove: moveTab,
                    onMoveError: model.reportTabTransitionError,
                    onClose: closeTab,
                    onCloseOthers: closeOtherTabs
                )
                Divider()
                PhonePadTextEditor(
                    documentID: activeDocumentID,
                    text: Binding(
                        get: { model.activeText },
                        set: {
                            _ = model.editDocument(
                                documentID: activeDocumentID,
                                text: $0
                            )
                        }
                    ),
                    isEditable: !model.editorMutationDisabled,
                    transitionController: editorTransitionController
                )
                .disabled(model.editorInteractionDisabled)
            }
            .navigationTitle(model.state.activeTab.document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: createTab) {
                        Image(systemName: "plus.rectangle.on.rectangle")
                    }
                    .disabled(model.fileMutationDisabled)
                    .accessibilityLabel("New Tab")
                    .accessibilityIdentifier("phonepad.toolbar.new-tab")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    actionMenu
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phonepad.root")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let tabTransitionError = model.tabTransitionError {
                Text(tabTransitionError)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red)
                    .accessibilityIdentifier("phonepad.tab.error")
            }
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
            tabCloseFeedback
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            fileSaveFeedback
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            externalOpenFeedback
        }
        .sheet(isPresented: $recoveryIsPresented) {
            recoverySheet
        }
        .sheet(isPresented: $saveAsIsPresented, onDismiss: resetSaveAsPresentation) {
            saveAsSheet
        }
        .sheet(isPresented: tabClosePromptIsPresented) {
            tabClosePromptSheet
        }
        .sheet(isPresented: fileConflictResolutionIsPresented) {
            fileConflictResolutionSheet
        }
        .sheet(isPresented: $filePickerIsPresented) {
            PhonePadFilePicker(
                onSelection: selectOpenFile,
                onCancellation: cancelFilePicker,
                onFailure: failFilePicker
            )
        }
        .task {
            externalOpenIntakeStarted = true
            await intakeExternalOpenBatches()
            await model.refreshInitialRecoveryItems()
            initialRecoveryRefreshFinished = true
        }
        .onReceive(
            externalOpenSceneDelegate.$pendingExternalOpenBatches
        ) { _ in
            guard externalOpenIntakeStarted else {
                return
            }
            Task { @MainActor in
                await intakeExternalOpenBatches()
            }
        }
        .task(id: externalOpenProcessingTrigger) {
            guard let commitRequestID = externalOpenProcessingTrigger
                .readyCommitRequestID else {
                return
            }
            await processNextExternalOpen(
                commitRequestID: commitRequestID
            )
        }
    }

    @ViewBuilder
    private var externalOpenFeedback: some View {
        if let prompt = model.pendingExternalOpenRecoveryPrompt {
            externalOpenRecoveryPrompt(prompt: prompt)
        } else if model.externalOpenCleanupRequired {
            externalOpenCleanupFeedback
        } else if model.externalOpenInProgress {
            externalOpenProgressFeedback
        } else if let externalOpenError = model.externalOpenError {
            externalOpenErrorFeedback(message: externalOpenError)
        } else if let externalOpenNotice = model.externalOpenNotice {
            Text(externalOpenNotice)
                .font(.footnote)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.orange)
                .accessibilityIdentifier("phonepad.external-open.notice")
        }
    }

    private var externalOpenProgressFeedback: some View {
        ProgressView("Opening File")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.regularMaterial)
            .accessibilityIdentifier("phonepad.external-open.progress")
    }

    private func externalOpenErrorFeedback(
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .accessibilityIdentifier("phonepad.external-open.error")

            HStack(spacing: 8) {
                if model.externalOpenErrorRequiresDismissal {
                    Button("Continue") {
                        model.dismissTerminalExternalOpenError()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(
                        "phonepad.external-open.continue"
                    )
                } else {
                    Button("Retry") {
                        Task { @MainActor in
                            await model.retryExternalOpenCommit()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("phonepad.external-open.retry")

                    Button("Cancel", role: .cancel) {
                        cancelPendingExternalOpen()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("phonepad.external-open.cancel")
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.red)
    }

    private var externalOpenCleanupFeedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let externalOpenError = model.externalOpenError {
                Text(externalOpenError)
                    .font(.footnote)
                    .accessibilityIdentifier(
                        "phonepad.external-open.error"
                    )
            }
            if let externalOpenNotice = model.externalOpenNotice,
               externalOpenNotice != model.externalOpenError {
                Text(externalOpenNotice)
                    .font(.footnote)
                    .accessibilityIdentifier(
                        "phonepad.external-open.notice"
                    )
            }

            Button("Retry Cleanup") {
                retryExternalOpenCleanup()
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
            .disabled(model.externalOpenInProgress)
            .accessibilityIdentifier(
                "phonepad.external-open.retry-cleanup"
            )
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.red)
    }

    private func externalOpenRecoveryPrompt(
        prompt: PendingExternalOpenRecoveryPrompt
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.title)
                .font(.headline)
            Text("Preserved edits exist for this File. Choose which version to open.")
                .font(.footnote)

            if let externalOpenError = model.externalOpenError {
                Text(externalOpenError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("phonepad.external-open.error")
            }

            Button("Recover Edits") {
                recoverPendingExternalOpen()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(model.externalOpenInProgress)
            .accessibilityIdentifier(
                "phonepad.external-open.recover-edits"
            )

            Button("Discard Edits and Open File", role: .destructive) {
                discardRecoveryAndOpenPendingExternalOpen()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(model.externalOpenInProgress)
            .accessibilityIdentifier(
                "phonepad.external-open.discard-and-open"
            )

            Button("Cancel", role: .cancel) {
                cancelPendingExternalOpen()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(model.externalOpenInProgress)
            .accessibilityIdentifier("phonepad.external-open.cancel")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "phonepad.external-open.recovery-prompt"
        )
    }

    @MainActor
    private func intakeExternalOpenBatches() async {
        await intakePhonePadExternalOpenBatches(
            from: externalOpenSceneDelegate,
            into: model
        )
    }

    private var externalOpenProcessingTrigger:
        PhonePadExternalOpenProcessingTrigger {
        PhonePadExternalOpenProcessingTrigger(
            commitRequestID: model.externalOpenCommitRequestID,
            initialRecoveryRefreshFinished:
                initialRecoveryRefreshFinished,
            saveAsIsPresented: saveAsIsPresented,
            folderPickerIsPresented: folderPickerIsPresented,
            filePickerIsPresented: filePickerIsPresented
        )
    }

    @MainActor
    private func processNextExternalOpen(
        commitRequestID: UUID
    ) async {
        do {
            let committedDocument = try editorTransitionController
                .commitMarkedText()
            _ = await model.processNextExternalOpen(
                after: committedDocument,
                commitRequestID: commitRequestID
            )
        } catch {
            model.reportExternalOpenCommitFailure(
                commitRequestID: commitRequestID,
                error: error
            )
        }
    }

    private func cancelPendingExternalOpen() {
        Task { @MainActor in
            await model.cancelPendingExternalOpen()
        }
    }

    private func recoverPendingExternalOpen() {
        Task { @MainActor in
            await model.recoverPendingExternalOpen()
        }
    }

    private func discardRecoveryAndOpenPendingExternalOpen() {
        Task { @MainActor in
            await model.discardRecoveryAndOpenPendingExternalOpen()
        }
    }

    private func retryExternalOpenCleanup() {
        Task { @MainActor in
            await model.retryExternalOpenCleanup()
        }
    }

    private var actionMenu: some View {
        Menu {
            Button {
                presentOpenFilePicker()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .accessibilityIdentifier("phonepad.action-menu.open")

            Button {
                saveActiveDocument()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("phonepad.action-menu.save")

            Button {
                presentExplicitSaveAs()
            } label: {
                Label("Save As", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("phonepad.action-menu.save-as")

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

    private var tabClosePromptIsPresented: Binding<Bool> {
        Binding(
            get: { model.pendingTabClosePrompt != nil },
            set: { _ in }
        )
    }

    @ViewBuilder
    private var tabClosePromptSheet: some View {
        if let prompt = model.pendingTabClosePrompt {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text(prompt.title)
                        .font(.headline)

                    Text("This Tab has unsaved changes.")
                        .font(.body)

                    if let tabCloseError = model.tabCloseError {
                        Text(tabCloseError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("phonepad.tab-close.error")
                    }

                    if model.fileSaveInProgress
                        || model.tabTransitionInProgress {
                        ProgressView("Resolving Close")
                            .accessibilityIdentifier(
                                "phonepad.tab-close.progress"
                            )
                    }

                    Button("Save") {
                        savePendingTabClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(tabCloseDecisionDisabled)
                    .accessibilityIdentifier("phonepad.tab-close.save")

                    Button("Discard", role: .destructive) {
                        discardPendingTabClose()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(tabCloseDecisionDisabled)
                    .accessibilityIdentifier("phonepad.tab-close.discard")

                    Button("Cancel", role: .cancel) {
                        model.cancelPendingTabClose()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(tabCloseDecisionDisabled)
                    .accessibilityIdentifier("phonepad.tab-close.cancel")
                }
                .padding()
                .navigationTitle("Close Tab")
                .navigationBarTitleDisplayMode(.inline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                "phonepad.tab-close.prompt.\(prompt.documentID.rawValue.uuidString.lowercased())"
            )
            .interactiveDismissDisabled()
            .presentationDetents([.medium, .large])
        }
    }

    private var tabCloseDecisionDisabled: Bool {
        model.fileSaveInProgress || model.tabTransitionInProgress
    }

    @ViewBuilder
    private var tabCloseFeedback: some View {
        if model.tabCloseCleanupRequired,
           let tabCloseError = model.tabCloseError {
            VStack(alignment: .leading, spacing: 8) {
                Text(tabCloseError)
                    .font(.footnote)
                    .accessibilityIdentifier("phonepad.tab-close.error")

                Button("Retry Cleanup") {
                    retryPendingTabCloseCleanup()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
                .disabled(model.tabTransitionInProgress)
                .accessibilityIdentifier(
                    "phonepad.tab-close.retry-cleanup"
                )
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.red)
            .accessibilityIdentifier(
                "phonepad.tab-close.cleanup-required"
            )
        } else if !model.fileSaveCleanupRequired,
                  model.pendingTabClosePrompt == nil,
                  let tabCloseError = model.tabCloseError {
            Text(tabCloseError)
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.red)
                .accessibilityIdentifier("phonepad.tab-close.error")
        }
    }

    private var saveAsSheet: some View {
        NavigationStack {
            Form {
                Section("File") {
                    TextField("File Name", text: $saveAsFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(saveAsConfigurationDisabled)
                        .accessibilityIdentifier("phonepad.save-as.filename")

                    Picker("Encoding", selection: $saveAsEncoding) {
                        Text("UTF-8")
                            .tag(TextFileEncoding.utf8)
                            .accessibilityIdentifier("phonepad.save-as.encoding.utf8")
                        Text("UTF-8 with BOM")
                            .tag(TextFileEncoding.utf8WithBOM)
                            .accessibilityIdentifier(
                                "phonepad.save-as.encoding.utf8-with-bom"
                            )
                        Text("UTF-16 Little Endian with BOM")
                            .tag(TextFileEncoding.utf16LittleEndianWithBOM)
                            .accessibilityIdentifier(
                                "phonepad.save-as.encoding.utf16-little-endian-with-bom"
                            )
                        Text("UTF-16 Big Endian with BOM")
                            .tag(TextFileEncoding.utf16BigEndianWithBOM)
                            .accessibilityIdentifier(
                                "phonepad.save-as.encoding.utf16-big-endian-with-bom"
                            )
                        Text("Windows-1252")
                            .tag(TextFileEncoding.windows1252)
                            .accessibilityIdentifier(
                                "phonepad.save-as.encoding.windows-1252"
                            )
                        Text("ISO-8859-1")
                            .tag(TextFileEncoding.iso88591)
                            .accessibilityIdentifier(
                                "phonepad.save-as.encoding.iso-8859-1"
                            )
                    }
                    .pickerStyle(.menu)
                    .disabled(saveAsConfigurationDisabled)
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
                    .disabled(saveAsConfigurationDisabled)
                    .accessibilityIdentifier("phonepad.save-as.configuration-cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose Folder") {
                        chooseSaveFolder()
                    }
                    .disabled(saveAsConfigurationDisabled)
                    .accessibilityIdentifier("phonepad.save-as.choose-folder")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.save-as.sheet")
        .interactiveDismissDisabled(saveAsConfigurationDisabled)
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $folderPickerIsPresented) {
            PhonePadFolderPicker(
                onSelection: selectSaveFolder,
                onCancellation: cancelFolderPicker,
                onFailure: failFolderPicker
            )
        }
        .sheet(isPresented: replacementConfirmationIsPresented) {
            replacementConfirmationSheet
        }
    }

    private var saveAsConfigurationDisabled: Bool {
        switch saveAsPresentationOrigin {
        case .explicit, .fileConflict:
            return model.fileMutationDisabled
        case .tabClose:
            return model.fileSaveInProgress || model.fileSaveCleanupRequired
        }
    }

    @ViewBuilder
    private var fileSaveFeedback: some View {
        if !saveAsIsPresented,
           !model.fileConflictResolutionIsPresented,
           let fileConflictError = model.fileConflictError {
            fileReconciliationErrorBanner(message: fileConflictError)
        } else if !saveAsIsPresented,
                  !model.fileConflictResolutionIsPresented,
                  let conflict = model.activeFileConflict {
            fileConflictFeedbackBanner(conflict: conflict)
        } else if !saveAsIsPresented, model.fileSaveInProgress,
           let fileAction {
            ProgressView(fileAction.progressLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.regularMaterial)
                .accessibilityIdentifier(fileAction.progressIdentifier)
        } else if !saveAsIsPresented, model.fileSaveCleanupRequired,
           let fileSaveError = model.fileSaveError {
            cleanupRequiredFeedbackBanner(message: fileSaveError)
        } else if !saveAsIsPresented,
           let fileSaveError = model.fileSaveError {
            fileSaveFeedbackBanner(
                message: fileSaveError,
                color: .red,
                messageIdentifier: fileAction?.errorIdentifier ?? "phonepad.save.error"
            )
        } else if let fileSaveNotice = model.fileSaveNotice {
            fileSaveFeedbackBanner(
                message: fileSaveNotice,
                color: .orange,
                messageIdentifier: "phonepad.save.notice"
            )
        }
    }

    private func fileReconciliationErrorBanner(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("phonepad.file-reconciliation.error")

            Button("Retry") {
                Task { @MainActor in
                    await model.retryActiveFileReconciliation()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
            .accessibilityIdentifier("phonepad.file-reconciliation.retry")
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.red)
    }

    private func fileConflictFeedbackBanner(
        conflict: FileConflict
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fileConflictDescription(conflict))
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("phonepad.file-conflict.banner")

            Button("Resolve") {
                model.presentFileConflictResolution()
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
            .accessibilityIdentifier("phonepad.file-conflict.resolve")
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.red)
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
                dismissFileSaveFeedback()
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

    private func createTab() {
        model.clearTabTransitionFeedback()
        Task { @MainActor in
            do {
                let committedDocument = try editorTransitionController
                    .commitMarkedText()
                _ = await model.createTab(after: committedDocument)
            } catch {
                model.reportTabTransitionError(error)
            }
        }
    }

    private func selectTab(_ tabID: TabID) {
        guard tabID != model.state.activeTabID else {
            return
        }
        model.clearTabTransitionFeedback()
        Task { @MainActor in
            do {
                let committedDocument = try editorTransitionController
                    .commitMarkedText()
                _ = await model.selectTab(tabID, after: committedDocument)
            } catch {
                model.reportTabTransitionError(error)
            }
        }
    }

    private func moveTab(
        _ tabID: TabID,
        to placement: PhonePadCore.TabPlacement
    ) {
        model.clearTabTransitionFeedback()
        Task { @MainActor in
            _ = await model.moveTab(tabID, to: placement)
        }
    }

    private func closeTab(_ tabID: TabID) {
        model.clearTabTransitionFeedback()
        Task { @MainActor in
            do {
                let committedDocument = try editorTransitionController
                    .commitMarkedText()
                _ = await model.requestCloseTab(
                    tabID,
                    after: committedDocument
                )
            } catch {
                model.reportTabTransitionError(error)
            }
        }
    }

    private func closeOtherTabs(keeping tabID: TabID) {
        model.clearTabTransitionFeedback()
        Task { @MainActor in
            do {
                let committedDocument = try editorTransitionController
                    .commitMarkedText()
                _ = await model.requestCloseOtherTabs(
                    keeping: tabID,
                    after: committedDocument
                )
            } catch {
                model.reportTabTransitionError(error)
            }
        }
    }

    private func savePendingTabClose() {
        Task { @MainActor in
            let route = await model.savePendingTabClose()
            switch route {
            case .completed, .fileConflictRequired, .failed:
                break
            case let .saveAsRequired(documentID):
                presentTabCloseSaveAs(documentID: documentID)
            }
        }
    }

    private func discardPendingTabClose() {
        Task { @MainActor in
            _ = await model.discardPendingTabClose()
        }
    }

    private func retryPendingTabCloseCleanup() {
        Task { @MainActor in
            _ = await model.retryPendingTabCloseCleanup()
        }
    }

    private func saveActiveDocument() {
        model.clearFileSaveFeedback()
        fileAction = .save
        do {
            _ = try editorTransitionController.commitMarkedText()
        } catch {
            model.reportFileSaveTransitionError(error)
            return
        }

        guard model.state.activeTab.document.fileBinding != nil else {
            presentSaveAsAfterEditorCommit()
            return
        }

        Task { @MainActor in
            let saved = await model.saveActiveDocument()
            if saved, model.fileSaveNotice == nil {
                fileAction = nil
            }
        }
    }

    private func presentExplicitSaveAs() {
        model.clearFileSaveFeedback()
        fileAction = .save
        do {
            _ = try editorTransitionController.commitMarkedText()
        } catch {
            model.reportFileSaveTransitionError(error)
            return
        }
        presentSaveAsAfterEditorCommit()
    }

    private func presentSaveAsAfterEditorCommit() {
        saveAsPresentationOrigin = .explicit
        configureSaveAsPresentation()
    }

    private func presentConflictSaveAsAfterEditorCommit() {
        saveAsPresentationOrigin = .fileConflict
        configureSaveAsPresentation()
    }

    private func presentTabCloseSaveAs(documentID: DocumentID) {
        saveAsPresentationOrigin = .tabClose(documentID)
        configureSaveAsPresentation()
    }

    private func configureSaveAsPresentation() {
        saveAsFileName = suggestedFileName()
        saveAsEncoding = model.state.activeTab.document.fileBinding?.encoding ?? .utf8
        preparedSaveAs = nil
        model.cancelSaveAsReplacement()
        saveAsValidationError = nil
        saveAsIsPresented = true
    }

    private func suggestedFileName() -> String {
        if let binding = model.state.activeTab.document.fileBinding {
            return binding.displayName.value
        }
        let title = model.state.activeTab.document.title
        if title.lowercased().hasSuffix(".txt") {
            return title
        }
        return title + ".txt"
    }

    private func chooseSaveFolder() {
        model.clearFileSaveFeedback()
        do {
            preparedSaveAs = try model.prepareDocumentSaveAs(
                fileName: saveAsFileName,
                encoding: saveAsEncoding
            )
            saveAsValidationError = nil
            folderPickerIsPresented = true
        } catch {
            preparedSaveAs = nil
            saveAsValidationError = error.localizedDescription
        }
    }

    private func selectSaveFolder(_ selectedDirectoryURL: URL) {
        folderPickerIsPresented = false
        guard let preparedSaveAs else {
            model.reportFileSaveTransitionError(
                PhonePadSaveAsPresentationError.missingPreparation
            )
            return
        }

        Task { @MainActor in
            let preflight = await model.preflightDocumentSaveAs(
                preparation: preparedSaveAs,
                selectedDirectoryURL: selectedDirectoryURL
            )
            self.preparedSaveAs = nil
            guard let preflight else {
                return
            }
            switch preflight.target {
            case .replacementRequired:
                return
            case .ready, .currentFile:
                let saved = await model.completePreflightedSaveAs(preflight)
                guard saved else {
                    return
                }
                saveAsValidationError = nil
                saveAsPresentationOrigin = .explicit
                saveAsIsPresented = false
            }
        }
    }

    private func cancelFolderPicker() {
        folderPickerIsPresented = false
        preparedSaveAs = nil
    }

    private func failFolderPicker(_ error: Error) {
        folderPickerIsPresented = false
        preparedSaveAs = nil
        model.reportFileSaveTransitionError(error)
    }

    private func cancelSaveAs() {
        model.clearFileSaveFeedback()
        model.cancelSaveAsReplacement()
        fileAction = nil
        preparedSaveAs = nil
        saveAsValidationError = nil
        folderPickerIsPresented = false
        saveAsIsPresented = false
    }

    private var replacementConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { model.pendingSaveAsReplacement != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelSaveAsReplacement()
                }
            }
        )
    }

    private var replacementConfirmationSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Replace Existing File?", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)

                Text(model.pendingSaveAsReplacement?.target.plan.fileName.value ?? "")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("phonepad.save-as.replace-target")

                Spacer()

                Button("Replace", role: .destructive) {
                    confirmSaveAsReplacement()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
                .disabled(model.fileSaveInProgress)
                .accessibilityIdentifier("phonepad.save-as.replace")

                Button("Cancel", role: .cancel) {
                    cancelSaveAsReplacement()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(model.fileSaveInProgress)
                .accessibilityIdentifier("phonepad.save-as.cancel")
            }
            .padding()
            .navigationTitle("Confirm Replace")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.save-as.replace-confirmation")
        .interactiveDismissDisabled(model.fileSaveInProgress)
        .presentationDetents([.medium])
    }

    private var fileConflictResolutionIsPresented: Binding<Bool> {
        Binding(
            get: { model.fileConflictResolutionIsPresented },
            set: { isPresented in
                if !isPresented {
                    model.cancelFileConflictResolution()
                }
            }
        )
    }

    private var fileConflictResolutionSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("File Conflict", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)

                if let conflict = model.activeFileConflict {
                    Text(fileConflictDescription(conflict))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("phonepad.file-conflict.reason")
                }

                if let fileConflictError = model.fileConflictError {
                    Text(fileConflictError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("phonepad.file-conflict.error")
                }

                if model.fileSaveInProgress {
                    ProgressView("Reloading Current File")
                        .accessibilityIdentifier("phonepad.file-conflict.progress")
                }

                Spacer()

                Button("Discard Edits and Reload Current", role: .destructive) {
                    reloadCurrentFileFromConflict()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
                .disabled(model.fileSaveInProgress)
                .accessibilityIdentifier("phonepad.file-conflict.reload-current")

                Button("Save As") {
                    presentSaveAsFromFileConflict()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(model.fileSaveInProgress)
                .accessibilityIdentifier("phonepad.file-conflict.save-as")

                Button("Cancel", role: .cancel) {
                    model.cancelFileConflictResolution()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(model.fileSaveInProgress)
                .accessibilityIdentifier("phonepad.file-conflict.cancel")
            }
            .padding()
            .navigationTitle("Resolve File Conflict")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.file-conflict.sheet")
        .interactiveDismissDisabled()
        .presentationDetents([.medium, .large])
    }

    private func reloadCurrentFileFromConflict() {
        do {
            _ = try editorTransitionController.commitMarkedText()
        } catch {
            model.reportFileConflictTransitionError(error)
            return
        }
        Task { @MainActor in
            _ = await model.discardEditsAndReloadCurrentFile()
        }
    }

    private func presentSaveAsFromFileConflict() {
        do {
            _ = try editorTransitionController.commitMarkedText()
        } catch {
            model.reportFileConflictTransitionError(error)
            return
        }
        let pendingTabCloseDocumentID = model.pendingTabCloseDocumentID
        guard model.beginSaveAsFromFileConflict() else {
            return
        }
        if let pendingTabCloseDocumentID {
            presentTabCloseSaveAs(
                documentID: pendingTabCloseDocumentID
            )
        } else {
            presentConflictSaveAsAfterEditorCommit()
        }
    }

    private func confirmSaveAsReplacement() {
        Task { @MainActor in
            let saved = await model.confirmReplacementAndCompleteSaveAs()
            preparedSaveAs = nil
            guard saved else {
                return
            }
            saveAsValidationError = nil
            saveAsPresentationOrigin = .explicit
            saveAsIsPresented = false
        }
    }

    private func cancelSaveAsReplacement() {
        model.cancelSaveAsReplacement()
        preparedSaveAs = nil
    }

    private func resetSaveAsPresentation() {
        let dismissedOrigin = saveAsPresentationOrigin
        model.cancelSaveAsReplacement()
        preparedSaveAs = nil
        saveAsValidationError = nil
        folderPickerIsPresented = false
        fileAction = nil
        saveAsPresentationOrigin = .explicit
        switch dismissedOrigin {
        case .explicit:
            break
        case .fileConflict where model.activeFileConflict != nil:
            model.presentFileConflictResolution()
        case .fileConflict:
            break
        case let .tabClose(documentID):
            _ = model.restorePendingTabCloseDecisionAfterSaveAsCancellation(
                documentID: documentID
            )
        }
    }

    private func retrySaveCleanupFromSheet() {
        Task { @MainActor in
            let cleanupCompleted = await model.retryFileSaveCleanup()
            guard cleanupCompleted else {
                return
            }
            preparedSaveAs = nil
            saveAsValidationError = nil
            saveAsPresentationOrigin = .explicit
            saveAsIsPresented = false
        }
    }

    private func retrySaveCleanupFromBanner() {
        Task { @MainActor in
            _ = await model.retryFileSaveCleanup()
        }
    }

    private func presentOpenFilePicker() {
        model.clearFileSaveFeedback()
        fileAction = .open
        filePickerIsPresented = true
    }

    private func selectOpenFile(_ selectedURL: URL) {
        filePickerIsPresented = false
        fileAction = nil
        Task { @MainActor in
            await model.enqueueExternalOpenRequests([
                PhonePadExternalOpenRequest(
                    url: selectedURL,
                    accessIntent: .inPlace
                ),
            ])
            await intakeExternalOpenBatches()
        }
    }

    private func cancelFilePicker() {
        filePickerIsPresented = false
        fileAction = nil
    }

    private func failFilePicker(_ error: Error) {
        filePickerIsPresented = false
        fileAction = .open
        model.reportFileSaveTransitionError(error)
    }

    private func dismissFileSaveFeedback() {
        model.clearFileSaveFeedback()
        fileAction = nil
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
                            let committedDocument: CommittedEditorDocument
                            do {
                                committedDocument = try editorTransitionController
                                    .commitMarkedText()
                            } catch {
                                model.reportRecoveryTransitionError(error)
                                return
                            }
                            let recovered = await model.recoverRecovery(
                                documentID: item.documentID,
                                after: committedDocument
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

    private func fileConflictDescription(_ conflict: FileConflict) -> String {
        switch conflict {
        case .contentChanged:
            return "Original File content changed outside PhonePad. Current edits were not overwritten."
        case .stableIdentityChanged:
            return "Original File identity changed outside PhonePad. Current edits were not overwritten."
        case .ambiguousLocatorChange:
            return "Original File moved without a stable provider identity. Current edits were not overwritten."
        case let .unresolvedProviderVersions(count):
            return "Original File has \(count) unresolved provider conflict version(s). PhonePad will not resolve them; use Files or the provider before saving to this File."
        }
    }
}
