import Foundation
import PhonePadCore
import SwiftUI

private struct PendingRecoveryCheckpoint {
    let generation: UInt64
    let previousState: PhonePadState
    let text: String
    let editedAt: Date
    let firstPendingAt: ContinuousClock.Instant
    let lastEditAt: ContinuousClock.Instant
    let requiresImmediateCheckpoint: Bool
}

private enum RecoveryCheckpointPersistenceOutcome: Equatable {
    case persisted
    case superseded
    case failed
}

private enum PendingFileSaveCleanup {
    case standard(NewDocumentSaveResult)
    case saveAs(SaveAsResult)

    var documentID: DocumentID {
        switch self {
        case let .standard(result):
            return result.state.activeTab.document.id
        case let .saveAs(result):
            return result.state.activeTab.document.id
        }
    }
}

private enum PhonePadRecoveryActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case checkpointMustFinishBeforeRecovering
    case recoveryItemCannotBeRecovered
    case recoveryItemMissing

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another recovery action is still running. Wait for it to finish and retry."
        case .checkpointMustFinishBeforeRecovering:
            "Current edits could not be protected. Resolve the recovery error before opening preserved work."
        case .recoveryItemCannotBeRecovered:
            "This preserved work is corrupt or unsupported. Keep it for a compatible PhonePad version, or choose Discard Recovery."
        case .recoveryItemMissing:
            "Preserved work is no longer available. Refresh Document Recovery and retry."
        }
    }
}

private enum PhonePadFileSaveActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case activeDocumentIsNotBound
    case checkpointMustFinishBeforeFileAction
    case cleanupRequired
    case cleanupNotRequired

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another File action is still running. Wait for it to finish and retry."
        case .activeDocumentIsNotBound:
            "Current Document has no existing File. Choose Save As instead."
        case .checkpointMustFinishBeforeFileAction:
            "Current edits could not be protected. Resolve the recovery error before opening or saving a File."
        case .cleanupRequired:
            "File output is verified, but recovery cleanup is still required. Choose Retry Cleanup before editing or saving again."
        case .cleanupNotRequired:
            "No recovery cleanup is waiting. Choose Save to start a new File action."
        }
    }
}

@MainActor
final class PhonePadAppModel: ObservableObject {
    @Published private(set) var state: PhonePadState
    @Published private(set) var recoveryError: String?
    @Published private(set) var recoveryItems: [RecoveryItemSummary]
    @Published private(set) var recoveryCatalogError: String?
    @Published private(set) var activeRecoveryAction: DocumentID?
    @Published private(set) var fileSaveError: String?
    @Published private(set) var fileSaveNotice: String?
    @Published private(set) var fileSaveInProgress: Bool
    @Published private(set) var fileSaveCleanupRequired: Bool
    @Published private(set) var pendingSaveAsReplacement: PreparedSaveAsPreflight?

    private let recoveryStore: FileRecoveryStore
    private let fileAccessConnector: FileAccessConnector
    private let checkpointQuietPeriod: Duration
    private let checkpointMaximumInterval: Duration
    private let checkpointClock: ContinuousClock
    private var checkpointTask: Task<Void, Never>?
    private var pendingCheckpoint: PendingRecoveryCheckpoint?
    private var failedCheckpoint: PendingRecoveryCheckpoint?
    private var pendingFileSaveCleanup: PendingFileSaveCleanup?
    private var editGeneration: UInt64

    init(
        state: PhonePadState,
        recoveryStore: FileRecoveryStore,
        fileAccessConnector: FileAccessConnector,
        checkpointQuietPeriod: Duration,
        checkpointMaximumInterval: Duration
    ) {
        precondition(checkpointQuietPeriod > .zero, "Checkpoint quiet period must be positive.")
        precondition(checkpointMaximumInterval > .zero, "Checkpoint maximum interval must be positive.")
        self.state = state
        self.recoveryStore = recoveryStore
        self.fileAccessConnector = fileAccessConnector
        self.checkpointQuietPeriod = checkpointQuietPeriod
        self.checkpointMaximumInterval = checkpointMaximumInterval
        checkpointClock = ContinuousClock()
        recoveryError = nil
        recoveryItems = []
        recoveryCatalogError = nil
        activeRecoveryAction = nil
        fileSaveError = nil
        fileSaveNotice = nil
        fileSaveInProgress = false
        fileSaveCleanupRequired = false
        pendingSaveAsReplacement = nil
        pendingCheckpoint = nil
        failedCheckpoint = nil
        pendingFileSaveCleanup = nil
        editGeneration = 0
    }

