import Foundation

public enum RecoveryItemStatus: Equatable, Sendable {
    case recoverable
    case unavailable
    case corrupt
    case unsupportedVersion(UInt)
}

public enum RecoveryItemLastEdited: Equatable, Sendable {
    case available(Date)
    case unavailable
}

public struct RecoveryItemSummary: Equatable, Sendable {
    public let documentID: DocumentID
    public let title: String
    public let lastEdited: RecoveryItemLastEdited
    public let status: RecoveryItemStatus

    public init(
        documentID: DocumentID,
        title: String,
        lastEdited: RecoveryItemLastEdited,
        status: RecoveryItemStatus
    ) {
        self.documentID = documentID
        self.title = title
        self.lastEdited = lastEdited
        self.status = status
    }
}

public enum RecoveryTerminalOutcome: Equatable, Sendable {
    case complete
    case residualCleanupPending
}

public protocol RecoveryStoring: Sendable {
    func save(envelope: RecoveryEnvelope) async throws
    func load(documentID: DocumentID) async throws -> RecoveryEnvelope?
    func verifyCheckpoint(documentID: DocumentID) async throws -> RecoveryCheckpointVerification
    func recoveryItems() async throws -> [RecoveryItemSummary]
    func recoveryFileCollisionClaims(
        excludingDocumentID: DocumentID
    ) async throws -> [FileCollisionClaim]
    @discardableResult
    func discardRecovery(documentID: DocumentID) async throws -> RecoveryTerminalOutcome

    @discardableResult
    func completeRecoveryAfterSave(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome
}
