import Foundation
import PhonePadCore

enum RecoveryCheckpointCompletion {
    case notRequired
    case persisted(state: PhonePadState, documentID: DocumentID)
    case superseded
    case failed(state: PhonePadState?, recoveryError: String?)
    case blocked
}

struct RecoveryCheckpointDiscardResult {
    let state: PhonePadState
    let documentID: DocumentID
}

@MainActor
final class PhonePadRecoveryCheckpointCoordinator {
    typealias StateProvider = @MainActor () -> PhonePadState?
    typealias CompletionHandler = @MainActor (
        RecoveryCheckpointCompletion
    ) async -> Void

    private struct PendingRecoveryCheckpoint {
        let generation: UInt64
        let checkpointBaseState: PhonePadState
        let recoveryBaselineState: PhonePadState?
        let text: String
        let editedAt: Date
        let firstPendingAt: ContinuousClock.Instant
        let lastEditAt: ContinuousClock.Instant
        let requiresImmediateCheckpoint: Bool
    }

    private let recoveryStore: any RecoveryStoring
    private let quietPeriod: Duration
    private let maximumInterval: Duration
    private let clock: ContinuousClock
    private var pending: PendingRecoveryCheckpoint?
    private var failed: PendingRecoveryCheckpoint?
    private var editGeneration: UInt64
    private var task: Task<Void, Never>?

    init(
        recoveryStore: any RecoveryStoring,
        quietPeriod: Duration,
        maximumInterval: Duration
    ) {
        precondition(
            quietPeriod > .zero,
            "Checkpoint quiet period must be positive."
        )
        precondition(
            maximumInterval > .zero,
            "Checkpoint maximum interval must be positive."
        )
        self.recoveryStore = recoveryStore
        self.quietPeriod = quietPeriod
        self.maximumInterval = maximumInterval
        clock = ContinuousClock()
        pending = nil
        failed = nil
        editGeneration = 0
        task = nil
    }

    var allowsEditing: Bool {
        failed == nil
    }

    var isIdle: Bool {
        pending == nil && failed == nil
    }

    func hasUnavailableCheckpoint(state: PhonePadState) -> Bool {
        failed != nil
            && state.activeTab.document.recoveryState == .recoveryUnavailable
    }

    func scheduleEdit(
        previousState: PhonePadState,
        transition: RecoveryEditTransition,
        stateProvider: @escaping StateProvider,
        completionHandler: @escaping CompletionHandler
    ) {
        editGeneration += 1
        let now = clock.now
        let existingCheckpoint = pending
        pending = PendingRecoveryCheckpoint(
            generation: editGeneration,
            checkpointBaseState: existingCheckpoint?.checkpointBaseState
                ?? previousState,
            recoveryBaselineState: existingCheckpoint?.recoveryBaselineState
                ?? previousState,
            text: transition.envelope.text,
            editedAt: transition.envelope.editedAt,
            firstPendingAt: existingCheckpoint?.firstPendingAt ?? now,
            lastEditAt: now,
            requiresImmediateCheckpoint:
                existingCheckpoint?.requiresImmediateCheckpoint
                ?? (previousState.activeTab.document.recoveryState == .clean)
        )
        startTaskIfNeeded(
            stateProvider: stateProvider,
            completionHandler: completionHandler
        )
    }

    func protectExternalOpenTransition(
        transition: RecoveryEditTransition
    ) async -> RecoveryCheckpointCompletion {
        await cancelAndAwaitTask()
        guard isIdle else {
            return .blocked
        }
        editGeneration += 1
        let now = clock.now
        let checkpoint = PendingRecoveryCheckpoint(
            generation: editGeneration,
            checkpointBaseState: transition.state,
            recoveryBaselineState: nil,
            text: transition.envelope.text,
            editedAt: transition.envelope.editedAt,
            firstPendingAt: now,
            lastEditAt: now,
            requiresImmediateCheckpoint: true
        )
        pending = checkpoint
        return await persist(
            checkpoint: checkpoint,
            stateProvider: { transition.state }
        )
    }

    @discardableResult
    func clear(documentID: DocumentID) -> Bool {
        let hadPendingCheckpoint = pending?
            .checkpointBaseState.activeTab.document.id == documentID
        let hadFailedCheckpoint = failed?
            .checkpointBaseState.activeTab.document.id == documentID
        if pending?.checkpointBaseState.activeTab.document.id == documentID {
            pending = nil
        }
        if failed?.checkpointBaseState.activeTab.document.id == documentID {
            failed = nil
        }
        if hadPendingCheckpoint || hadFailedCheckpoint {
            editGeneration += 1
        }
        return isIdle
    }

