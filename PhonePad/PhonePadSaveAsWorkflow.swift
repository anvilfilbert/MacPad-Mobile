import Foundation
import PhonePadCore

public struct PreparedSaveAs: Equatable, Sendable {
    public let documentID: DocumentID
    public let sourceTitle: String
    public let sourceText: String
    public let sourceBinding: FileBinding?
    public let sourceWasUnsaved: Bool
    public let fileName: ValidatedFileName
    public let selectedEncoding: TextFileEncoding
    public let encodedFile: EncodedTextFile
    public let recoveryEditedAt: Date

    init(
        documentID: DocumentID,
        sourceTitle: String,
        sourceText: String,
        sourceBinding: FileBinding?,
        sourceWasUnsaved: Bool,
        fileName: ValidatedFileName,
        selectedEncoding: TextFileEncoding,
        encodedFile: EncodedTextFile,
        recoveryEditedAt: Date
    ) {
        self.documentID = documentID
        self.sourceTitle = sourceTitle
        self.sourceText = sourceText
        self.sourceBinding = sourceBinding
        self.sourceWasUnsaved = sourceWasUnsaved
        self.fileName = fileName
        self.selectedEncoding = selectedEncoding
        self.encodedFile = encodedFile
        self.recoveryEditedAt = recoveryEditedAt
    }
}

public struct PreparedSaveAsPreflight: Equatable, Sendable {
    public let preparedSave: PreparedSaveAs
    public let target: SaveAsTargetPreflight

    init(preparedSave: PreparedSaveAs, target: SaveAsTargetPreflight) {
        self.preparedSave = preparedSave
        self.target = target
    }
}

public struct SaveAsNotice: Equatable, Sendable {
    public let durableFileAccessUnavailable: Bool
    public let recoveryCleanupPending: Bool
    public let stagingCleanupFailureCode: Int?

    init(
        durableFileAccessUnavailable: Bool,
        recoveryCleanupPending: Bool,
        stagingCleanupFailureCode: Int?
    ) {
        self.durableFileAccessUnavailable = durableFileAccessUnavailable
        self.recoveryCleanupPending = recoveryCleanupPending
        self.stagingCleanupFailureCode = stagingCleanupFailureCode
    }
}

public struct SaveAsResult: Equatable, Sendable {
    public let state: PhonePadState
    public let disposition: NewDocumentSaveDisposition
    public let notice: SaveAsNotice?

    init(
        state: PhonePadState,
        disposition: NewDocumentSaveDisposition,
        notice: SaveAsNotice?
    ) {
        self.state = state
        self.disposition = disposition
        self.notice = notice
    }
}

public enum SaveAsWorkflowError: Error, Equatable, Sendable {
    case activeDocumentChangedSincePreparation(
        expected: DocumentID,
        actual: DocumentID
    )
    case activeDocumentTitleChangedSincePreparation(DocumentID)
    case activeDocumentTextChangedSincePreparation(DocumentID)
    case activeDocumentBindingChangedSincePreparation(DocumentID)
    case activeDocumentSaveStatusChangedSincePreparation(DocumentID)
    case targetRequiresReplacement
    case targetDoesNotRequireReplacement
    case targetIsCurrentFile
    case targetIsNotCurrentFile
    case currentFileRequiresBinding(DocumentID)
    case activeDocumentRecoveryNotProtected(
        documentID: DocumentID,
        actualState: DocumentRecoveryState
    )
    case outputVerifiedButRecoveryCleanupFailed(
        result: SaveAsResult,
        cleanupFailure: RecoveryCleanupFailure
    )
}

extension SaveAsWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .activeDocumentChangedSincePreparation(expected, actual):
            return "Save As was prepared for document \(expected.rawValue), but document \(actual.rawValue) is now active. Return to the intended Tab and choose Save As again."
        case let .activeDocumentTitleChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) changed while Save As was being prepared. Choose Save As again."
        case let .activeDocumentTextChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) text changed while Save As was being prepared. Choose Save As again."
        case let .activeDocumentBindingChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) File access changed while Save As was being prepared. Choose Save As again."
        case let .activeDocumentSaveStatusChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) changed save state while Save As was being prepared. Choose Save As again."
        case .targetRequiresReplacement:
            return "The selected File already exists. Confirm Replace before saving."
        case .targetDoesNotRequireReplacement:
            return "This Save As target has no pending replacement decision to cancel."
        case .targetIsCurrentFile:
            return "The selected File is this Document's current File. Use the current-File Save As path."
        case .targetIsNotCurrentFile:
            return "This Save As target is not the Document's current File. Choose Save As again."
        case let .currentFileRequiresBinding(documentID):
            return "Document \(documentID.rawValue) has no current File binding. Choose a different Save As target."
        case let .activeDocumentRecoveryNotProtected(documentID, actualState):
            return "Document \(documentID.rawValue) recovery is \(actualState.rawValue), not protected. Retry recovery before creating a File."
        case let .outputVerifiedButRecoveryCleanupFailed(_, cleanupFailure):
            return "File was saved and verified, but protected recovery cleanup did not finish: \(cleanupFailure.userFacingDescription) Keep the Document open and choose Retry Cleanup before editing or saving again."
        }
    }
}

