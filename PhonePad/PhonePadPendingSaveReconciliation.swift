import Foundation
import PhonePadCore

enum PendingSaveDestinationObservation: Equatable, Sendable {
    case missing
    case nonRegular(ExistingFileSystemItemKind)
    case available(
        identity: FileIdentity?,
        digest: FileDigest,
        providerConflictVersions: FileProviderConflictVersions
    )
}

private enum PendingSaveReconciliationDecision: Equatable, Sendable {
    case completeAuthorizedCleanup
    case recoverable
    case unresolved
}

func reconcilePendingSaveRecoveryItems(
    recoveryStore: any RecoveryStoring,
    fileAccessConnector: FileAccessConnector
) async throws -> [RecoveryItemSummary] {
    let summaries = try await recoveryStore.recoveryItems()
    var reconciledItems: [RecoveryItemSummary] = []
    for summary in summaries {
        guard summary.status == .recoverable,
              summary.requiresPendingSaveReconciliation else {
            reconciledItems.append(summary)
            continue
        }
        let envelope: RecoveryEnvelope
        do {
            guard let storedEnvelope = try await recoveryStore.load(
                documentID: summary.documentID
            ) else {
                reconciledItems.append(
                    summary.withStatus(.unavailable)
                )
                continue
            }
            envelope = storedEnvelope
        } catch {
            reconciledItems.append(summary.withStatus(.unavailable))
            continue
        }
        guard let pendingSave = envelope.pendingSave else {
            reconciledItems.append(summary)
            continue
        }
        let observation: PendingSaveDestinationObservation
        do {
            switch pendingSave.destination {
            case .boundFile:
                guard let fileReference = envelope.fileReference else {
                    reconciledItems.append(
                        summary.withStatus(.saveResultUnresolved)
                    )
                    continue
                }
                observation = try await fileAccessConnector
                    .observePendingBoundSaveDestination(
                        fileReference: fileReference
                    )
            case let .saveAs(destination):
                observation = try await fileAccessConnector
                    .observePendingSaveAsDestination(
                        destination: destination
                    )
            }
        } catch {
            reconciledItems.append(summary.withStatus(.unavailable))
            continue
        }

        switch pendingSaveReconciliationDecision(
            envelope: envelope,
            pendingSave: pendingSave,
            observation: observation
        ) {
        case .recoverable:
            reconciledItems.append(summary)
        case .unresolved:
            reconciledItems.append(
                summary.withStatus(.saveResultUnresolved)
            )
        case .completeAuthorizedCleanup:
            _ = try await recoveryStore.completeRecoveryAfterSave(
                documentID: summary.documentID
            )
        }
    }
    return reconciledItems
}

private func pendingSaveReconciliationDecision(
    envelope: RecoveryEnvelope,
    pendingSave: RecoveryPendingSave,
    observation: PendingSaveDestinationObservation
) -> PendingSaveReconciliationDecision {
    switch observation {
    case .missing:
        return .recoverable
    case .nonRegular:
        return .unresolved
    case let .available(identity, digest, providerConflictVersions):
        guard providerConflictVersions == .none else {
            return .unresolved
        }
        if case .boundFile = pendingSave.destination,
           let expectedIdentity = envelope.fileReference?.identity,
           identity != expectedIdentity {
            return .unresolved
        }
        if digest == pendingSave.intendedOutputDigest {
            return .completeAuthorizedCleanup
        }
        if case .boundFile = pendingSave.destination,
           digest == envelope.fileReference?.cleanDigest {
            return .recoverable
        }
        return .unresolved
    }
}

private extension RecoveryItemSummary {
    func withStatus(_ status: RecoveryItemStatus) -> RecoveryItemSummary {
        RecoveryItemSummary(
            documentID: documentID,
            title: title,
            lastEdited: lastEdited,
            status: status,
            requiresPendingSaveReconciliation:
                requiresPendingSaveReconciliation
        )
    }
}
