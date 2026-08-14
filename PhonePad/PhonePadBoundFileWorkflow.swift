import Foundation
import PhonePadCore

public typealias BoundFileSaveResult = NewDocumentSaveResult

public struct PreparedBoundFileSave: Equatable, Sendable {
    public let documentID: DocumentID
    public let sourceTitle: String
    public let sourceText: String
    public let sourceBinding: FileBinding
    public let encodedFile: EncodedTextFile
    public let recoveryEnvelope: RecoveryEnvelope

    init(
        documentID: DocumentID,
        sourceTitle: String,
        sourceText: String,
        sourceBinding: FileBinding,
        encodedFile: EncodedTextFile,
        recoveryEnvelope: RecoveryEnvelope
    ) {
        self.documentID = documentID
        self.sourceTitle = sourceTitle
        self.sourceText = sourceText
        self.sourceBinding = sourceBinding
        self.encodedFile = encodedFile
        self.recoveryEnvelope = recoveryEnvelope
    }
}

public enum BoundFileSaveWorkflowError: Error, Equatable, Sendable {
    case activeDocumentIsNotBound(DocumentID)
    case activeDocumentHasNoUnsavedChanges(DocumentID)
    case activeDocumentChangedSincePreparation(
        expected: DocumentID,
        actual: DocumentID
    )
    case activeDocumentTitleChangedSincePreparation(DocumentID)
    case activeDocumentTextChangedSincePreparation(DocumentID)
    case activeDocumentBindingChangedSincePreparation(DocumentID)
    case activeDocumentSaveStatusChangedSincePreparation(DocumentID)
    case activeDocumentRecoveryNotProtected(
        documentID: DocumentID,
        actualState: DocumentRecoveryState
    )
    case outputVerifiedButRecoveryCleanupFailed(
        result: BoundFileSaveResult,
        cleanupFailure: RecoveryCleanupFailure
    )
}

extension BoundFileSaveWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .activeDocumentIsNotBound(documentID):
            return "Document \(documentID.rawValue) has no existing File. Choose Save As instead."
        case let .activeDocumentHasNoUnsavedChanges(documentID):
            return "Document \(documentID.rawValue) has no unsaved changes. Its File was not rewritten."
        case let .activeDocumentChangedSincePreparation(expected, actual):
            return "Save was prepared for document \(expected.rawValue), but document \(actual.rawValue) is now active. Return to the intended Tab and choose Save again."
        case let .activeDocumentTitleChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) changed while Save was being prepared. Choose Save again."
        case let .activeDocumentTextChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) text changed while Save was being prepared. Choose Save again."
        case let .activeDocumentBindingChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) File access changed while Save was being prepared. Reopen the File or choose Save As."
        case let .activeDocumentSaveStatusChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) changed save state while Save was being prepared. Choose Save again."
        case let .activeDocumentRecoveryNotProtected(documentID, actualState):
            return "Document \(documentID.rawValue) recovery is \(actualState.rawValue), not protected. Retry recovery before writing its File."
        case let .outputVerifiedButRecoveryCleanupFailed(
            result,
            cleanupFailure
        ):
            switch result.disposition {
            case .bound:
                return "File was saved and verified, but protected recovery cleanup did not finish: \(cleanupFailure.userFacingDescription) Keep the Document open and choose Retry Cleanup before editing or saving again."
            case .verifiedDetached:
                return "File was saved and verified, but durable access and protected recovery cleanup did not finish: \(cleanupFailure.userFacingDescription) Keep the Document open and choose Retry Cleanup before editing or saving again."
            }
        }
    }
}

public func prepareBoundFileSave(
    state: PhonePadState,
    recoveryEditedAt: Date
) throws -> PreparedBoundFileSave {
    let document = state.activeTab.document
    guard let fileBinding = document.fileBinding else {
        throw BoundFileSaveWorkflowError.activeDocumentIsNotBound(document.id)
    }
    guard document.isUnsaved else {
        throw BoundFileSaveWorkflowError.activeDocumentHasNoUnsavedChanges(
            document.id
        )
    }

    let encodedFile = try encodeNewTextFile(text: document.text)
    let recoveryEnvelope = try RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: document.id,
        title: document.title,
        text: document.text,
        editedAt: recoveryEditedAt,
        fileReference: makeRecoveryFileReference(fileBinding: fileBinding),
        pendingSave: RecoveryPendingSave(
            intendedOutputDigest: encodedFile.digest
        )
    )
    return PreparedBoundFileSave(
        documentID: document.id,
        sourceTitle: document.title,
        sourceText: document.text,
        sourceBinding: fileBinding,
        encodedFile: encodedFile,
        recoveryEnvelope: recoveryEnvelope
    )
}