public func prepareSaveAs(
    state: PhonePadState,
    fileName: String,
    encoding: TextFileEncoding,
    recoveryEditedAt: Date
) throws -> PreparedSaveAs {
    let document = state.activeTab.document
    let validatedFileName = try ValidatedFileName(validating: fileName)
    let lineEnding = document.fileBinding?.lineEnding ?? .lf
    let encodedFile = try encodeTextFile(
        text: document.text,
        encoding: encoding,
        lineEnding: lineEnding
    )
    return PreparedSaveAs(
        documentID: document.id,
        sourceTitle: document.title,
        sourceText: document.text,
        sourceBinding: document.fileBinding,
        sourceWasUnsaved: document.isUnsaved,
        fileName: validatedFileName,
        selectedEncoding: encoding,
        encodedFile: encodedFile,
        recoveryEditedAt: recoveryEditedAt
    )
}

public func preflightPreparedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedSaveAs,
    selectedDirectoryURL: URL,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> PreparedSaveAsPreflight {
    try validatePreparedSaveAs(state: state, preparedSave: preparedSave)
    let activeClaims = activeTabFileCollisionClaims(state: state)
    let recoveryClaims = try await recoveryStore.recoveryFileCollisionClaims(
        excludingDocumentID: preparedSave.documentID
    )
    let target = try await fileAccessConnector.preflightSaveAsTarget(
        in: selectedDirectoryURL,
        fileName: preparedSave.fileName,
        currentDocumentID: preparedSave.documentID,
        collisionClaims: activeClaims + recoveryClaims
    )
    return PreparedSaveAsPreflight(preparedSave: preparedSave, target: target)
}

public func saveReadyPreparedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> SaveAsResult {
    switch preflight.target {
    case .ready:
        break
    case .replacementRequired:
        throw SaveAsWorkflowError.targetRequiresReplacement
    case .currentFile:
        throw SaveAsWorkflowError.targetIsCurrentFile
    }
    let protectedState = try await protectPreparedSaveAs(
        state: state,
        preflight: preflight,
        recoveryStore: recoveryStore
    )
    return try await saveReadyProtectedSaveAs(
        state: protectedState,
        preflight: preflight,
        fileAccessConnector: fileAccessConnector,
        recoveryStore: recoveryStore
    )
}

public func saveConfirmedReplacementPreparedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> SaveAsResult {
    guard case .replacementRequired = preflight.target else {
        throw SaveAsWorkflowError.targetDoesNotRequireReplacement
    }
    let protectedState = try await protectPreparedSaveAs(
        state: state,
        preflight: preflight,
        recoveryStore: recoveryStore
    )
    return try await saveConfirmedReplacementProtectedSaveAs(
        state: protectedState,
        preflight: preflight,
        fileAccessConnector: fileAccessConnector,
        recoveryStore: recoveryStore
    )
}

public func saveCurrentFilePreparedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> SaveAsResult {
    guard case .currentFile = preflight.target else {
        throw SaveAsWorkflowError.targetIsNotCurrentFile
    }
    let protectedState = try await protectPreparedSaveAs(
        state: state,
        preflight: preflight,
        recoveryStore: recoveryStore
    )
    return try await saveCurrentFileProtectedSaveAs(
        state: protectedState,
        preflight: preflight,
        fileAccessConnector: fileAccessConnector,
        recoveryStore: recoveryStore
    )
}

public func cancelPreparedSaveAs(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight
) throws -> PhonePadState {
    guard case .replacementRequired = preflight.target else {
        throw SaveAsWorkflowError.targetDoesNotRequireReplacement
    }
    return state
}