    convenience init(
        state: PhonePadState,
        recoveryStore: FileRecoveryStore,
        checkpointQuietPeriod: Duration,
        checkpointMaximumInterval: Duration
    ) {
        self.init(
            state: state,
            recoveryStore: recoveryStore,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: checkpointQuietPeriod,
            checkpointMaximumInterval: checkpointMaximumInterval
        )
    }

    convenience init(
        state: PhonePadState,
        recoveryStore: FileRecoveryStore
    ) {
        self.init(
            state: state,
            recoveryStore: recoveryStore,
            checkpointQuietPeriod: .milliseconds(300),
            checkpointMaximumInterval: .seconds(2)
        )
    }

    convenience init(recoveryRootURL: URL) {
        self.init(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryRootURL,
                fileManager: .default
            )
        )
    }

    var activeText: String {
        state.activeTab.document.text
    }

    var fileMutationDisabled: Bool {
        fileSaveInProgress
            || fileSaveCleanupRequired
            || pendingSaveAsReplacement != nil
    }

    var editorMutationDisabled: Bool {
        fileMutationDisabled || failedCheckpoint != nil
    }

    func clearFileSaveFeedback() {
        guard !fileSaveCleanupRequired else {
            return
        }
        fileSaveError = nil
        fileSaveNotice = nil
    }

    func reportFileSaveTransitionError(_ error: Error) {
        fileSaveError = error.localizedDescription
        fileSaveNotice = nil
    }

    @discardableResult
    func openDocument(selectedURL: URL) async -> Bool {
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer { fileSaveInProgress = false }

        guard await currentDocumentIsReadyForFileTransition() else {
            return false
        }

        do {
            let openedFile = try await fileAccessConnector.openTextFile(
                at: selectedURL
            )
            state = openBoundDocument(
                state: state,
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID()),
                text: openedFile.text,
                fileBinding: openedFile.binding
            )
            fileSaveError = nil
            fileSaveNotice = nil
            return true
        } catch {
            fileSaveError = error.localizedDescription
            return false
        }
    }

    func prepareDocumentSaveAs(
        fileName: String,
        encoding: TextFileEncoding
    ) throws -> PreparedSaveAs {
        guard !fileSaveCleanupRequired else {
            throw PhonePadFileSaveActionError.cleanupRequired
        }
        guard !fileSaveInProgress, pendingSaveAsReplacement == nil else {
            throw PhonePadFileSaveActionError.actionAlreadyInProgress
        }
        let preparedSave = try prepareSaveAs(
            state: state,
            fileName: fileName,
            encoding: encoding,
            recoveryEditedAt: Date()
        )
        clearFileSaveFeedback()
        return preparedSave
    }

    func preflightDocumentSaveAs(
        preparation: PreparedSaveAs,
        selectedDirectoryURL: URL
    ) async -> PreparedSaveAsPreflight? {
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return nil
        }
        guard !fileSaveInProgress, pendingSaveAsReplacement == nil else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return nil
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer { fileSaveInProgress = false }

        do {
            let preflight = try await preflightPreparedSaveAs(
                state: state,
                preparedSave: preparation,
                selectedDirectoryURL: selectedDirectoryURL,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            switch preflight.target {
            case .ready, .currentFile:
                pendingSaveAsReplacement = nil
            case .replacementRequired:
                pendingSaveAsReplacement = preflight
            }
            return preflight
        } catch {
            pendingSaveAsReplacement = nil
            fileSaveError = error.localizedDescription
            return nil
        }
    }

    func cancelSaveAsReplacement() {
        pendingSaveAsReplacement = nil
    }

    @discardableResult
    func completePreflightedSaveAs(
        _ preflight: PreparedSaveAsPreflight
    ) async -> Bool {
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress, pendingSaveAsReplacement == nil else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer {
            fileSaveInProgress = false
            pendingSaveAsReplacement = nil
        }

        guard await currentDocumentIsReadyForFileTransition() else {
            return false
        }

        do {
            let protectedState = try await protectPreparedSaveAs(
                state: state,
                preflight: preflight,
                recoveryStore: recoveryStore
            )
            state = protectedState
            recoveryError = nil

            let result: SaveAsResult
            switch preflight.target {
            case .ready:
                result = try await saveReadyProtectedSaveAs(
                    state: protectedState,
                    preflight: preflight,
                    fileAccessConnector: fileAccessConnector,
                    recoveryStore: recoveryStore
                )
            case .currentFile:
                result = try await saveCurrentFileProtectedSaveAs(
                    state: protectedState,
                    preflight: preflight,
                    fileAccessConnector: fileAccessConnector,
                    recoveryStore: recoveryStore
                )
            case .replacementRequired:
                throw SaveAsWorkflowError.targetRequiresReplacement
            }
            applyCompletedSaveAs(result)
            return true
        } catch {
            applySaveAsFailure(error)
            return false
        }
    }

    @discardableResult
    func confirmReplacementAndCompleteSaveAs() async -> Bool {
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard let replacement = pendingSaveAsReplacement else {
            fileSaveError = SaveAsWorkflowError
                .targetDoesNotRequireReplacement
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer {
            fileSaveInProgress = false
            pendingSaveAsReplacement = nil
        }

        guard await currentDocumentIsReadyForFileTransition() else {
            return false
        }

        do {
            let protectedState = try await protectPreparedSaveAs(
                state: state,
                preflight: replacement,
                recoveryStore: recoveryStore
            )
            state = protectedState
            recoveryError = nil
            let result = try await saveConfirmedReplacementProtectedSaveAs(
                state: protectedState,
                preflight: replacement,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            applyCompletedSaveAs(result)
            return true
        } catch {
            applySaveAsFailure(error)
            return false
        }
    }

    private func applyCompletedSaveAs(_ result: SaveAsResult) {
        state = result.state
        pendingFileSaveCleanup = nil
        fileSaveCleanupRequired = false
        fileSaveError = nil
        fileSaveNotice = fileSaveNoticeText(result.notice)
    }

    private func applySaveAsFailure(_ error: Error) {
        if let workflowError = error as? SaveAsWorkflowError,
           case let .outputVerifiedButRecoveryCleanupFailed(result, _) = workflowError {
            pendingFileSaveCleanup = .saveAs(result)
            fileSaveCleanupRequired = true
        }
        fileSaveError = error.localizedDescription
    }

    @discardableResult
    func saveActiveDocument() async -> Bool {
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard state.activeTab.document.fileBinding != nil else {
            fileSaveError = PhonePadFileSaveActionError
                .activeDocumentIsNotBound
                .localizedDescription
            return false
        }
        guard state.activeTab.document.isUnsaved else {
            clearFileSaveFeedback()
            return true
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer { fileSaveInProgress = false }

        do {
            let preparedSave = try prepareBoundFileSave(
                state: state,
                recoveryEditedAt: Date()
            )
            guard await currentDocumentIsReadyForFileTransition() else {
                return false
            }
            let protectedState = try await protectPreparedBoundFileSave(
                state: state,
                preparedSave: preparedSave,
                recoveryStore: recoveryStore
            )
            state = protectedState
            recoveryError = nil

            let result = try await saveProtectedBoundDocument(
                state: protectedState,
                preparedSave: preparedSave,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            state = result.state
            pendingFileSaveCleanup = nil
            fileSaveCleanupRequired = false
            fileSaveError = nil
            fileSaveNotice = fileSaveNoticeText(result.notice)
            return true
        } catch let error as BoundFileSaveWorkflowError {
            if case let .outputVerifiedButRecoveryCleanupFailed(
                result,
                _
            ) = error {
                pendingFileSaveCleanup = .standard(result)
                fileSaveCleanupRequired = true
            }
            fileSaveError = error.localizedDescription
            return false
        } catch {
            fileSaveError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func retryFileSaveCleanup() async -> Bool {
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard let pendingFileSaveCleanup else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupNotRequired
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        defer { fileSaveInProgress = false }

        do {
            let terminalOutcome = try await recoveryStore.completeRecoveryAfterSave(
                documentID: pendingFileSaveCleanup.documentID
            )
            switch pendingFileSaveCleanup {
            case let .standard(result):
                let completedResult = applyingRecoveryTerminalOutcome(
                    result: result,
                    terminalOutcome: terminalOutcome
                )
                state = completedResult.state
                fileSaveNotice = fileSaveNoticeText(completedResult.notice)
            case let .saveAs(result):
                let completedResult = applyingSaveAsRecoveryTerminalOutcome(
                    result: result,
                    terminalOutcome: terminalOutcome
                )
                state = completedResult.state
                fileSaveNotice = fileSaveNoticeText(completedResult.notice)
            }
            self.pendingFileSaveCleanup = nil
            fileSaveCleanupRequired = false
            fileSaveError = nil
            return true
        } catch {
            let cleanupFailure = RecoveryCleanupFailure(capturing: error)
            switch pendingFileSaveCleanup {
            case let .standard(result):
                fileSaveError = NewDocumentSaveWorkflowError
                    .outputVerifiedButRecoveryCleanupFailed(
                        result: result,
                        cleanupFailure: cleanupFailure
                    )
                    .localizedDescription
            case let .saveAs(result):
                fileSaveError = SaveAsWorkflowError
                    .outputVerifiedButRecoveryCleanupFailed(
                        result: result,
                        cleanupFailure: cleanupFailure
                    )
                    .localizedDescription
            }
            return false
        }
    }

    func reportRecoveryTransitionError(_ error: Error) {
        recoveryCatalogError = error.localizedDescription
    }

    func refreshRecoveryItems() async {
        do {
            let storedItems = try await recoveryStore.recoveryItems()
            let openDocumentIDs = Set(state.tabs.map(\.document.id))
            recoveryItems = storedItems.filter {
                !openDocumentIDs.contains($0.documentID)
            }
            recoveryCatalogError = nil
        } catch {
            recoveryItems = []
            recoveryCatalogError = error.localizedDescription
        }
    }

    @discardableResult
    func recoverRecovery(documentID: DocumentID) async -> Bool {
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { activeRecoveryAction = nil }

        guard await currentDocumentIsReadyForTransition() else {
            return false
        }

        do {
            guard let summary = recoveryItems.first(where: {
                $0.documentID == documentID
            }) else {
                throw PhonePadRecoveryActionError.recoveryItemMissing
            }
            guard summary.status == .recoverable else {
                throw PhonePadRecoveryActionError.recoveryItemCannotBeRecovered
            }
            guard let envelope = try await recoveryStore.load(documentID: documentID) else {
                throw PhonePadRecoveryActionError.recoveryItemMissing
            }
            let displayEnvelope = try RecoveryEnvelope(
                formatVersion: envelope.formatVersion,
                documentID: envelope.documentID,
                title: summary.title,
                text: envelope.text,
                editedAt: envelope.editedAt,
                fileReference: envelope.fileReference,
                pendingSave: envelope.pendingSave
            )
            state = recoverDocument(
                state: state,
                envelope: displayEnvelope,
                tabID: TabID(rawValue: UUID())
            )
            recoveryItems.removeAll { $0.documentID == documentID }
            recoveryCatalogError = nil
            return true
        } catch {
            recoveryCatalogError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func discardRecovery(documentID: DocumentID) async -> Bool {
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { activeRecoveryAction = nil }

        do {
            let terminalOutcome = try await recoveryStore.discardRecovery(
                documentID: documentID
            )
            recoveryItems.removeAll { $0.documentID == documentID }
            recoveryCatalogError = nil
            fileSaveError = nil
            switch terminalOutcome {
            case .complete:
                fileSaveNotice = nil
            case .residualCleanupPending:
                fileSaveNotice = "Preserved work was discarded. Protected cleanup remains and PhonePad will retry it on next recovery access."
            }
            return true
        } catch {
            recoveryCatalogError = error.localizedDescription
            return false
        }
    }

    func editActiveDocument(text: String) {
        guard !fileSaveCleanupRequired else {
            if fileSaveError == nil {
                fileSaveError = PhonePadFileSaveActionError
                    .cleanupRequired
                    .localizedDescription
            }
            return
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        guard failedCheckpoint == nil else {
            return
        }
        guard text != state.activeTab.document.text else {
            return
        }

        let previousState = state
        let transition: RecoveryEditTransition
        do {
            transition = try beginActiveDocumentEdit(
                state: previousState,
                newText: text,
                editedAt: Date()
            )
        } catch {
            recoveryError = error.localizedDescription
            return
        }

        state = transition.state
        recoveryError = nil

        editGeneration += 1
        let now = checkpointClock.now
        let existingCheckpoint = pendingCheckpoint
        pendingCheckpoint = PendingRecoveryCheckpoint(
            generation: editGeneration,
            previousState: previousState,
            text: text,
            editedAt: transition.envelope.editedAt,
            firstPendingAt: existingCheckpoint?.firstPendingAt ?? now,
            lastEditAt: now,
            requiresImmediateCheckpoint: existingCheckpoint?.requiresImmediateCheckpoint
                ?? (previousState.activeTab.document.recoveryState == .clean)
        )
        startCheckpointTaskIfNeeded()
    }

    private func startCheckpointTaskIfNeeded() {
        guard checkpointTask == nil else {
            return
        }
        checkpointTask = Task { @MainActor [weak self] in
            await self?.runCheckpointLoop()
        }
    }

    private func retryCurrentCheckpointIfNeeded() async -> Bool {
        let activeCheckpointTask = checkpointTask
        activeCheckpointTask?.cancel()
        if let activeCheckpointTask {
            await activeCheckpointTask.value
        }
        checkpointTask = nil
        guard let checkpoint = failedCheckpoint ?? pendingCheckpoint else {
            return state.activeTab.document.recoveryState != .checkpointPending
        }
        let outcome = await persist(checkpoint: checkpoint)
        return outcome == .persisted
    }

    private func currentDocumentIsReadyForTransition() async -> Bool {
        guard await retryCurrentCheckpointIfNeeded(),
              pendingCheckpoint == nil,
              failedCheckpoint == nil,
              state.activeTab.document.recoveryState != .checkpointPending else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .checkpointMustFinishBeforeRecovering
                .localizedDescription
            return false
        }
        return true
    }

    private func currentDocumentIsReadyForFileTransition() async -> Bool {
        guard await retryCurrentCheckpointIfNeeded(),
              pendingCheckpoint == nil,
              failedCheckpoint == nil,
              state.activeTab.document.recoveryState != .checkpointPending else {
            fileSaveError = PhonePadFileSaveActionError
                .checkpointMustFinishBeforeFileAction
                .localizedDescription
            return false
        }
        return true
    }

    private func runCheckpointLoop() async {
        while !Task.isCancelled {
            guard let checkpoint = await nextReadyCheckpoint() else {
                break
            }
            guard pendingCheckpoint?.generation == checkpoint.generation else {
                continue
            }
            let outcome = await persist(checkpoint: checkpoint)
            if outcome == .failed {
                break
            }
        }

        checkpointTask = nil
        if !Task.isCancelled,
           failedCheckpoint == nil,
           pendingCheckpoint != nil {
            startCheckpointTaskIfNeeded()
        }
    }

    private func nextReadyCheckpoint() async -> PendingRecoveryCheckpoint? {
        while !Task.isCancelled, let checkpoint = pendingCheckpoint {
            if checkpoint.requiresImmediateCheckpoint {
                return checkpoint
            }

            let quietDeadline = checkpoint.lastEditAt.advanced(by: checkpointQuietPeriod)
            let maximumDeadline = checkpoint.firstPendingAt.advanced(by: checkpointMaximumInterval)
            let deadline = min(quietDeadline, maximumDeadline)
            guard checkpointClock.now < deadline else {
                return checkpoint
            }

            do {
                try await checkpointClock.sleep(until: deadline)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func persist(
        checkpoint: PendingRecoveryCheckpoint
    ) async -> RecoveryCheckpointPersistenceOutcome {
        do {
            let updatedState = try await editActiveDocumentAndCheckpoint(
                state: checkpoint.previousState,
                newText: checkpoint.text,
                editedAt: checkpoint.editedAt,
                recoveryStore: recoveryStore
            )
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return .superseded
            }
            state = updatedState
            if pendingCheckpoint?.generation == checkpoint.generation {
                pendingCheckpoint = nil
            }
            if failedCheckpoint?.generation == checkpoint.generation {
                failedCheckpoint = nil
            }
            recoveryError = nil
            return .persisted
        } catch {
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return .superseded
            }
            if pendingCheckpoint?.generation == checkpoint.generation {
                pendingCheckpoint = nil
            }
            failedCheckpoint = checkpoint
            recoveryError = error.localizedDescription
            return .failed
        }
    }

    private func fileSaveNoticeText(_ notice: NewDocumentSaveNotice?) -> String? {
        switch notice {
        case .none:
            return nil
        case .durableFileAccessUnavailable:
            return "File was saved and verified, but PhonePad could not retain durable access. The Document is clean and detached; its next edit will require Save As."
        case .recoveryCleanupPending:
            return "File was saved and verified. The Document is clean. Protected recovery cleanup remains and PhonePad will retry it on next recovery access."
        case .durableFileAccessUnavailableAndRecoveryCleanupPending:
            return "File was saved and verified without durable access. The Document is clean and detached. Protected recovery cleanup remains and PhonePad will retry it on next recovery access."
        }
    }

    private func fileSaveNoticeText(_ notice: SaveAsNotice?) -> String? {
        guard let notice else {
            return nil
        }
        var messages: [String] = []
        if notice.durableFileAccessUnavailable {
            messages.append(
                "File was saved and verified, but PhonePad could not retain durable access. The Document is clean and detached; its next edit will require Save As."
            )
        } else {
            messages.append("File was saved and verified. The Document is clean.")
        }
        if let stagingCleanupFailureCode = notice.stagingCleanupFailureCode {
            messages.append(
                "The saved File remains verified, but temporary staging cleanup could not finish (code \(stagingCleanupFailureCode))."
            )
        }
        if notice.recoveryCleanupPending {
            messages.append(
                "Protected recovery cleanup remains and PhonePad will retry it on next recovery access."
            )
        }
        return messages.joined(separator: " ")
    }
}
