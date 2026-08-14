import Foundation
import PhonePadCore

public enum NewDocumentSaveDisposition: Equatable, Sendable {
    case bound
    case verifiedDetached
}

public enum NewDocumentSaveNotice: Equatable, Sendable {
    case durableFileAccessUnavailable
    case recoveryCleanupPending
    case durableFileAccessUnavailableAndRecoveryCleanupPending
}

public struct PreparedNewFileSave: Equatable, Sendable {
    public let documentID: DocumentID
    public let sourceTitle: String
    public let sourceText: String
    public let sourceWasUnsaved: Bool
    public let fileName: ValidatedFileName
    public let selectedEncoding: TextFileEncoding
    public let encodedFile: EncodedTextFile
    public let recoveryEditedAt: Date

    init(
        documentID: DocumentID,
        sourceTitle: String,
        sourceText: String,
        sourceWasUnsaved: Bool,
        fileName: ValidatedFileName,
        selectedEncoding: TextFileEncoding,
        encodedFile: EncodedTextFile,
        recoveryEditedAt: Date
    ) {
        self.documentID = documentID
        self.sourceTitle = sourceTitle
        self.sourceText = sourceText
        self.sourceWasUnsaved = sourceWasUnsaved
        self.fileName = fileName
        self.selectedEncoding = selectedEncoding
        self.encodedFile = encodedFile
        self.recoveryEditedAt = recoveryEditedAt
    }
}

public struct NewDocumentSaveResult: Equatable, Sendable {
    public let state: PhonePadState
    public let disposition: NewDocumentSaveDisposition
    public let notice: NewDocumentSaveNotice?

    init(
        state: PhonePadState,
        disposition: NewDocumentSaveDisposition,
        notice: NewDocumentSaveNotice?
    ) {
        self.state = state
        self.disposition = disposition
        self.notice = notice
    }
}

public enum RecoveryCleanupFailure: Error, Sendable {
    case fileRecoveryStore(FileRecoveryStoreError)
    case external(errorDomain: String, errorCode: Int)

    init(capturing error: Error) {
        if let recoveryStoreError = error as? FileRecoveryStoreError {
            self = .fileRecoveryStore(recoveryStoreError)
            return
        }
        let bridgedError = error as NSError
        self = .external(
            errorDomain: bridgedError.domain,
            errorCode: bridgedError.code
        )
    }

    public var errorDomain: String {
        switch self {
        case let .fileRecoveryStore(error):
            return (error as NSError).domain
        case let .external(errorDomain, _):
            return errorDomain
        }
    }

    public var errorCode: Int {
        switch self {
        case let .fileRecoveryStore(error):
            return (error as NSError).code
        case let .external(_, errorCode):
            return errorCode
        }
    }

    public var userFacingDescription: String {
        switch self {
        case let .fileRecoveryStore(error):
            return error.localizedDescription
        case let .external(errorDomain, errorCode):
            return "Recovery cleanup could not finish (\(errorDomain), code \(errorCode)). Retry Cleanup."
        }
    }
}

extension RecoveryCleanupFailure: Equatable {
    public static func == (
        lhs: RecoveryCleanupFailure,
        rhs: RecoveryCleanupFailure
    ) -> Bool {
        switch (lhs, rhs) {
        case (.fileRecoveryStore, .fileRecoveryStore):
            return lhs.errorDomain == rhs.errorDomain
                && lhs.errorCode == rhs.errorCode
                && lhs.userFacingDescription == rhs.userFacingDescription
        case let (
            .external(lhsDomain, lhsCode),
            .external(rhsDomain, rhsCode)
        ):
            return lhsDomain == rhsDomain && lhsCode == rhsCode
        default:
            return false
        }
    }
}

public enum NewDocumentSaveWorkflowError: Error, Equatable, Sendable {
    case activeDocumentAlreadyBound(DocumentID)
    case cleanUnboundDocumentContainsText(DocumentID)
    case activeDocumentChangedSincePreparation(
        expected: DocumentID,
        actual: DocumentID
    )
    case activeDocumentTitleChangedSincePreparation(DocumentID)
    case activeDocumentTextChangedSincePreparation(DocumentID)
    case activeDocumentSaveStatusChangedSincePreparation(DocumentID)
    case activeDocumentRecoveryNotProtected(
        documentID: DocumentID,
        actualState: DocumentRecoveryState
    )
    case outputVerifiedButRecoveryCleanupFailed(
        result: NewDocumentSaveResult,
        cleanupFailure: RecoveryCleanupFailure
    )
}