public func protectPreparedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight,
    recoveryStore: RecoveryStore
) async throws -> PhonePadState {
    let preparedSave = preflight.preparedSave
    try validatePreparedSaveAs(state: state, preparedSave: preparedSave)
    guard preparedSave.sourceWasUnsaved else {
        return state
    }
    let document = state.activeTab.document
    let pendingDestination: RecoveryPendingSaveDestination
    switch preflight.target {
    case .currentFile:
        guard preparedSave.sourceBinding != nil else {
            throw SaveAsWorkflowError.currentFileRequiresBinding(
                preparedSave.documentID
            )
        }
        pendingDestination = .boundFile
    case .ready, .replacementRequired:
        pendingDestination = .saveAs(
            RecoverySaveAsDestination(
                directoryBookmark: preflight.target.plan.directoryBookmark,
                fileName: preflight.target.plan.fileName
            )
        )
    }
    let envelope = try RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: document.id,
        title: document.title,
        text: document.text,
        editedAt: preparedSave.recoveryEditedAt,
        fileReference: document.recoveryFileReference,
        pendingSave: RecoveryPendingSave(
            intendedOutputDigest: preparedSave.encodedFile.digest,
            destination: pendingDestination
        )
    )
    try await recoveryStore.save(envelope: envelope)
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

public func saveReadyProtectedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> SaveAsResult {
    let preparedSave = preflight.preparedSave
    try validatePreparedSaveAs(state: state, preparedSave: preparedSave)
    if preparedSave.sourceWasUnsaved {
        let recoveryState = state.activeTab.document.recoveryState
        guard recoveryState == .protectedUnsaved else {
            throw SaveAsWorkflowError.activeDocumentRecoveryNotProtected(
                documentID: preparedSave.documentID,
                actualState: recoveryState
            )
        }
    }
    let plan: SaveAsTargetPlan
    switch preflight.target {
    case let .ready(readyPlan):
        plan = readyPlan
    case .replacementRequired:
        throw SaveAsWorkflowError.targetRequiresReplacement
    case .currentFile:
        throw SaveAsWorkflowError.targetIsCurrentFile
    }
    let activeClaims = activeTabFileCollisionClaims(state: state)
    let recoveryClaims = try await recoveryStore.recoveryFileCollisionClaims(
        excludingDocumentID: preparedSave.documentID
    )
    let commitOutcome = try await fileAccessConnector.createSaveAsTarget(
        plan: plan,
        encodedFile: preparedSave.encodedFile,
        currentDocumentID: preparedSave.documentID,
        collisionClaims: activeClaims + recoveryClaims
    )
    return try await finishVerifiedSaveAs(
        state: state,
        preparedSave: preparedSave,
        commitOutcome: commitOutcome,
        recoveryStore: recoveryStore
    )
}

public func saveConfirmedReplacementProtectedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> SaveAsResult {
    let preparedSave = preflight.preparedSave
    try validatePreparedSaveAs(state: state, preparedSave: preparedSave)
    if preparedSave.sourceWasUnsaved {
        let recoveryState = state.activeTab.document.recoveryState
        guard recoveryState == .protectedUnsaved else {
            throw SaveAsWorkflowError.activeDocumentRecoveryNotProtected(
                documentID: preparedSave.documentID,
                actualState: recoveryState
            )
        }
    }
    guard case let .replacementRequired(plan) = preflight.target else {
        throw SaveAsWorkflowError.targetDoesNotRequireReplacement
    }
    let activeClaims = activeTabFileCollisionClaims(state: state)
    let recoveryClaims = try await recoveryStore.recoveryFileCollisionClaims(
        excludingDocumentID: preparedSave.documentID
    )
    let commitOutcome = try await fileAccessConnector.replaceSaveAsTarget(
        plan: plan,
        encodedFile: preparedSave.encodedFile,
        currentDocumentID: preparedSave.documentID,
        collisionClaims: activeClaims + recoveryClaims
    )
    return try await finishVerifiedSaveAs(
        state: state,
        preparedSave: preparedSave,
        commitOutcome: commitOutcome,
        recoveryStore: recoveryStore
    )
}

public func saveCurrentFileProtectedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preflight: PreparedSaveAsPreflight,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> SaveAsResult {
    let preparedSave = preflight.preparedSave
    try validatePreparedSaveAs(state: state, preparedSave: preparedSave)
    if preparedSave.sourceWasUnsaved {
        let recoveryState = state.activeTab.document.recoveryState
        guard recoveryState == .protectedUnsaved else {
            throw SaveAsWorkflowError.activeDocumentRecoveryNotProtected(
                documentID: preparedSave.documentID,
                actualState: recoveryState
            )
        }
    }
    guard case .currentFile = preflight.target else {
        throw SaveAsWorkflowError.targetIsNotCurrentFile
    }
    guard let sourceBinding = preparedSave.sourceBinding else {
        throw SaveAsWorkflowError.currentFileRequiresBinding(
            preparedSave.documentID
        )
    }
    let saveOutcome = try await fileAccessConnector.saveTextFile(
        binding: sourceBinding,
        encodedFile: preparedSave.encodedFile
    )
    return try await finishVerifiedSaveAs(
        state: state,
        preparedSave: preparedSave,
        commitOutcome: .complete(saveOutcome),
        recoveryStore: recoveryStore
    )
}

