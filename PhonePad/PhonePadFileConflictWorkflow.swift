import Foundation
import PhonePadCore

public struct FileConflictReloadResult: Equatable, Sendable {
    public let state: PhonePadState
    public let recoveryCleanupPending: Bool

    init(state: PhonePadState, recoveryCleanupPending: Bool) {
        self.state = state
        self.recoveryCleanupPending = recoveryCleanupPending
    }
}

public enum FileConflictWorkflowError: Error, Equatable, Sendable {
    case documentMissing(DocumentID)
    case documentIsNotBound(DocumentID)
    case fileConflictRequired(DocumentID)
    case recoveryCleanupFailed(
        documentID: DocumentID,
        failure: RecoveryCleanupFailure
    )
}

extension FileConflictWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .documentMissing(documentID):
            return "Document \(documentID.rawValue) is no longer open. Return to its Tab and retry File Conflict resolution."
        case let .documentIsNotBound(documentID):
            return "Document \(documentID.rawValue) no longer has an original File. Use Save As to preserve its edits."
        case let .fileConflictRequired(documentID):
            return "Document \(documentID.rawValue) no longer has a File Conflict. Review its current state before continuing."
        case let .recoveryCleanupFailed(_, failure):
            return "Current File was read and validated, but protected edit cleanup failed: \(failure.userFacingDescription) Edits remain unchanged. Retry Reload Current or use Save As."
        }
    }
}

public func reloadCurrentFileAfterDiscardingEdits<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    documentID: DocumentID,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> FileConflictReloadResult {
    guard let document = state.tabs.first(where: {
        $0.document.id == documentID
    })?.document else {
        throw FileConflictWorkflowError.documentMissing(documentID)
    }
    guard let binding = document.fileBinding else {
        throw FileConflictWorkflowError.documentIsNotBound(documentID)
    }
    guard document.fileConflict != nil else {
        throw FileConflictWorkflowError.fileConflictRequired(documentID)
    }

    let snapshot = try await fileAccessConnector.readCurrentPresentedTextFile(
        documentID: documentID,
        binding: binding
    )
    let candidateState = try reloadDocumentFromBoundFile(
        state: state,
        documentID: documentID,
        text: snapshot.openedFile.text,
        observation: ObservedBoundFile(
            binding: snapshot.openedFile.binding,
            providerConflictVersions: snapshot.providerConflictVersions
        )
    )

    let terminalOutcome: RecoveryTerminalOutcome
    do {
        terminalOutcome = try await recoveryStore.discardRecovery(
            documentID: documentID
        )
    } catch {
        throw FileConflictWorkflowError.recoveryCleanupFailed(
            documentID: documentID,
            failure: RecoveryCleanupFailure(capturing: error)
        )
    }

    return FileConflictReloadResult(
        state: candidateState,
        recoveryCleanupPending: terminalOutcome == .residualCleanupPending
    )
}