extension NewDocumentSaveWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .activeDocumentAlreadyBound(documentID):
            return "Document \(documentID.rawValue) already has a File. Use Save for its existing File or Save As for a replacement."
        case let .cleanUnboundDocumentContainsText(documentID):
            return "Document \(documentID.rawValue) is not a fresh empty Document. Edit it before first Save so its content is protected for recovery."
        case let .activeDocumentChangedSincePreparation(expected, actual):
            return "Save As was prepared for document \(expected.rawValue), but document \(actual.rawValue) is now active. Return to the intended Tab and choose Save again."
        case let .activeDocumentTitleChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) changed while the Files picker was open. Choose Save again to use its current title."
        case let .activeDocumentTextChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) changed while the Files picker was open. Choose Save again to write its current text."
        case let .activeDocumentSaveStatusChangedSincePreparation(documentID):
            return "Document \(documentID.rawValue) changed save state while the Files picker was open. Choose Save again."
        case let .activeDocumentRecoveryNotProtected(documentID, actualState):
            return "Document \(documentID.rawValue) recovery is \(actualState.rawValue), not protected. Retry recovery before creating a File."
        case let .outputVerifiedButRecoveryCleanupFailed(
            result,
            cleanupFailure
        ):
            switch result.disposition {
            case .bound:
                return "File was created, verified, and bound, but protected recovery cleanup did not finish: \(cleanupFailure.userFacingDescription) Keep the Document open and choose Retry Cleanup before editing or saving again."
            case .verifiedDetached:
                return "File was created and verified without durable access, but protected recovery cleanup did not finish: \(cleanupFailure.userFacingDescription) Keep the Document open and choose Retry Cleanup before editing or saving again."
            }
        }
    }
}

public func prepareNewFileSave(
    state: PhonePadState,
    fileName: String,
    encoding: TextFileEncoding,
    recoveryEditedAt: Date
) throws -> PreparedNewFileSave {
    let document = state.activeTab.document
    guard document.fileBinding == nil else {
        throw NewDocumentSaveWorkflowError.activeDocumentAlreadyBound(document.id)
    }
    guard document.isUnsaved || document.text.isEmpty else {
        throw NewDocumentSaveWorkflowError.cleanUnboundDocumentContainsText(document.id)
    }

    let validatedFileName = try ValidatedFileName(validating: fileName)
    let encodedFile = try encodeTextFile(
        text: document.text,
        encoding: encoding,
        lineEnding: .lf
    )
    return PreparedNewFileSave(
        documentID: document.id,
        sourceTitle: document.title,
        sourceText: document.text,
        sourceWasUnsaved: document.isUnsaved,
        fileName: validatedFileName,
        selectedEncoding: encoding,
        encodedFile: encodedFile,
        recoveryEditedAt: recoveryEditedAt
    )
}

public func savePreparedNewDocument<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedNewFileSave,
    selectedFolderURL: URL,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> NewDocumentSaveResult {
    let protectedState = try await protectPreparedNewFileSave(
        state: state,
        preparedSave: preparedSave,
        recoveryStore: recoveryStore
    )
    return try await saveProtectedNewDocument(
        state: protectedState,
        preparedSave: preparedSave,
        selectedFolderURL: selectedFolderURL,
        fileAccessConnector: fileAccessConnector,
        recoveryStore: recoveryStore
    )
}

