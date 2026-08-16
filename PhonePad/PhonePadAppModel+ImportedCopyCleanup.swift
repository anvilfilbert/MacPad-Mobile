import Foundation
import PhonePadCore

extension PhonePadExternalOpenCoordinator {
    func retainImportedCopyCleanup(
        documentID: DocumentID?,
        tokens: [ImportedCopyCleanupToken]
    ) {
        retainingCleanup(documentID: documentID, tokens: tokens)
        refreshExternalOpenCleanupAvailability()
    }

    @discardableResult
    func retryExternalOpenCleanupIfNeeded() async -> Bool {
        guard !pendingExternalOpenCleanups.isEmpty else {
            refreshExternalOpenCleanupAvailability()
            return true
        }
        var remainingCleanups: [PendingImportedCopyCleanup] = []
        var failureMessages: [String] = []
        for cleanup in pendingExternalOpenCleanups {
            guard importedCopyCleanupIsRunnable(cleanup) else {
                remainingCleanups.append(cleanup)
                continue
            }
            var remainingTokens: [ImportedCopyCleanupToken] = []
            for token in cleanup.tokens {
                let outcome = await fileAccessConnector.cleanupImportedCopy(
                    token: token
                )
                switch outcome {
                case .removed, .alreadyAbsent:
                    break
                case let .residual(failure):
                    remainingTokens.append(token)
                    failureMessages.append(
                        importedCopyCleanupFailureMessage(failure)
                    )
                }
            }
            if !remainingTokens.isEmpty {
                remainingCleanups.append(
                    PendingImportedCopyCleanup(
                        documentID: cleanup.documentID,
                        tokens: remainingTokens
                    )
                )
            }
        }
        pendingExternalOpenCleanups = remainingCleanups
        refreshExternalOpenCleanupAvailability()
        guard failureMessages.isEmpty else {
            externalOpenGeneralNotice = failureMessages.joined(separator: " ")
            return false
        }
        externalOpenGeneralNotice = remainingCleanups.isEmpty
            ? "Imported File copy cleanup finished."
            : nil
        return true
    }

    @discardableResult
    func reconcileImportedCopyCleanupJournal() async -> Bool {
        do {
            let report = try await fileAccessConnector
                .reconcileImportedCopyCleanupJournal()
            let reportedItems = report.removed
                + report.alreadyAbsent
                + report.awaitingProtection
                + report.residuals.map(\.item)
            removePendingImportedCopyCleanupTokens(
                Set(reportedItems.map(\.token))
            )

            var retainedResiduals: [ImportedCopyCleanupResidual] = []
            for residual in report.residuals {
                if try await orphanedImportedCopyCandidateChange(
                    residual
                ) {
                    try await fileAccessConnector
                        .abandonImportedCopyCleanup(
                            tokens: [residual.item.token]
                        )
                } else {
                    retainedResiduals.append(residual)
                }
            }
            importedCopyCleanupJournalRetryRequired =
                !retainedResiduals.isEmpty
            var residualMessages = retainedResiduals.map { residual in
                retainImportedCopyCleanup(
                    documentID: residual.item.documentID,
                    tokens: [residual.item.token]
                )
                return importedCopyCleanupFailureMessage(residual.failure)
            }
            var awaitingProtectionMessages: [String] = []
            for item in report.awaitingProtection {
                guard try await importedCopyCleanupIsProtected(
                    documentID: item.documentID
                ) else {
                    importedCopyCleanupJournalRetryRequired = true
                    awaitingProtectionMessages.append(
                        "Interrupted imported File cleanup for Document \(item.documentID.rawValue.uuidString) is waiting for protected recovery data. Restore or protect that Document, then retry cleanup."
                    )
                    continue
                }

                let outcome = await fileAccessConnector.cleanupImportedCopy(
                    token: item.token
                )
                switch outcome {
                case .removed, .alreadyAbsent:
                    break
                case let .residual(failure):
                    importedCopyCleanupJournalRetryRequired = true
                    retainImportedCopyCleanup(
                        documentID: item.documentID,
                        tokens: [item.token]
                    )
                    residualMessages.append(
                        importedCopyCleanupFailureMessage(failure)
                    )
                }
            }

            setImportedCopyCleanupJournalError(
                residualMessages.isEmpty
                    ? nil
                    : residualMessages.joined(separator: " ")
            )
            importedCopyCleanupJournalNotice = awaitingProtectionMessages
                .isEmpty
                ? nil
                : awaitingProtectionMessages.joined(separator: " ")
            refreshExternalOpenCleanupAvailability()
            guard residualMessages.isEmpty,
                  awaitingProtectionMessages.isEmpty else {
                return false
            }
            return true
        } catch {
            importedCopyCleanupJournalRetryRequired = true
            importedCopyCleanupJournalNotice = nil
            refreshExternalOpenCleanupAvailability()
            setImportedCopyCleanupJournalError(
                "Interrupted imported File cleanup reconciliation failed. \(error.localizedDescription) Retry Cleanup."
            )
            return false
        }
    }

