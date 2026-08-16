import Foundation
import PhonePadCore

extension PhonePadAppModel {
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
    func locateOriginal(
        selectedURL: URL,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace,
              !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard activeDocumentCanLocateOriginal else {
            fileSaveError = RecoveredFileOpenError
                .fileReferenceMissing(state.activeTab.document.id)
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        let documentID = state.activeTab.document.id
        defer { finishFileMutation() }

        do {
            try validateCommittedDocument(committedDocument)
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            let result = try await reattachRecoveredDocument(
                state: state,
                documentID: documentID,
                selectedURL: selectedURL,
                editedAt: Date(),
                recoveryStore: recoveryStore,
                fileAccessConnector: fileAccessConnector
            )
            switch result {
            case let .reattached(reattachedState):
                state = reattachedState
                fileSaveNotice = reattachedState.activeTab.document.fileConflict
                    == nil
                    ? "Original File located. Recovered edits remain protected and can now be saved in place."
                    : nil
            case let .activatedExisting(activatedState):
                state = activatedState
                fileSaveNotice = "Original File is already open. Its existing Tab was activated; recovered text remains protected and detached for Save As."
            }
            recoveryError = nil
            fileSaveError = nil
            return true
        } catch {
            fileSaveError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func openDocument(
        selectedURL: URL,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard presentersShouldBeActive,
              !externalOpenTransitionOwnsWorkspace,
              canBeginExternalOpenAction else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        fileSaveError = nil
        fileSaveNotice = nil
        await enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: selectedURL,
                accessIntent: .inPlace
            ),
        ])
        guard let commitRequestID = externalOpenCommitRequestID else {
            fileSaveError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        let opened = await processNextExternalOpen(
            after: committedDocument,
            commitRequestID: commitRequestID
        )
        fileSaveError = opened ? nil : externalOpenError
        return opened
    }

    func prepareDocumentSaveAs(
        fileName: String,
        encoding: TextFileEncoding
    ) throws -> PreparedSaveAs {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            throw PhonePadFileSaveActionError.actionAlreadyInProgress
        }
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
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return nil
        }
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
        defer { finishFileMutation() }

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

    func presentFileConflictResolution() {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileConflictAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        guard state.activeTab.document.fileConflict != nil else {
            return
        }
        fileConflictError = nil
        fileConflictResolutionIsPresented = true
    }

    func cancelFileConflictResolution() {
        fileConflictResolutionIsPresented = false
        fileConflictError = nil
        restorePendingTabCloseDecisionAfterFileConflictCancellation()
        requestExternalOpenEditorCommitIfPossible()
    }