public func savePreparedBoundDocument<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedBoundFileSave,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> BoundFileSaveResult {
    let protectedState = try await protectPreparedBoundFileSave(
        state: state,
        preparedSave: preparedSave,
        recoveryStore: recoveryStore
    )
    return try await saveProtectedBoundDocument(
        state: protectedState,
        preparedSave: preparedSave,
        fileAccessConnector: fileAccessConnector,
        recoveryStore: recoveryStore
    )
}

public func protectPreparedBoundFileSave<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedBoundFileSave,
    recoveryStore: RecoveryStore
) async throws -> PhonePadState {
    try validatePreparedBoundSave(state: state, preparedSave: preparedSave)
    try await recoveryStore.save(envelope: preparedSave.recoveryEnvelope)
    let verification = try await recoveryStore.verifyCheckpoint(
        documentID: preparedSave.documentID
    )
    guard verification.isExcludedFromBackup else {
        throw PhonePadWorkflowError.recoveryCheckpointNotExcludedFromBackup(
            preparedSave.documentID
        )
    }

    #if !targetEnvironment(simulator)
    guard verification.hasCompleteFileProtection else {
        throw PhonePadWorkflowError.recoveryCheckpointNotCompletelyProtected(
            preparedSave.documentID
        )
    }
    #endif

    return try markActiveDocumentRecoveryProtected(state: state)
}

public func saveProtectedBoundDocument<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedBoundFileSave,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> BoundFileSaveResult {
    try validatePreparedBoundSave(state: state, preparedSave: preparedSave)
    let recoveryState = state.activeTab.document.recoveryState
    guard recoveryState == .protectedUnsaved else {
        throw BoundFileSaveWorkflowError.activeDocumentRecoveryNotProtected(
            documentID: preparedSave.documentID,
            actualState: recoveryState
        )
    }

    let saveOutcome = try await fileAccessConnector.saveUTF8File(
        binding: preparedSave.sourceBinding,
        encodedFile: preparedSave.encodedFile
    )
    let result = try makeBoundFileSaveResult(
        state: state,
        preparedSave: preparedSave,
        saveOutcome: saveOutcome
    )
    do {
        let terminalOutcome = try await recoveryStore.completeRecoveryAfterSave(
            documentID: preparedSave.documentID
        )
        return applyingRecoveryTerminalOutcome(
            result: result,
            terminalOutcome: terminalOutcome
        )
    } catch {
        throw BoundFileSaveWorkflowError.outputVerifiedButRecoveryCleanupFailed(
            result: result,
            cleanupFailure: RecoveryCleanupFailure(capturing: error)
        )
    }
}

private func validatePreparedBoundSave(
    state: PhonePadState,
    preparedSave: PreparedBoundFileSave
) throws {
    let document = state.activeTab.document
    guard document.id == preparedSave.documentID else {
        throw BoundFileSaveWorkflowError.activeDocumentChangedSincePreparation(
            expected: preparedSave.documentID,
            actual: document.id
        )
    }
    guard document.title == preparedSave.sourceTitle else {
        throw BoundFileSaveWorkflowError.activeDocumentTitleChangedSincePreparation(
            document.id
        )
    }
    guard document.text == preparedSave.sourceText else {
        throw BoundFileSaveWorkflowError.activeDocumentTextChangedSincePreparation(
            document.id
        )
    }
    guard document.fileBinding == preparedSave.sourceBinding else {
        throw BoundFileSaveWorkflowError.activeDocumentBindingChangedSincePreparation(
            document.id
        )
    }
    guard document.isUnsaved else {
        throw BoundFileSaveWorkflowError.activeDocumentSaveStatusChangedSincePreparation(
            document.id
        )
    }
}

private func makeBoundFileSaveResult(
    state: PhonePadState,
    preparedSave: PreparedBoundFileSave,
    saveOutcome: FileSaveOutcome
) throws -> BoundFileSaveResult {
    switch saveOutcome {
    case let .bound(fileBinding):
        return BoundFileSaveResult(
            state: try markActiveDocumentSavedToBoundFile(
                state: state,
                encodedFile: preparedSave.encodedFile,
                fileBinding: fileBinding
            ),
            disposition: .bound,
            notice: nil
        )
    case let .verifiedDetached(detachedFile):
        return BoundFileSaveResult(
            state: try markActiveDocumentSavedToDetachedFile(
                state: state,
                encodedFile: preparedSave.encodedFile,
                fileName: detachedFile.displayName
            ),
            disposition: .verifiedDetached,
            notice: .durableFileAccessUnavailable
        )
    }
}
