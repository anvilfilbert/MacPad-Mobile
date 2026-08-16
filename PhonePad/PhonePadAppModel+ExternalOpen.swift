import Foundation
import PhonePadCore

extension PhonePadExternalOpenCoordinator {
    func enqueueExternalOpenRequests(
        _ requests: [PhonePadExternalOpenRequest]
    ) async {
        let queuedRequests = requests.map { request in
            QueuedExternalOpenRequest(
                id: UUID(),
                request: request,
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID()),
                importedCopyCleanupTokens: [],
                importedCopyCleanupCapture:
                    importedCopyCleanupCapture(request: request)
            )
        }
        enqueue(requests: queuedRequests)
        await preflightQueuedExternalOpenCleanup(
            requestIDs: queuedRequests.map(\.id)
        )
    }

    func importedCopyCleanupCapture(
        request: PhonePadExternalOpenRequest
    ) -> ImportedCopyCleanupCapture {
        guard request.accessIntent == .copyRequired else {
            return .notRequired
        }
        do {
            guard let candidate = try fileAccessConnector
                .inspectImportedCopyCleanupCandidate(at: request.url) else {
                return .notRequired
            }
            return .candidate(candidate)
        } catch {
            return .inspectionFailed(error)
        }
    }

    func preflightQueuedExternalOpenCleanup(
        requestIDs: [UUID]
    ) async {
        let batchID = UUID()
        beginningCleanupPreflight(batchID: batchID)

        for requestID in requestIDs {
            do {
                _ = try await captureQueuedImportedCopyCleanup(
                    requestID: requestID
                )
                clearingCleanupPreflightFailure(requestID: requestID)
            } catch {
                let failure = ExternalOpenCleanupPreflightFailure(
                    requestID: requestID,
                    message: error.localizedDescription
                )
                recordingCleanupPreflightFailure(failure)
            }
        }
        await finishExternalOpenCleanupPreflight(batchID: batchID)
    }

    func finishExternalOpenCleanupPreflight(batchID: UUID) async {
        completingCleanupPreflight(batchID: batchID)
        guard !externalOpenCleanupPreflightInProgress else {
            return
        }
        await resumePendingActivationWorkAfterExclusiveAction()
    }

    var externalOpenCleanupPreflightInProgress: Bool {
        cleanupPreflightInProgress
    }

    var liveExternalOpenCleanupTokens:
        Set<ImportedCopyCleanupToken> {
        liveCleanupTokens
    }

    var externalOpenQueueRequiresCleanupPreflight: Bool {
        queueRequiresCleanupPreflight
    }

    func importedCopyCleanupPreflightRequired(
        request: QueuedExternalOpenRequest
    ) -> Bool {
        cleanupPreflightRequired(request: request)
    }

    func captureQueuedImportedCopyCleanup(
        requestID: UUID
    ) async throws -> QueuedExternalOpenRequest {
        guard let requestIndex = externalOpenQueue.firstIndex(where: {
            $0.id == requestID
        }) else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        var request = externalOpenQueue[requestIndex]
        guard request.importedCopyCleanupTokens.isEmpty else {
            return request
        }

        let capture: ImportedCopyCleanupCapture
        switch request.importedCopyCleanupCapture {
        case .notRequired, .candidate:
            capture = request.importedCopyCleanupCapture
        case .inspectionFailed:
            capture = importedCopyCleanupCapture(request: request.request)
            request = QueuedExternalOpenRequest(
                id: request.id,
                request: request.request,
                documentID: request.documentID,
                tabID: request.tabID,
                importedCopyCleanupTokens: request.importedCopyCleanupTokens,
                importedCopyCleanupCapture: capture
            )
            try replacingQueuedRequest(request)
        }

        switch capture {
        case .notRequired:
            return request
        case let .inspectionFailed(error):
            throw error
        case let .candidate(candidate):
            let token = try await fileAccessConnector
                .captureImportedCopyCleanup(
                    at: request.request.url,
                    documentID: request.documentID,
                    matching: candidate
                )
            retainImportedCopyCleanupTokenForRetry(
                token,
                requestID: request.id
            )
            guard let capturedRequest = externalOpenQueue.first(where: {
                $0.id == request.id
            }) else {
                throw PhonePadExternalOpenActionError.commitRequestMissing
            }
            return capturedRequest
        }
    }

    func prepareQueuedImportedCopyCleanup(
        requestID: UUID
    ) async throws -> QueuedExternalOpenRequest {
        guard externalOpenQueue.first?.id == requestID else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        return try await captureQueuedImportedCopyCleanup(
            requestID: requestID
        )
    }

    func reportExternalOpenCommitFailure(
        commitRequestID: UUID,
        error: Error
    ) {
        guard externalOpenCommitRequestID == commitRequestID else {
            return
        }
        externalOpenCommitRequestID = nil
        externalOpenError = error.localizedDescription
    }

    func retryExternalOpenCommit() async {
        guard !terminalExternalOpenErrorPendingDismissal,
              !externalOpenCleanupPreflightInProgress else {
            return
        }
        terminalExternalOpenErrorPendingDismissal = false
        externalOpenError = nil
        await preflightQueuedExternalOpenCleanup(
            requestIDs: externalOpenQueue.filter {
                importedCopyCleanupPreflightRequired(request: $0)
            }.map(\.id)
        )
    }

    func dismissTerminalExternalOpenError() {
        guard terminalExternalOpenErrorPendingDismissal,
              !externalOpenCleanupRequired else {
            return
        }
        terminalExternalOpenErrorPendingDismissal = false
        externalOpenError = nil
        requestExternalOpenEditorCommitIfPossible()
    }

    @discardableResult
    func processNextExternalOpen(
        after committedDocument: CommittedEditorDocument,
        commitRequestID: UUID
    ) async -> Bool {
        guard presentersShouldBeActive else {
            if externalOpenCommitRequestID == commitRequestID {
                externalOpenCommitRequestID = nil
            }
            return false
        }
        guard externalOpenCommitRequestID == commitRequestID,
              let queuedRequest = externalOpenQueue.first else {
            externalOpenError = PhonePadExternalOpenActionError
                .commitRequestMissing
                .localizedDescription
            return false
        }
        guard canBeginExternalOpenAction else {
            externalOpenCommitRequestID = nil
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        externalOpenInProgress = true
        if externalOpenError != importedCopyCleanupJournalErrorMessage {
            externalOpenError = nil
        }
        if !externalOpenCleanupRequired {
            externalOpenGeneralNotice = nil
        }
        terminalExternalOpenErrorPendingDismissal = false

        let opened: Bool
        do {
            try validateCommittedDocument(committedDocument)
            let request = try await prepareQueuedImportedCopyCleanup(
                requestID: queuedRequest.id
            )
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            opened = try await prepareAndResolveExternalOpen(request: request)
        } catch {
            externalOpenError = error.localizedDescription
            opened = false
        }
        await finishExternalOpenAction()
        return opened
    }

    func cancelPendingExternalOpen() async {
        guard !externalOpenCleanupRequired else {
            externalOpenError = PhonePadExternalOpenActionError
                .cleanupMustFinishBeforeDismissal
                .localizedDescription
            return
        }
        guard !externalOpenInProgress,
              !externalOpenCleanupPreflightInProgress,
              externalOpenCommitRequestID == nil,
              workspaceActivity.permitsExclusiveAction else {
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        externalOpenInProgress = true

        if terminalExternalOpenErrorPendingDismissal {
            terminalExternalOpenErrorPendingDismissal = false
            externalOpenError = nil
        } else if let decision = pendingExternalOpenDecision {
            do {
                if try queuedImportedCopyCleanupCandidateChanged(
                    request: decision.request
                ) {
                    try await fileAccessConnector
                        .abandonImportedCopyCleanup(
                            tokens: decision.importedCopyCleanupTokens
                        )
                    pendingExternalOpenDecision = nil
                    pendingExternalOpenRecoveryPrompt = nil
                    completeExternalOpenRequest(
                        requestID: decision.request.id
                    )
                    terminalExternalOpenErrorPendingDismissal = true
                    externalOpenError = FileAccessConnectorError
                        .importedCopyCleanupCandidateChanged
                        .localizedDescription
                } else {
                    retainImportedCopyCleanup(
                        documentID: nil,
                        tokens: decision.importedCopyCleanupTokens
                    )
                    pendingExternalOpenDecision = nil
                    pendingExternalOpenRecoveryPrompt = nil
                    completeExternalOpenRequest(
                        requestID: decision.request.id
                    )
                    await retryExternalOpenCleanupIfNeeded()
                    externalOpenError = nil
                }
            } catch {
                externalOpenError = error.localizedDescription
            }
        } else if let request = externalOpenQueue.first {
            do {
                let capturedRequest = try await
                    prepareQueuedImportedCopyCleanup(requestID: request.id)
                if try queuedImportedCopyCleanupCandidateChanged(
                    request: capturedRequest
                ) {
                    try await fileAccessConnector
                        .abandonImportedCopyCleanup(
                            tokens: capturedRequest
                                .importedCopyCleanupTokens
                        )
                    completeExternalOpenRequest(requestID: capturedRequest.id)
                    terminalExternalOpenErrorPendingDismissal = true
                    externalOpenError = FileAccessConnectorError
                        .importedCopyCleanupCandidateChanged
                        .localizedDescription
                } else {
                    retainImportedCopyCleanup(
                        documentID: nil,
                        tokens: capturedRequest.importedCopyCleanupTokens
                    )
                    completeExternalOpenRequest(requestID: capturedRequest.id)
                    await retryExternalOpenCleanupIfNeeded()
                    externalOpenError = nil
                }
            } catch FileAccessConnectorError
                .importedCopyCleanupCandidateChanged {
                completeExternalOpenRequest(requestID: request.id)
                terminalExternalOpenErrorPendingDismissal = true
                externalOpenError = FileAccessConnectorError
                    .importedCopyCleanupCandidateChanged
                    .localizedDescription
            } catch {
                externalOpenError = error.localizedDescription
            }
        } else {
            externalOpenError = nil
        }
        await finishExternalOpenAction()
    }

    func queuedImportedCopyCleanupCandidateChanged(
        request: QueuedExternalOpenRequest
    ) throws -> Bool {
        guard case let .candidate(candidate) =
                request.importedCopyCleanupCapture else {
            return false
        }
        let currentCandidate = try fileAccessConnector
            .inspectImportedCopyCleanupCandidate(at: request.request.url)
        return currentCandidate != candidate
    }

    @discardableResult
    func retryExternalOpenCleanup() async -> Bool {
        guard externalOpenCommitRequestID == nil,
              !externalOpenInProgress,
              pendingExternalOpenDecision == nil,
              !externalOpenCleanupInProgress else {
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard externalOpenCleanupRequired else {
            if let documentID = deferredImportedCopyCleanupDocumentID {
                let message = PhonePadExternalOpenActionError
                    .cleanupRequiresRecoveryProtection(documentID)
                    .localizedDescription
                externalOpenRecoveryProtectionFailure =
                    ExternalOpenRecoveryProtectionFailure(
                        documentID: documentID,
                        message: message
                    )
                externalOpenError = message
            } else {
                externalOpenError = PhonePadExternalOpenActionError
                    .cleanupNotRequired
                    .localizedDescription
            }
            return false
        }
        externalOpenCleanupInProgress = true
        defer { externalOpenCleanupInProgress = false }
        if importedCopyCleanupJournalRetryRequired {
            return await reconcileImportedCopyCleanupJournal()
        }
        return await retryExternalOpenCleanupIfNeeded()
    }

}

extension PhonePadAppModel {
    var canBeginExternalOpenAction: Bool {
        externalOpenCoordinator.canBeginExternalOpenAction
    }

    var externalOpenCleanupPreflightInProgress: Bool {
        externalOpenCoordinator.externalOpenCleanupPreflightInProgress
    }

    var externalOpenQueueRequiresCleanupPreflight: Bool {
        externalOpenCoordinator.externalOpenQueueRequiresCleanupPreflight
    }

    var liveExternalOpenCleanupTokens:
        Set<ImportedCopyCleanupToken> {
        externalOpenCoordinator.liveExternalOpenCleanupTokens
    }

    @discardableResult
    func reconcileImportedCopyCleanupJournal() async -> Bool {
        await externalOpenCoordinator.reconcileImportedCopyCleanupJournal()
    }

    @discardableResult
    func retryExternalOpenCleanupIfNeeded() async -> Bool {
        await externalOpenCoordinator.retryExternalOpenCleanupIfNeeded()
    }

    func refreshExternalOpenCleanupAvailability() {
        externalOpenCoordinator.refreshExternalOpenCleanupAvailability()
    }

    func clearExternalOpenRecoveryProtectionFailure(
        documentID: DocumentID
    ) {
        externalOpenCoordinator.clearExternalOpenRecoveryProtectionFailure(
            documentID: documentID
        )
    }

    func requestExternalOpenEditorCommitIfPossible() {
        externalOpenCoordinator.requestExternalOpenEditorCommitIfPossible()
    }

    func enqueueExternalOpenRequests(
        _ requests: [PhonePadExternalOpenRequest]
    ) async {
        await externalOpenCoordinator.enqueueExternalOpenRequests(requests)
    }

    func reportExternalOpenCommitFailure(
        commitRequestID: UUID,
        error: Error
    ) {
        externalOpenCoordinator.reportExternalOpenCommitFailure(
            commitRequestID: commitRequestID,
            error: error
        )
    }

    func retryExternalOpenCommit() async {
        await externalOpenCoordinator.retryExternalOpenCommit()
    }

    func dismissTerminalExternalOpenError() {
        externalOpenCoordinator.dismissTerminalExternalOpenError()
    }

    @discardableResult
    func processNextExternalOpen(
        after committedDocument: CommittedEditorDocument,
        commitRequestID: UUID
    ) async -> Bool {
        await externalOpenCoordinator.processNextExternalOpen(
            after: committedDocument,
            commitRequestID: commitRequestID
        )
    }

    func cancelPendingExternalOpen() async {
        await externalOpenCoordinator.cancelPendingExternalOpen()
    }

    @discardableResult
    func retryExternalOpenCleanup() async -> Bool {
        await externalOpenCoordinator.retryExternalOpenCleanup()
    }

    @discardableResult
    func recoverPendingExternalOpen() async -> Bool {
        await externalOpenCoordinator.recoverPendingExternalOpen()
    }

    @discardableResult
    func discardRecoveryAndOpenPendingExternalOpen() async -> Bool {
        await externalOpenCoordinator
            .discardRecoveryAndOpenPendingExternalOpen()
    }
}
