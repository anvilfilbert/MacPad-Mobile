import CryptoKit
import Darwin
import Foundation
import PhonePadCore
import UniformTypeIdentifiers

public enum ExistingFileSystemItemKind: String, Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case special
}

public struct VerifiedDetachedFile: Equatable, Sendable {
    public let displayName: ValidatedFileName
    public let digest: FileDigest
    public let encoding: TextFileEncoding
    public let lineEnding: TextLineEnding

    public init(
        displayName: ValidatedFileName,
        digest: FileDigest,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding
    ) {
        self.displayName = displayName
        self.digest = digest
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

public enum FileCreationOutcome: Equatable, Sendable {
    case bound(FileBinding)
    case verifiedDetached(VerifiedDetachedFile)
}

public struct OpenedTextFile: Equatable, Sendable {
    public let text: String
    public let binding: FileBinding

    public init(text: String, binding: FileBinding) {
        self.text = text
        self.binding = binding
    }
}

public enum FileOpenDetachmentReason: Error, Equatable, Sendable {
    case copyRequired
    case notWritable
    case writabilityNotReported
    case writabilityInspectionFailed(code: Int)
    case bookmarkCreationFailed(code: Int)
    case bookmarkResolutionFailed(code: Int)
    case bookmarkIsStale
    case bookmarkVerificationFailed(code: Int)
    case bookmarkResolvedToDifferentFile
}

public struct ImportedCopyCleanupToken: Equatable, Hashable, Sendable {
    let rawValue: UUID
}

struct ImportedCopyCleanupCandidate: Equatable, Sendable {
    let childName: ValidatedFileName
    let fingerprint: ImportedCopyCleanupFingerprint
}

public enum ImportedCopyCleanupFailure: Error, Equatable, Sendable {
    case unknownToken
    case itemChanged
    case verificationFailed(code: Int)
    case fileCoordinationFailed(code: Int)
    case fileCoordinationAccessorNotInvoked
    case deletionFailed(code: Int)
    case journal(ImportedCopyCleanupJournalError)
}

extension ImportedCopyCleanupFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownToken:
            return "cleanup capability is unavailable"
        case .itemChanged:
            return "supplied File no longer matches its verified cleanup capability"
        case let .verificationFailed(code):
            return "supplied File verification failed (system code \(code))"
        case let .fileCoordinationFailed(code):
            return "Apple Files cleanup coordination failed (system code \(code))"
        case .fileCoordinationAccessorNotInvoked:
            return "Apple Files cleanup coordination did not provide the supplied File"
        case let .deletionFailed(code):
            return "supplied File removal failed (system code \(code))"
        case let .journal(error):
            return error.localizedDescription
        }
    }
}

public enum ImportedCopyCleanupOutcome: Equatable, Sendable {
    case removed
    case alreadyAbsent
    case residual(ImportedCopyCleanupFailure)
}

public struct OpenedDetachedTextFile: Equatable, Sendable {
    public let snapshot: DetachedFileSnapshot
    public let reason: FileOpenDetachmentReason
    public let importedCopyCleanupToken: ImportedCopyCleanupToken?

    public init(
        snapshot: DetachedFileSnapshot,
        reason: FileOpenDetachmentReason,
        importedCopyCleanupToken: ImportedCopyCleanupToken?
    ) {
        self.snapshot = snapshot
        self.reason = reason
        self.importedCopyCleanupToken = importedCopyCleanupToken
    }
}

public struct RejectedTextFileOpen: Equatable, Sendable {
    public let error: FileAccessConnectorError
    public let importedCopyCleanupToken: ImportedCopyCleanupToken?

    public init(
        error: FileAccessConnectorError,
        importedCopyCleanupToken: ImportedCopyCleanupToken?
    ) {
        self.error = error
        self.importedCopyCleanupToken = importedCopyCleanupToken
    }
}

public enum OpenTextFileOutcome: Equatable, Sendable {
    case bound(PresentedTextFileSnapshot)
    case detached(OpenedDetachedTextFile)
    case rejected(RejectedTextFileOpen)
}

public enum ActiveFileOpenLocatorMatch: Equatable, Sendable {
    case none
    case missingItem(DocumentID)
    case requiresAuthoritativeRead([DocumentID])
    case ambiguous([DocumentID])
}

enum SelectedFileNodePresence: Equatable, Sendable {
    case missing
    case present
}

public enum ActiveFileOpenLocatorClaim: Equatable, Sendable {
    case bound(documentID: DocumentID, binding: FileBinding)
    case ephemeral(documentID: DocumentID, locatorURL: URL)
    case detached(
        documentID: DocumentID,
        reference: FileCollisionReference
    )
}

public enum FileSaveOutcome: Equatable, Sendable {
    case bound(FileBinding)
    case verifiedDetached(VerifiedDetachedFile)
}

public enum SaveAsTargetCommitOutcome: Equatable, Sendable {
    case complete(FileSaveOutcome)
    case verifiedWithResidualCleanup(FileSaveOutcome, code: Int)
}

public enum SaveAsRelocatedFileGeneration: Equatable, Sendable {
    case original
    case intended
    case unexpected
}

public enum FileVerificationFailure: Error, Equatable, Sendable {
    case itemIsNotRegularFile(ExistingFileSystemItemKind)
    case byteCountMismatch(expected: Int, actual: Int)
    case contentMismatch
    case digestMismatch
    case readFailed(code: Int)
    case digestConstructionFailed
}

public indirect enum FileAccessConnectorError: Error, Equatable, Sendable {
    case selectedFolderMissing
    case selectedLocationIsNotDirectory(ExistingFileSystemItemKind)
    case directChildResolutionFailed
    case targetAlreadyExists(ExistingFileSystemItemKind)
    case fileSystemInspectionFailed(code: Int32)
    case stagingCreationFailed(code: Int)
    case stagingVerificationFailed(FileVerificationFailure)
    case fileCoordinationFailed(code: Int)
    case fileCoordinationAccessorNotInvoked
    case exclusiveCreationFailed(code: Int32)
    case outputVerificationFailed(FileVerificationFailure)
    case unsafeStagingCleanupRefused(ExistingFileSystemItemKind, after: FileAccessConnectorError)
    case stagingCleanupFailed(code: Int, after: FileAccessConnectorError)
    case selectedFileMissing
    case selectedFileIsNotRegularFile(ExistingFileSystemItemKind)
    case selectedFileIsPackage
    case selectedFileHasUnsupportedContentType(String)
    case selectedFileMetadataInspectionFailed(code: Int)
    case inputTooLarge(actualByteCount: Int, maximumByteCount: Int)
    case inputReadFailed(code: Int)
    case textDecodingFailed(TextFileDecodingError)
    case selectedFileNameInvalid
    case fileIdentityInspectionFailed(code: Int)
    case fileIdentityValueInvalid
    case bookmarkCreationFailed(code: Int)
    case bookmarkResolutionFailed(code: Int)
    case bookmarkRefreshFailed(code: Int)
    case pendingBoundSaveBookmarkIsStale
    case filePresenterNotRegistered(documentID: DocumentID)
    case duplicateFilePresenterRegistration(documentID: DocumentID)
    case providerConflictVersionCountInvalid(count: Int)
    case collisionClaimBookmarkResolutionFailed(documentID: DocumentID, code: Int)
    case collisionClaimBookmarkIsStale(documentID: DocumentID)
    case recoveryClaimIsNotRecoveryItem(documentID: DocumentID)
    case activeLocatorBookmarkResolutionFailed(documentID: DocumentID, code: Int)
    case activeLocatorBookmarkIsStale(documentID: DocumentID)
    case importedCopyCleanupJournal(ImportedCopyCleanupJournalError)
    case importedCopyCleanupJournalCleanupFailed(
        ImportedCopyCleanupJournalError,
        ImportedCopyCleanupFailure
    )
    case importedCopyCleanupCandidateChanged
    case saveAsTargetCollision(FileCollisionClaim)
    case saveAsPlanRequiresAbsentTarget
    case saveAsPlanRequiresExistingTarget
    case saveAsDirectoryBookmarkResolutionFailed(code: Int)
    case saveAsDirectoryBookmarkIsStale
    case saveAsTargetAppeared(ExistingFileSystemItemKind)
    case saveAsTargetChanged
    case saveAsTargetSnapshotReadFailed(code: Int)
    case saveAsTargetHasUnresolvedProviderVersions(count: Int)
    case boundFileMissing
    case boundFileIsNotRegularFile(ExistingFileSystemItemKind)
    case fileConflict(FileConflict)
    case replacementStagingCreationFailed(code: Int)
    case replacementFailed(code: Int)
    case replacementOutcomeIndeterminate(code: Int)
    case replacementReportedRelocatedItem(
        code: Int,
        generation: SaveAsRelocatedFileGeneration,
        preservedFileName: ValidatedFileName
    )
    case replacementReportedItemPreservationFailed(
        replacementCode: Int,
        preservationCode: Int,
        generation: SaveAsRelocatedFileGeneration
    )
    case postWriteOutcomeIndeterminate
    case replacementStagingCleanupFailed(code: Int, after: FileAccessConnectorError)
    case replacementStagingCleanupFailedAfterVerifiedWrite(code: Int)
    case unexpectedFileSystemFailure(code: Int)
}

extension FileAccessConnectorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .selectedFolderMissing:
            return "Selected folder no longer exists. Choose an available Apple Files folder and try again."
        case let .selectedLocationIsNotDirectory(kind):
            return "Selected location is a \(kind.description), not a folder. Choose an Apple Files folder and try again."
        case .directChildResolutionFailed:
            return "File name does not resolve inside the selected folder. Choose the folder again and enter one File name."
        case let .targetAlreadyExists(kind):
            return "A \(kind.description) already uses that name. Choose another File name; existing content was not changed."
        case let .fileSystemInspectionFailed(code):
            return "File location could not be inspected (system code \(code)). Check Files access and try again."
        case let .stagingCreationFailed(code):
            return "Temporary File creation failed (system code \(code)). Check available storage and Files access, then try again."
        case let .stagingVerificationFailed(failure):
            return "Temporary File verification failed: \(failure.description). No destination File was claimed."
        case let .fileCoordinationFailed(code):
            return "Apple Files coordination failed (system code \(code)). Check provider availability and try again."
        case .fileCoordinationAccessorNotInvoked:
            return "Apple Files coordination did not provide the destination. Choose the folder again and try again."
        case let .exclusiveCreationFailed(code):
            return "Exclusive File creation failed (system code \(code)). Existing content was not overwritten. Choose another name or folder."
        case let .outputVerificationFailed(failure):
            return "Created File could not be verified: \(failure.description). Check Files before trying Save As again."
        case let .unsafeStagingCleanupRefused(kind, precedingError):
            return "Temporary File cleanup stopped because the staging item became a \(kind.description). Remove it in Files after resolving: \(precedingError.localizedDescription)"
        case let .stagingCleanupFailed(code, precedingError):
            return "Temporary File cleanup failed (system code \(code)) after: \(precedingError.localizedDescription)"
        case .selectedFileMissing:
            return "Selected File no longer exists. Choose an available File and try again."
        case let .selectedFileIsNotRegularFile(kind):
            return "Selected item is a \(kind.description), not a regular File. Choose a plain-text File."
        case .selectedFileIsPackage:
            return "Selected item is a File package, not a plain-text File. Choose a regular text File."
        case let .selectedFileHasUnsupportedContentType(identifier):
            return "Selected File has unsupported content type \(identifier). Choose a plain-text File or generic data File."
        case let .selectedFileMetadataInspectionFailed(code):
            return "Selected File type could not be inspected (system code \(code)). Check Files access and try again."
        case let .inputTooLarge(actualByteCount, maximumByteCount):
            return "Selected File is \(actualByteCount) bytes; MacPad Mobile supports at most \(maximumByteCount) bytes."
        case let .inputReadFailed(code):
            return "Selected File could not be read (system code \(code)). Check Files access and try again."
        case let .textDecodingFailed(error):
            return "Selected File is not supported plain text: \(error.localizedDescription)"
        case .selectedFileNameInvalid:
            return "Selected File has an unsupported name. Rename it in Files and try again."
        case let .fileIdentityInspectionFailed(code):
            return "File identity could not be inspected (system code \(code)). Check provider availability and try again."
        case .fileIdentityValueInvalid:
            return "File provider returned an invalid persistent identity. The File was not opened or changed."
        case let .bookmarkCreationFailed(code):
            return "Durable File access could not be saved (system code \(code)). Choose the File again and try again."
        case let .bookmarkResolutionFailed(code):
            return "Saved File access could not be resolved (system code \(code)). Locate the original File or use Save As."
        case let .bookmarkRefreshFailed(code):
            return "Updated File access could not be saved (system code \(code)). The original File was not changed."
        case .pendingBoundSaveBookmarkIsStale:
            return "Saved File access is stale. Locate the original File or use Save As before resolving its pending Save."
        case let .filePresenterNotRegistered(documentID):
            return "File presentation for Document \(documentID.rawValue) is not active. Return MacPad Mobile to the foreground and try again."
        case let .duplicateFilePresenterRegistration(documentID):
            return "File presentation received Document \(documentID.rawValue) more than once. No presenter was registered for that Document."
        case let .providerConflictVersionCountInvalid(count):
            return "File provider returned invalid unresolved-version count \(count). The File was not changed."
        case let .collisionClaimBookmarkResolutionFailed(documentID, code):
            return "File ownership for Document \(documentID.rawValue) could not be resolved (system code \(code)). No File was changed; retry Save As."
        case let .collisionClaimBookmarkIsStale(documentID):
            return "File ownership for Document \(documentID.rawValue) is stale. No File was changed; locate that File before retrying Save As."
        case let .recoveryClaimIsNotRecoveryItem(documentID):
            return "Recovery File ownership for Document \(documentID.rawValue) has an unsupported active-Tab claim. Refresh recovery data and try again."
        case let .activeLocatorBookmarkResolutionFailed(documentID, code):
            return "Open File location for Document \(documentID.rawValue) could not be resolved (system code \(code)). Locate that File before retrying Open."
        case let .activeLocatorBookmarkIsStale(documentID):
            return "Open File location for Document \(documentID.rawValue) is stale. Locate that File before retrying Open."
        case let .importedCopyCleanupJournal(error):
            return error.localizedDescription
        case let .importedCopyCleanupJournalCleanupFailed(journal, cleanup):
            return "\(journal.localizedDescription) Exact supplied-File cleanup also failed: \(cleanup.localizedDescription)."
        case .importedCopyCleanupCandidateChanged:
            return "Supplied File cleanup stopped because the Inbox item changed after External Open was queued. The replacement was not removed."
        case let .saveAsTargetCollision(claim):
            return "Save As target is already owned by Document \(claim.documentID.rawValue). Choose that Document or a different target."
        case .saveAsPlanRequiresAbsentTarget:
            return "Save As creation requires a plan for an absent target. Choose the destination again."
        case .saveAsPlanRequiresExistingTarget:
            return "Save As replacement requires a confirmed plan for an existing File. Choose the destination again."
        case let .saveAsDirectoryBookmarkResolutionFailed(code):
            return "Selected Save As folder could not be resolved (system code \(code)). Choose the folder again."
        case .saveAsDirectoryBookmarkIsStale:
            return "Selected Save As folder changed after selection. Choose the folder again before saving."
        case let .saveAsTargetAppeared(kind):
            return "A \(kind.description) appeared at the Save As target. Nothing was overwritten; review it and choose again."
        case .saveAsTargetChanged:
            return "Save As target changed after confirmation. Nothing was overwritten; review it and choose again."
        case let .saveAsTargetSnapshotReadFailed(code):
            return "Existing Save As target could not be read for confirmation (system code \(code)). Nothing was changed; check Files and try again."
        case let .saveAsTargetHasUnresolvedProviderVersions(count):
            return "Save As target has \(count) unresolved provider version(s). Nothing was overwritten; resolve them in Files and confirm replacement again."
        case .boundFileMissing:
            return "Original File no longer exists. Locate it or use Save As; unsaved edits were preserved."
        case let .boundFileIsNotRegularFile(kind):
            return "Original File became a \(kind.description). It was not changed; use Save As or restore the original File."
        case let .fileConflict(conflict):
            return conflict.description
        case let .replacementStagingCreationFailed(code):
            return "Replacement File preparation failed (system code \(code)). Check storage and Files access; the original File was not changed."
        case let .replacementFailed(code):
            return "Safe File replacement failed (system code \(code)). The original File was verified unchanged; try Save again or use Save As."
        case let .replacementOutcomeIndeterminate(code):
            return "Safe File replacement reported system code \(code), and the resulting bytes could not be classified. Check the File before resolving the preserved edit."
        case let .replacementReportedRelocatedItem(code, generation, preservedFileName):
            switch generation {
            case .original:
                return "Safe File replacement reported system code \(code) after relocating the verified original File. MacPad Mobile preserved it as \(preservedFileName.value) and retained the unsaved edit."
            case .intended:
                return "Safe File replacement reported system code \(code) after relocating the verified intended output. MacPad Mobile preserved it as \(preservedFileName.value) and retained the unsaved edit."
            case .unexpected:
                return "Safe File replacement reported system code \(code) after relocating an unexpected File version. MacPad Mobile preserved it as \(preservedFileName.value) and retained the unsaved edit."
            }
        case let .replacementReportedItemPreservationFailed(
            replacementCode,
            preservationCode,
            generation
        ):
            return "Safe File replacement reported system code \(replacementCode), and its temporary \(generation.description) item could not be made durable (system code \(preservationCode)). MacPad Mobile retained the unsaved edit; check Files before retrying."
        case .postWriteOutcomeIndeterminate:
            return "File changed during post-Save verification. Check the File before resolving the preserved edit."
        case let .replacementStagingCleanupFailed(code, precedingError):
            return "Replacement staging cleanup failed (system code \(code)) after: \(precedingError.localizedDescription)"
        case let .replacementStagingCleanupFailedAfterVerifiedWrite(code):
            return "File bytes were saved and verified, but replacement staging cleanup failed (system code \(code)). Check the File before resolving the preserved edit."
        case let .unexpectedFileSystemFailure(code):
            return "File creation failed unexpectedly (system code \(code)). Check Files access and try again."
        }
    }
}

private extension FileConflict {
    var description: String {
        switch self {
        case .contentChanged:
            return "Original File content changed outside MacPad Mobile. It was not overwritten; resolve the File Conflict explicitly."
        case .stableIdentityChanged:
            return "Original File identity changed outside MacPad Mobile. It was not overwritten; locate the original or use Save As."
        case .ambiguousLocatorChange:
            return "Original File moved without a stable provider identity. It was not overwritten; locate the original or use Save As."
        case let .unresolvedProviderVersions(count):
            return "Original File has \(count) unresolved provider conflict version(s). Resolve them in the provider before Save."
        }
    }
}

private extension SaveAsRelocatedFileGeneration {
    var description: String {
        switch self {
        case .original:
            return "verified original"
        case .intended:
            return "verified intended"
        case .unexpected:
            return "unexpected"
        }
    }
}

private extension ExistingFileSystemItemKind {
    var description: String {
        switch self {
        case .regularFile:
            return "File"
        case .directory:
            return "folder"
        case .symbolicLink:
            return "symbolic link"
        case .special:
            return "special filesystem item"
        }
    }
}

private extension FileVerificationFailure {
    var description: String {
        switch self {
        case let .itemIsNotRegularFile(kind):
            return "output became a \(kind.description)"
        case let .byteCountMismatch(expected, actual):
            return "expected \(expected) bytes but read \(actual)"
        case .contentMismatch:
            return "output bytes differ from the Document"
        case .digestMismatch:
            return "SHA-256 digest differs from the intended output"
        case let .readFailed(code):
            return "output could not be read (system code \(code))"
        case .digestConstructionFailed:
            return "SHA-256 digest validation failed"
        }
    }
}

