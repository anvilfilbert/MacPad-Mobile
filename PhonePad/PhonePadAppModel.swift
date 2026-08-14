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
    case cleanupRequired
    case cleanupNotRequired

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another File action is still running. Wait for it to finish and retry."
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

    private let recoveryStore: FileRecoveryStore
    private let fileAccessConnector: FileAccessConnector
    private let checkpointQuietPeriod: Duration
    private let checkpointMaximumInterval: Duration
    private let checkpointClock: ContinuousClock
    private var checkpointTask: Task<Void, Never>?
    private var pendingCheckpoint: PendingRecoveryCheckpoint?
    private var pendingFileSaveCleanup: NewDocumentSaveResult?
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
        pendingCheckpoint = nil
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
        fileSaveInProgress || fileSaveCleanupRequired
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

    func prepareNewDocumentSave(
        fileName: String,
        encoding: TextFileEncoding
    ) throws -> PreparedNewFileSave {
        guard !fileSaveCleanupRequired else {
            throw PhonePadFileSaveActionError.cleanupRequired
        }
        let preparedSave = try prepareNewFileSave(
            state: state,
            fileName: fileName,
            encoding: encoding,
            recoveryEditedAt: Date()
        )
        clearFileSaveFeedback()
        return preparedSave
    }

    @discardableResult
    func saveNewDocument(
        preparation: PreparedNewFileSave,
        selectedFolderURL: URL
    ) async -> Bool {
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

        await cancelPendingCheckpointForFileSave()

        do {
            let protectedState = try await protectPreparedNewFileSave(
                state: state,
                preparedSave: preparation,
                recoveryStore: recoveryStore
            )
            state = protectedState
            recoveryError = nil

            let result = try await saveProtectedNewDocument(
                state: protectedState,
                preparedSave: preparation,
                selectedFolderURL: selectedFolderURL,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            state = result.state
            pendingFileSaveCleanup = nil
            fileSaveCleanupRequired = false
            fileSaveError = nil
            fileSaveNotice = fileSaveNoticeText(result.notice)
            return true
        } catch let error as NewDocumentSaveWorkflowError {
            if case let .outputVerifiedButRecoveryCleanupFailed(
                result,
                _
            ) = error {
                pendingFileSaveCleanup = result
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
                documentID: pendingFileSaveCleanup.state.activeTab.document.id
            )
            let completedResult = applyingRecoveryTerminalOutcome(
                result: pendingFileSaveCleanup,
                terminalOutcome: terminalOutcome
            )
            state = completedResult.state
            self.pendingFileSaveCleanup = nil
            fileSaveCleanupRequired = false
            fileSaveError = nil
            fileSaveNotice = fileSaveNoticeText(completedResult.notice)
            return true
        } catch {
            let workflowError = NewDocumentSaveWorkflowError
                .outputVerifiedButRecoveryCleanupFailed(
                    result: pendingFileSaveCleanup,
                    cleanupFailure: RecoveryCleanupFailure(capturing: error)
                )
            fileSaveError = workflowError.localizedDescription
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
            let displayEnvelope = RecoveryEnvelope(
                formatVersion: envelope.formatVersion,
                documentID: envelope.documentID,
                title: summary.title,
                text: envelope.text,
                editedAt: envelope.editedAt
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

    private func cancelPendingCheckpointForFileSave() async {
        let activeCheckpointTask = checkpointTask
        activeCheckpointTask?.cancel()
        if let activeCheckpointTask {
            await activeCheckpointTask.value
        }
        checkpointTask = nil
        pendingCheckpoint = nil
    }

    private func currentDocumentIsReadyForTransition() async -> Bool {
        if let checkpointTask {
            await checkpointTask.value
        }

        guard pendingCheckpoint == nil,
              state.activeTab.document.recoveryState != .checkpointPending else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .checkpointMustFinishBeforeRecovering
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
            pendingCheckpoint = nil
            await persist(checkpoint: checkpoint)
        }

        checkpointTask = nil
        if !Task.isCancelled, pendingCheckpoint != nil {
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

    private func persist(checkpoint: PendingRecoveryCheckpoint) async {
        do {
            let updatedState = try await editActiveDocumentAndCheckpoint(
                state: checkpoint.previousState,
                newText: checkpoint.text,
                editedAt: checkpoint.editedAt,
                recoveryStore: recoveryStore
            )
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return
            }
            state = updatedState
            recoveryError = nil
        } catch {
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return
            }
            recoveryError = error.localizedDescription
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
}
