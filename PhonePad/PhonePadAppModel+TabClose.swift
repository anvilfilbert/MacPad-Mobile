import Foundation
import PhonePadCore

extension PhonePadAppModel {
    func beginTabCloseRequest() -> Bool {
        guard prepareTabTransition() else {
            tabCloseError = tabTransitionError
            return false
        }
        activeDocumentTransitionInProgress = true
        tabTransitionInProgress = true
        tabCloseError = nil
        return true
    }

    func beginPendingTabCloseSession(
        requirements: [TabCloseRequirement],
        retainedTabID: TabID?,
        committedDocument: CommittedEditorDocument
    ) async throws -> Bool {
        guard !requirements.isEmpty else {
            tabCloseError = nil
            return true
        }

        let originalActiveTabID = state.activeTabID
        do {
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
        } catch {
            let refreshedRequirements = try requirements.map { requirement in
                try prepareTabClose(
                    state: state,
                    tabID: tabCloseRequirementTab(requirement).id
                )
            }
            guard let activeRequirement = refreshedRequirements.first(where: {
                tabCloseRequirementTab($0).id == originalActiveTabID
            }), case let .unsaved(preparedClose) = activeRequirement else {
                throw error
            }
            pendingTabCloseSession = PendingTabCloseSession(
                requirements: refreshedRequirements,
                originalActiveTabID: originalActiveTabID,
                retainedTabID: retainedTabID,
                phase: .processing
            )
            publishPendingTabClosePrompt(preparedClose: preparedClose)
            tabCloseError = nil
            return true
        }

        let refreshedRequirements = try requirements.map { requirement in
            try prepareTabClose(
                state: state,
                tabID: tabCloseRequirementTab(requirement).id
            )
        }
        pendingTabCloseSession = PendingTabCloseSession(
            requirements: refreshedRequirements,
            originalActiveTabID: originalActiveTabID,
            retainedTabID: retainedTabID,
            phase: .processing
        )
        try await advancePendingTabCloseSession()
        tabCloseError = nil
        return true
    }