public actor FileAccessConnector {
    typealias BookmarkCreator = @Sendable (URL) throws -> Data
    typealias BookmarkResolver = @Sendable (FileBookmark) throws -> ResolvedFileBookmark
    typealias FileIdentityReader = @Sendable (URL) throws -> FileIdentity?
    typealias FileReplacer = @Sendable (URL, URL, FileManager) throws -> URL?
    typealias SaveAsStagingWriter = @Sendable (Data, URL) throws -> Void
    typealias SaveAsStagingCleaner = @Sendable (URL, URL, FileManager) throws -> Void
    typealias SaveAsRecoveryAccessorSourceProvider = @Sendable (
        URL,
        FileManager
    ) throws -> URL
    typealias UnresolvedVersionCountReader = @Sendable (URL) -> Int
    typealias FileWritabilityReader = @Sendable (URL) throws -> Bool?
    typealias ImportedCopyRemover = @Sendable (URL, FileManager) throws -> Void
    typealias ImportedCopyCleanupJournalMetadataVerifier =
        ImportedCopyCleanupMetadataVerifier

    private struct Dependencies {
        let fileManager: FileManager
        var bookmarkCreator: BookmarkCreator
        var bookmarkResolver: BookmarkResolver
        var identityReader: FileIdentityReader
        var replacer: FileReplacer
        var saveAsStagingWriter: SaveAsStagingWriter
        var saveAsStagingCleaner: SaveAsStagingCleaner
        var saveAsRecoveryAccessorSourceProvider:
            SaveAsRecoveryAccessorSourceProvider
        var unresolvedVersionCountReader: UnresolvedVersionCountReader
        var fileWritabilityReader: FileWritabilityReader
        var applicationInboxURL: URL?
        var importedCopyCleanupJournalRootURL: URL
        var importedCopyRemover: ImportedCopyRemover
        var importedCopyCleanupJournalMetadataVerifier:
            ImportedCopyCleanupJournalMetadataVerifier

        static func production(
            fileManager: FileManager
        ) -> Dependencies {
            Dependencies(
                fileManager: fileManager,
                bookmarkCreator: createBookmarkData,
                bookmarkResolver: resolveBookmark,
                identityReader: readPersistentFileIdentity,
                replacer: replaceFileSafely,
                saveAsStagingWriter: writeSaveAsStagingData,
                saveAsStagingCleaner: cleanSaveAsStaging,
                saveAsRecoveryAccessorSourceProvider:
                    retainSaveAsRecoveryAccessorSourceURL,
                unresolvedVersionCountReader: readUnresolvedVersionCount,
                fileWritabilityReader: readFileWritability,
                applicationInboxURL: defaultApplicationInboxURL(
                    fileManager: fileManager
                ),
                importedCopyCleanupJournalRootURL:
                    defaultImportedCopyCleanupJournalRootURL(),
                importedCopyRemover: removeImportedCopy,
                importedCopyCleanupJournalMetadataVerifier:
                    verifyImportedCopyCleanupJournalMetadata
            )
        }
    }

    private let fileManager: FileManager
    private let bookmarkCreator: BookmarkCreator
    private let bookmarkResolver: BookmarkResolver
    private let identityReader: FileIdentityReader
    private let replacer: FileReplacer
    private let saveAsStagingWriter: SaveAsStagingWriter
    private let saveAsStagingCleaner: SaveAsStagingCleaner
    private let saveAsRecoveryAccessorSourceProvider: SaveAsRecoveryAccessorSourceProvider
    private let unresolvedVersionCountReader: UnresolvedVersionCountReader
    private let fileWritabilityReader: FileWritabilityReader
    private nonisolated let applicationInboxURL: URL?
    private let importedCopyCleanupJournalRootURL: URL
    private let importedCopyRemover: ImportedCopyRemover
    private let importedCopyCleanupJournalMetadataVerifier:
        ImportedCopyCleanupJournalMetadataVerifier
    public nonisolated let presentationChangeHints: AsyncStream<DocumentID>
    private let presentationHintRelay: PresentationHintRelay
    private var presentedFiles: [DocumentID: PresentedFile]
    private var importedCopyCleanupRecords: [
        ImportedCopyCleanupToken: ImportedCopyCleanupRecord
    ]

    public init(fileManager: FileManager) {
        self.init(dependencies: .production(fileManager: fileManager))
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator
    ) {
        var dependencies = Dependencies.production(fileManager: fileManager)
        dependencies.bookmarkCreator = bookmarkCreator
        self.init(dependencies: dependencies)
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator,
        bookmarkResolver: @escaping BookmarkResolver,
        identityReader: @escaping FileIdentityReader,
        replacer: @escaping FileReplacer
    ) {
        var dependencies = Dependencies.production(fileManager: fileManager)
        dependencies.bookmarkCreator = bookmarkCreator
        dependencies.bookmarkResolver = bookmarkResolver
        dependencies.identityReader = identityReader
        dependencies.replacer = replacer
        self.init(dependencies: dependencies)
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator,
        bookmarkResolver: @escaping BookmarkResolver,
        identityReader: @escaping FileIdentityReader,
        replacer: @escaping FileReplacer,
        saveAsRecoveryAccessorSourceProvider: @escaping SaveAsRecoveryAccessorSourceProvider
    ) {
        var dependencies = Dependencies.production(fileManager: fileManager)
        dependencies.bookmarkCreator = bookmarkCreator
        dependencies.bookmarkResolver = bookmarkResolver
        dependencies.identityReader = identityReader
        dependencies.replacer = replacer
        dependencies.saveAsRecoveryAccessorSourceProvider =
            saveAsRecoveryAccessorSourceProvider
        self.init(dependencies: dependencies)
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator,
        bookmarkResolver: @escaping BookmarkResolver,
        identityReader: @escaping FileIdentityReader,
        replacer: @escaping FileReplacer,
        saveAsRecoveryAccessorSourceProvider: @escaping SaveAsRecoveryAccessorSourceProvider,
        unresolvedVersionCountReader: @escaping UnresolvedVersionCountReader
    ) {
        var dependencies = Dependencies.production(fileManager: fileManager)
        dependencies.bookmarkCreator = bookmarkCreator
        dependencies.bookmarkResolver = bookmarkResolver
        dependencies.identityReader = identityReader
        dependencies.replacer = replacer
        dependencies.saveAsRecoveryAccessorSourceProvider =
            saveAsRecoveryAccessorSourceProvider
        dependencies.unresolvedVersionCountReader =
            unresolvedVersionCountReader
        self.init(dependencies: dependencies)
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator,
        saveAsStagingWriter: @escaping SaveAsStagingWriter,
        saveAsStagingCleaner: @escaping SaveAsStagingCleaner
    ) {
        var dependencies = Dependencies.production(fileManager: fileManager)
        dependencies.bookmarkCreator = bookmarkCreator
        dependencies.saveAsStagingWriter = saveAsStagingWriter
        dependencies.saveAsStagingCleaner = saveAsStagingCleaner
        self.init(dependencies: dependencies)
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator,
        bookmarkResolver: @escaping BookmarkResolver,
        identityReader: @escaping FileIdentityReader,
        replacer: @escaping FileReplacer,
        fileWritabilityReader: @escaping FileWritabilityReader,
        applicationInboxURL: URL?
    ) {
        var dependencies = Dependencies.production(fileManager: fileManager)
        dependencies.bookmarkCreator = bookmarkCreator
        dependencies.bookmarkResolver = bookmarkResolver
        dependencies.identityReader = identityReader
        dependencies.replacer = replacer
        dependencies.fileWritabilityReader = fileWritabilityReader
        dependencies.applicationInboxURL = applicationInboxURL
        dependencies.importedCopyCleanupJournalRootURL =
            injectedImportedCopyCleanupJournalRootURL(
                applicationInboxURL: applicationInboxURL,
                fileManager: fileManager
            )
        self.init(dependencies: dependencies)
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator,
        bookmarkResolver: @escaping BookmarkResolver,
        identityReader: @escaping FileIdentityReader,
        replacer: @escaping FileReplacer,
        fileWritabilityReader: @escaping FileWritabilityReader,
        applicationInboxURL: URL,
        importedCopyCleanupJournalRootURL: URL,
        importedCopyRemover: @escaping ImportedCopyRemover,
        importedCopyCleanupJournalMetadataVerifier:
            @escaping ImportedCopyCleanupJournalMetadataVerifier
    ) {
        var dependencies = Dependencies.production(fileManager: fileManager)
        dependencies.bookmarkCreator = bookmarkCreator
        dependencies.bookmarkResolver = bookmarkResolver
        dependencies.identityReader = identityReader
        dependencies.replacer = replacer
        dependencies.fileWritabilityReader = fileWritabilityReader
        dependencies.applicationInboxURL = applicationInboxURL
        dependencies.importedCopyCleanupJournalRootURL =
            importedCopyCleanupJournalRootURL
        dependencies.importedCopyRemover = importedCopyRemover
        dependencies.importedCopyCleanupJournalMetadataVerifier =
            importedCopyCleanupJournalMetadataVerifier
        self.init(dependencies: dependencies)
    }

    private init(dependencies: Dependencies) {
        let presentationChanges = makePresentationChangeStream()
        self.fileManager = dependencies.fileManager
        self.bookmarkCreator = dependencies.bookmarkCreator
        self.bookmarkResolver = dependencies.bookmarkResolver
        self.identityReader = dependencies.identityReader
        self.replacer = dependencies.replacer
        self.saveAsStagingWriter = dependencies.saveAsStagingWriter
        self.saveAsStagingCleaner = dependencies.saveAsStagingCleaner
        self.saveAsRecoveryAccessorSourceProvider =
            dependencies.saveAsRecoveryAccessorSourceProvider
        self.unresolvedVersionCountReader =
            dependencies.unresolvedVersionCountReader
        self.fileWritabilityReader = dependencies.fileWritabilityReader
        self.applicationInboxURL = dependencies.applicationInboxURL
        self.importedCopyCleanupJournalRootURL =
            dependencies.importedCopyCleanupJournalRootURL
        self.importedCopyRemover = dependencies.importedCopyRemover
        self.importedCopyCleanupJournalMetadataVerifier =
            dependencies.importedCopyCleanupJournalMetadataVerifier
        self.presentationChangeHints = presentationChanges.stream
        self.presentationHintRelay = presentationChanges.relay
        self.presentedFiles = [:]
        self.importedCopyCleanupRecords = [:]
    }

    deinit {
        for presenter in presentedFiles.values {
            presenter.deactivate()
            presentationHintRelay.deactivate(
                documentID: presenter.documentID,
                generation: presenter.generation
            )
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presentationHintRelay.finish()
    }

    public func preflightSaveAsTarget(
        in selectedDirectoryURL: URL,
        fileName: ValidatedFileName,
        currentDocumentID: DocumentID,
        collisionClaims: [FileCollisionClaim]
    ) throws -> SaveAsTargetPreflight {
        let didStartSecurityScope = selectedDirectoryURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedDirectoryURL.stopAccessingSecurityScopedResource()
            }
        }

        let directoryKind = try inspectNode(
            at: selectedDirectoryURL,
            fileManager: fileManager
        )
        switch directoryKind {
        case .missing:
            throw FileAccessConnectorError.selectedFolderMissing
        case .directory:
            break
        case let .existing(kind):
            throw FileAccessConnectorError.selectedLocationIsNotDirectory(kind)
        }

        let targetURL = selectedDirectoryURL.appendingPathComponent(
            fileName.value,
            isDirectory: false
        )
        guard targetURL.deletingLastPathComponent().standardizedFileURL
            == selectedDirectoryURL.standardizedFileURL else {
            throw FileAccessConnectorError.directChildResolutionFailed
        }
        let expectation: SaveAsTargetExpectation
        switch try inspectNode(at: targetURL, fileManager: fileManager) {
        case .missing:
            expectation = .absent
        case .directory:
            if try isFilePackage(at: targetURL) {
                throw FileAccessConnectorError.selectedFileIsPackage
            }
            throw FileAccessConnectorError.targetAlreadyExists(.directory)
        case .existing(.regularFile):
            expectation = .existing(
                try coordinatedReadSaveAsTargetSnapshot(
                    at: targetURL,
                    fileManager: fileManager,
                    identityReader: identityReader
                )
            )
        case let .existing(kind):
            throw FileAccessConnectorError.targetAlreadyExists(kind)
        }

        let directoryBookmark: FileBookmark
        do {
            directoryBookmark = try FileBookmark(
                data: bookmarkCreator(selectedDirectoryURL)
            )
        } catch {
            throw FileAccessConnectorError.bookmarkCreationFailed(
                code: (error as NSError).code
            )
        }
        let plan = SaveAsTargetPlan(
            directoryBookmark: directoryBookmark,
            fileName: fileName,
            expectation: expectation
        )
        let matchingClaims = try matchingSaveAsCollisionClaims(
            targetURL: targetURL,
            targetIdentity: expectation.snapshotIdentity,
            claims: collisionClaims,
            bookmarkResolver: bookmarkResolver
        )
        if let blockingClaim = matchingClaims.first(where: { claim in
            !claim.isCurrentActiveFile(documentID: currentDocumentID)
        }) {
            throw FileAccessConnectorError.saveAsTargetCollision(blockingClaim)
        }
        if matchingClaims.contains(where: { claim in
            claim.isCurrentActiveFile(documentID: currentDocumentID)
        }) {
            return .currentFile(plan)
        }
        switch expectation {
        case .absent:
            return .ready(plan)
        case .existing:
            return .replacementRequired(plan)
        }
    }

    public func createSaveAsTarget(
        plan: SaveAsTargetPlan,
        encodedFile: EncodedTextFile,
        currentDocumentID: DocumentID,
        collisionClaims: [FileCollisionClaim]
    ) throws -> SaveAsTargetCommitOutcome {
        guard case .absent = plan.expectation else {
            throw FileAccessConnectorError.saveAsPlanRequiresAbsentTarget
        }
        let resolvedDirectory = try resolveSaveAsDirectory(
            bookmark: plan.directoryBookmark,
            bookmarkResolver: bookmarkResolver
        )
        let directoryURL = resolvedDirectory.url
        let didStartSecurityScope = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }
        try validateSaveAsDirectory(at: directoryURL, fileManager: fileManager)
        let targetURL = try makeDirectSaveAsTargetURL(
            directoryURL: directoryURL,
            fileName: plan.fileName
        )
        let stagingLocation: ReplacementStagingLocation
        do {
            stagingLocation = try makeReplacementStagingLocation(
                for: targetURL,
                fileManager: fileManager
            )
        } catch {
            throw FileAccessConnectorError.replacementStagingCreationFailed(
                code: (error as NSError).code
            )
        }
        do {
            try saveAsStagingWriter(encodedFile.data, stagingLocation.fileURL)
            try verifyFile(
                at: stagingLocation.fileURL,
                expectedData: encodedFile.data,
                expectedDigest: encodedFile.digest,
                fileManager: fileManager,
                errorContext: .staging
            )
        } catch {
            let stagingError: FileAccessConnectorError
            if let connectorError = error as? FileAccessConnectorError {
                stagingError = connectorError
            } else {
                stagingError = .replacementStagingCreationFailed(
                    code: (error as NSError).code
                )
            }
            let failure: Result<FileSaveOutcome, FileAccessConnectorError> = .failure(
                stagingError
            )
            _ = try finishSaveAsStagingLocation(
                stagingLocation,
                operationResult: failure,
                cleanupDisposition: .cleanupAllowed,
                fileManager: fileManager,
                stagingCleaner: saveAsStagingCleaner
            )
            throw stagingError
        }

        let operationResult: Result<FileSaveOutcome, FileAccessConnectorError>
        do {
            operationResult = .success(
                try coordinatedCreateSaveAsTarget(
                    stagingURL: stagingLocation.fileURL,
                    targetURL: targetURL,
                    fileName: plan.fileName,
                    encodedFile: encodedFile,
                    currentDocumentID: currentDocumentID,
                    collisionClaims: collisionClaims,
                    fileManager: fileManager,
                    bookmarkCreator: bookmarkCreator,
                    bookmarkResolver: bookmarkResolver,
                    identityReader: identityReader
                )
            )
        } catch let error as FileAccessConnectorError {
            operationResult = .failure(error)
        } catch {
            operationResult = .failure(
                .unexpectedFileSystemFailure(code: (error as NSError).code)
            )
        }
        return try finishSaveAsStagingLocation(
            stagingLocation,
            operationResult: operationResult,
            cleanupDisposition: .cleanupAllowed,
            fileManager: fileManager,
            stagingCleaner: saveAsStagingCleaner
        )
    }

    public func replaceSaveAsTarget(
        plan: SaveAsTargetPlan,
        encodedFile: EncodedTextFile,
        currentDocumentID: DocumentID,
        collisionClaims: [FileCollisionClaim]
    ) throws -> SaveAsTargetCommitOutcome {
        guard case let .existing(expectedSnapshot) = plan.expectation else {
            throw FileAccessConnectorError.saveAsPlanRequiresExistingTarget
        }
        let resolvedDirectory = try resolveSaveAsDirectory(
            bookmark: plan.directoryBookmark,
            bookmarkResolver: bookmarkResolver
        )
        let directoryURL = resolvedDirectory.url
        let didStartSecurityScope = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }
        try validateSaveAsDirectory(at: directoryURL, fileManager: fileManager)
        let targetURL = try makeDirectSaveAsTargetURL(
            directoryURL: directoryURL,
            fileName: plan.fileName
        )
        let stagingLocation: ReplacementStagingLocation
        do {
            stagingLocation = try makeReplacementStagingLocation(
                for: targetURL,
                fileManager: fileManager
            )
        } catch {
            throw FileAccessConnectorError.replacementStagingCreationFailed(
                code: (error as NSError).code
            )
        }
        do {
            try saveAsStagingWriter(encodedFile.data, stagingLocation.fileURL)
            try verifyFile(
                at: stagingLocation.fileURL,
                expectedData: encodedFile.data,
                expectedDigest: encodedFile.digest,
                fileManager: fileManager,
                errorContext: .staging
            )
        } catch {
            let stagingError: FileAccessConnectorError
            if let connectorError = error as? FileAccessConnectorError {
                stagingError = connectorError
            } else {
                stagingError = .replacementStagingCreationFailed(
                    code: (error as NSError).code
                )
            }
            let failure: Result<FileSaveOutcome, FileAccessConnectorError> = .failure(
                stagingError
            )
            _ = try finishSaveAsStagingLocation(
                stagingLocation,
                operationResult: failure,
                cleanupDisposition: .cleanupAllowed,
                fileManager: fileManager,
                stagingCleaner: saveAsStagingCleaner
            )
            throw stagingError
        }

        var replacementResult: SaveAsReplacementOperationResult
        do {
            replacementResult = try coordinatedReplaceSaveAsTarget(
                stagingURL: stagingLocation.fileURL,
                targetURL: targetURL,
                fileName: plan.fileName,
                expectedSnapshot: expectedSnapshot,
                encodedFile: encodedFile,
                currentDocumentID: currentDocumentID,
                collisionClaims: collisionClaims,
                fileManager: fileManager,
                bookmarkCreator: bookmarkCreator,
                bookmarkResolver: bookmarkResolver,
                identityReader: identityReader,
                replacer: replacer
            )
        } catch let error as FileAccessConnectorError {
            replacementResult = SaveAsReplacementOperationResult(
                result: .failure(error),
                cleanupDisposition: .cleanupAllowed,
                recoveryRequest: nil
            )
        } catch {
            replacementResult = SaveAsReplacementOperationResult(
                result: .failure(
                    .unexpectedFileSystemFailure(code: (error as NSError).code)
                ),
                cleanupDisposition: .cleanupAllowed,
                recoveryRequest: nil
            )
        }
        if let recoveryRequest = replacementResult.recoveryRequest {
            replacementResult = recoverReportedSaveAsItemDurably(
                request: recoveryRequest,
                targetURL: targetURL,
                targetFileName: plan.fileName,
                encodedFile: encodedFile,
                collisionClaims: collisionClaims,
                fileManager: fileManager,
                bookmarkResolver: bookmarkResolver,
                identityReader: identityReader,
                saveAsRecoveryAccessorSourceProvider: saveAsRecoveryAccessorSourceProvider
            )
        }
        return try finishSaveAsStagingLocation(
            stagingLocation,
            operationResult: replacementResult.result,
            cleanupDisposition: replacementResult.cleanupDisposition,
            fileManager: fileManager,
            stagingCleaner: saveAsStagingCleaner
        )
    }

    public func createFile(
        in folderURL: URL,
        fileName: ValidatedFileName,
        encodedFile: EncodedTextFile
    ) throws -> FileCreationOutcome {
        let didStartSecurityScope = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let folderKind = try inspectNode(at: folderURL, fileManager: fileManager)
        switch folderKind {
        case .missing:
            throw FileAccessConnectorError.selectedFolderMissing
        case .directory:
            break
        case let .existing(kind):
            throw FileAccessConnectorError.selectedLocationIsNotDirectory(kind)
        }

        let targetURL = folderURL.appendingPathComponent(fileName.value, isDirectory: false)
        guard targetURL.deletingLastPathComponent().standardizedFileURL == folderURL.standardizedFileURL else {
            throw FileAccessConnectorError.directChildResolutionFailed
        }
        try requireAbsentTarget(at: targetURL, fileManager: fileManager)

        let stagingURL = folderURL.appendingPathComponent(
            ".phonepad-create-\(UUID().uuidString).staging",
            isDirectory: false
        )
        do {
            try encodedFile.data.write(to: stagingURL, options: .withoutOverwriting)
        } catch {
            let typedError = FileAccessConnectorError.stagingCreationFailed(
                code: (error as NSError).code
            )
            try removeStagingIfPresent(
                at: stagingURL,
                fileManager: fileManager,
                precedingError: typedError,
                beforeUnlink: {}
            )
            throw typedError
        }

        do {
            try verifyFile(
                at: stagingURL,
                expectedData: encodedFile.data,
                expectedDigest: encodedFile.digest,
                fileManager: fileManager,
                errorContext: .staging
            )
            return try coordinatedCreate(
                stagingURL: stagingURL,
                targetURL: targetURL,
                fileName: fileName,
                encodedFile: encodedFile
            )
        } catch let precedingError as FileAccessConnectorError {
            try removeStagingIfPresent(
                at: stagingURL,
                fileManager: fileManager,
                precedingError: precedingError,
                beforeUnlink: {}
            )
            throw precedingError
        } catch {
            let typedError = FileAccessConnectorError.unexpectedFileSystemFailure(
                code: (error as NSError).code
            )
            try removeStagingIfPresent(
                at: stagingURL,
                fileManager: fileManager,
                precedingError: typedError,
                beforeUnlink: {}
            )
            throw typedError
        }
    }

    public func openTextFile(
        at selectedURL: URL,
        documentID: DocumentID
    ) throws -> PresentedTextFileSnapshot {
        let didStartSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        try requireSelectedOpenCandidate(at: selectedURL, fileManager: fileManager)
        let presenter = registerPresenter(
            documentID: documentID,
            url: selectedURL
        )
        var shouldRetainPresenter = false
        defer {
            if !shouldRetainPresenter {
                removePresenter(documentID: documentID)
            }
        }

        let fileManagerReference = FileManagerReference(fileManager: fileManager)
        let bookmarkCreator = bookmarkCreator
        let identityReader = identityReader
        let unresolvedVersionCountReader = unresolvedVersionCountReader
        let snapshot = try presenter.performSynchronousAccess {
            let snapshot = try coordinatePresentedTextFileRead(
                at: selectedURL,
                presenter: presenter,
                fileManager: fileManagerReference.fileManager,
                bookmarkCreator: bookmarkCreator,
                identityReader: identityReader,
                unresolvedVersionCountReader: unresolvedVersionCountReader
            )
            presenter.updatePresentedItemURL(snapshot.openedFile.binding.locatorURL)
            return snapshot
        }
        shouldRetainPresenter = true
        return snapshot
    }

    public func openTextFile(
        at selectedURL: URL,
        documentID: DocumentID,
        accessIntent: FileOpenAccessIntent
    ) throws -> OpenTextFileOutcome {
        let didStartSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let cleanupToken: ImportedCopyCleanupToken?
        switch accessIntent {
        case .inPlace:
            cleanupToken = nil
        case .copyRequired:
            cleanupToken = try prepareImportedCopyCleanupCapability(
                at: selectedURL,
                documentID: documentID
            )
        }
        return try openTextFileWithCleanupCapability(
            at: selectedURL,
            documentID: documentID,
            accessIntent: accessIntent,
            cleanupToken: cleanupToken
        )
    }

    func openTextFile(
        at selectedURL: URL,
        documentID: DocumentID,
        capturedImportedCopyCleanupToken cleanupToken:
            ImportedCopyCleanupToken
    ) throws -> OpenTextFileOutcome {
        let didStartSecurityScope = selectedURL
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }
        try requireImportedCopyCleanupCapability(
            token: cleanupToken,
            selectedURL: selectedURL,
            documentID: documentID
        )
        return try openTextFileWithCleanupCapability(
            at: selectedURL,
            documentID: documentID,
            accessIntent: .copyRequired,
            cleanupToken: cleanupToken
        )
    }

    private func openTextFileWithCleanupCapability(
        at selectedURL: URL,
        documentID: DocumentID,
        accessIntent: FileOpenAccessIntent,
        cleanupToken: ImportedCopyCleanupToken?
    ) throws -> OpenTextFileOutcome {
        let presenter: PresentedFile
        do {
            try requireSelectedOpenCandidate(
                at: selectedURL,
                fileManager: fileManager
            )
            presenter = registerPresenter(
                documentID: documentID,
                url: selectedURL
            )
        } catch let error as FileAccessConnectorError {
            return try rejectedTextFileOpen(
                error: error,
                cleanupToken: cleanupToken
            )
        }
        var shouldRetainPresenter = false
        defer {
            if !shouldRetainPresenter {
                removePresenter(documentID: documentID)
            }
        }

        let fileManagerReference = FileManagerReference(fileManager: fileManager)
        let bookmarkCreator = bookmarkCreator
        let bookmarkResolver = bookmarkResolver
        let identityReader = identityReader
        let unresolvedVersionCountReader = unresolvedVersionCountReader
        let fileWritabilityReader = fileWritabilityReader
        let coordinatedOutcome: TypedPresentedTextFileOutcome
        do {
            coordinatedOutcome = try presenter.performSynchronousAccess {
                try coordinateTypedPresentedTextFileRead(
                    at: selectedURL,
                    accessIntent: accessIntent,
                    presenter: presenter,
                    fileManager: fileManagerReference.fileManager,
                    bookmarkCreator: bookmarkCreator,
                    bookmarkResolver: bookmarkResolver,
                    identityReader: identityReader,
                    unresolvedVersionCountReader: unresolvedVersionCountReader,
                    fileWritabilityReader: fileWritabilityReader
                )
            }
        } catch let error as FileAccessConnectorError {
            return try rejectedTextFileOpen(
                error: error,
                cleanupToken: cleanupToken
            )
        }
        switch coordinatedOutcome {
        case let .bound(snapshot):
            presenter.updatePresentedItemURL(
                snapshot.openedFile.binding.locatorURL
            )
            shouldRetainPresenter = true
            return .bound(snapshot)
        case let .detached(snapshot, reason):
            try markImportedCopyAwaitingProtection(token: cleanupToken)
            return .detached(
                OpenedDetachedTextFile(
                    snapshot: snapshot,
                    reason: reason,
                    importedCopyCleanupToken: cleanupToken
                )
            )
        case let .rejected(error):
            return try rejectedTextFileOpen(
                error: error,
                cleanupToken: cleanupToken
            )
        }
    }

    private func requireImportedCopyCleanupCapability(
        token: ImportedCopyCleanupToken,
        selectedURL: URL,
        documentID: DocumentID
    ) throws {
        if importedCopyCleanupRecords[token] == nil {
            importedCopyCleanupRecords = try readImportedCopyCleanupRecords(
                rootURL: importedCopyCleanupJournalRootURL,
                inboxURL: applicationInboxURL,
                fileManager: fileManager,
                metadataVerifier:
                    importedCopyCleanupJournalMetadataVerifier
            )
        }
        guard let record = importedCopyCleanupRecords[token],
              record.documentID == documentID,
              record.url.standardizedFileURL
                == selectedURL.standardizedFileURL else {
            throw FileAccessConnectorError
                .importedCopyCleanupCandidateChanged
        }
        guard case .exact = inspectImportedCopyRecord(record) else {
            throw FileAccessConnectorError
                .importedCopyCleanupCandidateChanged
        }
    }

    public func captureImportedCopyCleanup(
        at selectedURL: URL,
        documentID: DocumentID
    ) throws -> ImportedCopyCleanupToken? {
        let didStartSecurityScope = selectedURL
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try prepareImportedCopyCleanupCapability(
            at: selectedURL,
            documentID: documentID
        )
    }

    nonisolated func inspectImportedCopyCleanupCandidate(
        at selectedURL: URL
    ) throws(FileAccessConnectorError) -> ImportedCopyCleanupCandidate? {
        let inspectionFileManager = FileManager()
        let record = try makeImportedCopyCleanupRecord(
            url: selectedURL,
            inboxURL: applicationInboxURL,
            documentID: DocumentID(rawValue: UUID()),
            phase: .cleanupAuthorized,
            fileManager: inspectionFileManager
        )
        return record.map(importedCopyCleanupCandidate)
    }

    func captureImportedCopyCleanup(
        at selectedURL: URL,
        documentID: DocumentID,
        matching candidate: ImportedCopyCleanupCandidate
    ) throws -> ImportedCopyCleanupToken {
        let didStartSecurityScope = selectedURL
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }
        guard let record = try makeImportedCopyCleanupRecord(
            url: selectedURL,
            inboxURL: applicationInboxURL,
            documentID: documentID,
            phase: .cleanupAuthorized,
            fileManager: fileManager
        ), importedCopyCleanupCandidate(record) == candidate else {
            throw FileAccessConnectorError
                .importedCopyCleanupCandidateChanged
        }
        return try persistImportedCopyCleanupCapability(record: record)
    }

    private func prepareImportedCopyCleanupCapability(
        at selectedURL: URL,
        documentID: DocumentID
    ) throws -> ImportedCopyCleanupToken? {
        let record = try makeImportedCopyCleanupRecord(
            url: selectedURL,
            inboxURL: applicationInboxURL,
            documentID: documentID,
            phase: .cleanupAuthorized,
            fileManager: fileManager
        )
        guard let record else {
            return nil
        }
        return try persistImportedCopyCleanupCapability(record: record)
    }

    private func persistImportedCopyCleanupCapability(
        record: ImportedCopyCleanupRecord
    ) throws -> ImportedCopyCleanupToken {
        let token = ImportedCopyCleanupToken(rawValue: UUID())
        do {
            var records = try readImportedCopyCleanupRecords(
                rootURL: importedCopyCleanupJournalRootURL,
                inboxURL: applicationInboxURL,
                fileManager: fileManager,
                metadataVerifier:
                    importedCopyCleanupJournalMetadataVerifier
            )
            records[token] = record
            try persistImportedCopyCleanupRecords(
                records,
                rootURL: importedCopyCleanupJournalRootURL,
                fileManager: fileManager,
                metadataVerifier:
                    importedCopyCleanupJournalMetadataVerifier
            )
            importedCopyCleanupRecords = records
            return token
        } catch let journalError as ImportedCopyCleanupJournalError {
            let cleanup = cleanupImportedCopyRecord(record)
            switch cleanup {
            case .removed, .alreadyAbsent:
                throw FileAccessConnectorError.importedCopyCleanupJournal(
                    journalError
                )
            case let .residual(failure):
                throw FileAccessConnectorError
                    .importedCopyCleanupJournalCleanupFailed(
                        journalError,
                        failure
                    )
            }
        }
    }

    private func rejectedTextFileOpen(
        error: FileAccessConnectorError,
        cleanupToken: ImportedCopyCleanupToken?
    ) throws -> OpenTextFileOutcome {
        let authorizedError = try authorizeRejectedImportedCopy(
            token: cleanupToken,
            rejection: error
        )
        return .rejected(
            RejectedTextFileOpen(
                error: authorizedError,
                importedCopyCleanupToken: cleanupToken
            )
        )
    }

    private func authorizeRejectedImportedCopy(
        token: ImportedCopyCleanupToken?,
        rejection: FileAccessConnectorError
    ) throws -> FileAccessConnectorError {
        guard let token else {
            return rejection
        }
        do {
            try authorizeImportedCopyCleanup(token: token)
            return rejection
        } catch let journalError as ImportedCopyCleanupJournalError {
            guard let record = importedCopyCleanupRecords[token] else {
                return FileAccessConnectorError.importedCopyCleanupJournal(
                    journalError
                )
            }
            let cleanup = cleanupImportedCopyRecord(record)
            switch cleanup {
            case .removed, .alreadyAbsent:
                importedCopyCleanupRecords.removeValue(forKey: token)
                return FileAccessConnectorError.importedCopyCleanupJournal(
                    journalError
                )
            case let .residual(failure):
                return FileAccessConnectorError
                    .importedCopyCleanupJournalCleanupFailed(
                        journalError,
                        failure
                    )
            }
        }
    }

    private func authorizeImportedCopyCleanup(
        token: ImportedCopyCleanupToken
    ) throws {
        if importedCopyCleanupRecords[token] == nil {
            importedCopyCleanupRecords = try readImportedCopyCleanupRecords(
                rootURL: importedCopyCleanupJournalRootURL,
                inboxURL: applicationInboxURL,
                fileManager: fileManager,
                metadataVerifier:
                    importedCopyCleanupJournalMetadataVerifier
            )
        }
        guard let record = importedCopyCleanupRecords[token] else {
            return
        }
        guard record.phase == .awaitingProtection else {
            return
        }
        let authorizedRecord = importedCopyCleanupRecord(
            record,
            phase: .cleanupAuthorized
        )
        var authorizedRecords = importedCopyCleanupRecords
        authorizedRecords[token] = authorizedRecord
        try persistImportedCopyCleanupRecords(
            authorizedRecords,
            rootURL: importedCopyCleanupJournalRootURL,
            fileManager: fileManager,
            metadataVerifier: importedCopyCleanupJournalMetadataVerifier
        )
        importedCopyCleanupRecords = authorizedRecords
    }

    private func markImportedCopyAwaitingProtection(
        token: ImportedCopyCleanupToken?
    ) throws {
        guard let token else {
            return
        }
        if importedCopyCleanupRecords[token] == nil {
            importedCopyCleanupRecords = try readImportedCopyCleanupRecords(
                rootURL: importedCopyCleanupJournalRootURL,
                inboxURL: applicationInboxURL,
                fileManager: fileManager,
                metadataVerifier:
                    importedCopyCleanupJournalMetadataVerifier
            )
        }
        guard let record = importedCopyCleanupRecords[token] else {
            throw ImportedCopyCleanupJournalError.invalidEntry
        }
        guard record.phase == .cleanupAuthorized else {
            return
        }
        let awaitingRecord = importedCopyCleanupRecord(
            record,
            phase: .awaitingProtection
        )
        var awaitingRecords = importedCopyCleanupRecords
        awaitingRecords[token] = awaitingRecord
        try persistImportedCopyCleanupRecords(
            awaitingRecords,
            rootURL: importedCopyCleanupJournalRootURL,
            fileManager: fileManager,
            metadataVerifier: importedCopyCleanupJournalMetadataVerifier
        )
        importedCopyCleanupRecords = awaitingRecords
    }

    func reassignImportedCopyCleanup(
        tokens: [ImportedCopyCleanupToken],
        documentID: DocumentID
    ) throws {
        guard !tokens.isEmpty else {
            return
        }
        importedCopyCleanupRecords = try readImportedCopyCleanupRecords(
            rootURL: importedCopyCleanupJournalRootURL,
            inboxURL: applicationInboxURL,
            fileManager: fileManager,
            metadataVerifier: importedCopyCleanupJournalMetadataVerifier
        )
        var reassignedRecords = importedCopyCleanupRecords
        for token in tokens {
            guard let record = reassignedRecords[token] else {
                throw ImportedCopyCleanupJournalError.invalidEntry
            }
            reassignedRecords[token] = importedCopyCleanupRecord(
                record,
                documentID: documentID
            )
        }
        try persistImportedCopyCleanupRecords(
            reassignedRecords,
            rootURL: importedCopyCleanupJournalRootURL,
            fileManager: fileManager,
            metadataVerifier: importedCopyCleanupJournalMetadataVerifier
        )
        importedCopyCleanupRecords = reassignedRecords
    }

    func abandonImportedCopyCleanup(
        tokens: [ImportedCopyCleanupToken]
    ) throws {
        guard !tokens.isEmpty else {
            return
        }
        importedCopyCleanupRecords = try readImportedCopyCleanupRecords(
            rootURL: importedCopyCleanupJournalRootURL,
            inboxURL: applicationInboxURL,
            fileManager: fileManager,
            metadataVerifier: importedCopyCleanupJournalMetadataVerifier
        )
        var remainingRecords = importedCopyCleanupRecords
        for token in tokens {
            guard remainingRecords.removeValue(forKey: token) != nil else {
                throw ImportedCopyCleanupFailure.unknownToken
            }
        }
        try persistImportedCopyCleanupRecords(
            remainingRecords,
            rootURL: importedCopyCleanupJournalRootURL,
            fileManager: fileManager,
            metadataVerifier: importedCopyCleanupJournalMetadataVerifier
        )
        importedCopyCleanupRecords = remainingRecords
    }

    public func matchActiveOpenLocators(
        selectedURL: URL,
        claims: [ActiveFileOpenLocatorClaim]
    ) throws -> ActiveFileOpenLocatorMatch {
        let didStartSecurityScope = selectedURL
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let selectedLocator = selectedURL.standardizedFileURL
        var matchingDocumentIDs: Set<DocumentID> = []
        var matchingEphemeralDocumentIDs: Set<DocumentID> = []
        for claim in claims {
            let documentID: DocumentID
            let locator: URL
            switch claim {
            case let .bound(claimedDocumentID, binding):
                documentID = claimedDocumentID
                if binding.locatorURL.standardizedFileURL == selectedLocator {
                    locator = binding.locatorURL
                } else {
                    locator = try resolveActiveOpenLocator(
                        bookmark: binding.bookmark,
                        documentID: documentID,
                        bookmarkResolver: bookmarkResolver
                    )
                }
            case let .ephemeral(claimedDocumentID, locatorURL):
                documentID = claimedDocumentID
                locator = locatorURL
                if locator.standardizedFileURL == selectedLocator {
                    matchingEphemeralDocumentIDs.insert(documentID)
                }
            case let .detached(claimedDocumentID, reference):
                documentID = claimedDocumentID
                locator = try resolveActiveOpenLocator(
                    bookmark: reference.bookmark,
                    documentID: documentID,
                    bookmarkResolver: bookmarkResolver
                )
            }
            if locator.standardizedFileURL == selectedLocator {
                matchingDocumentIDs.insert(documentID)
            }
        }
        let orderedMatches = matchingDocumentIDs.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        guard !orderedMatches.isEmpty else {
            return .none
        }
        if orderedMatches.count == 1 {
            switch try inspectSelectedFileNodePresence(
                at: selectedURL,
                fileManager: fileManager
            ) {
            case .missing:
                return .missingItem(orderedMatches[0])
            case .present:
                return .requiresAuthoritativeRead(orderedMatches)
            }
        }
        let matchesOnlyEphemeralDocuments = matchingDocumentIDs
            == matchingEphemeralDocumentIDs
        if matchesOnlyEphemeralDocuments,
           try inspectSelectedFileNodePresence(
               at: selectedURL,
               fileManager: fileManager
           ) == .present {
            return .requiresAuthoritativeRead(orderedMatches)
        }
        return .ambiguous(orderedMatches)
    }

    func selectedFileNodePresence(
        at selectedURL: URL
    ) throws -> SelectedFileNodePresence {
        let didStartSecurityScope = selectedURL
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try inspectSelectedFileNodePresence(
            at: selectedURL,
            fileManager: fileManager
        )
    }

    public func matchRecoveryFileClaims(
        candidate: FileOpenCandidate,
        claims: [FileCollisionClaim]
    ) throws -> RecoveryFileOpenCollision {
        let resolvedClaims = try claims.map { claim in
            try resolveRecoveryFileClaim(
                claim,
                bookmarkResolver: bookmarkResolver
            )
        }
        return PhonePadCore.recoveryFileOpenCollision(
            candidate: candidate,
            claims: resolvedClaims
        )
    }

    func matchingFileCollisionClaims(
        candidate: FileOpenCandidate,
        claims: [FileCollisionClaim]
    ) throws -> [FileCollisionClaim] {
        try matchingSaveAsCollisionClaims(
            targetURL: candidate.locatorURL,
            targetIdentity: candidate.identity,
            claims: claims,
            bookmarkResolver: bookmarkResolver
        )
    }

    func observePendingBoundSaveDestination(
        fileReference: RecoveryFileReference
    ) throws -> PendingSaveDestinationObservation {
        let resolvedBookmark: ResolvedFileBookmark
        do {
            resolvedBookmark = try bookmarkResolver(fileReference.bookmark)
        } catch {
            throw FileAccessConnectorError.bookmarkResolutionFailed(
                code: (error as NSError).code
            )
        }
        guard !resolvedBookmark.isStale else {
            throw FileAccessConnectorError.pendingBoundSaveBookmarkIsStale
        }
        let url = resolvedBookmark.url
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try observePendingSaveDestination(
            at: url,
            fileManager: fileManager,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader
        )
    }

    func observePendingSaveAsDestination(
        destination: RecoverySaveAsDestination
    ) throws -> PendingSaveDestinationObservation {
        let resolvedDirectory = try resolveSaveAsDirectory(
            bookmark: destination.directoryBookmark,
            bookmarkResolver: bookmarkResolver
        )
        let directoryURL = resolvedDirectory.url
        let didStartSecurityScope = directoryURL
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }
        try validateSaveAsDirectory(
            at: directoryURL,
            fileManager: fileManager
        )
        let targetURL = try makeDirectSaveAsTargetURL(
            directoryURL: directoryURL,
            fileName: destination.fileName
        )
        return try observePendingSaveDestination(
            at: targetURL,
            fileManager: fileManager,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader
        )
    }

    public func cleanupImportedCopy(
        token: ImportedCopyCleanupToken
    ) -> ImportedCopyCleanupOutcome {
        do {
            if importedCopyCleanupRecords[token] == nil {
                importedCopyCleanupRecords = try readImportedCopyCleanupRecords(
                    rootURL: importedCopyCleanupJournalRootURL,
                    inboxURL: applicationInboxURL,
                    fileManager: fileManager,
                    metadataVerifier:
                        importedCopyCleanupJournalMetadataVerifier
                )
            }
            try authorizeImportedCopyCleanup(token: token)
        } catch let error as ImportedCopyCleanupJournalError {
            return .residual(.journal(error))
        } catch {
            return .residual(
                .journal(
                    .couldNotReadJournal(code: (error as NSError).code)
                )
            )
        }
        guard let record = importedCopyCleanupRecords[token] else {
            return .residual(.unknownToken)
        }
        let outcome = cleanupImportedCopyRecord(record)
        switch outcome {
        case .removed, .alreadyAbsent:
            var remainingRecords = importedCopyCleanupRecords
            remainingRecords.removeValue(forKey: token)
            do {
                try persistImportedCopyCleanupRecords(
                    remainingRecords,
                    rootURL: importedCopyCleanupJournalRootURL,
                    fileManager: fileManager,
                    metadataVerifier:
                        importedCopyCleanupJournalMetadataVerifier
                )
                importedCopyCleanupRecords = remainingRecords
            } catch let error as ImportedCopyCleanupJournalError {
                return .residual(.journal(error))
            } catch {
                return .residual(
                    .journal(
                        .couldNotWriteJournal(code: (error as NSError).code)
                    )
                )
            }
        case .residual:
            break
        }
        return outcome
    }

    public func reconcileImportedCopyCleanupJournal() throws
        -> ImportedCopyCleanupReconciliationReport {
        let records = try readImportedCopyCleanupRecords(
            rootURL: importedCopyCleanupJournalRootURL,
            inboxURL: applicationInboxURL,
            fileManager: fileManager,
            metadataVerifier: importedCopyCleanupJournalMetadataVerifier
        )
        var remainingRecords = records
        var removed: [ImportedCopyCleanupJournalItem] = []
        var alreadyAbsent: [ImportedCopyCleanupJournalItem] = []
        var awaitingProtection: [ImportedCopyCleanupJournalItem] = []
        var residuals: [ImportedCopyCleanupResidual] = []
        for token in sortedImportedCopyCleanupTokens(records.keys) {
            guard let record = records[token] else {
                throw ImportedCopyCleanupJournalError.invalidEntry
            }
            let item = ImportedCopyCleanupJournalItem(
                token: token,
                documentID: record.documentID
            )
            guard record.phase == .cleanupAuthorized else {
                switch inspectImportedCopyRecord(record) {
                case .absent:
                    alreadyAbsent.append(item)
                    remainingRecords.removeValue(forKey: token)
                case .exact, .changed:
                    awaitingProtection.append(item)
                case let .failure(failure):
                    residuals.append(
                        ImportedCopyCleanupResidual(
                            item: item,
                            failure: failure
                        )
                    )
                }
                continue
            }
            switch cleanupImportedCopyRecord(record) {
            case .removed:
                removed.append(item)
                remainingRecords.removeValue(forKey: token)
            case .alreadyAbsent:
                alreadyAbsent.append(item)
                remainingRecords.removeValue(forKey: token)
            case let .residual(failure):
                residuals.append(
                    ImportedCopyCleanupResidual(
                        item: item,
                        failure: failure
                    )
                )
            }
        }
        if remainingRecords.count != records.count {
            try persistImportedCopyCleanupRecords(
                remainingRecords,
                rootURL: importedCopyCleanupJournalRootURL,
                fileManager: fileManager,
                metadataVerifier: importedCopyCleanupJournalMetadataVerifier
            )
        }
        importedCopyCleanupRecords = remainingRecords
        return ImportedCopyCleanupReconciliationReport(
            removed: removed,
            alreadyAbsent: alreadyAbsent,
            awaitingProtection: awaitingProtection,
            residuals: residuals
        )
    }

    private func cleanupImportedCopyRecord(
        _ record: ImportedCopyCleanupRecord
    ) -> ImportedCopyCleanupOutcome {
        let didStartSecurityScope = record.url
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                record.url.stopAccessingSecurityScopedResource()
            }
        }
        return coordinateImportedCopyCleanup(
            record: record,
            fileManager: fileManager,
            importedCopyRemover: importedCopyRemover
        )
    }

    private func inspectImportedCopyRecord(
        _ record: ImportedCopyCleanupRecord
    ) -> ImportedCopyVerificationOutcome {
        let didStartSecurityScope = record.url
            .startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                record.url.stopAccessingSecurityScopedResource()
            }
        }
        return verifyImportedCopy(
            at: record.url,
            record: record,
            fileManager: fileManager
        )
    }

    public func stopPresenting(documentID: DocumentID) {
        removePresenter(documentID: documentID)
    }

    public func startPresenting(
        documentID: DocumentID,
        binding: FileBinding
    ) throws {
        let resolvedBookmark = try resolvePresentedFileBookmark(
            binding: binding,
            bookmarkResolver: bookmarkResolver
        )
        let resolvedURL = resolvedBookmark.url
        let didStartSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        _ = registerPresenter(documentID: documentID, url: resolvedURL)
    }

    public func pausePresenters() {
        let registeredDocumentIDs = Array(presentedFiles.keys)
        for documentID in registeredDocumentIDs {
            removePresenter(documentID: documentID)
        }
    }

    public func resumePresenters(
        bindings: [PresentedFileRegistration]
    ) -> [DocumentID: PresentedFileResumeOutcome] {
        pausePresenters()
        let duplicateDocumentIDs = duplicatedPresentedDocumentIDs(
            registrations: bindings
        )
        var outcomes: [DocumentID: PresentedFileResumeOutcome] = [:]
        for documentID in duplicateDocumentIDs {
            outcomes[documentID] = .failed(
                .duplicateFilePresenterRegistration(documentID: documentID)
            )
        }

        var resolvedRegistrations: [ResolvedPresentedFileRegistration] = []
        for registration in bindings
        where !duplicateDocumentIDs.contains(registration.documentID) {
            do {
                let resolvedBookmark = try resolvePresentedFileBookmark(
                    binding: registration.binding,
                    bookmarkResolver: bookmarkResolver
                )
                let didStartSecurityScope = resolvedBookmark.url
                    .startAccessingSecurityScopedResource()
                let presenter = registerPresenter(
                    documentID: registration.documentID,
                    url: resolvedBookmark.url
                )
                resolvedRegistrations.append(
                    ResolvedPresentedFileRegistration(
                        registration: registration,
                        resolvedURL: resolvedBookmark.url,
                        didStartSecurityScope: didStartSecurityScope,
                        presenter: presenter
                    )
                )
            } catch let error as FileAccessConnectorError {
                outcomes[registration.documentID] = .failed(error)
            } catch {
                outcomes[registration.documentID] = .failed(
                    .unexpectedFileSystemFailure(code: (error as NSError).code)
                )
            }
        }

        for resolvedRegistration in resolvedRegistrations {
            defer {
                if resolvedRegistration.didStartSecurityScope {
                    resolvedRegistration.resolvedURL.stopAccessingSecurityScopedResource()
                }
            }
            do {
                outcomes[resolvedRegistration.registration.documentID] = .observed(
                    try observePresentedFile(
                        binding: resolvedRegistration.registration.binding,
                        presenter: resolvedRegistration.presenter
                    )
                )
            } catch let error as FileAccessConnectorError {
                outcomes[resolvedRegistration.registration.documentID] = .failed(error)
            } catch {
                outcomes[resolvedRegistration.registration.documentID] = .failed(
                    .unexpectedFileSystemFailure(code: (error as NSError).code)
                )
            }
        }
        return outcomes
    }

    public func reconcilePresentedFile(
        documentID: DocumentID,
        binding: FileBinding
    ) throws -> ObservedBoundFile {
        guard let presenter = presentedFiles[documentID] else {
            throw FileAccessConnectorError.filePresenterNotRegistered(
                documentID: documentID
            )
        }
        presentationHintRelay.acknowledge(documentID: documentID)
        let resolvedBookmark = try resolvePresentedFileBookmark(
            binding: binding,
            bookmarkResolver: bookmarkResolver
        )
        let resolvedURL = resolvedBookmark.url
        let didStartSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try observePresentedFile(
            binding: binding,
            presenter: presenter
        )
    }

    public func readCurrentPresentedTextFile(
        documentID: DocumentID,
        binding: FileBinding
    ) throws -> PresentedTextFileSnapshot {
        guard let presenter = presentedFiles[documentID] else {
            throw FileAccessConnectorError.filePresenterNotRegistered(
                documentID: documentID
            )
        }
        presentationHintRelay.acknowledge(documentID: documentID)
        let resolvedBookmark = try resolvePresentedFileBookmark(
            binding: binding,
            bookmarkResolver: bookmarkResolver
        )
        let resolvedURL = resolvedBookmark.url
        let didStartSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManagerReference = FileManagerReference(fileManager: fileManager)
        let bookmarkCreator = bookmarkCreator
        let identityReader = identityReader
        let unresolvedVersionCountReader = unresolvedVersionCountReader
        let snapshot = try presenter.performSynchronousAccess {
            let accessURL = presenter.currentPresentedItemURL()
            let snapshot = try coordinatePresentedTextFileRead(
                at: accessURL,
                presenter: presenter,
                fileManager: fileManagerReference.fileManager,
                bookmarkCreator: bookmarkCreator,
                identityReader: identityReader,
                unresolvedVersionCountReader: unresolvedVersionCountReader
            )
            presenter.updatePresentedItemURL(snapshot.openedFile.binding.locatorURL)
            return snapshot
        }
        return snapshot
    }

    public func openTextFile(at selectedURL: URL) throws -> OpenedTextFile {
        let didStartSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        try requireSelectedOpenCandidate(at: selectedURL, fileManager: fileManager)

        let resultBox = OpenFileCoordinationResultBox()
        var coordinationError: NSError?
        let fileCoordinator = NSFileCoordinator(filePresenter: nil)
        let fileManagerReference = FileManagerReference(fileManager: fileManager)
        let bookmarkCreator = bookmarkCreator
        let identityReader = identityReader
        fileCoordinator.coordinate(
            readingItemAt: selectedURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            resultBox.result = openCoordinatedTextFile(
                at: coordinatedURL,
                fileManager: fileManagerReference.fileManager,
                bookmarkCreator: bookmarkCreator,
                identityReader: identityReader
            )
        }

        if let result = resultBox.result {
            return try result.get()
        }
        if let coordinationError {
            throw FileAccessConnectorError.fileCoordinationFailed(
                code: coordinationError.code
            )
        }
        throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
    }

    private func registerPresenter(
        documentID: DocumentID,
        url: URL
    ) -> PresentedFile {
        removePresenter(documentID: documentID)
        let presentationHintRelay = presentationHintRelay
        let presenter = PresentedFile(
            documentID: documentID,
            itemURL: url,
            changeHandler: { changedDocumentID, generation in
                presentationHintRelay.offer(
                    documentID: changedDocumentID,
                    generation: generation
                )
            }
        )
        presentationHintRelay.activate(
            documentID: documentID,
            generation: presenter.generation
        )
        presentedFiles[documentID] = presenter
        NSFileCoordinator.addFilePresenter(presenter)
        return presenter
    }

    private func removePresenter(documentID: DocumentID) {
        guard let presenter = presentedFiles[documentID] else {
            return
        }
        presenter.deactivate()
        presentationHintRelay.deactivate(
            documentID: documentID,
            generation: presenter.generation
        )
        NSFileCoordinator.removeFilePresenter(presenter)
        presentedFiles.removeValue(forKey: documentID)
    }

    private func observePresentedFile(
        binding: FileBinding,
        presenter: PresentedFile
    ) throws -> ObservedBoundFile {
        let fileManagerReference = FileManagerReference(fileManager: fileManager)
        let bookmarkCreator = bookmarkCreator
        let identityReader = identityReader
        let unresolvedVersionCountReader = unresolvedVersionCountReader
        let observation = try presenter.performSynchronousAccess {
            let accessURL = presenter.currentPresentedItemURL()
            let observation = try coordinatePresentedFileObservation(
                at: accessURL,
                presenter: presenter,
                baseline: binding,
                fileManager: fileManagerReference.fileManager,
                bookmarkCreator: bookmarkCreator,
                identityReader: identityReader,
                unresolvedVersionCountReader: unresolvedVersionCountReader
            )
            presenter.updatePresentedItemURL(observation.binding.locatorURL)
            return observation
        }
        return observation
    }

    public func saveTextFile(
        binding: FileBinding,
        encodedFile: EncodedTextFile
    ) throws -> FileSaveOutcome {
        let coordination = makeLegacyBoundFileCoordination(
            fileManager: fileManager,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader,
            replacer: replacer
        )
        return try saveTextFile(
            binding: binding,
            encodedFile: encodedFile,
            coordination: coordination
        )
    }

    public func saveTextFile(
        documentID: DocumentID,
        binding: FileBinding,
        encodedFile: EncodedTextFile
    ) throws -> FileSaveOutcome {
        guard let presenter = presentedFiles[documentID] else {
            throw FileAccessConnectorError.filePresenterNotRegistered(
                documentID: documentID
            )
        }
        presentationHintRelay.acknowledge(documentID: documentID)
        let coordination = makePresentedBoundFileCoordination(
            presenter: presenter,
            fileManager: fileManager,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader,
            replacer: replacer
        )
        let outcome = try saveTextFile(
            binding: binding,
            encodedFile: encodedFile,
            coordination: coordination
        )
        switch outcome {
        case .bound:
            break
        case .verifiedDetached:
            removePresenter(documentID: documentID)
        }
        return outcome
    }

    private func saveTextFile(
        binding: FileBinding,
        encodedFile: EncodedTextFile,
        coordination: BoundFileCoordination
    ) throws -> FileSaveOutcome {
        let resolvedBookmark: ResolvedFileBookmark
        do {
            resolvedBookmark = try bookmarkResolver(binding.bookmark)
        } catch {
            throw FileAccessConnectorError.bookmarkResolutionFailed(
                code: (error as NSError).code
            )
        }

        let resolvedURL = resolvedBookmark.url
        let didStartSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        let targetURL = try coordination.targetURL(resolvedURL)

        if binding.identity == nil,
           targetURL.standardizedFileURL != binding.locatorURL.standardizedFileURL {
            throw FileAccessConnectorError.fileConflict(.ambiguousLocatorChange)
        }

        if resolvedBookmark.isStale {
            do {
                _ = try FileBookmark(data: bookmarkCreator(targetURL))
            } catch {
                throw FileAccessConnectorError.bookmarkRefreshFailed(
                    code: (error as NSError).code
                )
            }
        }

        let stagingLocation: ReplacementStagingLocation
        do {
            stagingLocation = try makeReplacementStagingLocation(
                for: targetURL,
                fileManager: fileManager
            )
        } catch {
            throw FileAccessConnectorError.replacementStagingCreationFailed(
                code: (error as NSError).code
            )
        }

        do {
            try encodedFile.data.write(
                to: stagingLocation.fileURL,
                options: .withoutOverwriting
            )
            try verifyFile(
                at: stagingLocation.fileURL,
                expectedData: encodedFile.data,
                expectedDigest: encodedFile.digest,
                fileManager: fileManager,
                errorContext: .staging
            )
        } catch let precedingError as FileAccessConnectorError {
            do {
                try removeReplacementStagingLocation(
                    stagingLocation,
                    fileManager: fileManager
                )
            } catch let cleanupError as ReplacementStagingCleanupError {
                throw FileAccessConnectorError.replacementStagingCleanupFailed(
                    code: cleanupError.code,
                    after: precedingError
                )
            } catch let cleanupError {
                throw FileAccessConnectorError.replacementStagingCleanupFailed(
                    code: (cleanupError as NSError).code,
                    after: precedingError
                )
            }
            throw precedingError
        } catch {
            let stagingError = FileAccessConnectorError.replacementStagingCreationFailed(
                code: (error as NSError).code
            )
            do {
                try removeReplacementStagingLocation(
                    stagingLocation,
                    fileManager: fileManager
                )
            } catch let cleanupError as ReplacementStagingCleanupError {
                throw FileAccessConnectorError.replacementStagingCleanupFailed(
                    code: cleanupError.code,
                    after: stagingError
                )
            } catch {
                throw FileAccessConnectorError.replacementStagingCleanupFailed(
                    code: (error as NSError).code,
                    after: stagingError
                )
            }
            throw stagingError
        }

        let operationResult: Result<VerifiedSavedFile, FileAccessConnectorError>
        do {
            let replacementURL = try coordination.replace(
                binding,
                targetURL,
                stagingLocation.fileURL,
                encodedFile
            )
            let verifiedFile = try coordination.verify(
                replacementURL,
                binding.identity,
                encodedFile
            )
            operationResult = .success(verifiedFile)
        } catch let error as FileAccessConnectorError {
            operationResult = .failure(error)
        } catch {
            operationResult = .failure(
                .unexpectedFileSystemFailure(code: (error as NSError).code)
            )
        }

        do {
            try removeReplacementStagingLocation(
                stagingLocation,
                fileManager: fileManager
            )
        } catch let cleanupError as ReplacementStagingCleanupError {
            switch operationResult {
            case .success:
                throw FileAccessConnectorError.replacementStagingCleanupFailedAfterVerifiedWrite(
                    code: cleanupError.code
                )
            case let .failure(precedingError):
                throw FileAccessConnectorError.replacementStagingCleanupFailed(
                    code: cleanupError.code,
                    after: precedingError
                )
            }
        } catch {
            let cleanupCode = (error as NSError).code
            switch operationResult {
            case .success:
                throw FileAccessConnectorError.replacementStagingCleanupFailedAfterVerifiedWrite(
                    code: cleanupCode
                )
            case let .failure(precedingError):
                throw FileAccessConnectorError.replacementStagingCleanupFailed(
                    code: cleanupCode,
                    after: precedingError
                )
            }
        }

        let verifiedFile = try operationResult.get()
        let displayName: ValidatedFileName
        do {
            displayName = try ValidatedFileName(
                validating: verifiedFile.url.lastPathComponent
            )
        } catch {
            throw FileAccessConnectorError.selectedFileNameInvalid
        }
        let detachedFile = VerifiedDetachedFile(
            displayName: displayName,
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
        let bookmark: FileBookmark
        do {
            bookmark = try FileBookmark(data: bookmarkCreator(verifiedFile.url))
        } catch {
            return .verifiedDetached(detachedFile)
        }
        return .bound(
            FileBinding(
                locatorURL: verifiedFile.url,
                bookmark: bookmark,
                identity: verifiedFile.identity,
                displayName: displayName,
                digest: encodedFile.digest,
                encoding: encodedFile.encoding,
                lineEnding: encodedFile.lineEnding
            )
        )
    }

    private func coordinatedCreate(
        stagingURL: URL,
        targetURL: URL,
        fileName: ValidatedFileName,
        encodedFile: EncodedTextFile
    ) throws -> FileCreationOutcome {
        let resultBox = FileCoordinationResultBox()
        var coordinationError: NSError?
        let fileManager = fileManager
        let bookmarkCreator = bookmarkCreator
        let identityReader = identityReader
        let fileCoordinator = NSFileCoordinator(filePresenter: nil)

        fileCoordinator.coordinate(
            writingItemAt: stagingURL,
            options: .forMoving,
            writingItemAt: targetURL,
            options: [],
            error: &coordinationError
        ) { coordinatedStagingURL, coordinatedTargetURL in
            resultBox.result = createCoordinatedFile(
                stagingURL: coordinatedStagingURL,
                coordinatedTargetURL: coordinatedTargetURL,
                fileName: fileName,
                encodedFile: encodedFile,
                fileCoordinator: fileCoordinator,
                fileManager: fileManager,
                bookmarkCreator: bookmarkCreator,
                identityReader: identityReader
            )
        }

        if let result = resultBox.result {
            return try result.get()
        }

        let targetKind = try inspectNode(at: targetURL, fileManager: fileManager)
        if case let .existing(kind) = targetKind {
            throw FileAccessConnectorError.targetAlreadyExists(kind)
        }
        if case .directory = targetKind {
            throw FileAccessConnectorError.targetAlreadyExists(.directory)
        }
        if let coordinationError {
            throw FileAccessConnectorError.fileCoordinationFailed(code: coordinationError.code)
        }
        throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
    }
}