private func finishVerifiedSaveAs<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedSaveAs,
    commitOutcome: SaveAsTargetCommitOutcome,
    recoveryStore: RecoveryStore
) async throws -> SaveAsResult {
    let result = try makeSaveAsResult(
        state: state,
        preparedSave: preparedSave,
        commitOutcome: commitOutcome
    )
    guard preparedSave.sourceWasUnsaved else {
        return result
    }
    do {
        let terminalOutcome = try await recoveryStore.completeRecoveryAfterSave(
            documentID: preparedSave.documentID
        )
        return applyingSaveAsRecoveryTerminalOutcome(
            result: result,
            terminalOutcome: terminalOutcome
        )
    } catch {
        throw SaveAsWorkflowError.outputVerifiedButRecoveryCleanupFailed(
            result: result,
            cleanupFailure: RecoveryCleanupFailure(capturing: error)
        )
    }
}

private func makeSaveAsResult(
    state: PhonePadState,
    preparedSave: PreparedSaveAs,
    commitOutcome: SaveAsTargetCommitOutcome
) throws -> SaveAsResult {
    let saveOutcome: FileSaveOutcome
    let stagingCleanupFailureCode: Int?
    switch commitOutcome {
    case let .complete(outcome):
        saveOutcome = outcome
        stagingCleanupFailureCode = nil
    case let .verifiedWithResidualCleanup(outcome, code):
        saveOutcome = outcome
        stagingCleanupFailureCode = code
    }
    switch saveOutcome {
    case let .bound(binding):
        return SaveAsResult(
            state: try markActiveDocumentSavedToBoundFile(
                state: state,
                encodedFile: preparedSave.encodedFile,
                fileBinding: binding
            ),
            disposition: .bound,
            notice: makeSaveAsNotice(
                durableFileAccessUnavailable: false,
                recoveryCleanupPending: false,
                stagingCleanupFailureCode: stagingCleanupFailureCode
            )
        )
    case let .verifiedDetached(detachedFile):
        return SaveAsResult(
            state: try markActiveDocumentSavedToDetachedFile(
                state: state,
                encodedFile: preparedSave.encodedFile,
                fileName: detachedFile.displayName
            ),
            disposition: .verifiedDetached,
            notice: makeSaveAsNotice(
                durableFileAccessUnavailable: true,
                recoveryCleanupPending: false,
                stagingCleanupFailureCode: stagingCleanupFailureCode
            )
        )
    }
}

func applyingSaveAsRecoveryTerminalOutcome(
    result: SaveAsResult,
    terminalOutcome: RecoveryTerminalOutcome
) -> SaveAsResult {
    guard terminalOutcome == .residualCleanupPending else {
        return result
    }
    return SaveAsResult(
        state: result.state,
        disposition: result.disposition,
        notice: makeSaveAsNotice(
            durableFileAccessUnavailable: result.notice?.durableFileAccessUnavailable ?? false,
            recoveryCleanupPending: true,
            stagingCleanupFailureCode: result.notice?.stagingCleanupFailureCode
        )
    )
}

private func makeSaveAsNotice(
    durableFileAccessUnavailable: Bool,
    recoveryCleanupPending: Bool,
    stagingCleanupFailureCode: Int?
) -> SaveAsNotice? {
    guard durableFileAccessUnavailable
        || recoveryCleanupPending
        || stagingCleanupFailureCode != nil
    else {
        return nil
    }
    return SaveAsNotice(
        durableFileAccessUnavailable: durableFileAccessUnavailable,
        recoveryCleanupPending: recoveryCleanupPending,
        stagingCleanupFailureCode: stagingCleanupFailureCode
    )
}

private func validatePreparedSaveAs(
    state: PhonePadState,
    preparedSave: PreparedSaveAs
) throws {
    let document = state.activeTab.document
    guard document.id == preparedSave.documentID else {
        throw SaveAsWorkflowError.activeDocumentChangedSincePreparation(
            expected: preparedSave.documentID,
            actual: document.id
        )
    }
    guard document.title == preparedSave.sourceTitle else {
        throw SaveAsWorkflowError.activeDocumentTitleChangedSincePreparation(
            document.id
        )
    }
    guard document.text == preparedSave.sourceText else {
        throw SaveAsWorkflowError.activeDocumentTextChangedSincePreparation(
            document.id
        )
    }
    guard document.fileBinding == preparedSave.sourceBinding else {
        throw SaveAsWorkflowError.activeDocumentBindingChangedSincePreparation(
            document.id
        )
    }
    guard document.isUnsaved == preparedSave.sourceWasUnsaved else {
        throw SaveAsWorkflowError.activeDocumentSaveStatusChangedSincePreparation(
            document.id
        )
    }
}
