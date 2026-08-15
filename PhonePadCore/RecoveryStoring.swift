import Foundation

public enum RecoveryItemStatus: Equatable, Sendable {
    case recoverable
    case saveResultUnresolved
    case unavailable
    case corrupt
    case unsupportedVersion(UInt)

    public var allowsRecovery: Bool {
        switch self {
        case .recoverable, .saveResultUnresolved:
            return true
        case .unavailable, .corrupt, .unsupportedVersion:
            return false
        }
    }
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
    public let requiresPendingSaveReconciliation: Bool

    public init(
        documentID: DocumentID,
        title: String,
        lastEdited: RecoveryItemLastEdited,
        status: RecoveryItemStatus
    ) {
        self.init(
            documentID: documentID,
            title: title,
            lastEdited: lastEdited,
            status: status,
            requiresPendingSaveReconciliation: false
        )
    }

    public init(
        documentID: DocumentID,
        title: String,
        lastEdited: RecoveryItemLastEdited,
        status: RecoveryItemStatus,
        requiresPendingSaveReconciliation: Bool
    ) {
        self.documentID = documentID
        self.title = title
        self.lastEdited = lastEdited
        self.status = status
        self.requiresPendingSaveReconciliation =
            requiresPendingSaveReconciliation
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