    func setImportedCopyCleanupJournalError(_ message: String?) {
        if externalOpenError == importedCopyCleanupJournalErrorMessage {
            externalOpenError = nil
        }
        importedCopyCleanupJournalErrorMessage = message
        if let message {
            externalOpenError = message
        }
    }

    func recordExternalOpenRecoveryProtectionFailure(
        documentID: DocumentID,
        message: String?
    ) {
        guard let message else {
            externalOpenRecoveryProtectionFailure = nil
            externalOpenError = nil
            return
        }
        externalOpenRecoveryProtectionFailure =
            ExternalOpenRecoveryProtectionFailure(
                documentID: documentID,
                message: message
            )
        externalOpenError = message
    }

    func clearExternalOpenRecoveryProtectionFailure(
        documentID: DocumentID
    ) {
        guard let failure = externalOpenRecoveryProtectionFailure,
              failure.documentID == documentID else {
            return
        }
        if externalOpenError == failure.message {
            externalOpenError = nil
        }
        externalOpenRecoveryProtectionFailure = nil
    }

    func removePendingImportedCopyCleanupTokens(
        _ tokens: Set<ImportedCopyCleanupToken>
    ) {
        guard !tokens.isEmpty else {
            return
        }
        pendingExternalOpenCleanups = pendingExternalOpenCleanups.compactMap {
            cleanup in
            let remainingTokens = cleanup.tokens.filter { token in
                !tokens.contains(token)
            }
            guard !remainingTokens.isEmpty else {
                return nil
            }
            return PendingImportedCopyCleanup(
                documentID: cleanup.documentID,
                tokens: remainingTokens
            )
        }
    }

    func importedCopyCleanupIsProtected(
        documentID: DocumentID
    ) async throws -> Bool {
        if let document = state.tabs.first(where: { tab in
            tab.document.id == documentID
        })?.document {
            switch document.recoveryState {
            case .clean, .protectedUnsaved:
                return true
            case .checkpointPending, .recoveryUnavailable:
                break
            }
        }
        return try await recoveryStore.load(documentID: documentID) != nil
    }

    func orphanedImportedCopyCandidateChange(
        _ residual: ImportedCopyCleanupResidual
    ) async throws -> Bool {
        guard residual.failure == .itemChanged else {
            return false
        }
        let isProtected = try await importedCopyCleanupIsProtected(
            documentID: residual.item.documentID
        )
        return !isProtected
    }

    var deferredImportedCopyCleanupDocumentID: DocumentID? {
        pendingExternalOpenCleanups.first(where: { cleanup in
            cleanup.documentID != nil
                && !importedCopyCleanupIsRunnable(cleanup)
        })?.documentID
    }

    func importedCopyCleanupIsRunnable(
        _ cleanup: PendingImportedCopyCleanup
    ) -> Bool {
        guard let documentID = cleanup.documentID,
              let document = state.tabs.first(where: { tab in
                  tab.document.id == documentID
              })?.document else {
            return true
        }
        switch document.recoveryState {
        case .clean, .protectedUnsaved:
            return true
        case .checkpointPending, .recoveryUnavailable:
            return false
        }
    }

    func refreshExternalOpenCleanupAvailability() {
        externalOpenCleanupRequired = importedCopyCleanupJournalRetryRequired
            || pendingExternalOpenCleanups.contains(
                where: importedCopyCleanupIsRunnable
            )
    }

}
