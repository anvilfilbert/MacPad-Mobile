import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class FileAccessConnectorTests: XCTestCase {
    func testPreflightSaveAsAbsentTargetReturnsReadyDurablePlan() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Draft.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)

        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case .ready = preflight else {
            return XCTFail("Expected absent target to be ready, received \(preflight).")
        }
        XCTAssertEqual(preflight.plan.fileName, fileName)
        XCTAssertEqual(preflight.plan.expectation, .absent)
        var bookmarkIsStale = false
        let resolvedDirectoryURL = try URL(
            resolvingBookmarkData: preflight.plan.directoryBookmark.data,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        )
        XCTAssertFalse(bookmarkIsStale)
        XCTAssertEqual(
            resolvedDirectoryURL.standardizedFileURL,
            folderURL.standardizedFileURL
        )
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), [])
    }

    func testPreflightSaveAsExistingRegularTargetRequiresExactReplacementSnapshot() async throws {
        let folderURL = try makeTemporaryFolder()
        let targetURL = folderURL.appendingPathComponent("Existing.txt", isDirectory: false)
        let originalData = Data("Existing bytes\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let fileName = try ValidatedFileName(validating: "Existing.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)

        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .replacementRequired(plan) = preflight,
              case let .existing(snapshot) = plan.expectation else {
            return XCTFail(
                "Expected existing target replacement snapshot, received \(preflight)."
            )
        }
        XCTAssertEqual(snapshot.digest, try digest(data: originalData))
        XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Existing.txt"])
    }

    func testPreflightSaveAsStreamsSnapshotForExistingTargetAboveTextLimit() async throws {
        let folderURL = try makeTemporaryFolder()
        let targetURL = folderURL.appendingPathComponent("Large Existing.bin")
        let originalData = Data(
            repeating: 0xa5,
            count: maximumSupportedTextFileByteCount + 1
        )
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: try ValidatedFileName(validating: "Large Existing.bin"),
            currentDocumentID: DocumentID(rawValue: UUID()),
            collisionClaims: []
        )

        guard case let .replacementRequired(plan) = preflight,
              case let .existing(snapshot) = plan.expectation else {
            return XCTFail("Expected large regular target snapshot, received \(preflight).")
        }
        XCTAssertEqual(snapshot.digest, try digest(data: originalData))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int,
            maximumSupportedTextFileByteCount + 1
        )
    }

    func testPreflightSaveAsCurrentActiveFileReturnsCurrentFilePlan() async throws {
        let folderURL = try makeTemporaryFolder()
        let targetURL = folderURL.appendingPathComponent("Current.txt", isDirectory: false)
        try Data("Current bytes\n".utf8).write(
            to: targetURL,
            options: .withoutOverwriting
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let identity = FileIdentity(volumeUUID: UUID(), documentIdentifier: 41)
        let reference = FileCollisionReference(
            bookmark: try FileBookmark(
                data: targetURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            ),
            identity: identity
        )
        let connector = makeInjectedConnector(
            identityReader: { _ in identity },
            replacer: replaceFile
        )

        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: try ValidatedFileName(validating: "Current.txt"),
            currentDocumentID: currentDocumentID,
            collisionClaims: [
                .activeTab(documentID: currentDocumentID, reference: reference)
            ]
        )

        guard case .currentFile = preflight else {
            return XCTFail("Expected current File routing, received \(preflight).")
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("Current bytes\n".utf8))
    }

    func testPreflightSaveAsRejectsActiveRecoveryAndPendingDestinationCollisions() async throws {
        let folderURL = try makeTemporaryFolder()
        let targetURL = folderURL.appendingPathComponent("Claimed.txt", isDirectory: false)
        let originalData = Data("Claimed bytes\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let currentDocumentID = DocumentID(rawValue: UUID())
        let claimedDocumentID = DocumentID(rawValue: UUID())
        let identity = FileIdentity(volumeUUID: UUID(), documentIdentifier: 42)
        let targetBookmark = try FileBookmark(
            data: targetURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        )
        let directoryBookmark = try FileBookmark(
            data: folderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        )
        let reference = FileCollisionReference(
            bookmark: targetBookmark,
            identity: identity
        )
        let claims: [FileCollisionClaim] = [
            .activeTab(documentID: claimedDocumentID, reference: reference),
            .recoveryItem(documentID: claimedDocumentID, reference: reference),
            .pendingSaveAs(
                documentID: claimedDocumentID,
                destination: RecoverySaveAsDestination(
                    directoryBookmark: directoryBookmark,
                    fileName: try ValidatedFileName(validating: "Claimed.txt")
                )
            ),
        ]

        for claim in claims {
            let connector = makeInjectedConnector(
                identityReader: { _ in identity },
                replacer: replaceFile
            )
            do {
                _ = try await connector.preflightSaveAsTarget(
                    in: folderURL,
                    fileName: try ValidatedFileName(validating: "Claimed.txt"),
                    currentDocumentID: currentDocumentID,
                    collisionClaims: [claim]
                )
                XCTFail("Expected Save As collision for \(claim).")
            } catch let error as FileAccessConnectorError {
                XCTAssertEqual(error, .saveAsTargetCollision(claim))
            }
            XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
        }
    }

    func testPreflightSaveAsRejectsPackageSymlinkAndSpecialTargetsWithoutMutation() async throws {
        let folderURL = try makeTemporaryFolder()
        let packageURL = folderURL.appendingPathComponent("Document.rtfd", isDirectory: true)
        let destinationURL = folderURL.appendingPathComponent("Destination.txt", isDirectory: false)
        let symbolicLinkURL = folderURL.appendingPathComponent("Link.txt", isDirectory: false)
        let specialURL = folderURL.appendingPathComponent("Pipe.txt", isDirectory: false)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        let packageContentURL = packageURL.appendingPathComponent("TXT.rtf")
        let packageData = Data("Package bytes".utf8)
        try packageData.write(to: packageContentURL, options: .withoutOverwriting)
        let destinationData = Data("Destination bytes".utf8)
        try destinationData.write(to: destinationURL, options: .withoutOverwriting)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: destinationURL
        )
        XCTAssertEqual(
            specialURL.path.withCString { path in
                mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
            },
            0
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)
        let cases: [(String, FileAccessConnectorError)] = [
            ("Document.rtfd", .selectedFileIsPackage),
            ("Link.txt", .targetAlreadyExists(.symbolicLink)),
            ("Pipe.txt", .targetAlreadyExists(.special)),
        ]

        for testCase in cases {
            do {
                _ = try await connector.preflightSaveAsTarget(
                    in: folderURL,
                    fileName: try ValidatedFileName(validating: testCase.0),
                    currentDocumentID: currentDocumentID,
                    collisionClaims: []
                )
                XCTFail("Expected \(testCase.0) to be rejected.")
            } catch let error as FileAccessConnectorError {
                XCTAssertEqual(error, testCase.1)
            }
        }
        XCTAssertEqual(try Data(contentsOf: packageContentURL), packageData)
        XCTAssertEqual(try Data(contentsOf: destinationURL), destinationData)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symbolicLinkURL.path),
            destinationURL.path
        )
    }

    func testCreateSaveAsTargetWritesAndVerifiesPreflightedAbsentTarget() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Created Save As.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let encodedFile = try encodeTextFile(
            text: "First\nSecond",
            encoding: .utf8WithBOM,
            lineEnding: .crlf
        )
        let connector = FileAccessConnector(fileManager: .default)
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )
        guard case let .ready(plan) = preflight else {
            return XCTFail("Expected ready Save As plan, received \(preflight).")
        }

        let outcome = try await connector.createSaveAsTarget(
            plan: plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .complete(.bound(binding)) = outcome else {
            return XCTFail("Expected bound Save As output, received \(outcome).")
        }
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        XCTAssertEqual(try Data(contentsOf: targetURL), encodedFile.data)
        XCTAssertEqual(binding.locatorURL.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertEqual(binding.displayName, fileName)
        XCTAssertEqual(binding.digest, encodedFile.digest)
        XCTAssertEqual(binding.encoding, .utf8WithBOM)
        XCTAssertEqual(binding.lineEnding, .crlf)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), [fileName.value])
    }

    func testCreateSaveAsTargetAbortsWhenAbsentTargetAppearsWithoutResidue() async throws {
        let folderURL = try makeTemporaryFolder()
        let targetURL = folderURL.appendingPathComponent("Appeared.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: try ValidatedFileName(validating: "Appeared.txt"),
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )
        let appearedData = Data("Another writer won".utf8)
        try appearedData.write(to: targetURL, options: .withoutOverwriting)

        do {
            _ = try await connector.createSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "PhonePad output"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected appeared target to abort Save As creation.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .saveAsTargetAppeared(.regularFile))
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), appearedData)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), ["Appeared.txt"])
    }

    func testCreateSaveAsTargetRechecksPendingRecoveryCollisionBeforeWriting() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Pending.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )
        let claim = FileCollisionClaim.pendingSaveAs(
            documentID: DocumentID(rawValue: UUID()),
            destination: RecoverySaveAsDestination(
                directoryBookmark: preflight.plan.directoryBookmark,
                fileName: fileName
            )
        )

        do {
            _ = try await connector.createSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "Protected output"),
                currentDocumentID: currentDocumentID,
                collisionClaims: [claim]
            )
            XCTFail("Expected pending recovery target collision to abort creation.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .saveAsTargetCollision(claim))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folderURL.appendingPathComponent(fileName.value).path
            )
        )
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), [])
    }

    func testCreateSaveAsTargetBookmarkFailureReturnsVerifiedDetachedOutput() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Detached Save As.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { url in
                if url.standardizedFileURL == folderURL.standardizedFileURL {
                    return try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }
                throw ForcedBookmarkCreationError()
            }
        )
        let encodedFile = try encodeNewTextFile(text: "Verified detached\n")
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        let outcome = try await connector.createSaveAsTarget(
            plan: preflight.plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .complete(.verifiedDetached(detachedFile)) = outcome else {
            return XCTFail("Expected verified detached Save As, received \(outcome).")
        }
        XCTAssertEqual(detachedFile.displayName, fileName)
        XCTAssertEqual(detachedFile.digest, encodedFile.digest)
        XCTAssertEqual(
            try Data(contentsOf: folderURL.appendingPathComponent(fileName.value)),
            encodedFile.data
        )
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), [fileName.value])
    }

    func testCreateSaveAsTargetCleansPartialStagingAfterWriteFailure() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Write Failure.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let recordedURLs = RecordedSaveAsStagingURLs()
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeBookmarkData,
            saveAsStagingWriter: { _, stagingURL in
                recordedURLs.record(fileURL: stagingURL)
                try Data("partial".utf8).write(
                    to: stagingURL,
                    options: .withoutOverwriting
                )
                throw ForcedSaveAsStagingError(code: 811)
            },
            saveAsStagingCleaner: { directoryURL, fileURL, fileManager in
                recordedURLs.record(directoryURL: directoryURL)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                try fileManager.removeItem(at: directoryURL)
            }
        )
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        do {
            _ = try await connector.createSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "Never committed"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected injected staging write failure.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .replacementStagingCreationFailed(code: 811))
        }
        let stagingURLs = try XCTUnwrap(recordedURLs.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path))
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), [])
    }

    func testCreateSaveAsTargetReturnsVerifiedOutcomeWhenStagingCleanupRemains() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Cleanup Notice.txt")
        let currentDocumentID = DocumentID(rawValue: UUID())
        let recordedURLs = RecordedSaveAsStagingURLs()
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeBookmarkData,
            saveAsStagingWriter: { data, stagingURL in
                try data.write(to: stagingURL, options: .withoutOverwriting)
            },
            saveAsStagingCleaner: { directoryURL, fileURL, _ in
                recordedURLs.record(directoryURL: directoryURL, fileURL: fileURL)
                throw ForcedSaveAsStagingError(code: 812)
            }
        )
        let encodedFile = try encodeNewTextFile(text: "Verified despite cleanup\n")
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        let outcome = try await connector.createSaveAsTarget(
            plan: preflight.plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .verifiedWithResidualCleanup(.bound(binding), code) = outcome else {
            return XCTFail("Expected verified cleanup notice, received \(outcome).")
        }
        XCTAssertEqual(code, 812)
        XCTAssertEqual(binding.digest, encodedFile.digest)
        XCTAssertEqual(
            try Data(contentsOf: folderURL.appendingPathComponent(fileName.value)),
            encodedFile.data
        )
        let stagingURLs = try XCTUnwrap(recordedURLs.snapshot())
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path) {
                try FileManager.default.removeItem(at: stagingURLs.directoryURL)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path))
    }

    func testReplaceSaveAsTargetRechecksAndVerifiesConfirmedExistingTarget() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Replace.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let originalData = Data("Original bytes\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let currentDocumentID = DocumentID(rawValue: UUID())
        let encodedFile = try encodeTextFile(
            text: "Café\nSecond",
            encoding: .windows1252,
            lineEnding: .cr
        )
        let connector = FileAccessConnector(fileManager: .default)
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )
        guard case let .replacementRequired(plan) = preflight else {
            return XCTFail("Expected replacement confirmation plan, received \(preflight).")
        }

        let outcome = try await connector.replaceSaveAsTarget(
            plan: plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .complete(.bound(binding)) = outcome else {
            return XCTFail("Expected verified replacement binding, received \(outcome).")
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), encodedFile.data)
        XCTAssertEqual(binding.locatorURL.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertEqual(binding.displayName, fileName)
        XCTAssertEqual(binding.digest, encodedFile.digest)
        XCTAssertEqual(binding.encoding, .windows1252)
        XCTAssertEqual(binding.lineEnding, .cr)
        XCTAssertEqual(try folderItemNames(folderURL: folderURL), [fileName.value])
    }

    func testReplaceSaveAsTargetAbortsWhenConfirmedContentChanges() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Changed.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let originalData = Data("Confirmed bytes\n".utf8)
        let changedData = Data("Changed elsewhere\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )
        try changedData.write(to: targetURL, options: .atomic)

        do {
            _ = try await connector.replaceSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected changed replacement target to abort.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .saveAsTargetChanged)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), changedData)
    }

    func testReplaceSaveAsTargetAbortsWhenConfirmedTargetDisappearsOrChangesType() async throws {
        let replacementKinds: [ExistingFileSystemItemKind?] = [
            nil,
            .directory,
            .symbolicLink,
            .special,
        ]

        for replacementKind in replacementKinds {
            let folderURL = try makeTemporaryFolder()
            let fileName = try ValidatedFileName(validating: "Race.txt")
            let targetURL = folderURL.appendingPathComponent(fileName.value)
            let destinationURL = folderURL.appendingPathComponent("Destination.txt")
            let destinationData = Data("Destination bytes\n".utf8)
            try Data("Confirmed bytes\n".utf8).write(
                to: targetURL,
                options: .withoutOverwriting
            )
            let currentDocumentID = DocumentID(rawValue: UUID())
            let connector = FileAccessConnector(fileManager: .default)
            let preflight = try await connector.preflightSaveAsTarget(
                in: folderURL,
                fileName: fileName,
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            try FileManager.default.removeItem(at: targetURL)
            switch replacementKind {
            case nil:
                break
            case .directory:
                try FileManager.default.createDirectory(
                    at: targetURL,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
            case .symbolicLink:
                try destinationData.write(
                    to: destinationURL,
                    options: .withoutOverwriting
                )
                try FileManager.default.createSymbolicLink(
                    at: targetURL,
                    withDestinationURL: destinationURL
                )
            case .special:
                XCTAssertEqual(
                    targetURL.path.withCString { path in
                        mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
                    },
                    0
                )
            case .regularFile:
                XCTFail("Unexpected replacement test case.")
            }

            do {
                _ = try await connector.replaceSaveAsTarget(
                    plan: preflight.plan,
                    encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
                    currentDocumentID: currentDocumentID,
                    collisionClaims: []
                )
                XCTFail("Expected replacement target race to abort.")
            } catch let error as FileAccessConnectorError {
                XCTAssertEqual(error, .saveAsTargetChanged)
            }
            if replacementKind == .symbolicLink {
                XCTAssertEqual(try Data(contentsOf: destinationURL), destinationData)
            }
        }
    }

    func testReplaceSaveAsTargetAbortsWhenStableIdentityChanges() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Identity.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let originalData = Data("Same bytes\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let confirmedIdentity = FileIdentity(
            volumeUUID: UUID(),
            documentIdentifier: 91
        )
        let changedIdentity = FileIdentity(
            volumeUUID: UUID(),
            documentIdentifier: 92
        )
        let identities = SequencedFileIdentities(
            identities: [confirmedIdentity, changedIdentity]
        )
        let connector = makeInjectedConnector(
            identityReader: { _ in identities.next() },
            replacer: replaceFile
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        do {
            _ = try await connector.replaceSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected stable identity change to abort replacement.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .saveAsTargetChanged)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
    }

    func testReplaceSaveAsTargetRechecksFreshCollisionBeforeWriting() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Claimed Replace.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let originalData = Data("Claimed bytes\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let currentDocumentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )
        let claim = FileCollisionClaim.recoveryItem(
            documentID: DocumentID(rawValue: UUID()),
            reference: FileCollisionReference(
                bookmark: try FileBookmark(data: makeBookmarkData(url: targetURL)),
                identity: nil
            )
        )

        do {
            _ = try await connector.replaceSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "Protected edit\n"),
                currentDocumentID: currentDocumentID,
                collisionClaims: [claim]
            )
            XCTFail("Expected refreshed collision to abort replacement.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .saveAsTargetCollision(claim))
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
    }

    func testReplaceSaveAsTargetBookmarkFailureReturnsVerifiedDetachedOutput() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Detached Replace.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        try Data("Original\n".utf8).write(to: targetURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { url in
                if url.standardizedFileURL == folderURL.standardizedFileURL {
                    return try makeBookmarkData(url: url)
                }
                throw ForcedBookmarkCreationError()
            }
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let encodedFile = try encodeNewTextFile(text: "Verified replacement\n")
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        let outcome = try await connector.replaceSaveAsTarget(
            plan: preflight.plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .complete(.verifiedDetached(detachedFile)) = outcome else {
            return XCTFail("Expected verified detached replacement, received \(outcome).")
        }
        XCTAssertEqual(detachedFile.displayName, fileName)
        XCTAssertEqual(detachedFile.digest, encodedFile.digest)
        XCTAssertEqual(try Data(contentsOf: targetURL), encodedFile.data)
    }

    func testReplaceSaveAsTargetCleansPartialStagingAfterWriteFailure() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Replace Write Failure.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let originalData = Data("Original stays\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let recordedURLs = RecordedSaveAsStagingURLs()
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeBookmarkData,
            saveAsStagingWriter: { _, stagingURL in
                recordedURLs.record(fileURL: stagingURL)
                try Data("partial".utf8).write(
                    to: stagingURL,
                    options: .withoutOverwriting
                )
                throw ForcedSaveAsStagingError(code: 813)
            },
            saveAsStagingCleaner: { directoryURL, fileURL, fileManager in
                recordedURLs.record(directoryURL: directoryURL)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                try fileManager.removeItem(at: directoryURL)
            }
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        do {
            _ = try await connector.replaceSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "Never committed"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected injected replacement staging failure.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .replacementStagingCreationFailed(code: 813))
        }
        let stagingURLs = try XCTUnwrap(recordedURLs.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
    }

    func testReplaceSaveAsTargetReturnsVerifiedOutcomeWhenStagingCleanupRemains() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Replace Cleanup Notice.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        try Data("Original\n".utf8).write(to: targetURL, options: .withoutOverwriting)
        let recordedURLs = RecordedSaveAsStagingURLs()
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeBookmarkData,
            saveAsStagingWriter: { data, stagingURL in
                try data.write(to: stagingURL, options: .withoutOverwriting)
            },
            saveAsStagingCleaner: { directoryURL, fileURL, _ in
                recordedURLs.record(directoryURL: directoryURL, fileURL: fileURL)
                throw ForcedSaveAsStagingError(code: 814)
            }
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let encodedFile = try encodeNewTextFile(text: "Verified replacement\n")
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        let outcome = try await connector.replaceSaveAsTarget(
            plan: preflight.plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .verifiedWithResidualCleanup(.bound(binding), code) = outcome else {
            return XCTFail("Expected verified replacement cleanup notice, received \(outcome).")
        }
        XCTAssertEqual(code, 814)
        XCTAssertEqual(binding.digest, encodedFile.digest)
        XCTAssertEqual(try Data(contentsOf: targetURL), encodedFile.data)
        let stagingURLs = try XCTUnwrap(recordedURLs.snapshot())
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path) {
                try FileManager.default.removeItem(at: stagingURLs.directoryURL)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path))
    }

    func testReplaceSaveAsTargetClassifiesReportedFailureWithoutLosingVerifiedState() async throws {
        let originalFolderURL = try makeTemporaryFolder()
        let originalFileName = try ValidatedFileName(validating: "Unchanged Replace.txt")
        let originalTargetURL = originalFolderURL.appendingPathComponent(originalFileName.value)
        let originalData = Data("Original\n".utf8)
        try originalData.write(to: originalTargetURL, options: .withoutOverwriting)
        let unchangedConnector = makeInjectedConnector(
            identityReader: { _ in nil },
            replacer: { _, _, _ in
                throw ForcedReplacementError(code: 815)
            }
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let unchangedPreflight = try await unchangedConnector.preflightSaveAsTarget(
            in: originalFolderURL,
            fileName: originalFileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        do {
            _ = try await unchangedConnector.replaceSaveAsTarget(
                plan: unchangedPreflight.plan,
                encodedFile: try encodeNewTextFile(text: "Edited\n"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected unchanged replacement failure.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .replacementFailed(code: 815))
        }
        XCTAssertEqual(try Data(contentsOf: originalTargetURL), originalData)

        let succeededFolderURL = try makeTemporaryFolder()
        let succeededFileName = try ValidatedFileName(validating: "Reported Replace.txt")
        let succeededTargetURL = succeededFolderURL.appendingPathComponent(
            succeededFileName.value
        )
        try originalData.write(to: succeededTargetURL, options: .withoutOverwriting)
        let succeededConnector = makeInjectedConnector(
            identityReader: { _ in nil },
            replacer: { originalURL, stagingURL, fileManager in
                _ = try replaceFile(
                    originalURL: originalURL,
                    stagingURL: stagingURL,
                    fileManager: fileManager
                )
                throw ForcedReplacementError(code: 816)
            }
        )
        let encodedFile = try encodeNewTextFile(text: "Verified despite report\n")
        let succeededPreflight = try await succeededConnector.preflightSaveAsTarget(
            in: succeededFolderURL,
            fileName: succeededFileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        let outcome = try await succeededConnector.replaceSaveAsTarget(
            plan: succeededPreflight.plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .complete(.bound(binding)) = outcome else {
            return XCTFail("Expected verified replacement outcome, received \(outcome).")
        }
        XCTAssertEqual(binding.digest, encodedFile.digest)
        XCTAssertEqual(try Data(contentsOf: succeededTargetURL), encodedFile.data)
    }

    func testReplaceSaveAsTargetPreservesReportedRelocatedOriginalForMissingOrThirdTarget() async throws {
        let thirdTargetCases: [Data?] = [
            nil,
            Data("Unexpected third version\n".utf8),
        ]

        for thirdTargetData in thirdTargetCases {
            let folderURL = try makeTemporaryFolder()
            let fileName = try ValidatedFileName(validating: "Relocated.txt")
            let targetURL = folderURL.appendingPathComponent(fileName.value)
            let originalData = Data("Confirmed original\n".utf8)
            try originalData.write(to: targetURL, options: .withoutOverwriting)
            let recordedURLs = RecordedSaveAsStagingURLs()
            let currentDocumentID = DocumentID(rawValue: UUID())
            let preflight: SaveAsTargetPreflight
            var preservedFileName: ValidatedFileName?
            do {
                let connector = makeInjectedConnector(
                    identityReader: { _ in nil },
                    replacer: { originalURL, stagingURL, fileManager in
                        recordedURLs.record(fileURL: stagingURL)
                        try fileManager.removeItem(at: stagingURL)
                        try fileManager.moveItem(at: originalURL, to: stagingURL)
                        if let thirdTargetData {
                            try thirdTargetData.write(
                                to: originalURL,
                                options: .withoutOverwriting
                            )
                        }
                        throw NSError(
                            domain: "PhonePadTests.RelocatedOriginal",
                            code: 817,
                            userInfo: ["NSFileOriginalItemLocationKey": stagingURL]
                        )
                    }
                )
                preflight = try await connector.preflightSaveAsTarget(
                    in: folderURL,
                    fileName: fileName,
                    currentDocumentID: currentDocumentID,
                    collisionClaims: []
                )
                do {
                    _ = try await connector.replaceSaveAsTarget(
                        plan: preflight.plan,
                        encodedFile: try encodeNewTextFile(text: "Intended edit\n"),
                        currentDocumentID: currentDocumentID,
                        collisionClaims: []
                    )
                    XCTFail("Expected relocated replacement outcome to remain explicit.")
                } catch let error as FileAccessConnectorError {
                    guard case let .replacementReportedRelocatedItem(
                        code,
                        generation,
                        fileName
                    ) = error else {
                        return XCTFail("Expected durable relocated-item result, received \(error).")
                    }
                    XCTAssertEqual(code, 817)
                    XCTAssertEqual(generation, .original)
                    preservedFileName = fileName
                }
            }
            let stagingURLs = try XCTUnwrap(recordedURLs.snapshot())
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.fileURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path))
            let durableFileName = try XCTUnwrap(preservedFileName)
            var directoryBookmarkIsStale = false
            let resolvedDirectoryURL = try URL(
                resolvingBookmarkData: preflight.plan.directoryBookmark.data,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &directoryBookmarkIsStale
            )
            XCTAssertFalse(directoryBookmarkIsStale)
            let preservedURL = resolvedDirectoryURL.appendingPathComponent(
                durableFileName.value
            )
            let reopenedFile = try await FileAccessConnector(
                fileManager: .default
            ).openTextFile(at: preservedURL)
            XCTAssertEqual(reopenedFile.text, "Confirmed original\n")
            XCTAssertEqual(try Data(contentsOf: preservedURL), originalData)
            if let thirdTargetData {
                XCTAssertEqual(try Data(contentsOf: targetURL), thirdTargetData)
                XCTAssertNotEqual(durableFileName, fileName)
            } else {
                XCTAssertEqual(durableFileName, fileName)
                XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
            }
        }
    }

    func testReplaceSaveAsTargetPreservesReportedIntendedOrUnexpectedItemAsSibling() async throws {
        let encodedFile = try encodeNewTextFile(text: "Intended output\n")
        let reportedCases: [(Data, SaveAsRelocatedFileGeneration)] = [
            (encodedFile.data, .intended),
            (Data("Unexpected reported bytes\n".utf8), .unexpected),
        ]

        for (reportedData, expectedGeneration) in reportedCases {
            let folderURL = try makeTemporaryFolder()
            let fileName = try ValidatedFileName(validating: "Requested.txt")
            let targetURL = folderURL.appendingPathComponent(fileName.value)
            try Data("Original\n".utf8).write(
                to: targetURL,
                options: .withoutOverwriting
            )
            let connector = makeInjectedConnector(
                identityReader: { _ in nil },
                replacer: { originalURL, stagingURL, fileManager in
                    try reportedData.write(to: stagingURL, options: .atomic)
                    try fileManager.removeItem(at: originalURL)
                    throw NSError(
                        domain: "PhonePadTests.RelocatedGeneration",
                        code: 818,
                        userInfo: ["NSFileOriginalItemLocationKey": stagingURL]
                    )
                }
            )
            let currentDocumentID = DocumentID(rawValue: UUID())
            let preflight = try await connector.preflightSaveAsTarget(
                in: folderURL,
                fileName: fileName,
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            var preservedFileName: ValidatedFileName?

            do {
                _ = try await connector.replaceSaveAsTarget(
                    plan: preflight.plan,
                    encodedFile: encodedFile,
                    currentDocumentID: currentDocumentID,
                    collisionClaims: []
                )
                XCTFail("Expected reported generation to remain an explicit failure.")
            } catch let error as FileAccessConnectorError {
                guard case let .replacementReportedRelocatedItem(
                    code,
                    generation,
                    fileName
                ) = error else {
                    return XCTFail("Expected durable reported item, received \(error).")
                }
                XCTAssertEqual(code, 818)
                XCTAssertEqual(generation, expectedGeneration)
                preservedFileName = fileName
            }
            let durableFileName = try XCTUnwrap(preservedFileName)
            XCTAssertNotEqual(durableFileName, fileName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
            XCTAssertEqual(
                try Data(
                    contentsOf: folderURL.appendingPathComponent(
                        durableFileName.value
                    )
                ),
                reportedData
            )
        }
    }

    func testReplaceSaveAsTargetRestoresOriginalWhenCoordinationAccessorChangesSourceURL() async throws {
        let folderURL = try makeTemporaryFolder()
        let providerTemporaryDirectoryURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Same Volume.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let relocatedURL = providerTemporaryDirectoryURL.appendingPathComponent(
            "Provider Relocated Original"
        )
        let coordinatedSourceURL = providerTemporaryDirectoryURL.appendingPathComponent(
            "Coordinated Provider Source"
        )
        let originalData = Data("Original from provider temp\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let connector = makeInjectedConnector(
            identityReader: { _ in nil },
            replacer: { originalURL, stagingURL, fileManager in
                try fileManager.removeItem(at: stagingURL)
                try fileManager.moveItem(at: originalURL, to: relocatedURL)
                throw NSError(
                    domain: "PhonePadTests.SameVolumeRelocatedOriginal",
                    code: 820,
                    userInfo: ["NSFileOriginalItemLocationKey": relocatedURL]
                )
            },
            saveAsRecoveryAccessorSourceProvider: {
                accessorSourceURL,
                fileManager in
                try fileManager.moveItem(
                    at: accessorSourceURL,
                    to: coordinatedSourceURL
                )
                return coordinatedSourceURL
            }
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        do {
            _ = try await connector.replaceSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "Intended edit\n"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected provider-reported original recovery result.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .replacementReportedRelocatedItem(
                    code: 820,
                    generation: .original,
                    preservedFileName: fileName
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocatedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: coordinatedSourceURL.path)
        )
        XCTAssertEqual(try Data(contentsOf: targetURL), originalData)
        let reopenedFile = try await FileAccessConnector(
            fileManager: .default
        ).openTextFile(at: targetURL)
        XCTAssertEqual(reopenedFile.text, "Original from provider temp\n")
    }

    func testReplaceSaveAsTargetPreservesTemporaryCandidateWhenDurableRecoveryFails() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Recovery Failure.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let originalData = Data("Original generation\n".utf8)
        try originalData.write(to: targetURL, options: .withoutOverwriting)
        let confirmedIdentity = FileIdentity(
            volumeUUID: UUID(),
            documentIdentifier: 101
        )
        let changedIdentity = FileIdentity(
            volumeUUID: UUID(),
            documentIdentifier: 102
        )
        let identities = SequencedFileIdentities(
            identities: [
                confirmedIdentity,
                confirmedIdentity,
                confirmedIdentity,
                changedIdentity,
            ]
        )
        let recordedURLs = RecordedSaveAsStagingURLs()
        let connector = makeInjectedConnector(
            identityReader: { _ in identities.next() },
            replacer: { originalURL, stagingURL, fileManager in
                recordedURLs.record(fileURL: stagingURL)
                try fileManager.removeItem(at: stagingURL)
                try fileManager.moveItem(at: originalURL, to: stagingURL)
                throw NSError(
                    domain: "PhonePadTests.RelocatedRecoveryFailure",
                    code: 819,
                    userInfo: ["NSFileOriginalItemLocationKey": stagingURL]
                )
            }
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        do {
            _ = try await connector.replaceSaveAsTarget(
                plan: preflight.plan,
                encodedFile: try encodeNewTextFile(text: "Intended edit\n"),
                currentDocumentID: currentDocumentID,
                collisionClaims: []
            )
            XCTFail("Expected durable recovery verification to fail.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .replacementReportedItemPreservationFailed(
                    replacementCode: 819,
                    preservationCode: Int(EBUSY),
                    generation: .original
                )
            )
        }
        let stagingURLs = try XCTUnwrap(recordedURLs.snapshot())
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path) {
                try FileManager.default.removeItem(at: stagingURLs.directoryURL)
            }
        }
        XCTAssertEqual(try Data(contentsOf: stagingURLs.fileURL), originalData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURLs.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func testReplaceSaveAsTargetAcceptsVerifiedDifferentReturnedDirectChild() async throws {
        let folderURL = try makeTemporaryFolder()
        let requestedFileName = try ValidatedFileName(validating: "Requested.txt")
        let returnedFileName = try ValidatedFileName(validating: "Provider Result.txt")
        let requestedURL = folderURL.appendingPathComponent(requestedFileName.value)
        let returnedURL = folderURL.appendingPathComponent(returnedFileName.value)
        let originalData = Data("Original remains\n".utf8)
        try originalData.write(to: requestedURL, options: .withoutOverwriting)
        let connector = makeInjectedConnector(
            identityReader: { _ in nil },
            replacer: { _, stagingURL, fileManager in
                try fileManager.moveItem(at: stagingURL, to: returnedURL)
                return returnedURL
            }
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let encodedFile = try encodeNewTextFile(text: "Provider output\n")
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: requestedFileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        let outcome = try await connector.replaceSaveAsTarget(
            plan: preflight.plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .complete(.bound(binding)) = outcome else {
            return XCTFail("Expected verified provider result binding, received \(outcome).")
        }
        XCTAssertEqual(binding.locatorURL.standardizedFileURL, returnedURL.standardizedFileURL)
        XCTAssertEqual(binding.displayName, returnedFileName)
        XCTAssertEqual(binding.digest, encodedFile.digest)
        XCTAssertEqual(try Data(contentsOf: returnedURL), encodedFile.data)
        XCTAssertEqual(try Data(contentsOf: requestedURL), originalData)
    }

    func testCreateSaveAsTargetKeepsBookmarkWhenOptionalIdentityInspectionFails() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileName = try ValidatedFileName(validating: "Bookmark First.txt")
        let targetURL = folderURL.appendingPathComponent(fileName.value)
        let connector = makeInjectedConnector(
            identityReader: { _ in
                throw ForcedIdentityReadError()
            },
            replacer: replaceFile
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let encodedFile = try encodeNewTextFile(text: "Durably attached\n")
        let preflight = try await connector.preflightSaveAsTarget(
            in: folderURL,
            fileName: fileName,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        let outcome = try await connector.createSaveAsTarget(
            plan: preflight.plan,
            encodedFile: encodedFile,
            currentDocumentID: currentDocumentID,
            collisionClaims: []
        )

        guard case let .complete(.bound(binding)) = outcome else {
            return XCTFail("Expected bookmark-backed output, received \(outcome).")
        }
        XCTAssertNil(binding.identity)
        var bookmarkIsStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: binding.bookmark.data,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        )
        XCTAssertFalse(bookmarkIsStale)
        XCTAssertEqual(resolvedURL.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: targetURL), encodedFile.data)
    }

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

    func testOpenTextFileReadsExactBytesAndReturnsDurableBinding() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Opened.txt", isDirectory: false)
        let bytes = Data("First line\nSecond line\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        let openedFile = try await connector.openTextFile(at: fileURL)

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

    func testOpenTextFileDecodesUTF16LEAndRetainsExactBaselineMetadata() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Windows.txt", isDirectory: false)
        let bytes = Data([
            0xff, 0xfe,
            0x41, 0x00, 0x0d, 0x00, 0x0a, 0x00,
            0xac, 0x20, 0x0d, 0x00, 0x0a, 0x00,
        ])
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        let openedFile = try await connector.openTextFile(at: fileURL)

        XCTAssertEqual(openedFile.text, "A\n€\n")
        XCTAssertEqual(openedFile.binding.digest, try digest(data: bytes))
        XCTAssertEqual(openedFile.binding.encoding, .utf16LittleEndianWithBOM)
        XCTAssertEqual(openedFile.binding.lineEnding, .crlf)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenTextFileRejectsExplicitRTFTypeBeforeByteDecoding() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Formatted.rtf", isDirectory: false)
        let bytes = Data("Ordinary ASCII that would otherwise decode".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        await assertOpenFails(
            connector: connector,
            fileURL: fileURL,
            expectedError: .selectedFileHasUnsupportedContentType(UTType.rtf.identifier)
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenTextFileAcceptsExtensionlessAndGenericDataAfterByteValidation() async throws {
        let folderURL = try makeTemporaryFolder()
        let extensionlessURL = folderURL.appendingPathComponent(
            "Extensionless",
            isDirectory: false
        )
        let genericDataURL = folderURL.appendingPathComponent(
            "Generic.dat",
            isDirectory: false
        )
        let bytes = Data("Validated generic text\n".utf8)
        try bytes.write(to: extensionlessURL, options: .withoutOverwriting)
        try bytes.write(to: genericDataURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        let extensionless = try await connector.openTextFile(at: extensionlessURL)
        let genericData = try await connector.openTextFile(at: genericDataURL)

        XCTAssertEqual(extensionless.text, "Validated generic text\n")
        XCTAssertEqual(genericData.text, "Validated generic text\n")
        XCTAssertEqual(extensionless.binding.digest, try digest(data: bytes))
        XCTAssertEqual(genericData.binding.digest, try digest(data: bytes))
    }

    func testOpenTextFileAcceptsValidatedTextIndependentOfImageExtension() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Image.png", isDirectory: false)
        let bytes = Data("ASCII bytes are not enough to override an explicit image type".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        let openedFile = try await connector.openTextFile(at: fileURL)

        XCTAssertEqual(openedFile.text, String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(openedFile.binding.encoding, .utf8)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenTextFileRejectsPackageBeforeInspectingItsContents() async throws {
        let folderURL = try makeTemporaryFolder()
        let packageURL = folderURL.appendingPathComponent("Document.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        let contentURL = packageURL.appendingPathComponent("TXT.rtf", isDirectory: false)
        try Data("Package content".utf8).write(
            to: contentURL,
            options: .withoutOverwriting
        )
        let connector = FileAccessConnector(fileManager: .default)

        await assertOpenFails(
            connector: connector,
            fileURL: packageURL,
            expectedError: .selectedFileIsPackage
        )

        XCTAssertEqual(try Data(contentsOf: contentURL), Data("Package content".utf8))
    }

    func testOpenTextFileRejectsBinarySignatureDespitePlainTextType() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Disguised.txt", isDirectory: false)
        let bytes = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x41, 0x42, 0x43,
        ])
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        await assertOpenFails(
            connector: connector,
            fileURL: fileURL,
            expectedError: .textDecodingFailed(
                .unsupportedContent(.rasterImage)
            )
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenTextFileRejectsUTF32MarkerFromExtensionlessData() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("UTF32", isDirectory: false)
        let bytes = Data([0x00, 0x00, 0xfe, 0xff, 0x00, 0x00, 0x00, 0x41])
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        await assertOpenFails(
            connector: connector,
            fileURL: fileURL,
            expectedError: .textDecodingFailed(.unsupportedContent(.utf32))
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenTextFileFallsBackFromInvalidUTF8ToWindows1252() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Legacy.txt", isDirectory: false)
        let bytes = Data([0x80, 0x20, 0x41])
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)

        let openedFile = try await connector.openTextFile(at: fileURL)

        XCTAssertEqual(openedFile.text, "€ A")
        XCTAssertEqual(openedFile.binding.encoding, .windows1252)
        XCTAssertEqual(openedFile.binding.digest, try digest(data: bytes))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testOpenTextFileRejectsOversizedFileWithoutReadingItAsText() async throws {
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

    func testOpenTextFileRejectsDirectorySymbolicLinkAndMissingItem() async throws {
        let folderURL = try makeTemporaryFolder()
        let directoryURL = folderURL.appendingPathComponent("Directory.txt", isDirectory: true)
        let destinationURL = folderURL.appendingPathComponent("Destination.txt", isDirectory: false)
        let symbolicLinkURL = folderURL.appendingPathComponent("Link.txt", isDirectory: false)
        let specialURL = folderURL.appendingPathComponent("Pipe.txt", isDirectory: false)
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
        let specialCreationResult = specialURL.path.withCString { path in
            mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(specialCreationResult, 0)
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
            fileURL: specialURL,
            expectedError: .selectedFileIsNotRegularFile(.special)
        )
        await assertOpenFails(
            connector: connector,
            fileURL: missingURL,
            expectedError: .selectedFileMissing
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("destination".utf8))
    }

    func testSaveTextFileReplacesOriginalOnlyOnExplicitCallAndReturnsVerifiedBinding() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Bound.txt", isDirectory: false)
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let openedFile = try await connector.openTextFile(at: fileURL)
        let encodedFile = try encodeNewTextFile(text: "Edited\r\ncontent\n")

        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        let outcome = try await connector.saveTextFile(
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

    func testSaveTextFileWritesExactOpenedEncodingAndLineEndingBytes() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Preserved.txt", isDirectory: false)
        let originalBytes = Data([
            0xff, 0xfe,
            0x41, 0x00, 0x0d, 0x00, 0x0a, 0x00,
        ])
        let expectedBytes = Data([
            0xff, 0xfe,
            0x42, 0x00, 0x0d, 0x00, 0x0a, 0x00,
            0xac, 0x20, 0x0d, 0x00, 0x0a, 0x00,
        ])
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let openedFile = try await connector.openTextFile(at: fileURL)
        let encodedFile = try encodeTextFile(
            text: "B\n€\n",
            encoding: openedFile.binding.encoding,
            lineEnding: openedFile.binding.lineEnding
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        let outcome = try await connector.saveTextFile(
            binding: openedFile.binding,
            encodedFile: encodedFile
        )

        guard case let .bound(savedBinding) = outcome else {
            return XCTFail("Expected durable saved binding, received \(outcome).")
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), expectedBytes)
        XCTAssertEqual(savedBinding.encoding, .utf16LittleEndianWithBOM)
        XCTAssertEqual(savedBinding.lineEnding, .crlf)
        XCTAssertEqual(savedBinding.digest, try digest(data: expectedBytes))
    }

    func testSaveTextFileBlocksExternalContentMutationWithoutOverwritingIt() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Conflict.txt", isDirectory: false)
        try Data("Original\n".utf8).write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let openedFile = try await connector.openTextFile(at: fileURL)
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

    func testSaveTextFileBlocksStableIdentityChangeEvenWhenDigestMatches() async throws {
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

    func testSaveTextFileReportsDeletedDirectoryAndSymbolicLinkTargetsWithoutWriting() async throws {
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
            let openedFile = try await connector.openTextFile(at: fileURL)
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

    func testSaveTextFileReportsBookmarkResolutionFailureWhenOriginalDisappears() async throws {
        let folderURL = try makeTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Missing.txt", isDirectory: false)
        try Data("Original\n".utf8).write(to: fileURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let openedFile = try await connector.openTextFile(at: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        await assertSaveFails(
            connector: connector,
            binding: openedFile.binding,
            encodedFile: try encodeNewTextFile(text: "PhonePad edit\n"),
            expectedError: .bookmarkResolutionFailed(code: 4)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveTextFileClassifiesReplacementFailureBeforeWriteAsUnchanged() async throws {
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

    func testSaveTextFileTreatsVerifiedIntendedBytesAsSuccessWhenReplacementReportsError() async throws {
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

        let outcome = try await connector.saveTextFile(
            binding: binding,
            encodedFile: encodedFile
        )

        guard case let .bound(savedBinding) = outcome else {
            return XCTFail("Expected verified bound save, received \(outcome).")
        }
        XCTAssertEqual(savedBinding.digest, encodedFile.digest)
        XCTAssertEqual(try Data(contentsOf: fileURL), encodedFile.data)
    }

    func testSaveTextFileReportsIndeterminateOutcomeWhenReplacementErrorLeavesThirdContent() async throws {
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

private struct ForcedIdentityReadError: Error, Sendable {}

private struct ForcedSaveAsStagingError: CustomNSError, Sendable {
    static let errorDomain: String = "PhonePadTests.ForcedSaveAsStaging"

    let code: Int

    var errorCode: Int {
        code
    }
}

private struct SaveAsStagingURLs: Sendable {
    let directoryURL: URL
    let fileURL: URL
}

private final class RecordedSaveAsStagingURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var directoryURL: URL?
    private var fileURL: URL?

    func record(fileURL: URL) {
        record(
            directoryURL: fileURL.deletingLastPathComponent(),
            fileURL: fileURL
        )
    }

    func record(directoryURL: URL) {
        lock.lock()
        self.directoryURL = directoryURL
        lock.unlock()
    }

    func record(directoryURL: URL, fileURL: URL) {
        lock.lock()
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        lock.unlock()
    }

    func snapshot() -> SaveAsStagingURLs? {
        lock.lock()
        defer { lock.unlock() }
        guard let directoryURL, let fileURL else {
            return nil
        }
        return SaveAsStagingURLs(
            directoryURL: directoryURL,
            fileURL: fileURL
        )
    }
}

private final class SequencedFileIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [FileIdentity]

    init(identities: [FileIdentity]) {
        self.identities = identities
    }

    func next() -> FileIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard !identities.isEmpty else {
            return nil
        }
        return identities.removeFirst()
    }
}

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

private func makeBookmarkData(url: URL) throws -> Data {
    try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
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
    makeInjectedConnector(
        identityReader: identityReader,
        replacer: replacer,
        saveAsRecoveryAccessorSourceProvider: { sourceURL, _ in sourceURL }
    )
}

private func makeInjectedConnector(
    identityReader: @escaping FileAccessConnector.FileIdentityReader,
    replacer: @escaping FileAccessConnector.FileReplacer,
    saveAsRecoveryAccessorSourceProvider: @escaping FileAccessConnector.SaveAsRecoveryAccessorSourceProvider
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
        replacer: replacer,
        saveAsRecoveryAccessorSourceProvider: saveAsRecoveryAccessorSourceProvider
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
        _ = try await connector.openTextFile(at: fileURL)
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
        _ = try await connector.saveTextFile(
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
