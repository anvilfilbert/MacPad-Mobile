import Foundation
import PhonePadCore

extension PhonePadExternalOpenCoordinator {
    @discardableResult
    func recoverPendingExternalOpen() async -> Bool {
        guard let decision = beginPendingExternalOpenDecisionAction() else {
            return false
        }

        let expectedState = state
        var preparation: ExternalOpenPreparation?
        let recovered: Bool
        do {
            let refreshedPreparation = try await readAndPrepareExternalOpen(
                request: decision.request.request,
                requestID: decision.request.id,
                documentID: decision.recoveryMatch.documentID,
                tabID: decision.request.tabID,
                capturedImportedCopyCleanupToken: decision
                    .importedCopyCleanupTokens.first
            )
            preparation = refreshedPreparation
            let refreshedMatch = try await revalidatedExternalOpenMatch(
                candidate: refreshedPreparation.candidate,
                decision: decision
            )
            guard state == expectedState else {
                throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                    decision.recoveryMatch.documentID
                )
            }
            guard let envelope = try await recoveryStore.load(
                documentID: refreshedMatch.documentID
            ) else {
                throw PhonePadExternalOpenActionError.recoveryItemMissing(
                    refreshedMatch.documentID
                )
            }
            guard state == expectedState else {
                throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                    decision.recoveryMatch.documentID
                )
            }