struct ResolvedFileBookmark: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

private final class FileManagerReference: @unchecked Sendable {
    let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }
}

private struct ReplacementStagingLocation: Sendable {
    let directoryURL: URL
    let fileURL: URL
}

private struct ReplacementStagingCleanupError: Error, Sendable {
    let code: Int
}

private struct ResolvedPresentedFileRegistration: Sendable {
    let registration: PresentedFileRegistration
    let resolvedURL: URL
    let didStartSecurityScope: Bool
    let presenter: PresentedFile
}

private struct BoundFileObservation: Sendable {
    let data: Data
    let digest: FileDigest
    let identity: FileIdentity?
}

private struct VerifiedSavedFile: Sendable {
    let url: URL
    let identity: FileIdentity?
}

private enum TypedPresentedTextFileOutcome: Sendable {
    case bound(PresentedTextFileSnapshot)
    case detached(
        DetachedFileSnapshot,
        FileOpenDetachmentReason
    )
    case rejected(FileAccessConnectorError)
}

private struct BoundFileCoordination: Sendable {
    let targetURL: @Sendable (URL) throws -> URL
    let replace: @Sendable (
        FileBinding,
        URL,
        URL,
        EncodedTextFile
    ) throws -> URL
    let verify: @Sendable (
        URL,
        FileIdentity?,
        EncodedTextFile
    ) throws -> VerifiedSavedFile
}

