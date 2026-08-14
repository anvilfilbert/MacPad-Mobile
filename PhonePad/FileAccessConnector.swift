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
        case let .unexpectedFileSystemFailure(code):
            return "File creation failed unexpectedly (system code \(code)). Check Files access and try again."
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

    private let fileManager: FileManager
    private let fileCoordinator: NSFileCoordinator
    private let bookmarkCreator: BookmarkCreator

    public init(fileManager: FileManager) {
        self.fileManager = fileManager
        self.fileCoordinator = NSFileCoordinator(filePresenter: nil)
        self.bookmarkCreator = createBookmarkData
    }

    init(
        fileManager: FileManager,
        bookmarkCreator: @escaping BookmarkCreator
    ) {
        self.fileManager = fileManager
        self.fileCoordinator = NSFileCoordinator(filePresenter: nil)
        self.bookmarkCreator = bookmarkCreator
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
        } catch let error as FileAccessConnectorError {
            try removeStagingIfPresent(
                at: stagingURL,
                fileManager: fileManager,
                precedingError: error,
                beforeUnlink: {}
            )
            throw error
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
                bookmarkCreator: bookmarkCreator
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

private func createCoordinatedFile(
    stagingURL: URL,
    coordinatedTargetURL: URL,
    fileName: ValidatedFileName,
    encodedFile: EncodedTextFile,
    fileCoordinator: NSFileCoordinator,
    fileManager: FileManager,
    bookmarkCreator: FileAccessConnector.BookmarkCreator
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
        let bookmark: FileBookmark
        do {
            bookmark = try FileBookmark(data: bookmarkCreator(coordinatedTargetURL))
        } catch {
            return .success(.verifiedDetached(detachedFile))
        }

        let binding = FileBinding(
            locatorURL: coordinatedTargetURL,
            bookmark: bookmark,
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
