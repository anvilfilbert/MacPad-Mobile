import CryptoKit
import Darwin
import Foundation
import PhonePadCore

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

public struct OpenedUTF8File: Equatable, Sendable {
    public let text: String
    public let binding: FileBinding

    public init(text: String, binding: FileBinding) {
        self.text = text
        self.binding = binding
    }
}

public enum FileSaveOutcome: Equatable, Sendable {
    case bound(FileBinding)
    case verifiedDetached(VerifiedDetachedFile)
}

public enum BoundFileConflict: Equatable, Sendable {
    case contentChanged
    case stableIdentityChanged
    case ambiguousLocatorChange
    case unresolvedProviderVersions(count: Int)
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
    case inputTooLarge(actualByteCount: Int, maximumByteCount: Int)
    case inputReadFailed(code: Int)
    case inputIsNotUTF8
    case selectedFileNameInvalid
    case fileIdentityInspectionFailed(code: Int)
    case fileIdentityValueInvalid
    case bookmarkCreationFailed(code: Int)
    case bookmarkResolutionFailed(code: Int)
    case bookmarkRefreshFailed(code: Int)
    case boundFileMissing
    case boundFileIsNotRegularFile(ExistingFileSystemItemKind)
    case fileConflict(BoundFileConflict)
    case replacementStagingCreationFailed(code: Int)
    case replacementFailed(code: Int)
    case replacementOutcomeIndeterminate(code: Int)
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
        case let .inputTooLarge(actualByteCount, maximumByteCount):
            return "Selected File is \(actualByteCount) bytes; PhonePad supports at most \(maximumByteCount) bytes."
        case let .inputReadFailed(code):
            return "Selected File could not be read (system code \(code)). Check Files access and try again."
        case .inputIsNotUTF8:
            return "Selected File is not valid UTF-8 plain text. Choose another File."
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

private extension BoundFileConflict {
    var description: String {
        switch self {
        case .contentChanged:
            return "Original File content changed outside PhonePad. It was not overwritten; resolve the File Conflict explicitly."
        case .stableIdentityChanged:
            return "Original File identity changed outside PhonePad. It was not overwritten; locate the original or use Save As."
        case .ambiguousLocatorChange:
            return "Original File moved without a stable provider identity. It was not overwritten; locate the original or use Save As."
        case let .unresolvedProviderVersions(count):
            return "Original File has \(count) unresolved provider conflict version(s). Resolve them in the provider before Save."
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

    private let fileManager: FileManager
    private let bookmarkCreator: BookmarkCreator
    private let bookmarkResolver: BookmarkResolver
    private let identityReader: FileIdentityReader
    private let replacer: FileReplacer

    public init(fileManager: FileManager) {
        self.fileManager = fileManager
        self.bookmarkCreator = createBookmarkData
        self.bookmarkResolver = resolveBookmark
        self.identityReader = readPersistentFileIdentity
        self.replacer = replaceFileSafely
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator
    ) {
        self.fileManager = fileManager
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = resolveBookmark
        self.identityReader = readPersistentFileIdentity
        self.replacer = replaceFileSafely
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator,
        bookmarkResolver: @escaping BookmarkResolver,
        identityReader: @escaping FileIdentityReader,
        replacer: @escaping FileReplacer
    ) {
        self.fileManager = fileManager
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
        self.identityReader = identityReader
        self.replacer = replacer
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

    public func openUTF8File(at selectedURL: URL) throws -> OpenedUTF8File {
        let didStartSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        try requireSelectedRegularFile(at: selectedURL, fileManager: fileManager)

        let resultBox = OpenFileCoordinationResultBox()
        var coordinationError: NSError?
        let fileCoordinator = NSFileCoordinator(filePresenter: nil)
        let fileManager = fileManager
        let bookmarkCreator = bookmarkCreator
        let identityReader = identityReader
        fileCoordinator.coordinate(
            readingItemAt: selectedURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            resultBox.result = openCoordinatedUTF8File(
                at: coordinatedURL,
                fileManager: fileManager,
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

    public func saveUTF8File(
        binding: FileBinding,
        encodedFile: EncodedTextFile
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

        if binding.identity == nil,
           resolvedURL.standardizedFileURL != binding.locatorURL.standardizedFileURL {
            throw FileAccessConnectorError.fileConflict(.ambiguousLocatorChange)
        }

        if resolvedBookmark.isStale {
            do {
                _ = try FileBookmark(data: bookmarkCreator(resolvedURL))
            } catch {
                throw FileAccessConnectorError.bookmarkRefreshFailed(
                    code: (error as NSError).code
                )
            }
        }

        let stagingLocation: ReplacementStagingLocation
        do {
            stagingLocation = try makeReplacementStagingLocation(
                for: resolvedURL,
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
            let replacementURL = try coordinatedReplaceBoundFile(
                binding: binding,
                resolvedURL: resolvedURL,
                stagingURL: stagingLocation.fileURL,
                encodedFile: encodedFile,
                fileManager: fileManager,
                identityReader: identityReader,
                replacer: replacer
            )
            let verifiedFile = try coordinatedVerifySavedFile(
                at: replacementURL,
                expectedIdentity: binding.identity,
                encodedFile: encodedFile,
                fileManager: fileManager,
                identityReader: identityReader
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

private struct ReplacementStagingLocation: Sendable {
    let directoryURL: URL
    let fileURL: URL
}

private struct ReplacementStagingCleanupError: Error, Sendable {
    let code: Int
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

private enum RegularFileReadFailure: Error, Equatable, Sendable {
    case missing
    case itemIsNotRegularFile(ExistingFileSystemItemKind)
    case tooLarge(actualByteCount: Int, maximumByteCount: Int)
    case readFailed(code: Int)
}

private final class OpenFileCoordinationResultBox: @unchecked Sendable {
    var result: Result<OpenedUTF8File, FileAccessConnectorError>?
}

private final class BoundFileReplacementResultBox: @unchecked Sendable {
    var result: Result<URL, FileAccessConnectorError>?
}

private final class SavedFileVerificationResultBox: @unchecked Sendable {
    var result: Result<VerifiedSavedFile, FileAccessConnectorError>?
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

private func openCoordinatedUTF8File(
    at url: URL,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator,
    identityReader: FileAccessConnector.FileIdentityReader
) -> Result<OpenedUTF8File, FileAccessConnectorError> {
    do {
        let data = try readSelectedFile(at: url, fileManager: fileManager)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FileAccessConnectorError.inputIsNotUTF8
        }
        let digest = try makeDigest(data: data)
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
            digest: digest,
            encoding: .utf8,
            lineEnding: .lf
        )
        return .success(OpenedUTF8File(text: text, binding: binding))
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        return .failure(
            .unexpectedFileSystemFailure(code: (error as NSError).code)
        )
    }
}

private func requireSelectedRegularFile(
    at url: URL,
    fileManager: FileManager
) throws {
    switch try inspectNode(at: url, fileManager: fileManager) {
    case .missing:
        throw FileAccessConnectorError.selectedFileMissing
    case .directory:
        throw FileAccessConnectorError.selectedFileIsNotRegularFile(.directory)
    case .existing(.regularFile):
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

private func coordinatedReplaceBoundFile(
    binding: FileBinding,
    resolvedURL: URL,
    stagingURL: URL,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    replacer: FileAccessConnector.FileReplacer
) throws -> URL {
    let resultBox = BoundFileReplacementResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
    fileCoordinator.coordinate(
        writingItemAt: resolvedURL,
        options: [],
        error: &coordinationError
    ) { coordinatedURL in
        resultBox.result = replaceCoordinatedBoundFile(
            binding: binding,
            resolvedURL: resolvedURL,
            coordinatedURL: coordinatedURL,
            stagingURL: stagingURL,
            encodedFile: encodedFile,
            fileManager: fileManager,
            identityReader: identityReader,
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
    resolvedURL: URL,
    coordinatedURL: URL,
    stagingURL: URL,
    encodedFile: EncodedTextFile,
    fileManager: FileManager,
    identityReader: FileAccessConnector.FileIdentityReader,
    replacer: FileAccessConnector.FileReplacer
) -> Result<URL, FileAccessConnectorError> {
    do {
        if binding.identity == nil,
           coordinatedURL.standardizedFileURL != resolvedURL.standardizedFileURL {
            throw FileAccessConnectorError.fileConflict(.ambiguousLocatorChange)
        }
        let unresolvedVersions = NSFileVersion.unresolvedConflictVersionsOfItem(
            at: coordinatedURL
        ) ?? []
        guard unresolvedVersions.isEmpty else {
            throw FileAccessConnectorError.fileConflict(
                .unresolvedProviderVersions(count: unresolvedVersions.count)
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
    identityReader: FileAccessConnector.FileIdentityReader
) throws -> VerifiedSavedFile {
    let resultBox = SavedFileVerificationResultBox()
    var coordinationError: NSError?
    let fileCoordinator = NSFileCoordinator(filePresenter: nil)
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
            identityReader: identityReader
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
    identityReader: FileAccessConnector.FileIdentityReader
) -> Result<VerifiedSavedFile, FileAccessConnectorError> {
    do {
        let unresolvedVersions = NSFileVersion.unresolvedConflictVersionsOfItem(
            at: url
        ) ?? []
        guard unresolvedVersions.isEmpty else {
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