    @discardableResult
    func beginSaveAsFromFileConflict() -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileConflictAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard state.activeTab.document.fileConflict != nil else {
            fileConflictError = FileConflictWorkflowError
                .fileConflictRequired(state.activeTab.document.id)
                .localizedDescription
            return false
        }
        fileConflictResolutionIsPresented = false
        fileConflictError = nil
        if let tabID = pendingTabCloseCandidateTabID,
           pendingTabCloseSession?.phase == .fileConflict(tabID) {
            setPendingTabClosePhase(.saveAs(tabID))
        }
        return true
    }

    func reportFileConflictTransitionError(_ error: Error) {
        fileConflictError = error.localizedDescription
    }

    @discardableResult
    func discardEditsAndReloadCurrentFile() async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileConflictAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileConflictError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        let documentID = state.activeTab.document.id
        guard state.activeTab.document.fileConflict != nil else {
            fileConflictError = FileConflictWorkflowError
                .fileConflictRequired(documentID)
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileConflictError = nil
        fileSaveError = nil
        fileSaveNotice = nil
        defer { finishFileMutation() }

        await holdCurrentCheckpointForFileConflictReload()

        do {
            let result = try await reloadCurrentFileAfterDiscardingEdits(
                state: state,
                documentID: documentID,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            state = result.state
            recoveryCheckpointCoordinator.clearAll()
            recoveryError = nil
            presenterRefreshPending = true
            fileConflictError = nil
            fileSaveError = nil
            fileSaveNotice = result.recoveryCleanupPending
                ? "Edits were discarded and current File content was reloaded. Protected cleanup remains and MacPad Mobile will retry it on next recovery access."
                : nil
            fileConflictResolutionIsPresented = state.activeTab.document.fileConflict != nil
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: documentID
            )
            return true
        } catch {
            fileConflictError = error.localizedDescription
            fileConflictResolutionIsPresented = true
            return false
        }
    }

    func reconcilePresentedFile(documentID: DocumentID) async {
        guard presentersShouldBeActive else {
            presenterRefreshPending = true
            return
        }
        guard transitionArbiter.canReconcilePresentedFiles else {
            presenterRefreshPending = true
            return
        }
        let lifecycleGeneration = presenterLifecycleGeneration
        guard let document = state.tabs.first(where: {
            $0.document.id == documentID
        })?.document, let binding = document.fileBinding else {
            await fileAccessConnector.stopPresenting(documentID: documentID)
            return
        }
        let hadConflict = document.fileConflict != nil

        do {
            let observation = try await fileAccessConnector.reconcilePresentedFile(
                documentID: documentID,
                binding: binding
            )
            guard presentersShouldBeActive,
                  presenterLifecycleGeneration == lifecycleGeneration else {
                return
            }
            guard transitionArbiter.canReconcilePresentedFiles else {
                presenterRefreshPending = true
                return
            }
            guard state.tabs.first(where: {
                $0.document.id == documentID
            })?.document.fileBinding == binding else {
                return
            }
            state = try reconcileBoundDocument(
                state: state,
                documentID: documentID,
                observation: observation
            )
            if state.activeTab.document.id == documentID {
                fileConflictError = nil
                if !hadConflict,
                   state.activeTab.document.fileConflict != nil {
                    fileConflictResolutionIsPresented = true
                }
            }
        } catch {
            if state.activeTab.document.id == documentID {
                fileConflictError = error.localizedDescription
            }
        }
    }

    func sceneBecameInactive() async {
        presenterLifecycleGeneration += 1
        let generation = presenterLifecycleGeneration
        presentersShouldBeActive = false
        externalOpenCoordinator.pausePendingCommitForInactiveScene()
        if !fileSaveCleanupRequired, pendingTabCloseSession == nil {
            presenterRefreshPending = false
        }
        await fileAccessConnector.pausePresenters()
        guard presenterLifecycleGeneration == generation,
              !presentersShouldBeActive else {
            return
        }
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenInProgress else {
            return
        }
        _ = await retryCurrentCheckpointIfNeeded()
    }

    func sceneBecameActive() async {
        presenterLifecycleGeneration += 1
        let generation = presenterLifecycleGeneration
        presentersShouldBeActive = true
        externalOpenCoordinator.markActivationReconciliationPending()
        await reconcileImportedCopyCleanupJournalForActiveSceneIfPossible()
        requestExternalOpenEditorCommitIfPossible()
        await resumePresentersIfActive(generation: generation)
    }

    func reconcileImportedCopyCleanupJournalForActiveSceneIfPossible()
        async {
        await externalOpenCoordinator.reconcileCleanupForActiveSceneIfPossible(
            presentersShouldBeActive: presentersShouldBeActive,
            fileSaveInProgress: fileSaveInProgress
        )
    }

    func retryActiveFileReconciliation() async {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        fileConflictError = nil
        await sceneBecameActive()
    }

    func resumePresentersIfActive(generation: UInt64) async {
        guard presentersShouldBeActive,
              presenterLifecycleGeneration == generation else {
            return
        }
        guard transitionArbiter.canReconcilePresentedFiles else {
            presenterRefreshPending = true
            return
        }
        presenterRefreshPending = false
        let registrations = state.tabs.compactMap { tab -> PresentedFileRegistration? in
            guard let binding = tab.document.fileBinding else {
                return nil
            }
            return PresentedFileRegistration(
                documentID: tab.document.id,
                binding: binding
            )
        }
        let outcomes = await fileAccessConnector.resumePresenters(
            bindings: registrations
        )
        guard presentersShouldBeActive,
              presenterLifecycleGeneration == generation else {
            return
        }
        guard transitionArbiter.canReconcilePresentedFiles else {
            presenterRefreshPending = true
            return
        }
        var detectedActiveConflict = false
        for registration in registrations {
            guard transitionArbiter.canReconcilePresentedFiles,
                  state.tabs.first(where: {
                      $0.document.id == registration.documentID
                  })?.document.fileBinding == registration.binding,
                  let outcome = outcomes[registration.documentID] else {
                continue
            }
            switch outcome {
            case let .observed(observation):
                do {
                    let hadConflict = state.tabs.first(where: {
                        $0.document.id == registration.documentID
                    })?.document.fileConflict != nil
                    state = try reconcileBoundDocument(
                        state: state,
                        documentID: registration.documentID,
                        observation: observation
                    )
                    if state.activeTab.document.id == registration.documentID {
                        fileConflictError = nil
                        if !hadConflict,
                           state.activeTab.document.fileConflict != nil {
                            detectedActiveConflict = true
                        }
                    }
                } catch {
                    if state.activeTab.document.id == registration.documentID {
                        fileConflictError = error.localizedDescription
                    }
                }
            case let .failed(error):
                if state.activeTab.document.id == registration.documentID {
                    fileConflictError = error.localizedDescription
                }
            }
        }
        if detectedActiveConflict {
            fileConflictResolutionIsPresented = true
        }
    }

    @discardableResult
    func completePreflightedSaveAs(
        _ preflight: PreparedSaveAsPreflight
    ) async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
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
            finishFileMutation()
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
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: preflight.preparedSave.documentID
            )
            return true
        } catch let error as FileAccessConnectorError {
            if case .currentFile = preflight.target,
               let conflict = error.underlyingFileConflict {
                applyDetectedFileConflict(
                    documentID: preflight.preparedSave.documentID,
                    conflict: conflict
                )
            } else {
                applySaveAsFailure(error)
            }
            return false
        } catch {
            applySaveAsFailure(error)
            return false
        }
    }

    @discardableResult
    func confirmReplacementAndCompleteSaveAs() async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
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
            finishFileMutation()
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
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: replacement.preparedSave.documentID
            )
            return true
        } catch {
            applySaveAsFailure(error)
            return false
        }
    }

    func applyCompletedSaveAs(_ result: SaveAsResult) {
        state = result.state
        presenterRefreshPending = true
        pendingFileSaveCleanup = nil
        fileSaveCleanupRequired = false
        fileSaveError = nil
        fileSaveNotice = fileSaveNoticeText(result.notice)
        fileConflictResolutionIsPresented = false
        fileConflictError = nil
    }

    func applySaveAsFailure(_ error: Error) {
        if let workflowError = error as? SaveAsWorkflowError,
           case let .outputVerifiedButRecoveryCleanupFailed(result, _) = workflowError {
            pendingFileSaveCleanup = .saveAs(result)
            fileSaveCleanupRequired = true
            if result.state.activeTab.document.id
                == pendingTabCloseDocumentID,
               let tabID = pendingTabCloseCandidateTabID {
                setPendingTabClosePhase(.cleanup(tabID))
                pendingTabClosePrompt = nil
            }
        }
        fileSaveError = error.localizedDescription
    }

    @discardableResult
    func saveActiveDocument() async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsBoundSave,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
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
        guard state.activeTab.document.fileConflict == nil else {
            fileSaveError = nil
            fileSaveNotice = nil
            fileConflictError = nil
            fileConflictResolutionIsPresented = true
            return false
        }
        guard state.activeTab.document.isUnsaved else {
            clearFileSaveFeedback()
            return true
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer { finishFileMutation() }

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
                if result.state.activeTab.document.id
                    == pendingTabCloseDocumentID,
                   let tabID = pendingTabCloseCandidateTabID {
                    setPendingTabClosePhase(.cleanup(tabID))
                    pendingTabClosePrompt = nil
                }
            }
            fileSaveError = error.localizedDescription
            return false
        } catch let error as FileAccessConnectorError {
            if let conflict = error.underlyingFileConflict {
                applyDetectedFileConflict(
                    documentID: state.activeTab.document.id,
                    conflict: conflict
                )
                return false
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
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileSaveCleanup,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
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
        defer { finishFileMutation() }

        do {
            let cleanupDocumentID = pendingFileSaveCleanup.documentID
            let terminalOutcome = try await recoveryStore.completeRecoveryAfterSave(
                documentID: cleanupDocumentID
            )
            switch pendingFileSaveCleanup {
            case let .standard(result):
                let completedResult = applyingRecoveryTerminalOutcome(
                    result: result,
                    terminalOutcome: terminalOutcome
                )
                state = completedResult.state
                presenterRefreshPending = true
                fileSaveNotice = fileSaveNoticeText(completedResult.notice)
            case let .saveAs(result):
                let completedResult = applyingSaveAsRecoveryTerminalOutcome(
                    result: result,
                    terminalOutcome: terminalOutcome
                )
                state = completedResult.state
                presenterRefreshPending = true
                fileSaveNotice = fileSaveNoticeText(completedResult.notice)
            }
            self.pendingFileSaveCleanup = nil
            fileSaveCleanupRequired = false
            fileSaveError = nil
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: cleanupDocumentID
            )
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

}