    func clearAll() {
        if pending != nil || failed != nil {
            editGeneration += 1
        }
        pending = nil
        failed = nil
    }

    func retry(currentState: PhonePadState) async -> RecoveryCheckpointCompletion {
        await cancelAndAwaitTask()
        guard let checkpoint = failed ?? pending else {
            if currentState.activeTab.document.recoveryState
                == .checkpointPending
                || currentState.activeTab.document.recoveryState
                    == .recoveryUnavailable {
                return .failed(state: nil, recoveryError: nil)
            }
            return .notRequired
        }
        return await persist(
            checkpoint: checkpoint,
            stateProvider: { currentState }
        )
    }

    @discardableResult
    func holdForFileConflictReload() async -> Bool {
        await cancelAndAwaitTask()
        guard let checkpoint = failed ?? pending else {
            return false
        }
        failed = checkpoint
        pending = nil
        return true
    }

    func discardUnavailableEdits(
        state: PhonePadState
    ) async throws -> RecoveryCheckpointDiscardResult {
        await cancelAndAwaitTask()
        guard let checkpoint = failed,
              state.activeTab.document.recoveryState
                == .recoveryUnavailable else {
            throw PhonePadRecoveryUnavailableActionError.recoveryIsAvailable
        }
        let documentID = state.activeTab.document.id
        let restoredState: PhonePadState
        if let baselineState = checkpoint.recoveryBaselineState {
            restoredState = try restoreDocumentAfterRecoveryFailure(
                state: state,
                baselineState: baselineState,
                documentID: documentID,
                expectedUnprotectedText: checkpoint.text
            )
        } else {
            let requirement = try prepareTabClose(
                state: state,
                tabID: state.activeTabID
            )
            guard case let .unsaved(preparedClose) = requirement else {
                throw PhonePadRecoveryUnavailableActionError
                    .recoveryIsAvailable
            }
            let result = try await discardAndClosePreparedUnsavedTab(
                state: state,
                preparedClose: preparedClose,
                replacementDocumentID: DocumentID(rawValue: UUID()),
                replacementTabID: TabID(rawValue: UUID()),
                recoveryStore: recoveryStore
            )
            restoredState = result.state
        }
        pending = nil
        failed = nil
        return RecoveryCheckpointDiscardResult(
            state: restoredState,
            documentID: documentID
        )
    }

    func recoveryUnavailableNotice(
        state: PhonePadState
    ) -> RecoveryUnavailableNotice? {
        guard let checkpoint = failed,
              state.activeTab.document.id
                == checkpoint.checkpointBaseState.activeTab.document.id,
              state.activeTab.document.recoveryState
                == .recoveryUnavailable else {
            return nil
        }
        let baselineDocument = checkpoint.recoveryBaselineState?
            .tabs
            .first(where: { tab in
                tab.document.id == state.activeTab.document.id
            })?
            .document
        return RecoveryUnavailableNotice(
            documentID: state.activeTab.document.id,
            hasNewerUnprotectedText: baselineDocument?.text
                != state.activeTab.document.text,
            hasLastVerifiedCheckpoint: baselineDocument?.recoveryState
                == .protectedUnsaved
        )
    }

    func cancelAndAwaitTask() async {
        let activeTask = task
        activeTask?.cancel()
        if let activeTask {
            await activeTask.value
        }
        task = nil
    }

    private func startTaskIfNeeded(
        stateProvider: @escaping StateProvider,
        completionHandler: @escaping CompletionHandler
    ) {
        guard task == nil else {
            return
        }
        task = Task { @MainActor [weak self] in
            await self?.runCheckpointLoop(
                stateProvider: stateProvider,
                completionHandler: completionHandler
            )
        }
    }

    private func runCheckpointLoop(
        stateProvider: @escaping StateProvider,
        completionHandler: @escaping CompletionHandler
    ) async {
        while !Task.isCancelled {
            guard let checkpoint = await nextReadyCheckpoint() else {
                break
            }
            guard pending?.generation == checkpoint.generation else {
                continue
            }
            let completion = await persist(
                checkpoint: checkpoint,
                stateProvider: stateProvider
            )
            await completionHandler(completion)
            if case .failed = completion {
                break
            }
        }

        task = nil
        if !Task.isCancelled, failed == nil, pending != nil {
            startTaskIfNeeded(
                stateProvider: stateProvider,
                completionHandler: completionHandler
            )
        }
    }