private enum RegularFileReadFailure: Error, Equatable, Sendable {
    case missing
    case itemIsNotRegularFile(ExistingFileSystemItemKind)
    case tooLarge(actualByteCount: Int, maximumByteCount: Int)
    case readFailed(code: Int)
}

private final class OpenFileCoordinationResultBox: @unchecked Sendable {
    var result: Result<OpenedTextFile, FileAccessConnectorError>?
}

private final class PresentedOpenCoordinationResultBox: @unchecked Sendable {
    var result: Result<PresentedTextFileSnapshot, FileAccessConnectorError>?
}

private final class TypedPresentedOpenCoordinationResultBox: @unchecked Sendable {
    var result: Result<TypedPresentedTextFileOutcome, FileAccessConnectorError>?
}

private final class ImportedCopyCleanupResultBox: @unchecked Sendable {
    var outcome: ImportedCopyCleanupOutcome?
}

private enum ImportedCopyVerificationOutcome: Sendable {
    case exact
    case absent
    case changed
    case failure(ImportedCopyCleanupFailure)
}

private final class PresentedFileObservationResultBox: @unchecked Sendable {
    var result: Result<ObservedBoundFile, FileAccessConnectorError>?
}

private final class BoundFileReplacementResultBox: @unchecked Sendable {
    var result: Result<URL, FileAccessConnectorError>?
}

private final class SavedFileVerificationResultBox: @unchecked Sendable {
    var result: Result<VerifiedSavedFile, FileAccessConnectorError>?
}

private final class SaveAsTargetSnapshotResultBox: @unchecked Sendable {
    var result: Result<SaveAsTargetSnapshot, FileAccessConnectorError>?
}

private final class PendingSaveDestinationObservationResultBox:
    @unchecked Sendable {
    var result: Result<
        PendingSaveDestinationObservation,
        FileAccessConnectorError
    >?
}

private final class SaveAsCommitResultBox: @unchecked Sendable {
    var result: Result<FileSaveOutcome, FileAccessConnectorError>?
}

private final class SaveAsReplacementOperationResultBox: @unchecked Sendable {
    var result: SaveAsReplacementOperationResult?
}

private final class SaveAsRecoveryMoveResultBox: @unchecked Sendable {
    var result: Result<URL, FileAccessConnectorError>?
}

private enum SaveAsStagingCleanupDisposition: Sendable {
    case cleanupAllowed
    case preserveStaging
}

private struct SaveAsReplacementOperationResult: Sendable {
    let result: Result<FileSaveOutcome, FileAccessConnectorError>
    let cleanupDisposition: SaveAsStagingCleanupDisposition
    let recoveryRequest: SaveAsReportedItemRecoveryRequest?
}

private enum SaveAsObservedGeneration: Equatable, Sendable {
    case original
    case intended
    case other
}

private struct SaveAsReportedItemRecoveryRequest: Sendable {
    let replacementErrorCode: Int
    let sourceURL: URL
    let generation: SaveAsRelocatedFileGeneration
    let snapshot: SaveAsTargetSnapshot
}

private struct SaveAsReportedItemObservation: Sendable {
    let generation: SaveAsRelocatedFileGeneration
    let snapshot: SaveAsTargetSnapshot
}

private enum ReportedOriginalItemLocation: Sendable {
    case absent
    case valid(URL)
    case invalid(code: Int)
}

private final class FileCoordinationResultBox: @unchecked Sendable {
    var result: Result<FileCreationOutcome, FileAccessConnectorError>?
}

private enum FileSystemNodeKind: Equatable, Sendable {
    case missing
    case directory
    case existing(ExistingFileSystemItemKind)
}

private enum FileVerificationContext: Sendable {
    case staging
    case output
}

private func createBookmarkData(url: URL) throws -> Data {
    try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}

private func resolveBookmark(bookmark: FileBookmark) throws -> ResolvedFileBookmark {
    var bookmarkIsStale = false
    let url = try URL(
        resolvingBookmarkData: bookmark.data,
        options: [.withoutUI, .withoutImplicitStartAccessing],
        relativeTo: nil,
        bookmarkDataIsStale: &bookmarkIsStale
    )
    return ResolvedFileBookmark(url: url, isStale: bookmarkIsStale)
}

private func readPersistentFileIdentity(url: URL) throws -> FileIdentity? {
    let values: URLResourceValues
    do {
        values = try url.resourceValues(
            forKeys: [.documentIdentifierKey, .volumeUUIDStringKey]
        )
    } catch {
        throw FileAccessConnectorError.fileIdentityInspectionFailed(
            code: (error as NSError).code
        )
    }
    guard let documentIdentifier = values.documentIdentifier,
          let volumeUUIDString = values.volumeUUIDString else {
        return nil
    }
    guard let volumeUUID = UUID(uuidString: volumeUUIDString) else {
        throw FileAccessConnectorError.fileIdentityValueInvalid
    }
    return FileIdentity(
        volumeUUID: volumeUUID,
        documentIdentifier: documentIdentifier
    )
}

private func replaceFileSafely(
    originalURL: URL,
    stagingURL: URL,
    fileManager: FileManager
) throws -> URL? {
    try fileManager.replaceItemAt(
        originalURL,
        withItemAt: stagingURL,
        backupItemName: nil,
        options: []
    )
}

private func writeSaveAsStagingData(data: Data, url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
}

private func cleanSaveAsStaging(
    directoryURL: URL,
    fileURL: URL,
    fileManager: FileManager
) throws {
    try removeReplacementStagingLocation(
        ReplacementStagingLocation(
            directoryURL: directoryURL,
            fileURL: fileURL
        ),
        fileManager: fileManager
    )
}

