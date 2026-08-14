import CryptoKit
import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class FileAccessConnectorTests: XCTestCase {
    func testCreateFileWritesAndVerifiesExactBytesWithResolvableBookmark() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Created.txt")
        let encodedFile = try encodeNewTextFile(text: "Line 1\nLine 2")
        let connector = FileAccessConnector(fileManager: .default)

        let outcome = try await connector.createFile(
            in: folderURL,
            fileName: fileName,
            encodedFile: encodedFile
        )

        guard case let .bound(binding) = outcome else {
            return XCTFail("Expected verified File binding, received \(outcome).")
        }
        let targetURL = folderURL.appendingPathComponent("Created.txt", isDirectory: false)
        let expectedBytes = Data("Line 1\nLine 2".utf8)
        let expectedDigest = try FileDigest(
            bytes: Data([
                0x91, 0x40, 0xdd, 0xc6, 0x51, 0xfb, 0x38, 0x61,
                0x32, 0x21, 0x11, 0x77, 0x3b, 0xee, 0x1a, 0xfd,
                0x59, 0xdb, 0x94, 0xa6, 0xdc, 0xba, 0x56, 0x21,
                0x2a, 0x5c, 0xab, 0xd8, 0xaa, 0xaf, 0x68, 0x74,
            ])
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), expectedBytes)
        XCTAssertEqual(binding.locatorURL.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertEqual(binding.displayName, fileName)
        XCTAssertEqual(binding.digest, expectedDigest)
        XCTAssertEqual(binding.encoding, .utf8)
        XCTAssertEqual(binding.lineEnding, .lf)

        var bookmarkIsStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: binding.bookmark.data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        )
        XCTAssertFalse(bookmarkIsStale)
        XCTAssertEqual(resolvedURL.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: resolvedURL), expectedBytes)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Created.txt"])
    }

    func testCreateFileRejectsExistingRegularFileWithoutChangingIt() async throws {
        let folderURL = try makeTemporaryFolder()
        let targetURL = folderURL.appendingPathComponent("Existing.txt", isDirectory: false)
        let originalBytes = Data("Original bytes".utf8)
        try originalBytes.write(to: targetURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        await assertCreateFails(
            connector: connector,
            folderURL: folderURL,
            fileName: "Existing.txt",
            expectedError: .targetAlreadyExists(.regularFile)
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), originalBytes)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Existing.txt"])
    }

    func testCreateFileRejectsExistingDirectoryWithoutChangingIt() async throws {
        let folderURL = try makeTemporaryFolder()
        let targetURL = folderURL.appendingPathComponent("Existing.txt", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        let childURL = targetURL.appendingPathComponent("child", isDirectory: false)
        try Data("child bytes".utf8).write(to: childURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        await assertCreateFails(
            connector: connector,
            folderURL: folderURL,
            fileName: "Existing.txt",
            expectedError: .targetAlreadyExists(.directory)
        )

        XCTAssertEqual(try Data(contentsOf: childURL), Data("child bytes".utf8))
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Existing.txt"])
    }

    func testCreateFileRejectsExistingSymbolicLinkWithoutChangingIt() async throws {
        let folderURL = try makeTemporaryFolder()
        let destinationURL = folderURL.appendingPathComponent("Destination.txt", isDirectory: false)
        let linkURL = folderURL.appendingPathComponent("Existing.txt", isDirectory: false)
        let destinationBytes = Data("Destination bytes".utf8)
        try destinationBytes.write(to: destinationURL, options: .withoutOverwriting)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: destinationURL)
        let connector = FileAccessConnector(fileManager: .default)

        await assertCreateFails(
            connector: connector,
            folderURL: folderURL,
            fileName: "Existing.txt",
            expectedError: .targetAlreadyExists(.symbolicLink)
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), destinationBytes)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            destinationURL.path
        )
        XCTAssertEqual(
            try folderItemNames(folderURL: folderURL),
            ["Destination.txt", "Existing.txt"]
        )
    }

    func testConcurrentCreatesProduceExactlyOneVerifiedFileWithoutResidue() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Race.txt")
        let encodedFile = try encodeNewTextFile(text: "One durable result\n")
        let firstConnector = FileAccessConnector(fileManager: .default)
        let secondConnector = FileAccessConnector(fileManager: .default)

        async let firstObservation = observeCreate(
            connector: firstConnector,
            folderURL: folderURL,
            fileName: fileName,
            encodedFile: encodedFile
        )
        async let secondObservation = observeCreate(
            connector: secondConnector,
            folderURL: folderURL,
            fileName: fileName,
            encodedFile: encodedFile
        )
        let observations = await [firstObservation, secondObservation]

        XCTAssertEqual(observations.filter { $0 == .success }.count, 1)
        XCTAssertEqual(
            observations.filter { $0 == .failure(.targetAlreadyExists(.regularFile)) }.count,
            1
        )
        let targetURL = folderURL.appendingPathComponent("Race.txt", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: targetURL), encodedFile.data)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Race.txt"])
    }

    func testBookmarkFailureReportsVerifiedDetachedFileAndLeavesExactOutput() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Detached.txt")
        let encodedFile = try encodeNewTextFile(text: "Verified before bookmark\n")
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { _ in
                throw ForcedBookmarkCreationError()
            }
        )

        let outcome = try await connector.createFile(
            in: folderURL,
            fileName: fileName,
            encodedFile: encodedFile
        )

        guard case let .verifiedDetached(detachedFile) = outcome else {
            return XCTFail("Expected verified detached File, received \(outcome).")
        }
        XCTAssertEqual(detachedFile.displayName, fileName)
        XCTAssertEqual(detachedFile.digest, encodedFile.digest)
        XCTAssertEqual(detachedFile.encoding, .utf8)
        XCTAssertEqual(detachedFile.lineEnding, .lf)
        let targetURL = folderURL.appendingPathComponent("Detached.txt", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: targetURL), encodedFile.data)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Detached.txt"])
    }

    func testStagingCleanupRefusesDirectoryReplacedAfterInspectionWithoutRecursiveRemoval() throws {
        let folderURL = try makeTemporaryFolder()
        let stagingURL = folderURL.appendingPathComponent(
            ".phonepad-create-race.staging",
            isDirectory: false
        )
        try Data("temporary bytes".utf8).write(
            to: stagingURL,
            options: .withoutOverwriting
        )
        let childURL = stagingURL.appendingPathComponent(
            "must-remain.txt",
            isDirectory: false
        )
        let precedingError = FileAccessConnectorError.stagingVerificationFailed(
            .contentMismatch
        )

        do {
            try removeStagingIfPresent(
                at: stagingURL,
                fileManager: .default,
                precedingError: precedingError,
                beforeUnlink: {
                    try FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.createDirectory(
                        at: stagingURL,
                        withIntermediateDirectories: false,
                        attributes: nil
                    )
                    try Data("nested data".utf8).write(
                        to: childURL,
                        options: .withoutOverwriting
                    )
                }
            )
            XCTFail("Expected replaced staging directory to be refused.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .unsafeStagingCleanupRefused(
                    .directory,
                    after: precedingError
                )
            )
        } catch {
            XCTFail("Expected typed FileAccessConnectorError, received \(error).")
        }

        XCTAssertEqual(try Data(contentsOf: childURL), Data("nested data".utf8))
    }

    func testOpenUTF8FileReadsExactBytesAndReturnsDurableBinding() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Opened.txt", isDirectory: false)
        let bytes = Data("First line\nSecond line\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        let openedFile = try await connector.openUTF8File(at: fileURL)

        XCTAssertEqual(openedFile.text, "First line\nSecond line\n")
        XCTAssertEqual(openedFile.binding.locatorURL.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(openedFile.binding.displayName.value, "Opened.txt")
        XCTAssertEqual(openedFile.binding.digest, try digest(data: bytes))
        XCTAssertEqual(openedFile.binding.encoding, .utf8)
        XCTAssertEqual(openedFile.binding.lineEnding, .lf)

        var bookmarkIsStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: openedFile.binding.bookmark.data,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        )
        XCTAssertFalse(bookmarkIsStale)
        XCTAssertEqual(resolvedURL.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenUTF8FileRejectsInvalidUTF8WithoutChangingBytes() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Invalid.txt", isDirectory: false)
        let bytes = Data([0xf0, 0x28, 0x8c, 0x28])
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        await assertOpenFails(
            connector: connector,
            fileURL: fileURL,
            expectedError: .inputIsNotUTF8
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenUTF8FileRejectsOversizedFileWithoutReadingItAsText() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Oversized.txt", isDirectory: false)
        let bytes = Data(
            repeating: 0x61,
            count: maximumSupportedTextFileByteCount + 1
        )
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        await assertOpenFails(
            connector: connector,
            fileURL: fileURL,
            expectedError: .inputTooLarge(
                actualByteCount: maximumSupportedTextFileByteCount + 1,
                maximumByteCount: maximumSupportedTextFileByteCount
            )
        )

        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
            maximumSupportedTextFileByteCount + 1
        )
    }

    func testOpenUTF8FileRejectsDirectorySymbolicLinkAndMissingItem() async throws {
        let folderURL = try makeTemporaryFolder()
        let directoryURL = folderURL.appendingPathComponent("Directory.txt", isDirectory: true)
        let destinationURL = folderURL.appendingPathComponent("Destination.txt", isDirectory: false)
        let symbolicLinkURL = folderURL.appendingPathComponent("Link.txt", isDirectory: false)
        let missingURL = folderURL.appendingPathComponent("Missing.txt", isDirectory: false)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        try Data("destination".utf8).write(to: destinationURL, options: .withoutOverwriting)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: destinationURL
        )
        let connector = FileAccessConnector(fileManager: .default)

        await assertOpenFails(
            connector: connector,
            fileURL: directoryURL,
            expectedError: .selectedFileIsNotRegularFile(.directory)
        )
        await assertOpenFails(
            connector: connector,
            fileURL: symbolicLinkURL,
            expectedError: .selectedFileIsNotRegularFile(.symbolicLink)
        )
        await assertOpenFails(
            connector: connector,
            fileURL: missingURL,
            expectedError: .selectedFileMissing
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("destination".utf8))
    }

    func testSaveUTF8FileReplacesOriginalOnlyOnExplicitCallAndReturnsVerifiedBinding() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Bound.txt", isDirectory: false)
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let openedFile = try await connector.openUTF8File(at: fileURL)
        let encodedFile = try encodeNewTextFile(text: "Edited\r\ncontent\n")

        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        let outcome = try await connector.saveUTF8File(
            binding: openedFile.binding,
            encodedFile: encodedFile
        )

        guard case let .bound(savedBinding) = outcome else {
            return XCTFail("Expected durable saved binding, received \(outcome).")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("Edited\ncontent\n".utf8))
        XCTAssertEqual(savedBinding.locatorURL.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(savedBinding.digest, encodedFile.digest)
        XCTAssertEqual(savedBinding.identity, openedFile.binding.identity)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Bound.txt"])
    }

    func testSaveUTF8FileBlocksExternalContentMutationWithoutOverwritingIt() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Conflict.txt", isDirectory: false)
        try Data("Original\n".utf8).write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let openedFile = try await connector.openUTF8File(at: fileURL)
        let externalBytes = Data("External change\n".utf8)
        try externalBytes.write(to: fileURL, options: .atomic)

        await assertSaveFails(
            connector: connector,
            binding: openedFile.binding,
            encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
            expectedError: .fileConflict(.contentChanged)
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), externalBytes)
    }

    func testSaveUTF8FileBlocksStableIdentityChangeEvenWhenDigestMatches() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Identity.txt", isDirectory: false)
        let bytes = Data("Same bytes\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let expectedIdentity = FileIdentity(
            volumeUUID: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 10
        )
        let currentIdentity = FileIdentity(
            volumeUUID: expectedIdentity.volumeUUID,
            documentIdentifier: 11
        )
        let binding = try makeBinding(
            fileURL: fileURL,
            identity: expectedIdentity,
            data: bytes
        )
        let connector = makeInjectedConnector(
            identityReader: { _ in currentIdentity },
            replacer: replaceFile
        )

        await assertSaveFails(
            connector: connector,
            binding: binding,
            encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
            expectedError: .fileConflict(.stableIdentityChanged)
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testSaveUTF8FileReportsDeletedDirectoryAndSymbolicLinkTargetsWithoutWriting() async throws {
        let replacementCases: [(ExistingFileSystemItemKind?, FileAccessConnectorError)] = [
            (nil, .boundFileMissing),
            (.directory, .boundFileIsNotRegularFile(.directory)),
            (.symbolicLink, .boundFileIsNotRegularFile(.symbolicLink)),
        ]

        for (replacementKind, expectedError) in replacementCases {
            let folderURL = try makeTemporaryFolder()
            let fileURL = folderURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
            let destinationURL = folderURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
            try Data("Original\n".utf8).write(to: fileURL, options: .withoutOverwriting)
            let connector = FileAccessConnector(fileManager: .default)
            let openedFile = try await connector.openUTF8File(at: fileURL)
            try FileManager.default.removeItem(at: fileURL)
            switch replacementKind {
            case .directory:
                try FileManager.default.createDirectory(
                    at: fileURL,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
            case .symbolicLink:
                try Data("Destination\n".utf8).write(
                    to: destinationURL,
                    options: .withoutOverwriting
                )
                try FileManager.default.createSymbolicLink(
                    at: fileURL,
                    withDestinationURL: destinationURL
                )
            case nil:
                break
            case .regularFile, .special:
                XCTFail("Unexpected test case kind.")
            }
            let saveConnector = makeInjectedConnector(
                resolvedURL: fileURL,
                identityReader: { _ in nil },
                replacer: replaceFile
            )

            await assertSaveFails(
                connector: saveConnector,
                binding: openedFile.binding,
                encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
                expectedError: expectedError
            )
        }
    }

    func testSaveUTF8FileReportsBookmarkResolutionFailureWhenOriginalDisappears() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Missing.txt", isDirectory: false)
        try Data("Original\n".utf8).write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let openedFile = try await connector.openUTF8File(at: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        await assertSaveFails(
            connector: connector,
            binding: openedFile.binding,
            encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
            expectedError: .bookmarkResolutionFailed(code: 4)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveUTF8FileClassifiesReplacementFailureBeforeWriteAsUnchanged() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Unchanged.txt", isDirectory: false)
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let binding = try makeBinding(fileURL: fileURL, identity: nil, data: originalBytes)
        let connector = makeInjectedConnector(
            identityReader: { _ in nil },
            replacer: { _, _, _ in
                throw ForcedReplacementError(code: 701)
            }
        )

        await assertSaveFails(
            connector: connector,
            binding: binding,
            encodedFile: try encodeNewTextFile(text: "Edited\n"),
            expectedError: .replacementFailed(code: 701)
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
    }

    func testSaveUTF8FileTreatsVerifiedIntendedBytesAsSuccessWhenReplacementReportsError() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Succeeded.txt", isDirectory: false)
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let binding = try makeBinding(fileURL: fileURL, identity: nil, data: originalBytes)
        let connector = makeInjectedConnector(
            identityReader: { _ in nil },
            replacer: { originalURL, stagingURL, fileManager in
                _ = try replaceFile(
                    originalURL: originalURL,
                    stagingURL: stagingURL,
                    fileManager: fileManager
                )
                throw ForcedReplacementError(code: 702)
            }
        )
        let encodedFile = try encodeNewTextFile(text: "Edited\n")

        let outcome = try await connector.saveUTF8File(
            binding: binding,
            encodedFile: encodedFile
        )

        guard case let .bound(savedBinding) = outcome else {
            return XCTFail("Expected verified bound save, received \(outcome).")
        }
        XCTAssertEqual(savedBinding.digest, encodedFile.digest)
        XCTAssertEqual(try Data(contentsOf: fileURL), encodedFile.data)
    }

    func testSaveUTF8FileReportsIndeterminateOutcomeWhenReplacementErrorLeavesThirdContent() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Indeterminate.txt", isDirectory: false)
        let originalBytes = Data("Original\n".utf8)
        let thirdBytes = Data("Third writer\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let binding = try makeBinding(fileURL: fileURL, identity: nil, data: originalBytes)
        let connector = makeInjectedConnector(
            identityReader: { _ in nil },
            replacer: { originalURL, _, _ in
                try thirdBytes.write(to: originalURL, options: .atomic)
                throw ForcedReplacementError(code: 703)
            }
        )

        await assertSaveFails(
            connector: connector,
            binding: binding,
            encodedFile: try encodeNewTextFile(text: "Edited\n"),
            expectedError: .replacementOutcomeIndeterminate(code: 703)
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), thirdBytes)
    }

    private func makeTemporaryFolder() throws -> URL {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: folderURL)
        }
        return folderURL
    }
}

