public protocol RecoveryStoring: Sendable {
    func save(envelope: RecoveryEnvelope) async throws
    func load(documentID: DocumentID) async throws -> RecoveryEnvelope?
    func verifyCheckpoint(documentID: DocumentID) async throws -> RecoveryCheckpointVerification
}
