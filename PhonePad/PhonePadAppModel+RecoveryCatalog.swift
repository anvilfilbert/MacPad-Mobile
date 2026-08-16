import Foundation
import PhonePadCore

extension PhonePadAppModel {
    func reportRecoveryTransitionError(_ error: Error) {
        recoveryCatalogError = error.localizedDescription
    }

    func refreshRecoveryItems() async {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        await loadRecoveryItems()
    }

    func refreshInitialRecoveryItems() async {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenInProgress,
              !externalOpenCoordinator.blocksRecoveryCatalogMutation else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        await loadRecoveryItems()
    }

    func loadRecoveryItems() async {
        do {
            let storedItems = try await reconcilePendingSaveRecoveryItems(
                recoveryStore: recoveryStore,
                fileAccessConnector: fileAccessConnector
            )
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
    func recoverRecovery(
        documentID: DocumentID,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !state.tabs.contains(where: { tab in
            tab.document.id == documentID
        }) else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .recoveryDocumentAlreadyOpen(documentID)
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { finishRecoveryAction() }

        do {
            try validateCommittedDocument(committedDocument)
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            guard let summary = recoveryItems.first(where: {
                $0.documentID == documentID
            }) else {
                throw PhonePadRecoveryActionError.recoveryItemMissing
            }
            guard summary.status.allowsRecovery else {
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
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !state.tabs.contains(where: { tab in
            tab.document.id == documentID
        }) else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .recoveryDocumentAlreadyOpen(documentID)
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { finishRecoveryAction() }

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
                fileSaveNotice = "Preserved work was discarded. Protected cleanup remains and MacPad Mobile will retry it on next recovery access."
            }
            return true
        } catch {
            recoveryCatalogError = error.localizedDescription
            return false
        }
    }

}