private struct ForcedBookmarkCreationError: Error, Sendable {}

private struct ForcedReplacementError: CustomNSError, Sendable {
    static let errorDomain: String = "PhonePadTests.ForcedReplacement"

    let code: Int

    var errorCode: Int {
        code
    }
}

private enum CreateObservation: Equatable, Sendable {
    case success
    case failure(FileAccessConnectorError)
}

private func observeCreate(
    connector: FileAccessConnector,
    folderURL: URL,
    fileName: ValidatedFileName,
    encodedFile: EncodedTextFile
) async -> CreateObservation {
    do {
        _ = try await connector.createFile(
            in: folderURL,
            fileName: fileName,
            encodedFile: encodedFile
        )
        return .success
    } catch let error as FileAccessConnectorError {
        return .failure(error)
    } catch {
        XCTFail("Expected typed FileAccessConnectorError, received \(error).")
        return .failure(.unexpectedFileSystemFailure(code: (error as NSError).code))
    }
}

@MainActor
private func assertCreateFails(
    connector: FileAccessConnector,
    folderURL: URL,
    fileName: String,
    expectedError: FileAccessConnectorError
) async {
    do {
        _ = try await connector.createFile(
            in: folderURL,
            fileName: try ValidatedFileName(validating: fileName),
            encodedFile: try encodeNewTextFile(text: "Replacement")
        )
        XCTFail("Expected File creation to fail.")
    } catch let error as FileAccessConnectorError {
        XCTAssertEqual(error, expectedError)
    } catch {
        XCTFail("Expected typed FileAccessConnectorError, received \(error).")
    }
}

