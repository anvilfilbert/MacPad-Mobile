import Foundation
import PhonePadCore

public enum DiscardedTabCloseNotice: Equatable, Sendable {
    case residualRecoveryCleanupPending
}

public struct DiscardedTabCloseResult: Equatable, Sendable {
    public let state: PhonePadState
    public let closedDocumentID: DocumentID
    public let notice: DiscardedTabCloseNotice?

    init(
        state: PhonePadState,
        closedDocumentID: DocumentID,
        notice: DiscardedTabCloseNotice?
    ) {
        self.state = state
        self.closedDocumentID = closedDocumentID
        self.notice = notice
    }
}

public enum TabCloseWorkflowError: Error, Equatable, Sendable {
    case recoveryCleanupFailed(
        documentID: DocumentID,
        failure: RecoveryCleanupFailure
    )
}

extension TabCloseWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .recoveryCleanupFailed(_, failure):
            return "Protected edit cleanup failed: \(failure.userFacingDescription) Keep the Tab open and choose Retry Cleanup."
        }
    }
}

public func discardAndClosePreparedUnsavedTab<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedClose: PreparedUnsavedTabClose,
    replacementDocumentID: DocumentID,
    replacementTabID: TabID,
    recoveryStore: RecoveryStore
) async throws -> DiscardedTabCloseResult {
    _ = try closePreparedDiscardedTab(
        state: state,
        preparedClose: preparedClose,
        replacementDocumentID: replacementDocumentID,
        replacementTabID: replacementTabID
    )

    let documentID = preparedClose.tab.document.id
    let terminalOutcome: RecoveryTerminalOutcome
    do {
        terminalOutcome = try await recoveryStore.discardRecovery(
            documentID: documentID
        )
    } catch {
        throw TabCloseWorkflowError.recoveryCleanupFailed(
            documentID: documentID,
            failure: RecoveryCleanupFailure(capturing: error)
        )
    }

    let closedState = try closePreparedDiscardedTab(
        state: state,
        preparedClose: preparedClose,
        replacementDocumentID: replacementDocumentID,
        replacementTabID: replacementTabID
    )
    let notice: DiscardedTabCloseNotice? = terminalOutcome == .residualCleanupPending
        ? .residualRecoveryCleanupPending
        : nil
    return DiscardedTabCloseResult(
        state: closedState,
        closedDocumentID: documentID,
        notice: notice
    )
}