            let cleanupTokens = uniqueImportedCopyCleanupTokens(
                decision.importedCopyCleanupTokens
                    + [refreshedPreparation.importedCopyCleanupToken]
                        .compactMap { $0 }
            )
            switch refreshedPreparation {
            case let .activateExisting(
                _,
                provisionalDocumentID,
                _,
                _,
                _
            ):
                await fileAccessConnector.stopPresenting(
                    documentID: provisionalDocumentID
                )
                state = try openExternallyRecoveredDetachedDocument(
                    state: state,
                    envelope: envelope,
                    tabID: decision.request.tabID
                )
            case let .prepared(payload):
                try await applyRecoveredExternalOpen(
                    payload: payload,
                    match: refreshedMatch,
                    envelope: envelope,
                    tabID: decision.request.tabID
                )
            }
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: state.activeTab.document.id,
                candidate: refreshedPreparation.candidate
            )
            retainImportedCopyCleanup(
                documentID: decision.recoveryMatch.documentID,
                tokens: cleanupTokens
            )
            recoveryItems.removeAll {
                $0.documentID == decision.recoveryMatch.documentID
            }
            pendingExternalOpenDecision = nil
            pendingExternalOpenRecoveryPrompt = nil
            completeExternalOpenRequest(requestID: decision.request.id)
            _ = await retryExternalOpenCleanupIfNeeded()
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: refreshedPreparation.detachmentReason
            )
            externalOpenError = nil
            presentActiveFileConflictIfNeeded()
            recovered = true
        } catch {
            if let preparation {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: decision.request.id
                )
            }
            externalOpenError = error.localizedDescription
            recovered = false
        }
        await finishExternalOpenAction()
        return recovered
    }

    @discardableResult
    func discardRecoveryAndOpenPendingExternalOpen() async -> Bool {
        guard let decision = beginPendingExternalOpenDecisionAction() else {
            return false
        }

        let expectedState = state
        var preparation: ExternalOpenPreparation?
        let opened: Bool
        do {
            let refreshedDocumentID = decision
                .importedCopyCleanupTokens.isEmpty
                ? decision.request.documentID
                : decision.recoveryMatch.documentID
            let refreshedPreparation = try await readAndPrepareExternalOpen(
                request: decision.request.request,
                requestID: decision.request.id,
                documentID: refreshedDocumentID,
                tabID: decision.request.tabID,
                capturedImportedCopyCleanupToken: decision
                    .importedCopyCleanupTokens.first
            )
            preparation = refreshedPreparation
            _ = try await revalidatedExternalOpenMatch(
                candidate: refreshedPreparation.candidate,
                decision: decision
            )
            let cleanupTokens = uniqueImportedCopyCleanupTokens(
                decision.importedCopyCleanupTokens
                    + [refreshedPreparation.importedCopyCleanupToken]
                        .compactMap { $0 }
            )
            let recoveryNotice: DiscardedRecoveryDocumentOpenNotice?
            let commitResult: ExternalOpenCommitResult
            var decisionCleanupDocumentID: DocumentID? = nil
            switch refreshedPreparation {
            case let .activateExisting(
                activatedState,
                provisionalDocumentID,
                _,
                _,
                _
            ):
                decisionCleanupDocumentID = activatedState.activeTab.document.id
                try await fileAccessConnector.reassignImportedCopyCleanup(
                    tokens: cleanupTokens,
                    documentID: activatedState.activeTab.document.id
                )
                try dryRunExternalOpenCommit(
                    preparation: refreshedPreparation,
                    expectedState: expectedState
                )
                let terminalOutcome = try await recoveryStore.discardRecovery(
                    documentID: decision.recoveryMatch.documentID
                )
                guard state == expectedState else {
                    throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                        decision.recoveryMatch.documentID
                    )
                }
                try await activateExistingExternalOpen(
                    state: activatedState,
                    provisionalDocumentID: provisionalDocumentID
                )
                completeExternalOpenRequest(requestID: decision.request.id)
                recoveryNotice = terminalOutcome == .residualCleanupPending
                    ? .residualRecoveryCleanupPending
                    : nil
                commitResult = .complete
            case let .prepared(.bound(prepared, _)):
                let result = try await
                    discardRecoveryAndCommitPreparedBoundDocumentOpen(
                        state: expectedState,
                        recoveryDocumentID: decision.recoveryMatch.documentID,
                        preparedOpen: prepared,
                        recoveryStore: recoveryStore
                    )
                guard state == expectedState else {
                    throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                        decision.recoveryMatch.documentID
                    )
                }
                state = result.state
                presentActiveFileConflictIfNeeded()
                completeExternalOpenRequest(requestID: decision.request.id)
                recoveryNotice = result.notice
                commitResult = .complete
            case let .prepared(.detached(prepared, openedFile)):
                let result = try await
                    discardRecoveryAndCommitPreparedDetachedDocumentOpen(
                        state: expectedState,
                        recoveryDocumentID: decision.recoveryMatch.documentID,
                        preparedOpen: prepared,
                        recoveryStore: recoveryStore
                    )
                guard state == expectedState else {
                    throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                        decision.recoveryMatch.documentID
                    )
                }
                state = result.transition.state
                decisionCleanupDocumentID = result.transition.envelope.documentID
                retainExternalOpenDetachmentNoticeIfNeeded(
                    reason: openedFile.reason
                )
                let protected = await persistExternalOpenTransition(
                    result.transition
                )
                completeExternalOpenRequest(requestID: decision.request.id)
                recoveryNotice = result.notice
                commitResult = protected
                    ? .complete
                    : .recoveryProtectionFailed
            }
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: state.activeTab.document.id,
                candidate: refreshedPreparation.candidate
            )
            retainImportedCopyCleanup(
                documentID: decisionCleanupDocumentID,
                tokens: cleanupTokens
            )
            recoveryItems.removeAll {
                $0.documentID == decision.recoveryMatch.documentID
            }
            pendingExternalOpenDecision = nil
            pendingExternalOpenRecoveryPrompt = nil
            if commitResult == .complete {
                _ = await retryExternalOpenCleanupIfNeeded()
                retainExternalOpenDetachmentNoticeIfNeeded(
                    reason: refreshedPreparation.detachmentReason
                )
                if recoveryNotice == .residualRecoveryCleanupPending {
                    appendExternalOpenNotice(
                        "Preserved work was discarded and the supplied File opened. Protected recovery marker cleanup remains."
                    )
                }
                externalOpenError = nil
                opened = true
            } else {
                recordExternalOpenRecoveryProtectionFailure(
                    documentID: state.activeTab.document.id,
                    message: recoveryError
                )
                opened = false
            }
        } catch {
            if let preparation {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: decision.request.id
                )
            }
            externalOpenError = error.localizedDescription
            opened = false
        }
        await finishExternalOpenAction()
        return opened
    }

    func beginPendingExternalOpenDecisionAction()
        -> PendingExternalOpenDecision? {
        guard let decision = pendingExternalOpenDecision,
              !externalOpenInProgress,
              workspaceActivity.permitsExclusiveAction else {
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return nil
        }
        externalOpenInProgress = true
        externalOpenError = nil
        return decision
    }

    func revalidatedExternalOpenMatch(
        candidate: FileOpenCandidate,
        decision: PendingExternalOpenDecision
    ) async throws -> RecoveryFileOpenMatch {
        let claims = try await recoveryStore.recoveryFileCollisionClaims(
            excludingDocumentID: decision.request.documentID
        )
        let collision = try await fileAccessConnector.matchRecoveryFileClaims(
            candidate: candidate,
            claims: claims
        )
        switch collision {
        case let .item(match)
        where match.documentID == decision.recoveryMatch.documentID:
            return match
        case let .ambiguous(documentIDs):
            throw PhonePadExternalOpenActionError
                .recoveryCollisionAmbiguous(documentIDs)
        case .none, .item:
            throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                decision.recoveryMatch.documentID
            )
        }
    }

    func applyRecoveredExternalOpen(
        payload: PreparedExternalOpenPayload,
        match: RecoveryFileOpenMatch,
        envelope: RecoveryEnvelope,
        tabID: TabID
    ) async throws {
        switch payload {
        case let .bound(prepared, snapshot)
        where match.kinds.contains(.sourceFile):
            state = try openExternallyRecoveredBoundDocument(
                state: state,
                envelope: envelope,
                tabID: tabID,
                observation: ObservedBoundFile(
                    binding: snapshot.openedFile.binding,
                    providerConflictVersions: snapshot.providerConflictVersions
                )
            )
            guard state.activeTab.document.id == envelope.documentID else {
                await fileAccessConnector.stopPresenting(
                    documentID: prepared.documentID
                )
                throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                    envelope.documentID
                )
            }
        case .bound:
            await stopProvisionalPresenter(payload: payload)
            state = try openExternallyRecoveredDetachedDocument(
                state: state,
                envelope: envelope,
                tabID: tabID
            )
        case .detached:
            state = try openExternallyRecoveredDetachedDocument(
                state: state,
                envelope: envelope,
                tabID: tabID
            )
        }
    }

    func dryRunExternalOpenCommit(
        preparation: ExternalOpenPreparation,
        expectedState: PhonePadState
    ) throws {
        guard state == expectedState else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        switch preparation {
        case .activateExisting:
            return
        case let .prepared(.bound(prepared, _)):
            _ = try commitPreparedBoundDocumentOpen(
                state: state,
                prepared: prepared
            )
        case let .prepared(.detached(prepared, _)):
            _ = try commitPreparedDetachedDocumentOpen(
                state: state,
                prepared: prepared
            )
        }
    }

}