private func folderItemNames(folderURL: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: nil,
        options: []
    )
    .map(\.lastPathComponent)
    .sorted()
}

private func digest(data: Data) throws -> FileDigest {
    try FileDigest(bytes: Data(SHA256.hash(data: data)))
}

private func makeBinding(
    fileURL: URL,
    identity: FileIdentity?,
    data: Data
) throws -> FileBinding {
    FileBinding(
        locatorURL: fileURL,
        bookmark: try FileBookmark(
            data: fileURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        ),
        identity: identity,
        displayName: try ValidatedFileName(validating: fileURL.lastPathComponent),
        digest: try digest(data: data),
        encoding: .utf8,
        lineEnding: .lf
    )
}

private func makeInjectedConnector(
    identityReader: @escaping FileAccessConnector.FileIdentityReader,
    replacer: @escaping FileAccessConnector.FileReplacer
) -> FileAccessConnector {
    FileAccessConnector(
        fileManager: .default,
        bookmarkCreator: { url in
            try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        bookmarkResolver: { bookmark in
            var bookmarkIsStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark.data,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
            return ResolvedFileBookmark(url: url, isStale: bookmarkIsStale)
        },
        identityReader: identityReader,
        replacer: replacer
    )
}

private func makeInjectedConnector(
    resolvedURL: URL,
    identityReader: @escaping FileAccessConnector.FileIdentityReader,
    replacer: @escaping FileAccessConnector.FileReplacer
) -> FileAccessConnector {
    FileAccessConnector(
        fileManager: .default,
        bookmarkCreator: { url in
            try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        bookmarkResolver: { _ in
            ResolvedFileBookmark(url: resolvedURL, isStale: false)
        },
        identityReader: identityReader,
        replacer: replacer
    )
}

private func replaceFile(
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

@MainActor
private func assertOpenFails(
    connector: FileAccessConnector,
    fileURL: URL,
    expectedError: FileAccessConnectorError
) async {
    do {
        _ = try await connector.openUTF8File(at: fileURL)
        XCTFail("Expected File Open to fail.")
    } catch let error as FileAccessConnectorError {
        XCTAssertEqual(error, expectedError)
    } catch {
        XCTFail("Expected typed FileAccessConnectorError, received \(error).")
    }
}

@MainActor
private func assertSaveFails(
    connector: FileAccessConnector,
    binding: FileBinding,
    encodedFile: EncodedTextFile,
    expectedError: FileAccessConnectorError
) async {
    do {
        _ = try await connector.saveUTF8File(
            binding: binding,
            encodedFile: encodedFile
        )
        XCTFail("Expected bound File Save to fail.")
    } catch let error as FileAccessConnectorError {
        XCTAssertEqual(error, expectedError)
    } catch {
        XCTFail("Expected typed FileAccessConnectorError, received \(error).")
    }
}
