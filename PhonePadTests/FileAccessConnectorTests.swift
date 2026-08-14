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