    func beginPendingTabCloseDecisionResolution() -> Bool {
        guard pendingTabCloseResolutionCanBegin() else {
            return false
        }
        guard !tabCloseCleanupRequired else {
            tabCloseError = PhonePadTabCloseActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard pendingTabClosePrompt != nil else {
            tabCloseError = PhonePadTabCloseActionError
                .noPendingDecision
                .localizedDescription
            return false
        }
        startPendingTabCloseResolution()
        return true
    }

    func beginPendingTabCloseCleanupResolution() -> Bool {
        guard pendingTabCloseResolutionCanBegin() else {
            return false
        }
        guard tabCloseCleanupRequired,
              pendingTabCloseCleanup != nil else {
            tabCloseError = PhonePadTabCloseActionError
                .cleanupNotRequired
                .localizedDescription
            return false
        }
        startPendingTabCloseResolution()
        return true
    }

    func pendingTabCloseResolutionCanBegin() -> Bool {
        guard pendingTabCloseSession != nil,
              !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil else {
            tabCloseError = PhonePadTabCloseActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        return true
    }

    func startPendingTabCloseResolution() {
        activeDocumentTransitionInProgress = true
        tabTransitionInProgress = true
        tabCloseError = nil
    }

    func advancePendingTabCloseSession() async throws {
        while let requirement = pendingTabCloseSession?.requirements.first {
            switch requirement {
            case let .clean(preparedClose):
                let closedState = try closePreparedCleanTab(
                    state: state,
                    preparedClose: preparedClose,
                    replacementDocumentID: DocumentID(rawValue: UUID()),
                    replacementTabID: TabID(rawValue: UUID())
                )
                await fileAccessConnector.stopPresenting(
                    documentID: preparedClose.tab.document.id
                )
                state = closedState
                pendingTabCloseSession?.requirements.removeFirst()
                pendingTabCloseSession?.phase = .processing
            case let .unsaved(preparedClose):
                publishPendingTabClosePrompt(preparedClose: preparedClose)
                return
            }
        }

        try restoreStableTabSelectionForPendingClose()
        pendingTabCloseSession = nil
        pendingTabClosePrompt = nil
        pendingTabCloseCleanup = nil
        tabCloseCleanupRequired = false
        tabCloseError = nil
        presentActiveFileConflictIfNeeded()
    }

    func applyDiscardedTabClose(
        _ result: DiscardedTabCloseResult,
        requirementIndex: Int
    ) async throws {
        await fileAccessConnector.stopPresenting(
            documentID: result.closedDocumentID
        )
        state = result.state
        clearCheckpointState(closedDocumentID: result.closedDocumentID)
        pendingTabCloseSession?.requirements.remove(at: requirementIndex)
        pendingTabCloseSession?.phase = .processing
        pendingTabClosePrompt = nil
        pendingTabCloseCleanup = nil
        tabCloseCleanupRequired = false
        tabCloseError = nil
        switch result.notice {
        case .none:
            fileSaveNotice = nil
        case .residualRecoveryCleanupPending:
            fileSaveNotice = "Protected edits were discarded. Protected cleanup remains and MacPad Mobile will retry it on next recovery access."
        }
        try await advancePendingTabCloseSession()
        _ = await retryExternalOpenCleanupIfNeeded()
    }

    func resumePendingTabCloseAfterSuccessfulSave(
        documentID: DocumentID
    ) async -> Bool {
        guard let requirementIndex = pendingTabCloseRequirementIndex(
            documentID: documentID
        ) else {
            return true
        }
        let ownsTabTransition = !fileSaveInProgress
        if ownsTabTransition {
            guard !tabTransitionInProgress else {
                tabCloseError = PhonePadTabCloseActionError
                    .actionAlreadyInProgress
                    .localizedDescription
                return false
            }
            activeDocumentTransitionInProgress = true
            tabTransitionInProgress = true
        }
        defer {
            if ownsTabTransition {
                finishTabTransition()
            }
        }

        do {
            guard var session = pendingTabCloseSession,
                  session.requirements.indices.contains(requirementIndex) else {
                throw PhonePadTabCloseActionError.noPendingDecision
            }
            let pendingTabID = tabCloseRequirementTab(
                session.requirements[requirementIndex]
            ).id
            let requirement = try prepareTabClose(
                state: state,
                tabID: pendingTabID
            )
            guard case .clean = requirement else {
                throw PhonePadTabCloseActionError.pendingTabRemainsUnsaved
            }
            session.requirements[requirementIndex] = requirement
            session.phase = .processing
            pendingTabCloseSession = session
            pendingTabClosePrompt = nil
            try await advancePendingTabCloseSession()
            tabCloseError = nil
            return true
        } catch {
            tabCloseError = error.localizedDescription
            return false
        }
    }

    func publishPendingTabClosePrompt(
        preparedClose: PreparedUnsavedTabClose
    ) {
        let tab = preparedClose.tab
        pendingTabClosePrompt = PendingTabClosePrompt(
            tabID: tab.id,
            documentID: tab.document.id,
            title: tab.document.title
        )
        pendingTabCloseSession?.phase = .decision(tab.id)
    }

    func setPendingTabClosePhase(_ phase: PendingTabClosePhase) {
        pendingTabCloseSession?.phase = phase
    }

    func pendingTabCloseRequirementIndex(
        tabID: TabID
    ) -> Int? {
        pendingTabCloseSession?.requirements.firstIndex(where: {
            tabCloseRequirementTab($0).id == tabID
        })
    }

    func pendingTabCloseRequirementIndex(
        documentID: DocumentID
    ) -> Int? {
        pendingTabCloseSession?.requirements.firstIndex(where: {
            tabCloseRequirementTab($0).document.id == documentID
        })
    }

    func pendingUnsavedTabClose(
        at requirementIndex: Int
    ) -> PreparedUnsavedTabClose? {
        guard let session = pendingTabCloseSession,
              session.requirements.indices.contains(requirementIndex),
              case let .unsaved(preparedClose) = session.requirements[
                  requirementIndex
              ] else {
            return nil
        }
        return preparedClose
    }

    func refreshPendingUnsavedTabClose(
        tabID: TabID
    ) throws -> PreparedUnsavedTabClose {
        guard var session = pendingTabCloseSession,
              let requirementIndex = session.requirements.firstIndex(where: {
                  tabCloseRequirementTab($0).id == tabID
              }) else {
            throw PhonePadTabCloseActionError.noPendingDecision
        }
        let requirement = try prepareTabClose(
            state: state,
            tabID: tabID
        )
        guard case let .unsaved(preparedClose) = requirement else {
            throw PhonePadTabCloseActionError.noPendingDecision
        }
        session.requirements[requirementIndex] = requirement
        pendingTabCloseSession = session
        return preparedClose
    }

    func tabCloseRequirementTab(
        _ requirement: TabCloseRequirement
    ) -> PhonePadTab {
        switch requirement {
        case let .clean(preparedClose):
            preparedClose.tab
        case let .unsaved(preparedClose):
            preparedClose.tab
        }
    }

    func restoreStableTabSelectionForPendingClose() throws {
        guard let session = pendingTabCloseSession else {
            return
        }
        let preferredTabID = session.retainedTabID
            ?? session.originalActiveTabID
        guard state.tabs.contains(where: { $0.id == preferredTabID }) else {
            return
        }
        state = try PhonePadCore.selectTab(
            state: state,
            tabID: preferredTabID
        )
    }

    func cancelPendingTabCloseSessionAfterFailure() {
        do {
            try restoreStableTabSelectionForPendingClose()
        } catch {
            tabCloseError = error.localizedDescription
        }
        pendingTabCloseSession = nil
        pendingTabClosePrompt = nil
        pendingTabCloseCleanup = nil
        tabCloseCleanupRequired = false
    }


}
