import Foundation
import PhonePadCore

extension PhonePadExternalOpenCoordinator {
    func prepareAndResolveExternalOpen(
        request: QueuedExternalOpenRequest
    ) async throws -> Bool {
        var authoritativeActiveOpenMatch: AuthoritativeActiveOpenMatch = .none
        var preliminaryCleanupToken = request.importedCopyCleanupTokens.first
        let activeLocatorMatch: ActiveFileOpenLocatorMatch
        do {
            activeLocatorMatch = try await fileAccessConnector
                .matchActiveOpenLocators(
                    selectedURL: request.request.url,
                    claims: activeExternalOpenLocatorClaims()
                )
        } catch {
            _ = try await captureImportedCopyCleanupForPreliminaryOpen(
                request: request,
                documentID: request.documentID
            )
            throw error
        }
        switch activeLocatorMatch {
        case .none:
            break
        case let .missingItem(documentID):
            let capturedCleanupToken = try await
                captureImportedCopyCleanupForPreliminaryOpen(
                    request: request,
                    documentID: request.documentID
                )
            preliminaryCleanupToken = capturedCleanupToken
                ?? preliminaryCleanupToken
            let nodePresence = try await fileAccessConnector
                .selectedFileNodePresence(at: request.request.url)
            if preliminaryCleanupToken == nil,
               nodePresence == .missing {
                return try await activateMatchedExternalOpen(
                    documentID: documentID,
                    tokens: request.importedCopyCleanupTokens,
                    requestID: request.id
                )
            }
            authoritativeActiveOpenMatch = try classifyAuthoritativeActiveOpenMatch(
                documentIDs: [documentID]
            )
        case let .requiresAuthoritativeRead(documentIDs):
            authoritativeActiveOpenMatch = try classifyAuthoritativeActiveOpenMatch(
                documentIDs: documentIDs
            )
        case let .ambiguous(documentIDs):
            _ = try await captureImportedCopyCleanupForPreliminaryOpen(
                request: request,
                documentID: request.documentID
            )
            throw PhonePadExternalOpenActionError
                .activeLocatorCollisionAmbiguous(documentIDs)
        }

        var preparation = try await readAndPrepareExternalOpen(
            request: request.request,
            requestID: request.id,
            documentID: request.documentID,
            tabID: request.tabID,
            capturedImportedCopyCleanupToken:
                preliminaryCleanupToken
        )
        if case .none = authoritativeActiveOpenMatch {
            do {
                authoritativeActiveOpenMatch = try
                    classifyAuthoritativeDurableDetachedIdentityMatch(
                        candidate: preparation.candidate
                    )
            } catch {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: request.id
                )
                throw error
            }
        }
        switch authoritativeActiveOpenMatch {
        case .none:
            break
        case let .ephemeral(authoritativeDocumentIDs):
            switch authoritativeEphemeralOpenMatch(
                candidate: preparation.candidate,
                documentIDs: authoritativeDocumentIDs
            ) {
            case .none:
                invalidateExternalOpenEphemeralClaims(
                    documentIDs: authoritativeDocumentIDs,
                    locatorURL: preparation.candidate.locatorURL
                )
            case let .item(documentID):
                if case let .activateExisting(activatedState, _, _, _, _) =
                    preparation,
                   activatedState.activeTab.document.id != documentID {
                    await retainExternalOpenPreparationForRetry(
                        preparation,
                        requestID: request.id
                    )
                    let ambiguousDocumentIDs = Set([
                        documentID,
                        activatedState.activeTab.document.id,
                    ]).sorted {
                        $0.rawValue.uuidString < $1.rawValue.uuidString
                    }
                    throw PhonePadExternalOpenActionError
                        .activeLocatorCollisionAmbiguous(
                            ambiguousDocumentIDs
                        )
                }
                await stopProvisionalPresenter(preparation: preparation)
                let cleanupTokens = uniqueImportedCopyCleanupTokens(
                    request.importedCopyCleanupTokens
                        + [preliminaryCleanupToken]
                            .compactMap { $0 }
                        + [preparation.importedCopyCleanupToken]
                            .compactMap { $0 }
                )
                try await fileAccessConnector.reassignImportedCopyCleanup(
                    tokens: cleanupTokens,
                    documentID: documentID
                )
                return try await activateMatchedExternalOpen(
                    documentID: documentID,
                    tokens: cleanupTokens,
                    requestID: request.id
                )
            case let .ambiguous(documentIDs):
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: request.id
                )
                throw PhonePadExternalOpenActionError
                    .activeLocatorCollisionAmbiguous(documentIDs)
            }
        case let .durable(documentID):
            do {
                preparation = try reconcileAuthoritativeDurableExternalOpen(
                    preparation: preparation,
                    documentID: documentID
                )
            } catch {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: request.id
                )
                throw error
            }
        }
        let payload: PreparedExternalOpenPayload
        switch preparation {
        case let .activateExisting(
            activatedState,
            provisionalDocumentID,
            candidate,
            cleanupToken,
            detachmentReason
        ):
            let cleanupDocumentID = activatedState.activeTab.document.id
            let cleanupTokens = uniqueImportedCopyCleanupTokens(
                request.importedCopyCleanupTokens
                    + [cleanupToken].compactMap { $0 }
            )
            try await fileAccessConnector.reassignImportedCopyCleanup(
                tokens: cleanupTokens,
                documentID: cleanupDocumentID
            )
            try await activateExistingExternalOpen(
                state: activatedState,
                provisionalDocumentID: provisionalDocumentID
            )
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: cleanupDocumentID,
                candidate: candidate
            )
            retainImportedCopyCleanup(
                documentID: cleanupDocumentID,
                tokens: cleanupTokens
            )
            completeExternalOpenRequest(requestID: request.id)
            _ = await retryExternalOpenCleanupIfNeeded()
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: detachmentReason
            )
            return true
        case let .prepared(preparedPayload):
            payload = preparedPayload
        }

        do {
            let claims = try await recoveryStore.recoveryFileCollisionClaims(
                excludingDocumentID: request.documentID
            )
            let collision = try await fileAccessConnector
                .matchRecoveryFileClaims(
                    candidate: payload.candidate,
                    claims: claims
                )
            switch collision {
            case .none:
                let result = try await commitExternalOpen(
                    payload: payload,
                    request: request
                )
                return result == .complete
            case let .item(match):
                guard let envelope = try await recoveryStore.load(
                    documentID: match.documentID
                ) else {
                    throw PhonePadExternalOpenActionError
                        .recoveryItemMissing(match.documentID)
                }
                let cleanupTokens = uniqueImportedCopyCleanupTokens(
                    request.importedCopyCleanupTokens
                        + [payload.importedCopyCleanupToken]
                            .compactMap { $0 }
                )
                try await fileAccessConnector.reassignImportedCopyCleanup(
                    tokens: cleanupTokens,
                    documentID: match.documentID
                )
                await stopProvisionalPresenter(payload: payload)
                if match.kinds == [.pendingSaveAsDestination],
                   state.tabs.contains(where: { tab in
                       tab.document.id == match.documentID
                   }) {
                    return try await activateMatchedExternalOpen(
                        documentID: match.documentID,
                        tokens: cleanupTokens,
                        requestID: request.id
                    )
                }
                pendingExternalOpenDecision = PendingExternalOpenDecision(
                    request: request,
                    recoveryMatch: match,
                    importedCopyCleanupTokens: cleanupTokens
                )
                pendingExternalOpenRecoveryPrompt = PendingExternalOpenRecoveryPrompt(
                    recoveryDocumentID: match.documentID,
                    title: envelope.title
                )
                externalOpenError = nil
                return true
            case let .ambiguous(documentIDs):
                throw PhonePadExternalOpenActionError
                    .recoveryCollisionAmbiguous(documentIDs)
            }
        } catch {
            await retainExternalOpenPreparationForRetry(
                .prepared(payload),
                requestID: request.id
            )
            throw error
        }
    }

    func captureImportedCopyCleanupForPreliminaryOpen(
        request: QueuedExternalOpenRequest,
        documentID: DocumentID
    ) async throws -> ImportedCopyCleanupToken? {
        guard request.request.accessIntent == .copyRequired else {
            return nil
        }
        if let capturedToken = request.importedCopyCleanupTokens.first {
            return capturedToken
        }
        let token = try await fileAccessConnector.captureImportedCopyCleanup(
            at: request.request.url,
            documentID: documentID
        )
        retainImportedCopyCleanupTokenForRetry(
            token,
            requestID: request.id
        )
        return token
    }

    func activateMatchedExternalOpen(
        documentID: DocumentID,
        tokens: [ImportedCopyCleanupToken],
        requestID: UUID
    ) async throws -> Bool {
        guard let tab = state.tabs.first(where: { tab in
            tab.document.id == documentID
        }) else {
            throw PhonePadStateError.documentMissing(documentID)
        }
        state = try PhonePadCore.selectTab(
            state: state,
            tabID: tab.id
        )
        retainImportedCopyCleanup(
            documentID: documentID,
            tokens: uniqueImportedCopyCleanupTokens(tokens)
        )
        completeExternalOpenRequest(requestID: requestID)
        _ = await retryExternalOpenCleanupIfNeeded()
        presentActiveFileConflictIfNeeded()
        return true
    }

    func classifyAuthoritativeActiveOpenMatch(
        documentIDs: [DocumentID]
    ) throws -> AuthoritativeActiveOpenMatch {
        let orderedDocumentIDs = Array(Set(documentIDs)).sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        guard !orderedDocumentIDs.isEmpty else {
            return .none
        }
        let durableDocumentIDs = try orderedDocumentIDs.filter { documentID in
            guard let document = state.tabs.first(where: { tab in
                tab.document.id == documentID
            })?.document else {
                throw PhonePadStateError.documentMissing(documentID)
            }
            return document.fileBinding != nil
                || document.recoveryFileReference != nil
        }
        guard !durableDocumentIDs.isEmpty else {
            return .ephemeral(orderedDocumentIDs)
        }
        guard orderedDocumentIDs.count == 1,
              durableDocumentIDs.count == 1,
              let documentID = durableDocumentIDs.first else {
            throw PhonePadExternalOpenActionError
                .activeLocatorCollisionAmbiguous(orderedDocumentIDs)
        }
        return .durable(documentID)
    }

    func classifyAuthoritativeDurableDetachedIdentityMatch(
        candidate: FileOpenCandidate
    ) throws -> AuthoritativeActiveOpenMatch {
        guard let candidateIdentity = candidate.identity else {
            return .none
        }
        let documentIDs = state.tabs.compactMap { tab -> DocumentID? in
            guard tab.document.fileBinding == nil,
                  tab.document.recoveryFileReference?.identity
                    == candidateIdentity else {
                return nil
            }
            return tab.document.id
        }
        return try classifyAuthoritativeActiveOpenMatch(
            documentIDs: documentIDs
        )
    }

    func reconcileAuthoritativeDurableExternalOpen(
        preparation: ExternalOpenPreparation,
        documentID: DocumentID
    ) throws -> ExternalOpenPreparation {
        guard let tab = state.tabs.first(where: { tab in
            tab.document.id == documentID
        }) else {
            throw PhonePadStateError.documentMissing(documentID)
        }
        switch preparation {
        case let .activateExisting(
            activatedState,
            _,
            candidate,
            _,
            _
        ):
            guard activatedState.activeTab.document.id == documentID else {
                let documentIDs = Set([
                    documentID,
                    activatedState.activeTab.document.id,
                ]).sorted {
                    $0.rawValue.uuidString < $1.rawValue.uuidString
                }
                throw PhonePadExternalOpenActionError
                    .activeLocatorCollisionAmbiguous(documentIDs)
            }
            if tab.document.fileBinding == nil,
               let reference = tab.document.recoveryFileReference {
                try requireMatchingDurableDetachedSource(
                    reference: reference,
                    candidate: candidate,
                    documentID: documentID
                )
            }
            return preparation
        case let .prepared(payload):
            let activatedState: PhonePadState
            if tab.document.fileBinding != nil {
                switch payload {
                case let .bound(_, snapshot):
                    let reconciledState = try reconcileBoundDocument(
                        state: state,
                        documentID: documentID,
                        observation: ObservedBoundFile(
                            binding: snapshot.openedFile.binding,
                            providerConflictVersions:
                                snapshot.providerConflictVersions
                        )
                    )
                    activatedState = try PhonePadCore.selectTab(
                        state: reconciledState,
                        tabID: tab.id
                    )
                case .detached:
                    activatedState = try
                        activateAuthoritativelyMatchedBoundFileOpen(
                            state: state,
                            documentID: documentID,
                            candidate: payload.candidate
                        )
                }
            } else if let reference = tab.document.recoveryFileReference {
                try requireMatchingDurableDetachedSource(
                    reference: reference,
                    candidate: payload.candidate,
                    documentID: documentID
                )
                activatedState = try PhonePadCore.selectTab(
                    state: state,
                    tabID: tab.id
                )
            } else {
                throw RecoveredFileOpenError.fileReferenceMissing(documentID)
            }
            return .activateExisting(
                state: activatedState,
                provisionalDocumentID: payload.provisionalDocumentID,
                candidate: payload.candidate,
                importedCopyCleanupToken:
                    payload.importedCopyCleanupToken,
                detachmentReason: payload.detachmentReason
            )
        }
    }

    func requireMatchingDurableDetachedSource(
        reference: RecoveryFileReference,
        candidate: FileOpenCandidate,
        documentID: DocumentID
    ) throws {
        switch (reference.identity, candidate.identity) {
        case let (.some(referenceIdentity), .some(candidateIdentity))
        where referenceIdentity == candidateIdentity:
            break
        case (.none, .none):
            break
        case (.some, .some), (.some, .none), (.none, .some):
            throw PhonePadExternalOpenActionError
                .durableDetachedSourceIdentityChanged(documentID)
        }
        switch candidate.providerConflictVersions {
        case .none:
            break
        case let .unresolved(count):
            throw PhonePadExternalOpenActionError
                .durableDetachedSourceHasUnresolvedProviderVersions(
                    documentID: documentID,
                    count: count
                )
        }
        guard reference.cleanDigest == candidate.digest else {
            throw PhonePadExternalOpenActionError
                .durableDetachedSourceContentChanged(documentID)
        }
    }

    func activeExternalOpenLocatorClaims()
        -> [ActiveFileOpenLocatorClaim] {
        let ephemeralDocumentIDs = Set(
            state.tabs.compactMap { tab -> DocumentID? in
                guard tab.document.fileBinding == nil,
                      tab.document.recoveryFileReference == nil else {
                    return nil
                }
                return tab.document.id
            }
        )
        externalOpenEphemeralClaims = externalOpenEphemeralClaims
            .filter { documentID, _ in
                ephemeralDocumentIDs.contains(documentID)
            }

        return state.tabs.flatMap { tab -> [ActiveFileOpenLocatorClaim] in
            if let binding = tab.document.fileBinding {
                return [
                    .bound(
                        documentID: tab.document.id,
                        binding: binding
                    ),
                ]
            }
            if let reference = tab.document.recoveryFileReference {
                return [
                    .detached(
                        documentID: tab.document.id,
                        reference: FileCollisionReference(
                            bookmark: reference.bookmark,
                            identity: reference.identity
                        )
                    ),
                ]
            }
            return externalOpenEphemeralClaims[tab.document.id, default: []]
                .sorted { lhs, rhs in
                    lhs.candidate.locatorURL.absoluteString
                        < rhs.candidate.locatorURL.absoluteString
                }
                .map { claim in
                    .ephemeral(
                        documentID: tab.document.id,
                        locatorURL: claim.candidate.locatorURL
                    )
                }
        }
    }

    func retainExternalOpenEphemeralClaimIfNeeded(
        documentID: DocumentID,
        candidate: FileOpenCandidate
    ) {
        guard let document = state.tabs.first(where: { tab in
            tab.document.id == documentID
        })?.document,
        document.fileBinding == nil,
        document.recoveryFileReference == nil else {
            removingEphemeralClaims(documentID: documentID)
            return
        }
        retainingEphemeralClaim(
            documentID: documentID,
            candidate: candidate
        )
    }

    func authoritativeEphemeralOpenMatch(
        candidate: FileOpenCandidate,
        documentIDs: [DocumentID]
    ) -> AuthoritativeEphemeralOpenMatch {
        authoritativeEphemeralMatch(
            candidate: candidate,
            documentIDs: documentIDs
        )
    }

    func invalidateExternalOpenEphemeralClaims(
        documentIDs: [DocumentID],
        locatorURL: URL
    ) {
        invalidatingEphemeralClaims(
            documentIDs: documentIDs,
            locatorURL: locatorURL
        )
    }

    func readAndPrepareExternalOpen(
        request: PhonePadExternalOpenRequest,
        requestID: UUID,
        documentID: DocumentID,
        tabID: TabID,
        capturedImportedCopyCleanupToken:
            ImportedCopyCleanupToken?
    ) async throws -> ExternalOpenPreparation {
        let outcome: OpenTextFileOutcome
        if let capturedImportedCopyCleanupToken {
            outcome = try await fileAccessConnector.openTextFile(
                at: request.url,
                documentID: documentID,
                capturedImportedCopyCleanupToken:
                    capturedImportedCopyCleanupToken
            )
        } else {
            outcome = try await fileAccessConnector.openTextFile(
                at: request.url,
                documentID: documentID,
                accessIntent: request.accessIntent
            )
        }
        switch outcome {
        case let .bound(snapshot):
            let preparation = prepareBoundDocumentOpen(
                state: state,
                documentID: documentID,
                tabID: tabID,
                text: snapshot.openedFile.text,
                observation: ObservedBoundFile(
                    binding: snapshot.openedFile.binding,
                    providerConflictVersions: snapshot.providerConflictVersions
                )
            )
            switch preparation {
            case let .activateExisting(activatedState):
                return .activateExisting(
                    state: activatedState,
                    provisionalDocumentID: documentID,
                    candidate: FileOpenCandidate(
                        locatorURL: snapshot.openedFile.binding.locatorURL,
                        identity: snapshot.openedFile.binding.identity,
                        digest: snapshot.openedFile.binding.digest,
                        providerConflictVersions: snapshot.providerConflictVersions
                    ),
                    importedCopyCleanupToken: nil,
                    detachmentReason: nil
                )
            case let .prepared(prepared):
                return .prepared(
                    .bound(prepared: prepared, snapshot: snapshot)
                )
            }
        case let .detached(openedFile):
            let preparation: DetachedDocumentOpenPreparation
            do {
                preparation = try prepareDetachedDocumentOpen(
                    state: state,
                    documentID: documentID,
                    tabID: tabID,
                    snapshot: openedFile.snapshot,
                    editedAt: Date()
                )
            } catch {
                retainImportedCopyCleanupTokenForRetry(
                    openedFile.importedCopyCleanupToken,
                    requestID: requestID
                )
                throw error
            }
            switch preparation {
            case let .activateExisting(activatedState):
                return .activateExisting(
                    state: activatedState,
                    provisionalDocumentID: documentID,
                    candidate: openedFile.snapshot.candidate,
                    importedCopyCleanupToken: openedFile
                        .importedCopyCleanupToken,
                    detachmentReason: openedFile.reason
                )
            case let .prepared(prepared):
                return .prepared(
                    .detached(
                        prepared: prepared,
                        openedFile: openedFile
                    )
                )
            }
        case let .rejected(rejection):
            guard let cleanupToken = rejection.importedCopyCleanupToken else {
                completeRejectedExternalOpenRequest(requestID: requestID)
                throw rejection.error
            }
            let cleanupOutcome = await fileAccessConnector
                .cleanupImportedCopy(token: cleanupToken)
            switch cleanupOutcome {
            case .removed, .alreadyAbsent:
                completeRejectedExternalOpenRequest(requestID: requestID)
                throw rejection.error
            case let .residual(failure):
                retainImportedCopyCleanup(
                    documentID: nil,
                    tokens: [cleanupToken]
                )
                let actionError = PhonePadExternalOpenActionError
                    .rejectedFileCleanupFailed(
                        rejection: rejection.error,
                        cleanup: failure
                    )
                externalOpenGeneralNotice = actionError.localizedDescription
                completeRejectedExternalOpenRequest(requestID: requestID)
                throw actionError
            }
        }
    }

    func completeRejectedExternalOpenRequest(requestID: UUID) {
        if pendingExternalOpenDecision?.request.id == requestID {
            pendingExternalOpenDecision = nil
            pendingExternalOpenRecoveryPrompt = nil
        }
        completeExternalOpenRequest(requestID: requestID)
        terminalExternalOpenErrorPendingDismissal = true
    }

    func activateExistingExternalOpen(
        state activatedState: PhonePadState,
        provisionalDocumentID: DocumentID
    ) async throws {
        let retainedDocument = activatedState.activeTab.document
        if let retainedBinding = retainedDocument.fileBinding {
            do {
                try await fileAccessConnector.startPresenting(
                    documentID: retainedDocument.id,
                    binding: retainedBinding
                )
            } catch {
                await fileAccessConnector.stopPresenting(
                    documentID: provisionalDocumentID
                )
                throw error
            }
        }
        await fileAccessConnector.stopPresenting(
            documentID: provisionalDocumentID
        )
        state = activatedState
        markPresenterRefreshPending()
        presentActiveFileConflictIfNeeded()
    }

    func commitExternalOpen(
        payload: PreparedExternalOpenPayload,
        request: QueuedExternalOpenRequest
    ) async throws -> ExternalOpenCommitResult {
        switch payload {
        case let .bound(prepared, _):
            retainImportedCopyCleanup(
                documentID: nil,
                tokens: request.importedCopyCleanupTokens
            )
            state = try commitPreparedBoundDocumentOpen(
                state: state,
                prepared: prepared
            )
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: state.activeTab.document.id,
                candidate: prepared.candidate
            )
            presentActiveFileConflictIfNeeded()
            completeExternalOpenRequest(requestID: request.id)
            _ = await retryExternalOpenCleanupIfNeeded()
            return .complete
        case let .detached(prepared, openedFile):
            let transition = try commitPreparedDetachedDocumentOpen(
                state: state,
                prepared: prepared
            )
            state = transition.state
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: openedFile.reason
            )
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: transition.envelope.documentID,
                candidate: openedFile.snapshot.candidate
            )
            retainImportedCopyCleanup(
                documentID: transition.envelope.documentID,
                tokens: uniqueImportedCopyCleanupTokens(
                    request.importedCopyCleanupTokens
                        + [openedFile.importedCopyCleanupToken]
                            .compactMap { $0 }
                )
            )
            let protected = await persistExternalOpenTransition(transition)
            completeExternalOpenRequest(requestID: request.id)
            guard protected else {
                recordExternalOpenRecoveryProtectionFailure(
                    documentID: transition.envelope.documentID,
                    message: recoveryError
                )
                return .recoveryProtectionFailed
            }
            _ = await retryExternalOpenCleanupIfNeeded()
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: openedFile.reason
            )
            return .complete
        }
    }

    func retainExternalOpenDetachmentNoticeIfNeeded(
        reason: FileOpenDetachmentReason?
    ) {
        guard let reason,
              state.activeTab.document.fileBinding == nil,
              state.activeTab.document.isUnsaved else {
            return
        }
        externalOpenDocumentNotice = ExternalOpenDocumentNotice(
            documentID: state.activeTab.document.id,
            message: externalOpenDetachmentNotice(reason: reason)
        )
    }

    func appendExternalOpenNotice(_ notice: String) {
        guard externalOpenGeneralNotice != notice,
              externalOpenGeneralNotice?.contains(notice) != true else {
            return
        }
        if let generalNotice =
            externalOpenGeneralNotice {
            externalOpenGeneralNotice = generalNotice
                + " " + notice
        } else {
            externalOpenGeneralNotice = notice
        }
    }

    func stopProvisionalPresenter(
        payload: PreparedExternalOpenPayload
    ) async {
        guard case let .bound(prepared, _) = payload else {
            return
        }
        await fileAccessConnector.stopPresenting(
            documentID: prepared.documentID
        )
    }

    func stopProvisionalPresenter(
        preparation: ExternalOpenPreparation
    ) async {
        switch preparation {
        case let .activateExisting(_, provisionalDocumentID, _, _, _):
            await fileAccessConnector.stopPresenting(
                documentID: provisionalDocumentID
            )
        case let .prepared(payload):
            await stopProvisionalPresenter(payload: payload)
        }
    }

    func retainExternalOpenPreparationForRetry(
        _ preparation: ExternalOpenPreparation,
        requestID: UUID
    ) async {
        await stopProvisionalPresenter(preparation: preparation)
        retainImportedCopyCleanupTokenForRetry(
            preparation.importedCopyCleanupToken,
            requestID: requestID
        )
    }

    func retainImportedCopyCleanupTokenForRetry(
        _ token: ImportedCopyCleanupToken?,
        requestID: UUID
    ) {
        retainingCleanupTokenForRetry(token, requestID: requestID)
    }

    var canBeginExternalOpenAction: Bool {
        !externalOpenInProgress
            && !externalOpenCleanupInProgress
            && pendingExternalOpenDecision == nil
            && !workspaceActivity.fileConflictPresented
            && workspaceActivity.permitsExclusiveAction
    }

    func requestExternalOpenEditorCommitIfPossible() {
        guard let request = externalOpenQueue.first else {
            return
        }
        guard !externalOpenCleanupPreflightInProgress else {
            return
        }
        guard !importedCopyCleanupPreflightRequired(request: request) else {
            if let failure = externalOpenCleanupPreflightFailures[request.id] {
                externalOpenError = failure.message
            }
            return
        }
        guard presentersShouldBeActive,
              externalOpenCommitRequestID == nil,
              externalOpenError == nil
                || externalOpenError
                    == importedCopyCleanupJournalErrorMessage,
              canBeginExternalOpenAction else {
            return
        }
        externalOpenCommitRequestID = UUID()
    }

    func completeExternalOpenRequest(requestID: UUID) {
        do {
            try completingRequest(requestID: requestID)
        } catch {
            externalOpenError = PhonePadExternalOpenActionError
                .commitRequestMissing
                .localizedDescription
        }
    }

    func finishExternalOpenAction() async {
        if !presentersShouldBeActive {
            await fileAccessConnector.pausePresenters()
            markPresenterRefreshPending()
        }
        externalOpenInProgress = false
        externalOpenCommitRequestID = nil
        await resumePendingActivationWorkAfterExclusiveAction()
    }

    func persistExternalOpenTransition(
        _ transition: RecoveryEditTransition
    ) async -> Bool {
        let completion = await protectRecoveryForExternalOpen(transition)
        guard case .blocked = completion else {
            return await applyRecoveryCheckpointCompletion(completion)
        }
        recoveryError = PhonePadTabTransitionError
            .checkpointMustFinishBeforeTransition
            .localizedDescription
        return false
    }

}