public func saveProtectedNewDocument<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedNewFileSave,
    selectedFolderURL: URL,
    fileAccessConnector: FileAccessConnector,
    recoveryStore: RecoveryStore
) async throws -> NewDocumentSaveResult {
    try validatePreparedSave(state: state, preparedSave: preparedSave)
    if preparedSave.sourceWasUnsaved {
        let recoveryState = state.activeTab.document.recoveryState
        guard recoveryState == .protectedUnsaved else {
            throw NewDocumentSaveWorkflowError.activeDocumentRecoveryNotProtected(
                documentID: preparedSave.documentID,
                actualState: recoveryState
            )
        }
    }
    let creationOutcome = try await fileAccessConnector.createFile(
        in: selectedFolderURL,
        fileName: preparedSave.fileName,
        encodedFile: preparedSave.encodedFile
    )
    let result = try makeNewDocumentSaveResult(
        state: state,
        preparedSave: preparedSave,
        creationOutcome: creationOutcome
    )
    guard preparedSave.sourceWasUnsaved else {
        return result
    }

    do {
        let terminalOutcome = try await recoveryStore.completeRecoveryAfterSave(
            documentID: preparedSave.documentID
        )
        return applyingRecoveryTerminalOutcome(
            result: result,
            terminalOutcome: terminalOutcome
        )
    } catch {
        throw NewDocumentSaveWorkflowError.outputVerifiedButRecoveryCleanupFailed(
            result: result,
            cleanupFailure: RecoveryCleanupFailure(capturing: error)
        )
    }
}

func applyingRecoveryTerminalOutcome(
    result: NewDocumentSaveResult,
    terminalOutcome: RecoveryTerminalOutcome
) -> NewDocumentSaveResult {
    guard terminalOutcome == .residualCleanupPending else {
        return result
    }

    let notice: NewDocumentSaveNotice
    switch result.notice {
    case .none:
        notice = .recoveryCleanupPending
    case .durableFileAccessUnavailable:
        notice = .durableFileAccessUnavailableAndRecoveryCleanupPending
    case .recoveryCleanupPending:
        notice = .recoveryCleanupPending
    case .durableFileAccessUnavailableAndRecoveryCleanupPending:
        notice = .durableFileAccessUnavailableAndRecoveryCleanupPending
    }
    return NewDocumentSaveResult(
        state: result.state,
        disposition: result.disposition,
        notice: notice
    )
}

public func protectPreparedNewFileSave<RecoveryStore: RecoveryStoring>(
    state: PhonePadState,
    preparedSave: PreparedNewFileSave,
    recoveryStore: RecoveryStore
) async throws -> PhonePadState {
    try validatePreparedSave(state: state, preparedSave: preparedSave)
    guard preparedSave.sourceWasUnsaved else {
        return state
    }
    return try await editActiveDocumentAndCheckpoint(
        state: state,
        newText: preparedSave.sourceText,
        editedAt: preparedSave.recoveryEditedAt,
        recoveryStore: recoveryStore
    )
}

private func validatePreparedSave(
    state: PhonePadState,
    preparedSave: PreparedNewFileSave
) throws {
    let document = state.activeTab.document
    guard document.id == preparedSave.documentID else {
        throw NewDocumentSaveWorkflowError.activeDocumentChangedSincePreparation(
            expected: preparedSave.documentID,
            actual: document.id
        )
    }
    guard document.fileBinding == nil else {
        throw NewDocumentSaveWorkflowError.activeDocumentAlreadyBound(document.id)
    }
    guard document.title == preparedSave.sourceTitle else {
        throw NewDocumentSaveWorkflowError.activeDocumentTitleChangedSincePreparation(
            document.id
        )
    }
    guard document.text == preparedSave.sourceText else {
        throw NewDocumentSaveWorkflowError.activeDocumentTextChangedSincePreparation(
            document.id
        )
    }
    guard document.isUnsaved == preparedSave.sourceWasUnsaved else {
        throw NewDocumentSaveWorkflowError.activeDocumentSaveStatusChangedSincePreparation(
            document.id
        )
    }
}

private func makeNewDocumentSaveResult(
    state: PhonePadState,
    preparedSave: PreparedNewFileSave,
    creationOutcome: FileCreationOutcome
) throws -> NewDocumentSaveResult {
    switch creationOutcome {
    case let .bound(fileBinding):
        let savedState = try markActiveDocumentSavedToBoundFile(
            state: state,
            encodedFile: preparedSave.encodedFile,
            fileBinding: fileBinding
        )
        return NewDocumentSaveResult(
            state: savedState,
            disposition: .bound,
            notice: nil
        )
    case .verifiedDetached:
        let savedState = try markActiveDocumentSavedToDetachedFile(
            state: state,
            encodedFile: preparedSave.encodedFile,
            fileName: preparedSave.fileName
        )
        return NewDocumentSaveResult(
            state: savedState,
            disposition: .verifiedDetached,
            notice: .durableFileAccessUnavailable
        )
    }
}