private func openTypedCoordinatedTextFile(
    at url: URL,
    accessIntent: FileOpenAccessIntent,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader,
    fileWritabilityReader: FileAccessConnector.FileWritabilityReader
) -> Result<TypedPresentedTextFileOutcome, FileAccessConnectorError> {
    do {
        try validateSelectedFileForOpen(at: url, fileManager: fileManager)
        let data = try readSelectedFile(at: url, fileManager: fileManager)
        let decodedFile: DecodedTextFile
        do {
            decodedFile = try decodeSupportedTextFile(data: data)
        } catch let error as TextFileDecodingError {
            throw FileAccessConnectorError.textDecodingFailed(error)
        }
        let displayName: ValidatedFileName
        do {
            displayName = try ValidatedFileName(validating: url.lastPathComponent)
        } catch {
            throw FileAccessConnectorError.selectedFileNameInvalid
        }
        let identity = try readOpenFileIdentity(
            at: url,
            identityReader: identityReader
        )
        let providerConflictVersions = try makeProviderConflictVersions(
            unresolvedCount: unresolvedVersionCountReader(url)
        )
        let candidate = FileOpenCandidate(
            locatorURL: url,
            identity: identity,
            digest: decodedFile.digest,
            providerConflictVersions: providerConflictVersions
        )
        let ephemeralDetachedSnapshot = DetachedFileSnapshot(
            candidate: candidate,
            displayName: displayName,
            text: decodedFile.text,
            recoveryFileReference: nil
        )
        if accessIntent == .copyRequired {
            return .success(
                .detached(
                    ephemeralDetachedSnapshot,
                    .copyRequired
                )
            )
        }

        let bookmark: FileBookmark
        do {
            bookmark = try FileBookmark(data: bookmarkCreator(url))
        } catch {
            return .success(
                .detached(
                    ephemeralDetachedSnapshot,
                    .bookmarkCreationFailed(code: (error as NSError).code)
                )
            )
        }
        let resolvedBookmark: ResolvedFileBookmark
        do {
            resolvedBookmark = try bookmarkResolver(bookmark)
        } catch {
            return .success(
                .detached(
                    ephemeralDetachedSnapshot,
                    .bookmarkResolutionFailed(code: (error as NSError).code)
                )
            )
        }
        guard !resolvedBookmark.isStale else {
            return .success(
                .detached(
                    ephemeralDetachedSnapshot,
                    .bookmarkIsStale
                )
            )
        }
        let resolvedSourceMatch = bookmarkResolutionMatchesOpenSource(
            sourceURL: url,
            sourceIdentity: identity,
            resolvedURL: resolvedBookmark.url,
            identityReader: identityReader
        )
        switch resolvedSourceMatch {
        case let .failure(reason):
            return .success(
                .detached(
                    ephemeralDetachedSnapshot,
                    reason
                )
            )
        case .success(false):
            return .success(
                .detached(
                    ephemeralDetachedSnapshot,
                    .bookmarkResolvedToDifferentFile
                )
            )
        case .success(true):
            break
        }

        let binding = FileBinding(
            locatorURL: resolvedBookmark.url,
            bookmark: bookmark,
            identity: identity,
            displayName: displayName,
            digest: decodedFile.digest,
            encoding: decodedFile.encoding,
            lineEnding: decodedFile.lineEnding
        )
        let detachedSnapshot = DetachedFileSnapshot(
            candidate: candidate,
            displayName: displayName,
            text: decodedFile.text,
            recoveryFileReference: makeRecoveryFileReference(
                fileBinding: binding
            )
        )
        let isWritable: Bool?
        do {
            isWritable = try fileWritabilityReader(resolvedBookmark.url)
        } catch {
            return .success(
                .detached(
                    detachedSnapshot,
                    .writabilityInspectionFailed(code: (error as NSError).code)
                )
            )
        }
        guard let isWritable else {
            return .success(
                .detached(
                    detachedSnapshot,
                    .writabilityNotReported
                )
            )
        }
        guard isWritable else {
            return .success(
                .detached(
                    detachedSnapshot,
                    .notWritable
                )
            )
        }
        return .success(
            .bound(
                PresentedTextFileSnapshot(
                    openedFile: OpenedTextFile(
                        text: decodedFile.text,
                        binding: binding
                    ),
                    providerConflictVersions: providerConflictVersions
                )
            )
        )
    } catch let error as FileAccessConnectorError {
        return .success(.rejected(error))
    } catch {
        return .success(
            .rejected(
                .unexpectedFileSystemFailure(code: (error as NSError).code)
            )
        )
    }
}

private func readOpenFileIdentity(
    at url: URL,
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> FileIdentity? {
    do {
        return try identityReader(url)
    } catch let error as FileAccessConnectorError {
        throw error
    } catch {
        throw FileAccessConnectorError.fileIdentityInspectionFailed(
            code: (error as NSError).code
        )
    }
}

private func bookmarkResolutionMatchesOpenSource(
    sourceURL: URL,
    sourceIdentity: FileIdentity?,
    resolvedURL: URL,
    identityReader: FileAccessConnector.FileIdentityReader
) -> Result<Bool, FileOpenDetachmentReason> {
    if sourceURL.standardizedFileURL == resolvedURL.standardizedFileURL {
        return .success(true)
    }
    guard let sourceIdentity else {
        return .success(false)
    }
    do {
        return .success(try identityReader(resolvedURL) == sourceIdentity)
    } catch {
        return .failure(
            .bookmarkVerificationFailed(code: (error as NSError).code)
        )
    }
}

private func coordinateTypedPresentedTextFileRead(
    at url: URL,
    accessIntent: FileOpenAccessIntent,
    presenter: PresentedFile,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader,
    fileWritabilityReader: FileAccessConnector.FileWritabilityReader
) throws -> TypedPresentedTextFileOutcome {
    let resultBox = TypedPresentedOpenCoordinationResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: presenter)
    fileCoordinator.coordinate(
        readingItemAt: url,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = openTypedCoordinatedTextFile(
            at: coordinatedURL,
            accessIntent: accessIntent,
            fileManager: fileManager,
            bookmarkCreator: bookmarkCreator,
            bookmarkResolver: bookmarkResolver,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader,
            fileWritabilityReader: fileWritabilityReader
        )
    }
    if let result = resultBox.result {
        return try result.get()
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func readFileWritability(at url: URL) throws -> Bool? {
    try url.resourceValues(forKeys: [.isWritableKey]).isWritable
}

private func defaultApplicationInboxURL(fileManager: FileManager) -> URL? {
    fileManager.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first?.appendingPathComponent("Inbox", isDirectory: true)
}

private func makeImportedCopyCleanupRecord(
    url: URL,
    inboxURL: URL?,
    documentID: DocumentID,
    phase: ImportedCopyCleanupAuthorizationPhase,
    fileManager: FileManager
) throws(FileAccessConnectorError) -> ImportedCopyCleanupRecord? {
    guard url.isFileURL, let inboxURL else {
        return nil
    }
    let canonicalInboxURL = inboxURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
    let canonicalParentURL = url
        .deletingLastPathComponent()
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard canonicalParentURL == canonicalInboxURL else {
        return nil
    }
    var status = stat()
    let result = lstat(
        fileManager.fileSystemRepresentation(withPath: url.path),
        &status
    )
    guard result == 0 else {
        if errno == ENOENT {
            return nil
        }
        throw FileAccessConnectorError.fileSystemInspectionFailed(code: errno)
    }
    guard existingItemKind(mode: status.st_mode) == .regularFile else {
        return nil
    }
    let childName: ValidatedFileName
    do {
        childName = try ValidatedFileName(validating: url.lastPathComponent)
    } catch {
        throw FileAccessConnectorError.selectedFileNameInvalid
    }
    return ImportedCopyCleanupRecord(
        documentID: documentID,
        childName: childName,
        url: url.standardizedFileURL,
        inboxURL: canonicalInboxURL,
        fingerprint: ImportedCopyCleanupFingerprint(
            deviceID: Int64(status.st_dev),
            inode: UInt64(status.st_ino),
            generation: status.st_gen,
            byteCount: Int64(status.st_size),
            modificationTimeSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationTimeNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            statusChangeTimeSeconds: Int64(status.st_ctimespec.tv_sec),
            statusChangeTimeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        ),
        phase: phase
    )
}

private func importedCopyCleanupRecord(
    _ record: ImportedCopyCleanupRecord,
    phase: ImportedCopyCleanupAuthorizationPhase
) -> ImportedCopyCleanupRecord {
    ImportedCopyCleanupRecord(
        documentID: record.documentID,
        childName: record.childName,
        url: record.url,
        inboxURL: record.inboxURL,
        fingerprint: record.fingerprint,
        phase: phase
    )
}

private func importedCopyCleanupRecord(
    _ record: ImportedCopyCleanupRecord,
    documentID: DocumentID
) -> ImportedCopyCleanupRecord {
    ImportedCopyCleanupRecord(
        documentID: documentID,
        childName: record.childName,
        url: record.url,
        inboxURL: record.inboxURL,
        fingerprint: record.fingerprint,
        phase: record.phase
    )
}

private func importedCopyCleanupCandidate(
    _ record: ImportedCopyCleanupRecord
) -> ImportedCopyCleanupCandidate {
    ImportedCopyCleanupCandidate(
        childName: record.childName,
        fingerprint: record.fingerprint
    )
}

private func coordinateImportedCopyCleanup(
    record: ImportedCopyCleanupRecord,
    fileManager: FileManager,
    importedCopyRemover: FileAccessConnector.ImportedCopyRemover
) -> ImportedCopyCleanupOutcome {
    let resultBox = ImportedCopyCleanupResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
        writingItemAt: record.url,
        options: .forDeleting,
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.outcome = removeVerifiedImportedCopy(
            at: coordinatedURL,
            record: record,
            fileManager: fileManager,
            importedCopyRemover: importedCopyRemover
        )
    }
    if let outcome = resultBox.outcome {
        return outcome
    }
    if let coordinationError {
        return .residual(
            .fileCoordinationFailed(code: coordinationError.code)
        )
    }
    return .residual(.fileCoordinationAccessorNotInvoked)
}

private func removeVerifiedImportedCopy(
    at url: URL,
    record: ImportedCopyCleanupRecord,
    fileManager: FileManager,
    importedCopyRemover: FileAccessConnector.ImportedCopyRemover
) -> ImportedCopyCleanupOutcome {
    switch verifyImportedCopy(
        at: url,
        record: record,
        fileManager: fileManager
    ) {
    case .exact:
        break
    case .absent:
        return .alreadyAbsent
    case .changed:
        return .residual(.itemChanged)
    case let .failure(failure):
        return .residual(failure)
    }
    do {
        try importedCopyRemover(url, fileManager)
    } catch let error as NSError {
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .alreadyAbsent
        }
        return .residual(.deletionFailed(code: error.code))
    }
    return .removed
}

private func verifyImportedCopy(
    at url: URL,
    record: ImportedCopyCleanupRecord,
    fileManager: FileManager
) -> ImportedCopyVerificationOutcome {
    let canonicalParentURL = url
        .deletingLastPathComponent()
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard canonicalParentURL == record.inboxURL else {
        return .changed
    }
    var status = stat()
    let statusResult = lstat(
        fileManager.fileSystemRepresentation(withPath: url.path),
        &status
    )
    guard statusResult == 0 else {
        if errno == ENOENT {
            return .absent
        }
        return .failure(.verificationFailed(code: Int(errno)))
    }
    guard existingItemKind(mode: status.st_mode) == .regularFile,
          Int64(status.st_dev) == record.fingerprint.deviceID,
          UInt64(status.st_ino) == record.fingerprint.inode,
          status.st_gen == record.fingerprint.generation,
          Int64(status.st_size) == record.fingerprint.byteCount,
          Int64(status.st_mtimespec.tv_sec)
              == record.fingerprint.modificationTimeSeconds,
          Int64(status.st_mtimespec.tv_nsec)
              == record.fingerprint.modificationTimeNanoseconds,
          Int64(status.st_ctimespec.tv_sec)
              == record.fingerprint.statusChangeTimeSeconds,
          Int64(status.st_ctimespec.tv_nsec)
              == record.fingerprint.statusChangeTimeNanoseconds else {
        return .changed
    }
    return .exact
}