    private func nextReadyCheckpoint() async -> PendingRecoveryCheckpoint? {
        while !Task.isCancelled, let checkpoint = pending {
            if checkpoint.requiresImmediateCheckpoint {
                return checkpoint
            }

            let quietDeadline = checkpoint.lastEditAt.advanced(by: quietPeriod)
            let maximumDeadline = checkpoint.firstPendingAt.advanced(
                by: maximumInterval
            )
            let deadline = min(quietDeadline, maximumDeadline)
            guard clock.now < deadline else {
                return checkpoint
            }

            do {
                try await clock.sleep(until: deadline)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func persist(
        checkpoint: PendingRecoveryCheckpoint,
        stateProvider: StateProvider
    ) async -> RecoveryCheckpointCompletion {
        do {
            _ = try await editActiveDocumentAndCheckpoint(
                state: checkpoint.checkpointBaseState,
                newText: checkpoint.text,
                editedAt: checkpoint.editedAt,
                recoveryStore: recoveryStore
            )
            guard !Task.isCancelled,
                  editGeneration == checkpoint.generation else {
                return .superseded
            }
            guard let currentState = stateProvider() else {
                pending = nil
                failed = nil
                return .superseded
            }
            let documentID = checkpoint.checkpointBaseState.activeTab.document.id
            let protectedState = try markDocumentRecoveryProtected(
                state: currentState,
                documentID: documentID,
                expectedText: checkpoint.text
            )
            if pending?.generation == checkpoint.generation {
                pending = nil
            }
            if failed?.generation == checkpoint.generation {
                failed = nil
            }
            return .persisted(
                state: protectedState,
                documentID: documentID
            )
        } catch {
            guard !Task.isCancelled,
                  editGeneration == checkpoint.generation else {
                return .superseded
            }
            if pending?.generation == checkpoint.generation {
                pending = nil
            }
            guard let currentState = stateProvider() else {
                failed = nil
                return .superseded
            }
            do {
                let unavailableState = try markDocumentRecoveryUnavailable(
                    state: currentState,
                    documentID: checkpoint.checkpointBaseState
                        .activeTab.document.id,
                    expectedText: checkpoint.text
                )
                failed = checkpoint
                return .failed(
                    state: unavailableState,
                    recoveryError: error.localizedDescription
                )
            } catch let stateError {
                failed = checkpoint
                return .failed(
                    state: nil,
                    recoveryError: "Recovery checkpoint failed: \(error.localizedDescription) MacPad Mobile could not enter Recovery Unavailable: \(stateError.localizedDescription)"
                )
            }
        }
    }
}

extension PhonePadAppModel {
    func clearCheckpointState(closedDocumentID: DocumentID) {
        if recoveryCheckpointCoordinator.clear(documentID: closedDocumentID) {
            recoveryError = nil
        }
        refreshExternalOpenCleanupAvailability()
    }

    func prepareTabTransition() -> Bool {
        guard transitionArbiter.canBeginTabTransition else {
            tabTransitionError = PhonePadTabTransitionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        tabTransitionError = nil
        return true
    }

    func beginActiveDocumentTransition() -> Bool {
        guard prepareTabTransition() else {
            return false
        }
        activeDocumentTransitionInProgress = true
        tabTransitionInProgress = true
        return true
    }

    func beginTabReorder() -> Bool {
        guard prepareTabTransition() else {
            return false
        }
        tabTransitionInProgress = true
        return true
    }

    func validateCommittedDocument(
        _ committedDocument: CommittedEditorDocument
    ) throws {
        guard state.activeTab.document.id == committedDocument.documentID else {
            throw PhonePadTabTransitionError.committedDocumentIsNotActive
        }
        let canonicalText = try validateEditableDocumentText(
            text: committedDocument.text
        )
        guard state.activeTab.document.text == canonicalText else {
            throw PhonePadTabTransitionError.committedTextWasRejected
        }
    }

    func protectCommittedDocumentForActiveTransition(
        _ committedDocument: CommittedEditorDocument
    ) async throws {
        try validateCommittedDocument(committedDocument)
        switch state.activeTab.document.recoveryState {
        case .clean, .protectedUnsaved:
            return
        case .checkpointPending, .recoveryUnavailable:
            guard await retryCurrentCheckpointIfNeeded(),
                  recoveryCheckpointCoordinator.isIdle,
                  state.activeTab.document.recoveryState == .protectedUnsaved else {
                throw PhonePadTabTransitionError
                    .checkpointMustFinishBeforeTransition
            }
            try validateCommittedDocument(committedDocument)
        }
    }

    func editActiveDocument(text: String) {
        _ = editDocument(
            documentID: state.activeTab.document.id,
            text: text
        )
    }

    @discardableResult
    func editDocument(documentID: DocumentID, text: String) -> Bool {
        guard state.activeTab.document.id == documentID else {
            return false
        }
        guard !fileSaveCleanupRequired else {
            if fileSaveError == nil {
                fileSaveError = PhonePadFileSaveActionError
                    .cleanupRequired
                    .localizedDescription
            }
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard pendingSaveAsReplacement == nil,
              activeRecoveryAction == nil,
              !activeDocumentTransitionInProgress,
              pendingTabCloseSession == nil,
              !externalOpenInProgress,
              !externalOpenCoordinator.hasPendingDecision else {
            return false
        }
        guard recoveryCheckpointCoordinator.allowsEditing else {
            return false
        }
        guard text != state.activeTab.document.text else {
            return true
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
            return false
        }

        state = transition.state
        recoveryError = nil
        recoveryCheckpointCoordinator.scheduleEdit(
            previousState: previousState,
            transition: transition,
            stateProvider: { [weak self] in self?.state },
            completionHandler: { [weak self] completion in
                _ = await self?.applyRecoveryCheckpointCompletion(completion)
            }
        )
        return true
    }

    @discardableResult
    func retryActiveDocumentRecovery() async -> Bool {
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard recoveryCheckpointCoordinator.hasUnavailableCheckpoint(
            state: state
        ) else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .recoveryIsAvailable
                .localizedDescription
            return false
        }
        activeRecoveryAction = state.activeTab.document.id
        defer { finishRecoveryAction() }
        return await retryCurrentCheckpointIfNeeded()
    }

    @discardableResult
    func discardRecoveryUnavailableEdits() async -> Bool {
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard recoveryCheckpointCoordinator.hasUnavailableCheckpoint(
            state: state
        ) else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .recoveryIsAvailable
                .localizedDescription
            return false
        }
        activeRecoveryAction = state.activeTab.document.id
        defer { finishRecoveryAction() }
        do {
            let result = try await recoveryCheckpointCoordinator
                .discardUnavailableEdits(state: state)
            state = result.state
            externalOpenCoordinator.removeEphemeralClaims(
                documentID: result.documentID
            )
            recoveryError = nil
            clearExternalOpenRecoveryProtectionFailure(
                documentID: result.documentID
            )
            _ = await retryExternalOpenCleanupIfNeeded()
            presentActiveFileConflictIfNeeded()
            return true
        } catch {
            recoveryError = error.localizedDescription
            return false
        }
    }

    func retryCurrentCheckpointIfNeeded() async -> Bool {
        let completion = await recoveryCheckpointCoordinator.retry(
            currentState: state
        )
        return await applyRecoveryCheckpointCompletion(completion)
    }

    func holdCurrentCheckpointForFileConflictReload() async {
        guard await recoveryCheckpointCoordinator
            .holdForFileConflictReload() else {
            return
        }
        if recoveryError == nil {
            recoveryError = PhonePadRecoveryActionError
                .checkpointHeldForFileConflictReload
                .localizedDescription
        }
    }

    func cancelAndAwaitCheckpointTask() async {
        await recoveryCheckpointCoordinator.cancelAndAwaitTask()
    }

    func currentDocumentIsReadyForFileTransition() async -> Bool {
        guard await retryCurrentCheckpointIfNeeded(),
              recoveryCheckpointCoordinator.isIdle,
              state.activeTab.document.recoveryState != .checkpointPending,
              state.activeTab.document.recoveryState != .recoveryUnavailable else {
            fileSaveError = PhonePadFileSaveActionError
                .checkpointMustFinishBeforeFileAction
                .localizedDescription
            return false
        }
        return true
    }

    func applyRecoveryCheckpointCompletion(
        _ completion: RecoveryCheckpointCompletion
    ) async -> Bool {
        switch completion {
        case .notRequired:
            return true
        case let .persisted(protectedState, documentID):
            state = protectedState
            recoveryError = nil
            _ = await retryExternalOpenCleanupIfNeeded()
            clearExternalOpenRecoveryProtectionFailure(
                documentID: documentID
            )
            return true
        case let .failed(unavailableState, checkpointError):
            if let unavailableState {
                state = unavailableState
            }
            if let checkpointError {
                recoveryError = checkpointError
            }
            return false
        case .superseded, .blocked:
            return false
        }
    }

}
