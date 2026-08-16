import Foundation
import PhonePadCore

public enum DiscardedRecoveryDocumentOpenNotice: Equatable, Sendable {
    case residualRecoveryCleanupPending
}

public struct DiscardedRecoveryBoundDocumentOpenResult: Equatable, Sendable {
    public let state: PhonePadState
    public let discardedRecoveryDocumentID: DocumentID
    public let notice: DiscardedRecoveryDocumentOpenNotice?

    init(
        state: PhonePadState,
        discardedRecoveryDocumentID: DocumentID,
        notice: DiscardedRecoveryDocumentOpenNotice?
    ) {
        self.state = state
        self.discardedRecoveryDocumentID = discardedRecoveryDocumentID
        self.notice = notice
    }
}

public struct DiscardedRecoveryDetachedDocumentOpenResult: Equatable, Sendable {
    public let transition: RecoveryEditTransition
    public let discardedRecoveryDocumentID: DocumentID
    public let notice: DiscardedRecoveryDocumentOpenNotice?

    init(
        transition: RecoveryEditTransition,
        discardedRecoveryDocumentID: DocumentID,
        notice: DiscardedRecoveryDocumentOpenNotice?
    ) {
        self.transition = transition
        self.discardedRecoveryDocumentID = discardedRecoveryDocumentID
        self.notice = notice
    }
}

public enum ExternalOpenRecoveryWorkflowError: Error, Equatable, Sendable {
    case recoveryCleanupFailed(
        documentID: DocumentID,
        failure: RecoveryCleanupFailure
    )
}

extension ExternalOpenRecoveryWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .recoveryCleanupFailed(_, failure):
            return "Preserved edits could not be discarded before File Open: \(failure.userFacingDescription) Current Tabs and recovery remain unchanged. Retry Open so MacPad Mobile can read and prepare the File again."
        }
    }
}

public func discardRecoveryAndCommitPreparedBoundDocumentOpen<
    RecoveryStore: RecoveryStoring
>(
    state: PhonePadState,
    recoveryDocumentID: DocumentID,
    preparedOpen: PreparedBoundDocumentOpen,
    recoveryStore: RecoveryStore
) async throws -> DiscardedRecoveryBoundDocumentOpenResult {
    _ = try commitPreparedBoundDocumentOpen(
        state: state,
        prepared: preparedOpen
    )
    let terminalOutcome = try await discardExternalOpenRecovery(
        documentID: recoveryDocumentID,
        recoveryStore: recoveryStore
    )
    let openedState = try commitPreparedBoundDocumentOpen(
        state: state,
        prepared: preparedOpen
    )
    return DiscardedRecoveryBoundDocumentOpenResult(
        state: openedState,
        discardedRecoveryDocumentID: recoveryDocumentID,
        notice: externalOpenRecoveryNotice(
            terminalOutcome: terminalOutcome
        )
    )
}

public func discardRecoveryAndCommitPreparedDetachedDocumentOpen<
    RecoveryStore: RecoveryStoring
>(
    state: PhonePadState,
    recoveryDocumentID: DocumentID,
    preparedOpen: PreparedDetachedDocumentOpen,
    recoveryStore: RecoveryStore
) async throws -> DiscardedRecoveryDetachedDocumentOpenResult {
    _ = try commitPreparedDetachedDocumentOpen(
        state: state,
        prepared: preparedOpen
    )
    let terminalOutcome = try await discardExternalOpenRecovery(
        documentID: recoveryDocumentID,
        recoveryStore: recoveryStore
    )
    let transition = try commitPreparedDetachedDocumentOpen(
        state: state,
        prepared: preparedOpen
    )
    return DiscardedRecoveryDetachedDocumentOpenResult(
        transition: transition,
        discardedRecoveryDocumentID: recoveryDocumentID,
        notice: externalOpenRecoveryNotice(
            terminalOutcome: terminalOutcome
        )
    )
}

private func discardExternalOpenRecovery<RecoveryStore: RecoveryStoring>(
    documentID: DocumentID,
    recoveryStore: RecoveryStore
) async throws -> RecoveryTerminalOutcome {
    do {
        return try await recoveryStore.discardRecovery(
            documentID: documentID
        )
    } catch {
        throw ExternalOpenRecoveryWorkflowError.recoveryCleanupFailed(
            documentID: documentID,
            failure: RecoveryCleanupFailure(capturing: error)
        )
    }
}

private func externalOpenRecoveryNotice(
    terminalOutcome: RecoveryTerminalOutcome
) -> DiscardedRecoveryDocumentOpenNotice? {
    guard terminalOutcome == .residualCleanupPending else {
        return nil
    }
    return .residualRecoveryCleanupPending
}
