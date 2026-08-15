import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class ImportedCopyCleanupJournalTests: XCTestCase {
    func testInPlaceOpenNeverCreatesCleanupJournal() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let fileURL = inboxURL.appendingPathComponent("In Place.txt")
        try Data("Writable in-place content\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let documentID = DocumentID(rawValue: UUID())

        let outcome = try await connector.openTextFile(
            at: fileURL,
            documentID: documentID,
            accessIntent: .inPlace
        )

        guard case .bound = outcome else {
            return XCTFail("Expected writable in-place File to bind.")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journalRootURL.path)
        )
        await connector.stopPresenting(documentID: documentID)
    }

    func testCleanupResidualSurvivesConnectorRecreation() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let fileURL = inboxURL.appendingPathComponent("Residual.txt")
        let bytes = Data("Restart-safe cleanup\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        let failingConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: { _, _ in
                throw ForcedJournalDependencyError(code: 931)
            },
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let outcome = try await failingConnector.openTextFile(
            at: fileURL,
            documentID: documentID,
            accessIntent: .copyRequired
        )
        guard case let .detached(openedFile) = outcome else {
            return XCTFail("Expected detached imported copy, received \(outcome).")
        }
        let token = try XCTUnwrap(openedFile.importedCopyCleanupToken)

        let firstCleanup = await failingConnector.cleanupImportedCopy(token: token)

        XCTAssertEqual(firstCleanup, .residual(.deletionFailed(code: 931)))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        let recreatedConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let report = try await recreatedConnector
            .reconcileImportedCopyCleanupJournal()

        XCTAssertEqual(
            report.removed,
            [
                ImportedCopyCleanupJournalItem(
                    token: token,
                    documentID: documentID
                )
            ]
        )
        XCTAssertEqual(report.alreadyAbsent, [])
        XCTAssertEqual(report.awaitingProtection, [])
        XCTAssertEqual(report.residuals, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(journalExists(rootURL: journalRootURL))
    }

    func testReconciliationLeavesAwaitingAndUnrelatedInboxFiles() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let importedURL = inboxURL.appendingPathComponent("Awaiting.txt")
        let unrelatedURL = inboxURL.appendingPathComponent("Unrelated.txt")
        let importedBytes = Data("Accepted detached content\n".utf8)
        let unrelatedBytes = Data("Must remain untouched\n".utf8)
        try importedBytes.write(to: importedURL, options: .withoutOverwriting)
        try unrelatedBytes.write(to: unrelatedURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let outcome = try await connector.openTextFile(
            at: importedURL,
            documentID: documentID,
            accessIntent: .copyRequired
        )
        guard case let .detached(openedFile) = outcome else {
            return XCTFail("Expected detached imported copy, received \(outcome).")
        }
        let token = try XCTUnwrap(openedFile.importedCopyCleanupToken)
        let recreatedConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )

        let report = try await recreatedConnector
            .reconcileImportedCopyCleanupJournal()

        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(report.alreadyAbsent, [])
        XCTAssertEqual(
            report.awaitingProtection,
            [
                ImportedCopyCleanupJournalItem(
                    token: token,
                    documentID: documentID
                )
            ]
        )
        XCTAssertEqual(report.residuals, [])
        XCTAssertEqual(try Data(contentsOf: importedURL), importedBytes)
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), unrelatedBytes)
    }

    func testReconciliationRemovesAwaitingEntryAfterNewerTokenRemovedFile() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let importedURL = inboxURL.appendingPathComponent("Reopened.txt")
        try Data("Same supplied copy\n".utf8).write(
            to: importedURL,
            options: .withoutOverwriting
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let olderOutcome = try await connector.openTextFile(
                at: importedURL,
                documentID: documentID,
                accessIntent: .copyRequired
        )
        guard case let .detached(olderOpenedFile) = olderOutcome else {
            return XCTFail("Expected detached imported copy, received \(olderOutcome).")
        }
        let olderToken = try XCTUnwrap(
            olderOpenedFile.importedCopyCleanupToken
        )
        let capturedNewerToken = try await connector
            .captureImportedCopyCleanup(
                at: importedURL,
                documentID: documentID
            )
        let newerToken = try XCTUnwrap(capturedNewerToken)

        let newerCleanup = await connector.cleanupImportedCopy(
            token: newerToken
        )

        XCTAssertEqual(newerCleanup, .removed)
        let recreatedConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let report = try await recreatedConnector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertEqual(
            report.alreadyAbsent,
            [
                ImportedCopyCleanupJournalItem(
                    token: olderToken,
                    documentID: documentID
                )
            ]
        )
        XCTAssertEqual(report.awaitingProtection, [])
        XCTAssertEqual(report.residuals, [])
        XCTAssertFalse(journalExists(rootURL: journalRootURL))
    }

    func testSerializationContainsNoLocatorOrFileBytes() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let fileURL = inboxURL.appendingPathComponent("Private Input.txt")
        let privateText = "Private file bytes must not enter journal 910274\n"
        try Data(privateText.utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )

        _ = try await connector.openTextFile(
            at: fileURL,
            documentID: DocumentID(rawValue: UUID()),
            accessIntent: .copyRequired
        )

        let journalData = try Data(
            contentsOf: importedCopyCleanupJournalURL(
                rootURL: journalRootURL
            )
        )
        let journalText = try XCTUnwrap(
            String(data: journalData, encoding: .utf8)
        )
        XCTAssertTrue(journalText.contains("Private Input.txt"))
        XCTAssertFalse(journalText.contains(documentsURL.path))
        XCTAssertFalse(journalText.contains(inboxURL.path))
        XCTAssertFalse(journalText.contains(fileURL.path))
        XCTAssertFalse(journalText.contains(privateText))
        XCTAssertLessThan(journalData.count, 4_096)
    }

    func testCorruptJournalFailsClosed() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let importedURL = inboxURL.appendingPathComponent("Corrupt.txt")
        let unrelatedURL = inboxURL.appendingPathComponent("Unrelated.txt")
        let importedBytes = Data("Imported bytes\n".utf8)
        let unrelatedBytes = Data("Unrelated bytes\n".utf8)
        try importedBytes.write(to: importedURL, options: .withoutOverwriting)
        try unrelatedBytes.write(to: unrelatedURL, options: .withoutOverwriting)
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        _ = try await connector.openTextFile(
            at: importedURL,
            documentID: DocumentID(rawValue: UUID()),
            accessIntent: .copyRequired
        )
        let journalURL = importedCopyCleanupJournalURL(rootURL: journalRootURL)
        try Data("{not-json".utf8).write(
            to: journalURL,
            options: [.atomic, .completeFileProtection]
        )
        try applyImportedCopyCleanupJournalMetadata(
            url: journalURL,
            fileManager: .default
        )
        let recreatedConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )

        do {
            _ = try await recreatedConnector
                .reconcileImportedCopyCleanupJournal()
            XCTFail("Expected corrupt cleanup journal to fail closed.")
        } catch let error as ImportedCopyCleanupJournalError {
            XCTAssertEqual(error, .couldNotDecodeJournal)
        }
        XCTAssertEqual(try Data(contentsOf: importedURL), importedBytes)
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), unrelatedBytes)
    }

    func testUnprotectedJournalFailsClosed() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let importedURL = inboxURL.appendingPathComponent("Unprotected.txt")
        let importedBytes = Data("Protected journal required\n".utf8)
        try importedBytes.write(to: importedURL, options: .withoutOverwriting)
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        _ = try await connector.openTextFile(
            at: importedURL,
            documentID: DocumentID(rawValue: UUID()),
            accessIntent: .copyRequired
        )
        let recreatedConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: { _, itemKind, _ in
                if itemKind == .journalFile {
                    throw ImportedCopyCleanupJournalError
                        .fileProtectionVerificationFailed
                }
            }
        )

        do {
            _ = try await recreatedConnector
                .reconcileImportedCopyCleanupJournal()
            XCTFail("Expected unprotected cleanup journal to fail closed.")
        } catch let error as ImportedCopyCleanupJournalError {
            XCTAssertEqual(error, .fileProtectionVerificationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: importedURL), importedBytes)
    }

    func testCleanupRemovesTargetAndLastJournalEntry() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let fileURL = inboxURL.appendingPathComponent("Complete.txt")
        try Data("Cleanup complete\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let outcome = try await connector.openTextFile(
            at: fileURL,
            documentID: DocumentID(rawValue: UUID()),
            accessIntent: .copyRequired
        )
        guard case let .detached(openedFile) = outcome else {
            return XCTFail("Expected detached imported copy, received \(outcome).")
        }

        let cleanup = await connector.cleanupImportedCopy(
            token: try XCTUnwrap(openedFile.importedCopyCleanupToken)
        )

        XCTAssertEqual(cleanup, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(journalExists(rootURL: journalRootURL))
    }

    func testPreReadJournalFailureSynchronouslyRemovesExactImportedCopy() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let importedURL = inboxURL.appendingPathComponent("Rejected Before Read.txt")
        let unrelatedURL = inboxURL.appendingPathComponent("Unrelated.txt")
        let importedBytes = Data("Must never be accepted\n".utf8)
        let unrelatedBytes = Data("Must remain\n".utf8)
        try importedBytes.write(to: importedURL, options: .withoutOverwriting)
        try unrelatedBytes.write(to: unrelatedURL, options: .withoutOverwriting)
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: { _, itemKind, _ in
                if itemKind == .journalFile {
                    throw ImportedCopyCleanupJournalError
                        .fileProtectionVerificationFailed
                }
            }
        )

        do {
            _ = try await connector.openTextFile(
                at: importedURL,
                documentID: DocumentID(rawValue: UUID()),
                accessIntent: .copyRequired
            )
            XCTFail("Expected pre-read cleanup journal failure.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .importedCopyCleanupJournal(
                    .fileProtectionVerificationFailed
                )
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: importedURL.path)
        )
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), unrelatedBytes)
    }

    func testInitialJournalVerificationAndRemovalFailureReconcilesAuthorizedAfterTermination() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let importedURL = inboxURL.appendingPathComponent(
            "Initial Persistence Failure.txt"
        )
        let importedBytes = Data("Initial persistence failure\n".utf8)
        try importedBytes.write(
            to: importedURL,
            options: .withoutOverwriting
        )
        let documentID = DocumentID(rawValue: UUID())
        let failureGate = ImportedCopyCleanupInitialFailureGate(
            removalFailureCode: 933
        )
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: failureGate.remove,
            metadataVerifier: failureGate.verifyMetadata
        )

        do {
            _ = try await connector.openTextFile(
                at: importedURL,
                documentID: documentID,
                accessIntent: .copyRequired
            )
            XCTFail("Expected initial cleanup persistence failure.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .importedCopyCleanupJournalCleanupFailed(
                    .fileProtectionVerificationFailed,
                    .deletionFailed(code: 933)
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: importedURL), importedBytes)

        let recreatedConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let report = try await recreatedConnector
            .reconcileImportedCopyCleanupJournal()

        XCTAssertEqual(report.removed.count, 1)
        XCTAssertEqual(report.removed.first?.documentID, documentID)
        XCTAssertEqual(report.awaitingProtection, [])
        XCTAssertEqual(report.residuals, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedURL.path))
        XCTAssertFalse(journalExists(rootURL: journalRootURL))
    }

    func testRejectedCleanupSurvivesTerminationBeforeRemovalRecovers() async throws {
        let documentsURL = try makeTemporaryFolder()
        let inboxURL = try makeInbox(in: documentsURL)
        let journalRootURL = journalRoot(in: documentsURL)
        let importedURL = inboxURL.appendingPathComponent(
            "Rejected Dual Failure.txt"
        )
        let importedBytes = Data("Rejected\0binary".utf8)
        try importedBytes.write(
            to: importedURL,
            options: .withoutOverwriting
        )
        let documentID = DocumentID(rawValue: UUID())
        let failureGate = ImportedCopyCleanupDualFailureGate(
            removalFailureCode: 932
        )
        let connector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: failureGate.remove,
            metadataVerifier: failureGate.verifyMetadata
        )

        let outcome = try await connector.openTextFile(
            at: importedURL,
            documentID: documentID,
            accessIntent: .copyRequired
        )

        guard case let .rejected(rejection) = outcome else {
            return XCTFail("Expected rejected imported copy, received \(outcome).")
        }
        let token = try XCTUnwrap(rejection.importedCopyCleanupToken)
        XCTAssertEqual(
            rejection.error,
            .textDecodingFailed(.containsNullScalar)
        )
        XCTAssertEqual(try Data(contentsOf: importedURL), importedBytes)
        let failedCleanup = await connector.cleanupImportedCopy(token: token)
        XCTAssertEqual(
            failedCleanup,
            .residual(.deletionFailed(code: 932))
        )

        let recreatedConnector = makeConnector(
            inboxURL: inboxURL,
            journalRootURL: journalRootURL,
            remover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let recreatedReport = try await recreatedConnector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertEqual(
            recreatedReport.removed,
            [
                ImportedCopyCleanupJournalItem(
                    token: token,
                    documentID: documentID
                ),
            ]
        )
        XCTAssertEqual(recreatedReport.awaitingProtection, [])
        XCTAssertEqual(recreatedReport.residuals, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedURL.path))
        XCTAssertFalse(journalExists(rootURL: journalRootURL))
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

