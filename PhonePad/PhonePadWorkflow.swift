import Foundation
import PhonePadCore

public enum PhonePadWorkflowError: Error, LocalizedError, Sendable {
    case recoveryCheckpointNotExcludedFromBackup(DocumentID)
    case recoveryCheckpointNotCompletelyProtected(DocumentID)

    public var errorDescription: String? {
        switch self {
        case let .recoveryCheckpointNotExcludedFromBackup(documentID):
            "Recovery checkpoint for document \(documentID.rawValue) is not excluded from backup. Editing cannot continue until recovery succeeds."
        case let .recoveryCheckpointNotCompletelyProtected(documentID):
            "Recovery checkpoint for document \(documentID.rawValue) does not have complete file protection. Editing cannot continue until recovery succeeds."
        }
    }
}

public func editActiveDocumentAndCheckpoint<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    newText: String,
    editedAt: Date,
    recoveryStore: RecoveryStore
) async throws -> PhonePadState {
    let transition = try beginActiveDocumentEdit(
        state: state,
        newText: newText,
        editedAt: editedAt
    )
    try await recoveryStore.save(envelope: transition.envelope)

    let verification = try await recoveryStore.verifyCheckpoint(
        documentID: transition.envelope.documentID
    )
    guard verification.isExcludedFromBackup else {
        throw PhonePadWorkflowError.recoveryCheckpointNotExcludedFromBackup(
            transition.envelope.documentID
        )
    }

    #if !targetEnvironment(simulator)
    guard verification.hasCompleteFileProtection else {
        throw PhonePadWorkflowError.recoveryCheckpointNotCompletelyProtected(
            transition.envelope.documentID
        )
    }
    #endif

    return try markActiveDocumentRecoveryProtected(state: transition.state)
}