func removeImportedCopy(url: URL, fileManager: FileManager) throws {
    let result = unlink(
        fileManager.fileSystemRepresentation(withPath: url.path)
    )
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func resolveActiveOpenLocator(
    bookmark: FileBookmark,
    documentID: DocumentID,
    bookmarkResolver: FileAccessConnector.BookmarkResolver
) throws -> URL {
    let resolvedBookmark: ResolvedFileBookmark
    do {
        resolvedBookmark = try bookmarkResolver(bookmark)
    } catch {
        throw FileAccessConnectorError.activeLocatorBookmarkResolutionFailed(
            documentID: documentID,
            code: (error as NSError).code
        )
    }
    guard !resolvedBookmark.isStale else {
        throw FileAccessConnectorError.activeLocatorBookmarkIsStale(
            documentID: documentID
        )
    }
    return resolvedBookmark.url
}

private func resolveRecoveryFileClaim(
    _ claim: FileCollisionClaim,
    bookmarkResolver: FileAccessConnector.BookmarkResolver
) throws -> ResolvedRecoveryFileClaim {
    switch claim {
    case let .activeTab(documentID, _):
        throw FileAccessConnectorError.recoveryClaimIsNotRecoveryItem(
            documentID: documentID
        )
    case let .recoveryItem(documentID, reference):
        return ResolvedRecoveryFileClaim(
            documentID: documentID,
            kind: .sourceFile,
            locatorURL: try resolveCollisionClaimURL(
                bookmark: reference.bookmark,
                documentID: documentID,
                bookmarkResolver: bookmarkResolver
            ),
            identity: reference.identity
        )
    case let .pendingSaveAs(documentID, destination):
        let directoryURL = try resolveCollisionClaimURL(
            bookmark: destination.directoryBookmark,
            documentID: documentID,
            bookmarkResolver: bookmarkResolver
        )
        let targetURL = directoryURL.appendingPathComponent(
            destination.fileName.value,
            isDirectory: false
        )
        guard isDirectChild(targetURL, of: directoryURL) else {
            throw FileAccessConnectorError.directChildResolutionFailed
        }
        return ResolvedRecoveryFileClaim(
            documentID: documentID,
            kind: .pendingSaveAsDestination,
            locatorURL: targetURL,
            identity: nil
        )
    }
}

private func openCoordinatedTextFile(
    at url: URL,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader
) -> Result<OpenedTextFile, FileAccessConnectorError> {
    do {
        try validateSelectedFileForOpen(at: url, fileManager: fileManager)
        let data = try readSelectedFile(at: url, fileManager: fileManager)
        let decodedFile: DecodedTextFile
        do {
            decodedFile = try decodeSupportedTextFile(data: data)
        } catch let error as TextFileDecodingError {
            throw FileAccessConnectorError.textDecodingFailed(error)
        }
        let displayName: ValidatedFileName
        do {
            displayName = try ValidatedFileName(validating: url.lastPathComponent)
        } catch {
            throw FileAccessConnectorError.selectedFileNameInvalid
        }
        let identity: FileIdentity?
        do {
            identity = try identityReader(url)
        } catch let error as FileAccessConnectorError {
            throw error
        } catch {
            throw FileAccessConnectorError.fileIdentityInspectionFailed(
                code: (error as NSError).code
            )
        }
        let bookmark: FileBookmark
        do {
            bookmark = try FileBookmark(data: bookmarkCreator(url))
        } catch {
            throw FileAccessConnectorError.bookmarkCreationFailed(
                code: (error as NSError).code
            )
        }
        let binding = FileBinding(
            locatorURL: url,
            bookmark: bookmark,
            identity: identity,
            displayName: displayName,
            digest: decodedFile.digest,
            encoding: decodedFile.encoding,
            lineEnding: decodedFile.lineEnding
        )
        return .success(OpenedTextFile(text: decodedFile.text, binding: binding))
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        return .failure(
            .unexpectedFileSystemFailure(code: (error as NSError).code)
        )
    }
}

private func openPresentedCoordinatedTextFile(
    at url: URL,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader
) -> Result<PresentedTextFileSnapshot, FileAccessConnectorError> {
    openCoordinatedTextFile(
        at: url,
        fileManager: fileManager,
        bookmarkCreator: bookmarkCreator,
        identityReader: identityReader
    )
    .flatMap { openedFile in
        do {
            return .success(
                PresentedTextFileSnapshot(
                    openedFile: openedFile,
                    providerConflictVersions: try makeProviderConflictVersions(
                        unresolvedCount: unresolvedVersionCountReader(url)
                    )
                )
            )
        } catch let error as FileAccessConnectorError {
            return .failure(error)
        } catch {
            return .failure(
                .unexpectedFileSystemFailure(code: (error as NSError).code)
            )
        }
    }
}

private func coordinatePresentedTextFileRead(
    at url: URL,
    presenter: PresentedFile,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader
) throws -> PresentedTextFileSnapshot {
    let resultBox = PresentedOpenCoordinationResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: presenter)
    fileCoordinator.coordinate(
        readingItemAt: url,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = openPresentedCoordinatedTextFile(
            at: coordinatedURL,
            fileManager: fileManager,
            bookmarkCreator: bookmarkCreator,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader
        )
    }
    if let result = resultBox.result {
        return try result.get()
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func coordinatePresentedFileObservation(
    at url: URL,
    presenter: PresentedFile,
    baseline: FileBinding,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader
) throws -> ObservedBoundFile {
    let resultBox = PresentedFileObservationResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: presenter)
    fileCoordinator.coordinate(
        readingItemAt: url,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = observeCoordinatedPresentedFile(
            at: coordinatedURL,
            baseline: baseline,
            fileManager: fileManager,
            bookmarkCreator: bookmarkCreator,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader
        )
    }
    if let result = resultBox.result {
        return try result.get()
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func observeCoordinatedPresentedFile(
    at url: URL,
    baseline: FileBinding,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader
) -> Result<ObservedBoundFile, FileAccessConnectorError> {
    do {
        switch try inspectNode(at: url, fileManager: fileManager) {
        case .missing:
            throw FileAccessConnectorError.boundFileMissing
        case .directory:
            throw FileAccessConnectorError.boundFileIsNotRegularFile(.directory)
        case .existing(.regularFile):
            break
        case let .existing(kind):
            throw FileAccessConnectorError.boundFileIsNotRegularFile(kind)
        }
        let snapshot = try readPresentedFileSnapshot(
            at: url,
            fileManager: fileManager,
            identityReader: identityReader
        )
        let bookmark: FileBookmark
        do {
            bookmark = try FileBookmark(data: bookmarkCreator(url))
        } catch {
            throw FileAccessConnectorError.bookmarkRefreshFailed(
                code: (error as NSError).code
            )
        }
        let observedBinding = FileBinding(
            locatorURL: url,
            bookmark: bookmark,
            identity: snapshot.identity,
            displayName: baseline.displayName,
            digest: snapshot.digest,
            encoding: baseline.encoding,
            lineEnding: baseline.lineEnding
        )
        return .success(
            ObservedBoundFile(
                binding: observedBinding,
                providerConflictVersions: try makeProviderConflictVersions(
                    unresolvedCount: unresolvedVersionCountReader(url)
                )
            )
        )
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        return .failure(
            .unexpectedFileSystemFailure(code: (error as NSError).code)
        )
    }
}

private func readPresentedFileSnapshot(
    at url: URL,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> SaveAsTargetSnapshot {
    do {
        return try readSaveAsTargetSnapshot(
            at: url,
            fileManager: fileManager,
            identityReader: identityReader
        )
    } catch let error as FileAccessConnectorError {
        switch error {
        case .saveAsTargetChanged:
            throw FileAccessConnectorError.boundFileMissing
        case let .saveAsTargetSnapshotReadFailed(code):
            throw FileAccessConnectorError.inputReadFailed(code: code)
        case let .targetAlreadyExists(kind):
            throw FileAccessConnectorError.boundFileIsNotRegularFile(kind)
        default:
            throw error
        }
    }
}

private func resolvePresentedFileBookmark(
    binding: FileBinding,
    bookmarkResolver: FileAccessConnector.BookmarkResolver
) throws -> ResolvedFileBookmark {
    do {
        return try bookmarkResolver(binding.bookmark)
    } catch let error as FileAccessConnectorError {
        throw error
    } catch {
        throw FileAccessConnectorError.bookmarkResolutionFailed(
            code: (error as NSError).code
        )
    }
}

private func duplicatedPresentedDocumentIDs(
    registrations: [PresentedFileRegistration]
) -> Set<DocumentID> {
    var seenDocumentIDs: Set<DocumentID> = []
    var duplicateDocumentIDs: Set<DocumentID> = []
    for registration in registrations {
        if !seenDocumentIDs.insert(registration.documentID).inserted {
            duplicateDocumentIDs.insert(registration.documentID)
        }
    }
    return duplicateDocumentIDs
}

private struct SelectedFileMetadata {
    let contentType: UTType?
    let isPackage: Bool
}

private func validateSelectedFileForOpen(
    at url: URL,
    fileManager: FileManager
) throws {
    let nodeKind = try inspectNode(at: url, fileManager: fileManager)
    let nodeIsDirectory: Bool
    switch nodeKind {
    case .missing:
        throw FileAccessConnectorError.selectedFileMissing
    case .directory:
        nodeIsDirectory = true
    case .existing(.regularFile):
        nodeIsDirectory = false
    case let .existing(kind):
        throw FileAccessConnectorError.selectedFileIsNotRegularFile(kind)
    }
    let metadata = try readSelectedFileMetadata(at: url)
    if metadata.isPackage || metadata.contentType?.conforms(to: .package) == true {
        throw FileAccessConnectorError.selectedFileIsPackage
    }
    if nodeIsDirectory {
        throw FileAccessConnectorError.selectedFileIsNotRegularFile(.directory)
    }
    guard let contentType = metadata.contentType else {
        return
    }
    if contentType.conforms(to: .rtf)
        || contentType.conforms(to: .rtfd)
        || contentType.conforms(to: .flatRTFD) {
        throw FileAccessConnectorError.selectedFileHasUnsupportedContentType(
            contentType.identifier
        )
    }
    guard contentType.isDynamic || contentType.conforms(to: .data) else {
        throw FileAccessConnectorError.selectedFileHasUnsupportedContentType(
            contentType.identifier
        )
    }
}

private func readSelectedFileMetadata(at url: URL) throws -> SelectedFileMetadata {
    let packageValues: URLResourceValues
    do {
        packageValues = try url.resourceValues(forKeys: [.isPackageKey])
    } catch {
        throw FileAccessConnectorError.selectedFileMetadataInspectionFailed(
            code: (error as NSError).code
        )
    }
    let contentType: UTType?
    do {
        contentType = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
    } catch {
        throw FileAccessConnectorError.selectedFileMetadataInspectionFailed(
            code: (error as NSError).code
        )
    }
    return SelectedFileMetadata(
        contentType: contentType,
        isPackage: packageValues.isPackage == true
    )
}

private func isFilePackage(at url: URL) throws -> Bool {
    do {
        return try url.resourceValues(forKeys: [.isPackageKey]).isPackage == true
    } catch {
        throw FileAccessConnectorError.selectedFileMetadataInspectionFailed(
            code: (error as NSError).code
        )
    }
}

private func requireSelectedOpenCandidate(
    at url: URL,
    fileManager: FileManager
) throws {
    switch try inspectNode(at: url, fileManager: fileManager) {
    case .missing:
        throw FileAccessConnectorError.selectedFileMissing
    case .directory, .existing(.regularFile):
        return
    case let .existing(kind):
        throw FileAccessConnectorError.selectedFileIsNotRegularFile(kind)
    }
}

private func readSelectedFile(
    at url: URL,
    fileManager: FileManager
) throws -> Data {
    switch readRegularFile(at: url, fileManager: fileManager) {
    case let .success(data):
        return data
    case .failure(.missing):
        throw FileAccessConnectorError.selectedFileMissing
    case let .failure(.itemIsNotRegularFile(kind)):
        throw FileAccessConnectorError.selectedFileIsNotRegularFile(kind)
    case let .failure(.tooLarge(actualByteCount, maximumByteCount)):
        throw FileAccessConnectorError.inputTooLarge(
            actualByteCount: actualByteCount,
            maximumByteCount: maximumByteCount
        )
    case let .failure(.readFailed(code)):
        throw FileAccessConnectorError.inputReadFailed(code: code)
    }
}

private func readBoundFileObservation(
    at url: URL,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> BoundFileObservation {
    let data: Data
    switch readRegularFile(at: url, fileManager: fileManager) {
    case let .success(resultData):
        data = resultData
    case .failure(.missing):
        throw FileAccessConnectorError.boundFileMissing
    case let .failure(.itemIsNotRegularFile(kind)):
        throw FileAccessConnectorError.boundFileIsNotRegularFile(kind)
    case .failure(.tooLarge):
        throw FileAccessConnectorError.fileConflict(.contentChanged)
    case let .failure(.readFailed(code)):
        throw FileAccessConnectorError.inputReadFailed(code: code)
    }
    let identity: FileIdentity?
    do {
        identity = try identityReader(url)
    } catch let error as FileAccessConnectorError {
        throw error
    } catch {
        throw FileAccessConnectorError.fileIdentityInspectionFailed(
            code: (error as NSError).code
        )
    }
    return BoundFileObservation(
        data: data,
        digest: try makeDigest(data: data),
        identity: identity
    )
}

private func coordinatedReadSaveAsTargetSnapshot(
    at url: URL,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> SaveAsTargetSnapshot {
    let resultBox = SaveAsTargetSnapshotResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
        readingItemAt: url,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = Result {
            try readSaveAsTargetSnapshot(
                at: coordinatedURL,
                fileManager: fileManager,
                identityReader: identityReader
            )
        }
        .mapError { error in
            if let connectorError = error as? FileAccessConnectorError {
                return connectorError
            }
            return .unexpectedFileSystemFailure(code: (error as NSError).code)
        }
    }

    if let result = resultBox.result {
        return try result.get()
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func observePendingSaveDestination(
    at url: URL,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader:
        FileAccessConnector.UnresolvedVersionCountReader
) throws -> PendingSaveDestinationObservation {
    switch try inspectNode(at: url, fileManager: fileManager) {
    case .missing:
        return .missing
    case .directory:
        return .nonRegular(.directory)
    case let .existing(kind):
        guard kind == .regularFile else {
            return .nonRegular(kind)
        }
    }
    return try coordinatedReadPendingSaveDestinationObservation(
        at: url,
        fileManager: fileManager,
        identityReader: identityReader,
        unresolvedVersionCountReader: unresolvedVersionCountReader
    )
}

private func coordinatedReadPendingSaveDestinationObservation(
    at url: URL,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader:
        FileAccessConnector.UnresolvedVersionCountReader
) throws -> PendingSaveDestinationObservation {
    let resultBox = PendingSaveDestinationObservationResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
        readingItemAt: url,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = Result {
            do {
                let snapshot = try readSaveAsTargetSnapshot(
                    at: coordinatedURL,
                    fileManager: fileManager,
                    identityReader: identityReader
                )
                return .available(
                    identity: snapshot.identity,
                    digest: snapshot.digest,
                    providerConflictVersions:
                        try makeProviderConflictVersions(
                            unresolvedCount:
                                unresolvedVersionCountReader(coordinatedURL)
                        )
                )
            } catch FileAccessConnectorError.saveAsTargetChanged {
                return .missing
            } catch let FileAccessConnectorError.targetAlreadyExists(kind) {
                return .nonRegular(kind)
            }
        }
        .mapError { error in
            if let connectorError = error as? FileAccessConnectorError {
                return connectorError
            }
            return .unexpectedFileSystemFailure(
                code: (error as NSError).code
            )
        }
    }
    if let result = resultBox.result {
        return try result.get()
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func readSaveAsTargetSnapshot(
    at url: URL,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> SaveAsTargetSnapshot {
    let descriptor = open(
        fileManager.fileSystemRepresentation(withPath: url.path),
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        if errno == ENOENT {
            throw FileAccessConnectorError.saveAsTargetChanged
        }
        throw FileAccessConnectorError.saveAsTargetSnapshotReadFailed(
            code: Int(errno)
        )
    }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        let inspectionError = Int(errno)
        _ = close(descriptor)
        throw FileAccessConnectorError.saveAsTargetSnapshotReadFailed(
            code: inspectionError
        )
    }
    let itemKind = existingItemKind(mode: status.st_mode)
    guard itemKind == .regularFile else {
        _ = close(descriptor)
        throw FileAccessConnectorError.targetAlreadyExists(itemKind)
    }

    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let byteCount = buffer.withUnsafeMutableBytes { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }
        if byteCount > 0 {
            hasher.update(data: Data(buffer[0..<byteCount]))
            continue
        }
        if byteCount == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        let readError = Int(errno)
        _ = close(descriptor)
        throw FileAccessConnectorError.saveAsTargetSnapshotReadFailed(
            code: readError
        )
    }
    guard close(descriptor) == 0 else {
        throw FileAccessConnectorError.saveAsTargetSnapshotReadFailed(
            code: Int(errno)
        )
    }

    let identity: FileIdentity?
    do {
        identity = try identityReader(url)
    } catch let error as FileAccessConnectorError {
        throw error
    } catch {
        throw FileAccessConnectorError.fileIdentityInspectionFailed(
            code: (error as NSError).code
        )
    }
    let digest: FileDigest
    do {
        digest = try FileDigest(bytes: Data(hasher.finalize()))
    } catch {
        throw FileAccessConnectorError.outputVerificationFailed(
            .digestConstructionFailed
        )
    }
    return SaveAsTargetSnapshot(identity: identity, digest: digest)
}

private func resolveSaveAsDirectory(
    bookmark: FileBookmark,
    bookmarkResolver: FileAccessConnector.BookmarkResolver
) throws -> ResolvedFileBookmark {
    let resolvedBookmark: ResolvedFileBookmark
    do {
        resolvedBookmark = try bookmarkResolver(bookmark)
    } catch {
        throw FileAccessConnectorError.saveAsDirectoryBookmarkResolutionFailed(
            code: (error as NSError).code
        )
    }
    guard !resolvedBookmark.isStale else {
        throw FileAccessConnectorError.saveAsDirectoryBookmarkIsStale
    }
    return resolvedBookmark
}

private func validateSaveAsDirectory(
    at directoryURL: URL,
    fileManager: FileManager
) throws {
    switch try inspectNode(at: directoryURL, fileManager: fileManager) {
    case .missing:
        throw FileAccessConnectorError.selectedFolderMissing
    case .directory:
        return
    case let .existing(kind):
        throw FileAccessConnectorError.selectedLocationIsNotDirectory(kind)
    }
}

private func makeDirectSaveAsTargetURL(
    directoryURL: URL,
    fileName: ValidatedFileName
) throws -> URL {
    let targetURL = directoryURL.appendingPathComponent(
        fileName.value,
        isDirectory: false
    )
    guard targetURL.deletingLastPathComponent().standardizedFileURL
        == directoryURL.standardizedFileURL else {
        throw FileAccessConnectorError.directChildResolutionFailed
    }
    return targetURL
}

private func coordinatedCreateSaveAsTarget(
    stagingURL: URL,
    targetURL: URL,
    fileName: ValidatedFileName,
    encodedFile: EncodedTextFile,
    currentDocumentID: DocumentID,
    collisionClaims: [FileCollisionClaim],
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> FileSaveOutcome {
    let resultBox = SaveAsCommitResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
        writingItemAt: stagingURL,
        options: .forMoving,
        writingItemAt: targetURL,
        options: [],
        error: &coordinationError
    ) { coordinatedStagingURL, coordinatedTargetURL in
        resultBox.result = createCoordinatedSaveAsTarget(
            stagingURL: coordinatedStagingURL,
            targetURL: coordinatedTargetURL,
            expectedTargetURL: targetURL,
            fileName: fileName,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: collisionClaims,
            fileCoordinator: fileCoordinator,
            fileManager: fileManager,
            bookmarkCreator: bookmarkCreator,
            bookmarkResolver: bookmarkResolver,
            identityReader: identityReader
        )
    }

    if let result = resultBox.result {
        return try result.get()
    }
    let nodeKind = try inspectNode(at: targetURL, fileManager: fileManager)
    switch nodeKind {
    case .missing:
        break
    case .directory:
        throw FileAccessConnectorError.saveAsTargetAppeared(.directory)
    case let .existing(kind):
        throw FileAccessConnectorError.saveAsTargetAppeared(kind)
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func createCoordinatedSaveAsTarget(
    stagingURL: URL,
    targetURL: URL,
    expectedTargetURL: URL,
    fileName: ValidatedFileName,
    encodedFile: EncodedTextFile,
    currentDocumentID: DocumentID,
    collisionClaims: [FileCollisionClaim],
    fileCoordinator: NSFileCoordinator,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader
) -> Result<FileSaveOutcome, FileAccessConnectorError> {
    do {
        guard targetURL.standardizedFileURL == expectedTargetURL.standardizedFileURL else {
            throw FileAccessConnectorError.directChildResolutionFailed
        }
        switch try inspectNode(at: targetURL, fileManager: fileManager) {
        case .missing:
            break
        case .directory:
            throw FileAccessConnectorError.saveAsTargetAppeared(.directory)
        case let .existing(kind):
            throw FileAccessConnectorError.saveAsTargetAppeared(kind)
        }
        let matchingClaims = try matchingSaveAsCollisionClaims(
            targetURL: targetURL,
            targetIdentity: nil,
            claims: collisionClaims,
            bookmarkResolver: bookmarkResolver
        )
        if let collision = preferredBlockingSaveAsCollision(
            matchingClaims: matchingClaims,
            currentDocumentID: currentDocumentID
        ) {
            throw FileAccessConnectorError.saveAsTargetCollision(collision)
        }
        try verifyFile(
            at: stagingURL,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .staging
        )
        fileCoordinator.item(at: stagingURL, willMoveTo: targetURL)
        try renameExclusively(
            sourceURL: stagingURL,
            destinationURL: targetURL,
            fileManager: fileManager
        )
        fileCoordinator.item(at: stagingURL, didMoveTo: targetURL)
        try verifyFile(
            at: targetURL,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .output
        )
        return .success(
            makeVerifiedSaveAsOutcome(
                targetURL: targetURL,
                fileName: fileName,
                encodedFile: encodedFile,
                bookmarkCreator: bookmarkCreator,
                identityReader: identityReader
            )
        )
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        return .failure(
            .unexpectedFileSystemFailure(code: (error as NSError).code)
        )
    }
}

private func coordinatedReplaceSaveAsTarget(
    stagingURL: URL,
    targetURL: URL,
    fileName: ValidatedFileName,
    expectedSnapshot: SaveAsTargetSnapshot,
    encodedFile: EncodedTextFile,
    currentDocumentID: DocumentID,
    collisionClaims: [FileCollisionClaim],
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader,
    replacer: FileAccessConnector.FileReplacer
) throws -> SaveAsReplacementOperationResult {
    let resultBox = SaveAsReplacementOperationResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
        writingItemAt: stagingURL,
        options: .forMoving,
        writingItemAt: targetURL,
        options: .forReplacing,
        error: &coordinationError
    ) { coordinatedStagingURL, coordinatedTargetURL in
        resultBox.result = replaceCoordinatedSaveAsTarget(
            stagingURL: coordinatedStagingURL,
            targetURL: coordinatedTargetURL,
            expectedTargetURL: targetURL,
            fileName: fileName,
            expectedSnapshot: expectedSnapshot,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: collisionClaims,
            fileCoordinator: fileCoordinator,
            fileManager: fileManager,
            bookmarkCreator: bookmarkCreator,
            bookmarkResolver: bookmarkResolver,
            identityReader: identityReader,
            replacer: replacer
        )
    }

    if let result = resultBox.result {
        return result
    }
    switch try inspectNode(at: targetURL, fileManager: fileManager) {
    case .existing(.regularFile):
        break
    case .missing, .directory, .existing:
        throw FileAccessConnectorError.saveAsTargetChanged
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func replaceCoordinatedSaveAsTarget(
    stagingURL: URL,
    targetURL: URL,
    expectedTargetURL: URL,
    fileName: ValidatedFileName,
    expectedSnapshot: SaveAsTargetSnapshot,
    encodedFile: EncodedTextFile,
    currentDocumentID: DocumentID,
    collisionClaims: [FileCollisionClaim],
    fileCoordinator: NSFileCoordinator,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader,
    replacer: FileAccessConnector.FileReplacer
) -> SaveAsReplacementOperationResult {
    do {
        guard targetURL.standardizedFileURL == expectedTargetURL.standardizedFileURL else {
            throw FileAccessConnectorError.saveAsTargetChanged
        }
        try requireRegularSaveAsReplacementTarget(
            at: targetURL,
            fileManager: fileManager
        )
        let unresolvedVersions = NSFileVersion.unresolvedConflictVersionsOfItem(
            at: targetURL
        ) ?? []
        guard unresolvedVersions.isEmpty else {
            throw FileAccessConnectorError.saveAsTargetHasUnresolvedProviderVersions(
                count: unresolvedVersions.count
            )
        }
        let observedSnapshot = try readSaveAsTargetSnapshot(
            at: targetURL,
            fileManager: fileManager,
            identityReader: identityReader
        )
        guard observedSnapshot == expectedSnapshot else {
            throw FileAccessConnectorError.saveAsTargetChanged
        }
        let matchingClaims = try matchingSaveAsCollisionClaims(
            targetURL: targetURL,
            targetIdentity: observedSnapshot.identity,
            claims: collisionClaims,
            bookmarkResolver: bookmarkResolver
        )
        if let collision = preferredBlockingSaveAsCollision(
            matchingClaims: matchingClaims,
            currentDocumentID: currentDocumentID
        ) {
            throw FileAccessConnectorError.saveAsTargetCollision(collision)
        }
        try verifyFile(
            at: stagingURL,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .staging
        )

        fileCoordinator.item(at: stagingURL, willMoveTo: targetURL)
        let replacementURL: URL
        do {
            replacementURL = try replacer(targetURL, stagingURL, fileManager) ?? targetURL
        } catch {
            return classifyReportedSaveAsReplacementFailure(
                replacementError: error as NSError,
                stagingURL: stagingURL,
                targetURL: targetURL,
                fileName: fileName,
                expectedSnapshot: expectedSnapshot,
                encodedFile: encodedFile,
                fileCoordinator: fileCoordinator,
                fileManager: fileManager,
                bookmarkCreator: bookmarkCreator,
                collisionClaims: collisionClaims,
                bookmarkResolver: bookmarkResolver,
                identityReader: identityReader
            )
        }
        fileCoordinator.item(at: stagingURL, didMoveTo: replacementURL)
        let returnedFileName: ValidatedFileName
        do {
            returnedFileName = try validateReturnedSaveAsReplacementURL(
                replacementURL,
                expectedDirectoryURL: targetURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            let returnedSnapshot = try readSaveAsTargetSnapshot(
                at: replacementURL,
                fileManager: fileManager,
                identityReader: identityReader
            )
            let returnedClaims = try matchingSaveAsCollisionClaims(
                targetURL: replacementURL,
                targetIdentity: returnedSnapshot.identity,
                claims: collisionClaims,
                bookmarkResolver: bookmarkResolver
            )
            guard preferredBlockingSaveAsCollision(
                matchingClaims: returnedClaims,
                currentDocumentID: currentDocumentID
            ) == nil else {
                throw FileAccessConnectorError.postWriteOutcomeIndeterminate
            }
        } catch {
            return SaveAsReplacementOperationResult(
                result: .failure(.postWriteOutcomeIndeterminate),
                cleanupDisposition: .preserveStaging,
                recoveryRequest: nil
            )
        }
        let verificationResult = verifyCommittedSaveAsReplacement(
            targetURL: replacementURL,
            fileName: returnedFileName,
            encodedFile: encodedFile,
            fileManager: fileManager,
            bookmarkCreator: bookmarkCreator,
            identityReader: identityReader
        )
        switch verificationResult {
        case .success:
            return SaveAsReplacementOperationResult(
                result: verificationResult,
                cleanupDisposition: .cleanupAllowed,
                recoveryRequest: nil
            )
        case .failure:
            return SaveAsReplacementOperationResult(
                result: verificationResult,
                cleanupDisposition: .preserveStaging,
                recoveryRequest: nil
            )
        }
    } catch let error as FileAccessConnectorError {
        return SaveAsReplacementOperationResult(
            result: .failure(error),
            cleanupDisposition: .cleanupAllowed,
            recoveryRequest: nil
        )
    } catch {
        return SaveAsReplacementOperationResult(
            result: .failure(
                .unexpectedFileSystemFailure(code: (error as NSError).code)
            ),
            cleanupDisposition: .cleanupAllowed,
            recoveryRequest: nil
        )
    }
}

private func validateReturnedSaveAsReplacementURL(
    _ returnedURL: URL,
    expectedDirectoryURL: URL,
    fileManager: FileManager
) throws -> ValidatedFileName {
    guard returnedURL.isFileURL,
          returnedURL.deletingLastPathComponent().standardizedFileURL
            == expectedDirectoryURL.standardizedFileURL else {
        throw FileAccessConnectorError.postWriteOutcomeIndeterminate
    }
    try requireRegularSaveAsReplacementTarget(
        at: returnedURL,
        fileManager: fileManager
    )
    do {
        return try ValidatedFileName(validating: returnedURL.lastPathComponent)
    } catch {
        throw FileAccessConnectorError.postWriteOutcomeIndeterminate
    }
}

private func requireRegularSaveAsReplacementTarget(
    at targetURL: URL,
    fileManager: FileManager
) throws {
    switch try inspectNode(at: targetURL, fileManager: fileManager) {
    case .existing(.regularFile):
        return
    case .missing, .directory, .existing:
        throw FileAccessConnectorError.saveAsTargetChanged
    }
}

private func verifyCommittedSaveAsReplacement(
    targetURL: URL,
    fileName: ValidatedFileName,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader
) -> Result<FileSaveOutcome, FileAccessConnectorError> {
    do {
        let unresolvedVersions = NSFileVersion.unresolvedConflictVersionsOfItem(
            at: targetURL
        ) ?? []
        guard unresolvedVersions.isEmpty else {
            throw FileAccessConnectorError.postWriteOutcomeIndeterminate
        }
        do {
            try verifyFile(
                at: targetURL,
                expectedData: encodedFile.data,
                expectedDigest: encodedFile.digest,
                fileManager: fileManager,
                errorContext: .output
            )
        } catch {
            throw FileAccessConnectorError.postWriteOutcomeIndeterminate
        }
        return .success(
            makeVerifiedSaveAsOutcome(
                targetURL: targetURL,
                fileName: fileName,
                encodedFile: encodedFile,
                bookmarkCreator: bookmarkCreator,
                identityReader: identityReader
            )
        )
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        return .failure(.postWriteOutcomeIndeterminate)
    }
}

private func classifyReportedSaveAsReplacementFailure(
    replacementError: NSError,
    stagingURL: URL,
    targetURL: URL,
    fileName: ValidatedFileName,
    expectedSnapshot: SaveAsTargetSnapshot,
    encodedFile: EncodedTextFile,
    fileCoordinator: NSFileCoordinator,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    collisionClaims: [FileCollisionClaim],
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader
) -> SaveAsReplacementOperationResult {
    let verifiedReplacement = verifyCommittedSaveAsReplacement(
        targetURL: targetURL,
        fileName: fileName,
        encodedFile: encodedFile,
        fileManager: fileManager,
        bookmarkCreator: bookmarkCreator,
        identityReader: identityReader
    )
    if case .success = verifiedReplacement {
        fileCoordinator.item(at: stagingURL, didMoveTo: targetURL)
        return SaveAsReplacementOperationResult(
            result: verifiedReplacement,
            cleanupDisposition: .cleanupAllowed,
            recoveryRequest: nil
        )
    }
    let reportedLocation = reportedOriginalItemLocation(
        replacementError: replacementError,
        targetURL: targetURL,
        fileManager: fileManager
    )
    let reportedOriginalURL: URL?
    switch reportedLocation {
    case .absent:
        reportedOriginalURL = nil
    case let .valid(url):
        reportedOriginalURL = url
    case let .invalid(code):
        return SaveAsReplacementOperationResult(
            result: .failure(
                .replacementReportedItemPreservationFailed(
                    replacementCode: replacementError.code,
                    preservationCode: code,
                    generation: .unexpected
                )
            ),
            cleanupDisposition: .preserveStaging,
            recoveryRequest: nil
        )
    }
    let targetGeneration = observeSaveAsGeneration(
        at: targetURL,
        expectedSnapshot: expectedSnapshot,
        encodedFile: encodedFile,
        fileManager: fileManager,
        identityReader: identityReader
    )
    if targetGeneration == .original, reportedOriginalURL == nil {
        return SaveAsReplacementOperationResult(
            result: .failure(.replacementFailed(code: replacementError.code)),
            cleanupDisposition: .cleanupAllowed,
            recoveryRequest: nil
        )
    }
    if let reportedOriginalURL {
        let reportedObservation: SaveAsReportedItemObservation
        do {
            reportedObservation = try observeReportedSaveAsItem(
                at: reportedOriginalURL,
                expectedSnapshot: expectedSnapshot,
                encodedFile: encodedFile,
                fileManager: fileManager,
                identityReader: identityReader
            )
        } catch let error as FileAccessConnectorError {
            return SaveAsReplacementOperationResult(
                result: .failure(
                    .replacementReportedItemPreservationFailed(
                        replacementCode: replacementError.code,
                        preservationCode: preservationSystemCode(error: error),
                        generation: .unexpected
                    )
                ),
                cleanupDisposition: .preserveStaging,
                recoveryRequest: nil
            )
        } catch {
            return SaveAsReplacementOperationResult(
                result: .failure(
                    .replacementReportedItemPreservationFailed(
                        replacementCode: replacementError.code,
                        preservationCode: (error as NSError).code,
                        generation: .unexpected
                    )
                ),
                cleanupDisposition: .preserveStaging,
                recoveryRequest: nil
            )
        }
        let targetDirectoryURL = targetURL.deletingLastPathComponent()
        if isDirectChild(reportedOriginalURL, of: targetDirectoryURL) {
            let matchingClaims: [FileCollisionClaim]
            do {
                matchingClaims = try matchingSaveAsCollisionClaims(
                    targetURL: reportedOriginalURL,
                    targetIdentity: reportedObservation.snapshot.identity,
                    claims: collisionClaims,
                    bookmarkResolver: bookmarkResolver
                )
            } catch {
                return SaveAsReplacementOperationResult(
                    result: .failure(
                        .postWriteOutcomeIndeterminate
                    ),
                    cleanupDisposition: .preserveStaging,
                    recoveryRequest: nil
                )
            }
            guard matchingClaims.isEmpty else {
                return SaveAsReplacementOperationResult(
                    result: .failure(.postWriteOutcomeIndeterminate),
                    cleanupDisposition: .preserveStaging,
                    recoveryRequest: nil
                )
            }
            let preservedFileName: ValidatedFileName
            do {
                preservedFileName = try ValidatedFileName(
                    validating: reportedOriginalURL.lastPathComponent
                )
            } catch {
                return SaveAsReplacementOperationResult(
                    result: .failure(.selectedFileNameInvalid),
                    cleanupDisposition: .preserveStaging,
                    recoveryRequest: nil
                )
            }
            return SaveAsReplacementOperationResult(
                result: .failure(
                    .replacementReportedRelocatedItem(
                        code: replacementError.code,
                        generation: reportedObservation.generation,
                        preservedFileName: preservedFileName
                    )
                ),
                cleanupDisposition: reportedObservation.generation == .original
                    ? .cleanupAllowed
                    : .preserveStaging,
                recoveryRequest: nil
            )
        }
        return SaveAsReplacementOperationResult(
            result: .failure(
                .replacementOutcomeIndeterminate(code: replacementError.code)
            ),
            cleanupDisposition: .preserveStaging,
            recoveryRequest: SaveAsReportedItemRecoveryRequest(
                replacementErrorCode: replacementError.code,
                sourceURL: reportedOriginalURL,
                generation: reportedObservation.generation,
                snapshot: reportedObservation.snapshot
            )
        )
    }
    return SaveAsReplacementOperationResult(
        result: .failure(
            .replacementOutcomeIndeterminate(code: replacementError.code)
        ),
        cleanupDisposition: .preserveStaging,
        recoveryRequest: nil
    )
}

private func observeReportedSaveAsItem(
    at url: URL,
    expectedSnapshot: SaveAsTargetSnapshot,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> SaveAsReportedItemObservation {
    let snapshot = try readSaveAsTargetSnapshot(
        at: url,
        fileManager: fileManager,
        identityReader: identityReader
    )
    if snapshot == expectedSnapshot {
        return SaveAsReportedItemObservation(
            generation: .original,
            snapshot: snapshot
        )
    }
    do {
        try verifyFile(
            at: url,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .output
        )
        return SaveAsReportedItemObservation(
            generation: .intended,
            snapshot: snapshot
        )
    } catch {
        return SaveAsReportedItemObservation(
            generation: .unexpected,
            snapshot: snapshot
        )
    }
}

private func recoverReportedSaveAsItemDurably(
    request: SaveAsReportedItemRecoveryRequest,
    targetURL: URL,
    targetFileName: ValidatedFileName,
    encodedFile: EncodedTextFile,
    collisionClaims: [FileCollisionClaim],
    fileManager: FileManager,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader,
    saveAsRecoveryAccessorSourceProvider: FileAccessConnector.SaveAsRecoveryAccessorSourceProvider
) -> SaveAsReplacementOperationResult {
    do {
        var destination: (url: URL, fileName: ValidatedFileName)
        let targetIsAvailable: Bool
        switch try inspectNode(at: targetURL, fileManager: fileManager) {
        case .missing:
            if request.generation == .original {
                let targetClaims = try matchingSaveAsCollisionClaims(
                    targetURL: targetURL,
                    targetIdentity: nil,
                    claims: collisionClaims,
                    bookmarkResolver: bookmarkResolver
                )
                targetIsAvailable = targetClaims.isEmpty
            } else {
                targetIsAvailable = false
            }
        case .directory, .existing:
            targetIsAvailable = false
        }
        if targetIsAvailable {
            destination = (targetURL, targetFileName)
        } else {
            destination = try makeUnclaimedPreservedSaveAsDestination(
                directoryURL: targetURL.deletingLastPathComponent(),
                collisionClaims: collisionClaims,
                fileManager: fileManager,
                bookmarkResolver: bookmarkResolver
            )
        }
        do {
            try coordinatedMoveReportedSaveAsItem(
                request: request,
                destinationURL: destination.url,
                encodedFile: encodedFile,
                collisionClaims: collisionClaims,
                fileManager: fileManager,
                bookmarkResolver: bookmarkResolver,
                identityReader: identityReader,
                saveAsRecoveryAccessorSourceProvider: saveAsRecoveryAccessorSourceProvider
            )
        } catch let error as FileAccessConnectorError {
            guard targetIsAvailable, error.isSaveAsDestinationCollision else {
                throw error
            }
            destination = try makeUnclaimedPreservedSaveAsDestination(
                directoryURL: targetURL.deletingLastPathComponent(),
                collisionClaims: collisionClaims,
                fileManager: fileManager,
                bookmarkResolver: bookmarkResolver
            )
            try coordinatedMoveReportedSaveAsItem(
                request: request,
                destinationURL: destination.url,
                encodedFile: encodedFile,
                collisionClaims: collisionClaims,
                fileManager: fileManager,
                bookmarkResolver: bookmarkResolver,
                identityReader: identityReader,
                saveAsRecoveryAccessorSourceProvider: saveAsRecoveryAccessorSourceProvider
            )
        }
        return SaveAsReplacementOperationResult(
            result: .failure(
                .replacementReportedRelocatedItem(
                    code: request.replacementErrorCode,
                    generation: request.generation,
                    preservedFileName: destination.fileName
                )
            ),
            cleanupDisposition: .cleanupAllowed,
            recoveryRequest: nil
        )
    } catch let error as FileAccessConnectorError {
        return failedReportedSaveAsItemRecovery(
            request: request,
            preservationCode: preservationSystemCode(error: error)
        )
    } catch {
        return failedReportedSaveAsItemRecovery(
            request: request,
            preservationCode: (error as NSError).code
        )
    }
}

private func makeUnclaimedPreservedSaveAsDestination(
    directoryURL: URL,
    collisionClaims: [FileCollisionClaim],
    fileManager: FileManager,
    bookmarkResolver: FileAccessConnector.BookmarkResolver
) throws -> (url: URL, fileName: ValidatedFileName) {
    for _ in 0..<16 {
        let fileName = try ValidatedFileName(
            validating: "MacPad Mobile Preserved \(UUID().uuidString)"
        )
        let candidateURL = try makeDirectSaveAsTargetURL(
            directoryURL: directoryURL,
            fileName: fileName
        )
        guard case .missing = try inspectNode(
            at: candidateURL,
            fileManager: fileManager
        ) else {
            continue
        }
        let matchingClaims = try matchingSaveAsCollisionClaims(
            targetURL: candidateURL,
            targetIdentity: nil,
            claims: collisionClaims,
            bookmarkResolver: bookmarkResolver
        )
        guard matchingClaims.isEmpty else {
            continue
        }
        return (candidateURL, fileName)
    }
    throw FileAccessConnectorError.exclusiveCreationFailed(code: EEXIST)
}

private func coordinatedMoveReportedSaveAsItem(
    request: SaveAsReportedItemRecoveryRequest,
    destinationURL: URL,
    encodedFile: EncodedTextFile,
    collisionClaims: [FileCollisionClaim],
    fileManager: FileManager,
    bookmarkResolver: FileAccessConnector.BookmarkResolver,
    identityReader: FileAccessConnector.FileIdentityReader,
    saveAsRecoveryAccessorSourceProvider: FileAccessConnector.SaveAsRecoveryAccessorSourceProvider
) throws {
    let resultBox = SaveAsRecoveryMoveResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
        writingItemAt: request.sourceURL,
        options: .forMoving,
        writingItemAt: destinationURL,
        options: [],
        error: &coordinationError
    ) { coordinatedSourceURL, coordinatedDestinationURL in
        resultBox.result = Result {
            let accessorSourceURL = try saveAsRecoveryAccessorSourceProvider(
                coordinatedSourceURL,
                fileManager
            )
            guard accessorSourceURL.isFileURL,
                  coordinatedDestinationURL.isFileURL,
                  coordinatedDestinationURL == destinationURL else {
                throw FileAccessConnectorError.saveAsTargetChanged
            }
            let sourceDevice = try fileSystemDeviceID(
                at: accessorSourceURL,
                fileManager: fileManager
            )
            let destinationDevice = try fileSystemDeviceID(
                at: coordinatedDestinationURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            guard sourceDevice == destinationDevice else {
                throw FileAccessConnectorError.exclusiveCreationFailed(
                    code: EXDEV
                )
            }
            let sourceSnapshot = try readSaveAsTargetSnapshot(
                at: accessorSourceURL,
                fileManager: fileManager,
                identityReader: identityReader
            )
            guard sourceSnapshot == request.snapshot else {
                throw FileAccessConnectorError.saveAsTargetChanged
            }
            if request.generation == .intended {
                try verifyFile(
                    at: accessorSourceURL,
                    expectedData: encodedFile.data,
                    expectedDigest: encodedFile.digest,
                    fileManager: fileManager,
                    errorContext: .staging
                )
            }
            switch try inspectNode(
                at: coordinatedDestinationURL,
                fileManager: fileManager
            ) {
            case .missing:
                break
            case .directory:
                throw FileAccessConnectorError.targetAlreadyExists(.directory)
            case let .existing(kind):
                throw FileAccessConnectorError.targetAlreadyExists(kind)
            }
            let matchingClaims = try matchingSaveAsCollisionClaims(
                targetURL: coordinatedDestinationURL,
                targetIdentity: nil,
                claims: collisionClaims,
                bookmarkResolver: bookmarkResolver
            )
            if let collision = matchingClaims.first {
                throw FileAccessConnectorError.saveAsTargetCollision(collision)
            }
            fileCoordinator.item(
                at: accessorSourceURL,
                willMoveTo: coordinatedDestinationURL
            )
            try renameExclusively(
                sourceURL: accessorSourceURL,
                destinationURL: coordinatedDestinationURL,
                fileManager: fileManager
            )
            fileCoordinator.item(
                at: accessorSourceURL,
                didMoveTo: coordinatedDestinationURL
            )
            let destinationSnapshot = try readSaveAsTargetSnapshot(
                at: coordinatedDestinationURL,
                fileManager: fileManager,
                identityReader: identityReader
            )
            guard destinationSnapshot == request.snapshot else {
                throw FileAccessConnectorError.postWriteOutcomeIndeterminate
            }
            if request.generation == .intended {
                try verifyFile(
                    at: coordinatedDestinationURL,
                    expectedData: encodedFile.data,
                    expectedDigest: encodedFile.digest,
                    fileManager: fileManager,
                    errorContext: .output
                )
            }
            return coordinatedDestinationURL
        }
        .mapError { error in
            if let connectorError = error as? FileAccessConnectorError {
                return connectorError
            }
            return .unexpectedFileSystemFailure(code: (error as NSError).code)
        }
    }
    if let result = resultBox.result {
        _ = try result.get()
        return
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func retainSaveAsRecoveryAccessorSourceURL(
    sourceURL: URL,
    fileManager _: FileManager
) throws -> URL {
    sourceURL
}

private func failedReportedSaveAsItemRecovery(
    request: SaveAsReportedItemRecoveryRequest,
    preservationCode: Int
) -> SaveAsReplacementOperationResult {
    SaveAsReplacementOperationResult(
        result: .failure(
            .replacementReportedItemPreservationFailed(
                replacementCode: request.replacementErrorCode,
                preservationCode: preservationCode,
                generation: request.generation
            )
        ),
        cleanupDisposition: .preserveStaging,
        recoveryRequest: nil
    )
}

private func preservationSystemCode(error: FileAccessConnectorError) -> Int {
    switch error {
    case .saveAsTargetChanged:
        return Int(EBUSY)
    case .targetAlreadyExists:
        return Int(EEXIST)
    case .postWriteOutcomeIndeterminate:
        return Int(EIO)
    default:
        return error.systemCode
    }
}

private extension FileAccessConnectorError {
    var isSaveAsDestinationCollision: Bool {
        switch self {
        case .targetAlreadyExists:
            return true
        case let .exclusiveCreationFailed(code):
            return code == EEXIST
        case .saveAsTargetCollision:
            return true
        default:
            return false
        }
    }
}

private func reportedOriginalItemLocation(
    replacementError: NSError,
    targetURL: URL,
    fileManager: FileManager
) -> ReportedOriginalItemLocation {
    let rawValue = replacementError.userInfo["NSFileOriginalItemLocationKey"]
    let reportedURL: URL
    if let url = rawValue as? URL {
        reportedURL = url
    } else if let url = rawValue as? NSURL {
        reportedURL = url as URL
    } else if rawValue == nil {
        return .absent
    } else {
        return .invalid(code: Int(EINVAL))
    }
    guard reportedURL.isFileURL else {
        return .invalid(code: Int(EINVAL))
    }
    let standardizedURL = reportedURL.standardizedFileURL
    let reportedDevice: dev_t
    do {
        reportedDevice = try fileSystemDeviceID(
            at: standardizedURL,
            fileManager: fileManager
        )
    } catch let error as FileAccessConnectorError {
        return .invalid(code: preservationSystemCode(error: error))
    } catch {
        return .invalid(code: (error as NSError).code)
    }
    let targetDevice: dev_t
    do {
        targetDevice = try fileSystemDeviceID(
            at: targetURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
    } catch let error as FileAccessConnectorError {
        return .invalid(code: preservationSystemCode(error: error))
    } catch {
        return .invalid(code: (error as NSError).code)
    }
    guard reportedDevice == targetDevice else {
        return .invalid(code: Int(EXDEV))
    }
    return .valid(standardizedURL)
}

private func fileSystemDeviceID(
    at url: URL,
    fileManager: FileManager
) throws -> dev_t {
    var status = stat()
    let result = lstat(
        fileManager.fileSystemRepresentation(withPath: url.path),
        &status
    )
    guard result == 0 else {
        throw FileAccessConnectorError.fileSystemInspectionFailed(code: errno)
    }
    return status.st_dev
}

private func isDirectChild(_ url: URL, of directoryURL: URL) -> Bool {
    url.deletingLastPathComponent().standardizedFileURL
        == directoryURL.standardizedFileURL
}

private func observeSaveAsGeneration(
    at url: URL,
    expectedSnapshot: SaveAsTargetSnapshot,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader
) -> SaveAsObservedGeneration {
    do {
        try verifyFile(
            at: url,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .output
        )
        return .intended
    } catch {
        do {
            let snapshot = try readSaveAsTargetSnapshot(
                at: url,
                fileManager: fileManager,
                identityReader: identityReader
            )
            return snapshot == expectedSnapshot ? .original : .other
        } catch {
            return .other
        }
    }
}

private func makeVerifiedSaveAsOutcome(
    targetURL: URL,
    fileName: ValidatedFileName,
    encodedFile: EncodedTextFile,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader
) -> FileSaveOutcome {
    let detachedFile = VerifiedDetachedFile(
        displayName: fileName,
        digest: encodedFile.digest,
        encoding: encodedFile.encoding,
        lineEnding: encodedFile.lineEnding
    )
    let bookmark: FileBookmark
    do {
        bookmark = try FileBookmark(data: bookmarkCreator(targetURL))
    } catch {
        return .verifiedDetached(detachedFile)
    }
    let identity: FileIdentity?
    do {
        identity = try identityReader(targetURL)
    } catch {
        identity = nil
    }
    return .bound(
        FileBinding(
            locatorURL: targetURL,
            bookmark: bookmark,
            identity: identity,
            displayName: fileName,
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
    )
}

private func preferredBlockingSaveAsCollision(
    matchingClaims: [FileCollisionClaim],
    currentDocumentID: DocumentID
) -> FileCollisionClaim? {
    matchingClaims.first(where: { claim in
        !claim.isCurrentActiveFile(documentID: currentDocumentID)
    }) ?? matchingClaims.first
}

private func finishSaveAsStagingLocation(
    _ location: ReplacementStagingLocation,
    operationResult: Result<FileSaveOutcome, FileAccessConnectorError>,
    cleanupDisposition: SaveAsStagingCleanupDisposition,
    fileManager: FileManager,
    stagingCleaner: FileAccessConnector.SaveAsStagingCleaner
) throws -> SaveAsTargetCommitOutcome {
    if case .preserveStaging = cleanupDisposition {
        return .complete(try operationResult.get())
    }
    do {
        try stagingCleaner(
            location.directoryURL,
            location.fileURL,
            fileManager
        )
    } catch let cleanupError as ReplacementStagingCleanupError {
        switch operationResult {
        case let .success(outcome):
            return .verifiedWithResidualCleanup(
                outcome,
                code: cleanupError.code
            )
        case let .failure(precedingError):
            throw FileAccessConnectorError.replacementStagingCleanupFailed(
                code: cleanupError.code,
                after: precedingError
            )
        }
    } catch {
        let cleanupCode = (error as NSError).code
        switch operationResult {
        case let .success(outcome):
            return .verifiedWithResidualCleanup(
                outcome,
                code: cleanupCode
            )
        case let .failure(precedingError):
            throw FileAccessConnectorError.replacementStagingCleanupFailed(
                code: cleanupCode,
                after: precedingError
            )
        }
    }
    return .complete(try operationResult.get())
}

private func matchingSaveAsCollisionClaims(
    targetURL: URL,
    targetIdentity: FileIdentity?,
    claims: [FileCollisionClaim],
    bookmarkResolver: FileAccessConnector.BookmarkResolver
) throws -> [FileCollisionClaim] {
    var matches: [FileCollisionClaim] = []
    for claim in claims {
        if let reference = claim.fileReference {
            if let targetIdentity,
               let claimedIdentity = reference.identity,
               targetIdentity == claimedIdentity {
                matches.append(claim)
                continue
            }
            let resolvedURL = try resolveCollisionClaimURL(
                bookmark: reference.bookmark,
                documentID: claim.documentID,
                bookmarkResolver: bookmarkResolver
            )
            if resolvedURL.standardizedFileURL == targetURL.standardizedFileURL {
                matches.append(claim)
            }
            continue
        }
        guard let pendingDestination = claim.pendingSaveAsDestination else {
            continue
        }
        let resolvedDirectoryURL = try resolveCollisionClaimURL(
            bookmark: pendingDestination.directoryBookmark,
            documentID: claim.documentID,
            bookmarkResolver: bookmarkResolver
        )
        let claimedTargetURL = resolvedDirectoryURL.appendingPathComponent(
            pendingDestination.fileName.value,
            isDirectory: false
        )
        guard claimedTargetURL.deletingLastPathComponent().standardizedFileURL
            == resolvedDirectoryURL.standardizedFileURL else {
            throw FileAccessConnectorError.directChildResolutionFailed
        }
        if claimedTargetURL.standardizedFileURL == targetURL.standardizedFileURL {
            matches.append(claim)
        }
    }
    return matches
}

private func resolveCollisionClaimURL(
    bookmark: FileBookmark,
    documentID: DocumentID,
    bookmarkResolver: FileAccessConnector.BookmarkResolver
) throws -> URL {
    let resolvedBookmark: ResolvedFileBookmark
    do {
        resolvedBookmark = try bookmarkResolver(bookmark)
    } catch {
        throw FileAccessConnectorError.collisionClaimBookmarkResolutionFailed(
            documentID: documentID,
            code: (error as NSError).code
        )
    }
    guard !resolvedBookmark.isStale else {
        throw FileAccessConnectorError.collisionClaimBookmarkIsStale(
            documentID: documentID
        )
    }
    return resolvedBookmark.url
}

private extension SaveAsTargetExpectation {
    var snapshotIdentity: FileIdentity? {
        switch self {
        case .absent:
            return nil
        case let .existing(snapshot):
            return snapshot.identity
        }
    }
}

private extension FileCollisionClaim {
    func isCurrentActiveFile(documentID: DocumentID) -> Bool {
        switch self {
        case let .activeTab(claimedDocumentID, _):
            return claimedDocumentID == documentID
        case .recoveryItem, .pendingSaveAs:
            return false
        }
    }
}

private func readRegularFile(
    at url: URL,
    fileManager: FileManager
) -> Result<Data, RegularFileReadFailure> {
    let inspectedKind: FileSystemNodeKind
    do {
        inspectedKind = try inspectNode(at: url, fileManager: fileManager)
    } catch let error as FileAccessConnectorError {
        return .failure(.readFailed(code: error.systemCode))
    } catch {
        return .failure(.readFailed(code: (error as NSError).code))
    }
    switch inspectedKind {
    case .missing:
        return .failure(.missing)
    case .directory:
        return .failure(.itemIsNotRegularFile(.directory))
    case .existing(.regularFile):
        break
    case let .existing(kind):
        return .failure(.itemIsNotRegularFile(kind))
    }

    let descriptor = open(
        fileManager.fileSystemRepresentation(withPath: url.path),
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        if errno == ENOENT {
            return .failure(.missing)
        }
        return .failure(.readFailed(code: Int(errno)))
    }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        let readError = Int(errno)
        _ = close(descriptor)
        return .failure(.readFailed(code: readError))
    }
    let itemKind = existingItemKind(mode: status.st_mode)
    guard itemKind == .regularFile else {
        _ = close(descriptor)
        return .failure(.itemIsNotRegularFile(itemKind))
    }
    guard status.st_size >= 0, status.st_size <= Int64(Int.max) else {
        _ = close(descriptor)
        return .failure(.readFailed(code: Int(EOVERFLOW)))
    }
    let byteCount = Int(status.st_size)
    guard byteCount <= maximumSupportedTextFileByteCount else {
        _ = close(descriptor)
        return .failure(
            .tooLarge(
                actualByteCount: byteCount,
                maximumByteCount: maximumSupportedTextFileByteCount
            )
        )
    }

    let readResult = readBoundedRegularFile(
        descriptor: descriptor,
        expectedByteCount: byteCount
    )
    let closeResult = close(descriptor)
    if closeResult != 0 {
        return .failure(.readFailed(code: Int(errno)))
    }
    switch readResult {
    case let .success(data):
        return .success(data)
    case let .failure(.itemIsNotRegularFile(kind)):
        return .failure(.itemIsNotRegularFile(kind))
    case let .failure(.readFailed(code)):
        return .failure(.readFailed(code: code))
    case .failure(.byteCountMismatch),
         .failure(.contentMismatch),
         .failure(.digestMismatch),
         .failure(.digestConstructionFailed):
        return .failure(.readFailed(code: Int(EIO)))
    }
}

private func makeDigest(data: Data) throws -> FileDigest {
    do {
        return try FileDigest(bytes: Data(SHA256.hash(data: data)))
    } catch {
        throw FileAccessConnectorError.outputVerificationFailed(
            .digestConstructionFailed
        )
    }
}

private func makeReplacementStagingLocation(
    for originalURL: URL,
    fileManager: FileManager
) throws -> ReplacementStagingLocation {
    let directoryURL = try fileManager.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: originalURL,
        create: true
    )
    return ReplacementStagingLocation(
        directoryURL: directoryURL,
        fileURL: directoryURL.appendingPathComponent(
            "PhonePad-\(UUID().uuidString).staging",
            isDirectory: false
        )
    )
}

private func removeReplacementStagingLocation(
    _ location: ReplacementStagingLocation,
    fileManager: FileManager
) throws {
    let stagingResult = unlink(
        fileManager.fileSystemRepresentation(withPath: location.fileURL.path)
    )
    if stagingResult != 0, errno != ENOENT {
        throw ReplacementStagingCleanupError(code: Int(errno))
    }
    let directoryResult = rmdir(
        fileManager.fileSystemRepresentation(withPath: location.directoryURL.path)
    )
    if directoryResult != 0, errno != ENOENT {
        throw ReplacementStagingCleanupError(code: Int(errno))
    }
}

private func makeLegacyBoundFileCoordination(
    fileManager: FileManager,
    identityReader: @escaping FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: @escaping FileAccessConnector.UnresolvedVersionCountReader,
    replacer: @escaping FileAccessConnector.FileReplacer
) -> BoundFileCoordination {
    let fileManagerReference = FileManagerReference(fileManager: fileManager)
    return BoundFileCoordination(
        targetURL: { resolvedURL in resolvedURL },
        replace: { binding, resolvedURL, stagingURL, encodedFile in
            try coordinatedReplaceBoundFile(
                binding: binding,
                resolvedURL: resolvedURL,
                stagingURL: stagingURL,
                encodedFile: encodedFile,
                fileManager: fileManagerReference.fileManager,
                identityReader: identityReader,
                unresolvedVersionCountReader: unresolvedVersionCountReader,
                filePresenter: nil,
                replacer: replacer
            )
        },
        verify: { url, expectedIdentity, encodedFile in
            try coordinatedVerifySavedFile(
                at: url,
                expectedIdentity: expectedIdentity,
                encodedFile: encodedFile,
                fileManager: fileManagerReference.fileManager,
                identityReader: identityReader,
                unresolvedVersionCountReader: unresolvedVersionCountReader,
                filePresenter: nil
            )
        }
    )
}

private func makePresentedBoundFileCoordination(
    presenter: PresentedFile,
    fileManager: FileManager,
    identityReader: @escaping FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: @escaping FileAccessConnector.UnresolvedVersionCountReader,
    replacer: @escaping FileAccessConnector.FileReplacer
) -> BoundFileCoordination {
    let fileManagerReference = FileManagerReference(fileManager: fileManager)
    return BoundFileCoordination(
        targetURL: { _ in
            try presenter.performSynchronousAccess {
                presenter.currentPresentedItemURL()
            }
        },
        replace: { binding, _, stagingURL, encodedFile in
            try presenter.performSynchronousAccess {
                let accessURL = presenter.currentPresentedItemURL()
                let replacementURL = try coordinatedReplaceBoundFile(
                    binding: binding,
                    resolvedURL: accessURL,
                    stagingURL: stagingURL,
                    encodedFile: encodedFile,
                    fileManager: fileManagerReference.fileManager,
                    identityReader: identityReader,
                    unresolvedVersionCountReader: unresolvedVersionCountReader,
                    filePresenter: presenter,
                    replacer: replacer
                )
                presenter.updatePresentedItemURL(replacementURL)
                return replacementURL
            }
        },
        verify: { _, expectedIdentity, encodedFile in
            try presenter.performSynchronousAccess {
                let accessURL = presenter.currentPresentedItemURL()
                let verifiedFile = try coordinatedVerifySavedFile(
                    at: accessURL,
                    expectedIdentity: expectedIdentity,
                    encodedFile: encodedFile,
                    fileManager: fileManagerReference.fileManager,
                    identityReader: identityReader,
                    unresolvedVersionCountReader: unresolvedVersionCountReader,
                    filePresenter: presenter
                )
                presenter.updatePresentedItemURL(verifiedFile.url)
                return verifiedFile
            }
        }
    )
}

private func coordinatedReplaceBoundFile(
    binding: FileBinding,
    resolvedURL: URL,
    stagingURL: URL,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader,
    filePresenter: NSFilePresenter?,
    replacer: FileAccessConnector.FileReplacer
) throws -> URL {
    let resultBox = BoundFileReplacementResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: filePresenter)
    fileCoordinator.coordinate(
        writingItemAt: resolvedURL,
        options: [],
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = replaceCoordinatedBoundFile(
            binding: binding,
            coordinatedURL: coordinatedURL,
            stagingURL: stagingURL,
            encodedFile: encodedFile,
            fileManager: fileManager,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader,
            replacer: replacer
        )
    }

    if let result = resultBox.result {
        return try result.get()
    }
    if let coordinationError {
        throw FileAccessConnectorError.fileCoordinationFailed(
            code: coordinationError.code
        )
    }
    throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
}

private func replaceCoordinatedBoundFile(
    binding: FileBinding,
    coordinatedURL: URL,
    stagingURL: URL,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader,
    replacer: FileAccessConnector.FileReplacer
) -> Result<URL, FileAccessConnectorError> {
    do {
        if binding.identity == nil,
           coordinatedURL.standardizedFileURL != binding.locatorURL.standardizedFileURL {
            throw FileAccessConnectorError.fileConflict(.ambiguousLocatorChange)
        }
        let unresolvedVersionCount = unresolvedVersionCountReader(coordinatedURL)
        guard unresolvedVersionCount >= 0 else {
            throw FileAccessConnectorError.providerConflictVersionCountInvalid(
                count: unresolvedVersionCount
            )
        }
        guard unresolvedVersionCount == 0 else {
            throw FileAccessConnectorError.fileConflict(
                .unresolvedProviderVersions(count: unresolvedVersionCount)
            )
        }
        let originalObservation = try readBoundFileObservation(
            at: coordinatedURL,
            fileManager: fileManager,
            identityReader: identityReader
        )
        guard originalObservation.identity == binding.identity else {
            throw FileAccessConnectorError.fileConflict(.stableIdentityChanged)
        }
        guard originalObservation.digest == binding.digest else {
            throw FileAccessConnectorError.fileConflict(.contentChanged)
        }
        try verifyFile(
            at: stagingURL,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .staging
        )

        do {
            return .success(
                try replacer(coordinatedURL, stagingURL, fileManager) ?? coordinatedURL
            )
        } catch {
            let replacementErrorCode = (error as NSError).code
            let observedResult = Result {
                try readBoundFileObservation(
                    at: coordinatedURL,
                    fileManager: fileManager,
                    identityReader: identityReader
                )
            }
            switch observedResult {
            case let .success(observation)
                where observation.identity == binding.identity
                    && observation.digest == encodedFile.digest
                    && observation.data == encodedFile.data:
                return .success(coordinatedURL)
            case let .success(observation)
                where observation.identity == binding.identity
                    && observation.digest == originalObservation.digest
                    && observation.data == originalObservation.data:
                return .failure(
                    .replacementFailed(code: replacementErrorCode)
                )
            case .success, .failure:
                return .failure(
                    .replacementOutcomeIndeterminate(code: replacementErrorCode)
                )
            }
        }
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        return .failure(
            .unexpectedFileSystemFailure(code: (error as NSError).code)
        )
    }
}

private func coordinatedVerifySavedFile(
    at url: URL,
    expectedIdentity: FileIdentity?,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader,
    filePresenter: NSFilePresenter?
) throws -> VerifiedSavedFile {
    let resultBox = SavedFileVerificationResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: filePresenter)
    fileCoordinator.coordinate(
        readingItemAt: url,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = verifyCoordinatedSavedFile(
            at: coordinatedURL,
            expectedIdentity: expectedIdentity,
            encodedFile: encodedFile,
            fileManager: fileManager,
            identityReader: identityReader,
            unresolvedVersionCountReader: unresolvedVersionCountReader
        )
    }

    if let result = resultBox.result {
        return try result.get()
    }
    if coordinationError != nil {
        throw FileAccessConnectorError.postWriteOutcomeIndeterminate
    }
    throw FileAccessConnectorError.postWriteOutcomeIndeterminate
}

private func verifyCoordinatedSavedFile(
    at url: URL,
    expectedIdentity: FileIdentity?,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: FileAccessConnector.UnresolvedVersionCountReader
) -> Result<VerifiedSavedFile, FileAccessConnectorError> {
    do {
        let unresolvedVersionCount = unresolvedVersionCountReader(url)
        guard unresolvedVersionCount >= 0 else {
            return .failure(
                .providerConflictVersionCountInvalid(count: unresolvedVersionCount)
            )
        }
        guard unresolvedVersionCount == 0 else {
            return .failure(.postWriteOutcomeIndeterminate)
        }
        let observation = try readBoundFileObservation(
            at: url,
            fileManager: fileManager,
            identityReader: identityReader
        )
        guard observation.identity == expectedIdentity,
              observation.digest == encodedFile.digest,
              observation.data == encodedFile.data else {
            return .failure(.postWriteOutcomeIndeterminate)
        }
        return .success(
            VerifiedSavedFile(url: url, identity: observation.identity)
        )
    } catch {
        return .failure(.postWriteOutcomeIndeterminate)
    }
}

private func createCoordinatedFile(
    stagingURL: URL,
    coordinatedTargetURL: URL,
    fileName: ValidatedFileName,
    encodedFile: EncodedTextFile,
    fileCoordinator: NSFileCoordinator,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader
) -> Result<FileCreationOutcome, FileAccessConnectorError> {
    do {
        try requireAbsentTarget(at: coordinatedTargetURL, fileManager: fileManager)
        try verifyFile(
            at: stagingURL,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .staging
        )
        fileCoordinator.item(
            at: stagingURL,
            willMoveTo: coordinatedTargetURL
        )
        try renameExclusively(
            sourceURL: stagingURL,
            destinationURL: coordinatedTargetURL,
            fileManager: fileManager
        )
        fileCoordinator.item(
            at: stagingURL,
            didMoveTo: coordinatedTargetURL
        )
        try verifyFile(
            at: coordinatedTargetURL,
            expectedData: encodedFile.data,
            expectedDigest: encodedFile.digest,
            fileManager: fileManager,
            errorContext: .output
        )

        let detachedFile = VerifiedDetachedFile(
            displayName: fileName,
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
        let identity: FileIdentity?
        do {
            identity = try identityReader(coordinatedTargetURL)
        } catch {
            return .success(.verifiedDetached(detachedFile))
        }
        let bookmark: FileBookmark
        do {
            bookmark = try FileBookmark(data: bookmarkCreator(coordinatedTargetURL))
        } catch {
            return .success(.verifiedDetached(detachedFile))
        }

        let binding = FileBinding(
            locatorURL: coordinatedTargetURL,
            bookmark: bookmark,
            identity: identity,
            displayName: fileName,
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
        return .success(.bound(binding))
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        return .failure(.unexpectedFileSystemFailure(code: (error as NSError).code))
    }
}

private func requireAbsentTarget(
    at url: URL,
    fileManager: FileManager
) throws {
    switch try inspectNode(at: url, fileManager: fileManager) {
    case .missing:
        return
    case .directory:
        throw FileAccessConnectorError.targetAlreadyExists(.directory)
    case let .existing(kind):
        throw FileAccessConnectorError.targetAlreadyExists(kind)
    }
}

private func inspectNode(
    at url: URL,
    fileManager: FileManager
) throws -> FileSystemNodeKind {
    var status = stat()
    let result = lstat(fileManager.fileSystemRepresentation(withPath: url.path), &status)
    guard result == 0 else {
        let inspectionError = errno
        if inspectionError == ENOENT {
            return .missing
        }
        throw FileAccessConnectorError.fileSystemInspectionFailed(code: inspectionError)
    }

    let kind = existingItemKind(mode: status.st_mode)
    switch kind {
    case .directory:
        return .directory
    case .regularFile, .symbolicLink, .special:
        return .existing(kind)
    }
}

private func inspectSelectedFileNodePresence(
    at url: URL,
    fileManager: FileManager
) throws -> SelectedFileNodePresence {
    switch try inspectNode(at: url, fileManager: fileManager) {
    case .missing:
        return .missing
    case .directory, .existing:
        return .present
    }
}

private func renameExclusively(
    sourceURL: URL,
    destinationURL: URL,
    fileManager: FileManager
) throws {
    let result = sourceURL.path.withCString { sourcePath in
        destinationURL.path.withCString { destinationPath in
            renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
        }
    }
    guard result == 0 else {
        let renameError = errno
        if renameError == EEXIST {
            try requireAbsentTarget(at: destinationURL, fileManager: fileManager)
            throw FileAccessConnectorError.exclusiveCreationFailed(code: renameError)
        }
        throw FileAccessConnectorError.exclusiveCreationFailed(code: renameError)
    }
}

private func verifyFile(
    at url: URL,
    expectedData: Data,
    expectedDigest: FileDigest,
    fileManager: FileManager,
    errorContext: FileVerificationContext
) throws {
    let actualData: Data
    switch readBoundedRegularFile(
        at: url,
        expectedByteCount: expectedData.count,
        fileManager: fileManager
    ) {
    case let .success(data):
        actualData = data
    case let .failure(failure):
        throw verificationError(failure: failure, context: errorContext)
    }
    guard actualData.count == expectedData.count else {
        throw verificationError(
            failure: .byteCountMismatch(
                expected: expectedData.count,
                actual: actualData.count
            ),
            context: errorContext
        )
    }
    guard actualData == expectedData else {
        throw verificationError(failure: .contentMismatch, context: errorContext)
    }

    let actualDigest: FileDigest
    do {
        actualDigest = try FileDigest(bytes: Data(SHA256.hash(data: actualData)))
    } catch {
        throw verificationError(
            failure: .digestConstructionFailed,
            context: errorContext
        )
    }
    guard actualDigest == expectedDigest else {
        throw verificationError(failure: .digestMismatch, context: errorContext)
    }
}

private func readBoundedRegularFile(
    at url: URL,
    expectedByteCount: Int,
    fileManager: FileManager
) -> Result<Data, FileVerificationFailure> {
    guard expectedByteCount <= maximumSupportedTextFileByteCount else {
        return .failure(
            .byteCountMismatch(
                expected: maximumSupportedTextFileByteCount,
                actual: expectedByteCount
            )
        )
    }

    let descriptor = open(
        fileManager.fileSystemRepresentation(withPath: url.path),
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        return .failure(.readFailed(code: Int(errno)))
    }

    let readResult = readBoundedRegularFile(
        descriptor: descriptor,
        expectedByteCount: expectedByteCount
    )
    let closeResult = close(descriptor)
    if closeResult != 0 {
        return .failure(.readFailed(code: Int(errno)))
    }
    return readResult
}

private func readBoundedRegularFile(
    descriptor: Int32,
    expectedByteCount: Int
) -> Result<Data, FileVerificationFailure> {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        return .failure(.readFailed(code: Int(errno)))
    }

    let itemKind = existingItemKind(mode: status.st_mode)
    guard itemKind == .regularFile else {
        return .failure(.itemIsNotRegularFile(itemKind))
    }
    guard status.st_size >= 0, status.st_size <= Int64(Int.max) else {
        return .failure(.readFailed(code: Int(EOVERFLOW)))
    }

    let inspectedByteCount = Int(status.st_size)
    guard inspectedByteCount == expectedByteCount else {
        return .failure(
            .byteCountMismatch(
                expected: expectedByteCount,
                actual: inspectedByteCount
            )
        )
    }

    var data = Data()
    data.reserveCapacity(expectedByteCount + 1)
    while data.count <= expectedByteCount {
        let remainingByteCount = expectedByteCount + 1 - data.count
        if remainingByteCount == 0 {
            break
        }
        var buffer = [UInt8](
            repeating: 0,
            count: min(64 * 1024, remainingByteCount)
        )
        let readByteCount = buffer.withUnsafeMutableBytes { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }
        if readByteCount > 0 {
            data.append(contentsOf: buffer.prefix(readByteCount))
            continue
        }
        if readByteCount == 0 {
            break
        }
        if errno == EINTR {
            continue
        }
        return .failure(.readFailed(code: Int(errno)))
    }

    guard data.count == expectedByteCount else {
        return .failure(
            .byteCountMismatch(
                expected: expectedByteCount,
                actual: data.count
            )
        )
    }
    return .success(data)
}

private func existingItemKind(mode: mode_t) -> ExistingFileSystemItemKind {
    switch mode & S_IFMT {
    case S_IFREG:
        return .regularFile
    case S_IFDIR:
        return .directory
    case S_IFLNK:
        return .symbolicLink
    default:
        return .special
    }
}

private extension FileAccessConnectorError {
    var systemCode: Int {
        switch self {
        case let .fileSystemInspectionFailed(code):
            return Int(code)
        default:
            return (self as NSError).code
        }
    }
}

private func verificationError(
    failure: FileVerificationFailure,
    context: FileVerificationContext
) -> FileAccessConnectorError {
    switch context {
    case .staging:
        return .stagingVerificationFailed(failure)
    case .output:
        return .outputVerificationFailed(failure)
    }
}

func removeStagingIfPresent(
    at stagingURL: URL,
    fileManager: FileManager,
    precedingError: FileAccessConnectorError,
    beforeUnlink: @Sendable () throws -> Void
) throws {
    let kind: FileSystemNodeKind
    do {
        kind = try inspectNode(at: stagingURL, fileManager: fileManager)
    } catch let error as FileAccessConnectorError {
        throw FileAccessConnectorError.stagingCleanupFailed(
            code: error.systemCode,
            after: precedingError
        )
    }
    switch kind {
    case .missing:
        return
    case .existing(.regularFile):
        break
    case .directory:
        throw FileAccessConnectorError.unsafeStagingCleanupRefused(
            .directory,
            after: precedingError
        )
    case let .existing(itemKind):
        throw FileAccessConnectorError.unsafeStagingCleanupRefused(
            itemKind,
            after: precedingError
        )
    }
    do {
        try beforeUnlink()
    } catch {
        throw FileAccessConnectorError.stagingCleanupFailed(
            code: (error as NSError).code,
            after: precedingError
        )
    }

    let unlinkResult = unlink(
        fileManager.fileSystemRepresentation(withPath: stagingURL.path)
    )
    guard unlinkResult != 0 else {
        return
    }

    let unlinkError = errno
    let replacementKind: FileSystemNodeKind
    do {
        replacementKind = try inspectNode(at: stagingURL, fileManager: fileManager)
    } catch let error as FileAccessConnectorError {
        throw FileAccessConnectorError.stagingCleanupFailed(
            code: error.systemCode,
            after: precedingError
        )
    }
    switch replacementKind {
    case .missing:
        return
    case .directory:
        throw FileAccessConnectorError.unsafeStagingCleanupRefused(
            .directory,
            after: precedingError
        )
    case .existing(.directory):
        throw FileAccessConnectorError.unsafeStagingCleanupRefused(
            .directory,
            after: precedingError
        )
    case .existing(.symbolicLink):
        throw FileAccessConnectorError.unsafeStagingCleanupRefused(
            .symbolicLink,
            after: precedingError
        )
    case .existing(.special):
        throw FileAccessConnectorError.unsafeStagingCleanupRefused(
            .special,
            after: precedingError
        )
    case .existing(.regularFile):
        throw FileAccessConnectorError.stagingCleanupFailed(
            code: Int(unlinkError),
            after: precedingError
        )
    }
}

private struct PresentationChangeStream: Sendable {
    let stream: AsyncStream<DocumentID>
    let relay: PresentationHintRelay
}

private let maximumBufferedPresentationChangeHintCount: Int = 64

private func makePresentationChangeStream() -> PresentationChangeStream {
    let pair = AsyncStream<DocumentID>.makeStream(
        bufferingPolicy: .bufferingNewest(
            maximumBufferedPresentationChangeHintCount
        )
    )
    return PresentationChangeStream(
        stream: pair.stream,
        relay: PresentationHintRelay(continuation: pair.continuation)
    )
}

private func readUnresolvedVersionCount(url: URL) -> Int {
    NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.count ?? 0
}

private func makeProviderConflictVersions(
    unresolvedCount: Int
) throws -> FileProviderConflictVersions {
    guard unresolvedCount >= 0 else {
        throw FileAccessConnectorError.providerConflictVersionCountInvalid(
            count: unresolvedCount
        )
    }
    guard unresolvedCount > 0 else {
        return .none
    }
    return .unresolved(count: unresolvedCount)
}