private struct ForcedJournalDependencyError: CustomNSError, Sendable {
    static let errorDomain = "PhonePadTests.ForcedJournalDependency"
    let code: Int
    var errorCode: Int { code }
}

private final class ImportedCopyCleanupDualFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private let removalFailureCode: Int
    private var directoryVerificationCount: Int = 0
    private var shouldFail: Bool = true

    init(removalFailureCode: Int) {
        self.removalFailureCode = removalFailureCode
    }

    func verifyMetadata(
        _ url: URL,
        itemKind: ImportedCopyCleanupJournalItemKind,
        fileManager: FileManager
    ) throws {
        try verifyImportedCopyCleanupJournalMetadata(
            url: url,
            itemKind: itemKind,
            fileManager: fileManager
        )
        let mustFail = lock.withLock {
            guard itemKind == .directory else {
                return false
            }
            directoryVerificationCount += 1
            return shouldFail && directoryVerificationCount >= 3
        }
        guard !mustFail else {
            throw ImportedCopyCleanupJournalError
                .fileProtectionVerificationFailed
        }
    }

    func remove(_ url: URL, fileManager: FileManager) throws {
        let mustFail = lock.withLock { shouldFail }
        guard !mustFail else {
            throw ForcedJournalDependencyError(code: removalFailureCode)
        }
        try removeImportedCopy(url: url, fileManager: fileManager)
    }

}

private final class ImportedCopyCleanupInitialFailureGate: @unchecked Sendable {
    private let removalFailureCode: Int

    init(removalFailureCode: Int) {
        self.removalFailureCode = removalFailureCode
    }

    func verifyMetadata(
        _ url: URL,
        itemKind: ImportedCopyCleanupJournalItemKind,
        fileManager: FileManager
    ) throws {
        try verifyImportedCopyCleanupJournalMetadata(
            url: url,
            itemKind: itemKind,
            fileManager: fileManager
        )
        guard itemKind != .journalFile else {
            throw ImportedCopyCleanupJournalError
                .fileProtectionVerificationFailed
        }
    }

    func remove(_ url: URL, fileManager: FileManager) throws {
        _ = url
        _ = fileManager
        throw ForcedJournalDependencyError(code: removalFailureCode)
    }
}

private func makeConnector(
    inboxURL: URL,
    journalRootURL: URL,
    remover: @escaping FileAccessConnector.ImportedCopyRemover,
    metadataVerifier: @escaping FileAccessConnector
        .ImportedCopyCleanupJournalMetadataVerifier
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
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark.data,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedFileBookmark(url: url, isStale: isStale)
        },
        identityReader: { _ in nil },
        replacer: { originalURL, stagingURL, fileManager in
            try fileManager.replaceItemAt(
                originalURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        },
        fileWritabilityReader: { _ in true },
        applicationInboxURL: inboxURL,
        importedCopyCleanupJournalRootURL: journalRootURL,
        importedCopyRemover: remover,
        importedCopyCleanupJournalMetadataVerifier: metadataVerifier
    )
}

private func makeInbox(in documentsURL: URL) throws -> URL {
    let inboxURL = documentsURL.appendingPathComponent(
        "Inbox",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: inboxURL,
        withIntermediateDirectories: false,
        attributes: nil
    )
    return inboxURL
}

private func journalRoot(in documentsURL: URL) -> URL {
    documentsURL.appendingPathComponent("Cleanup Journal", isDirectory: true)
}

private func journalExists(rootURL: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: importedCopyCleanupJournalURL(rootURL: rootURL).path
    )
}
