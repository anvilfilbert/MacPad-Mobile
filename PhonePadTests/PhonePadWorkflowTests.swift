import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadWorkflowTests: XCTestCase {
    func testOrdinaryLaunchHasExactlyOneFreshUntitledTab() {
        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let tabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        let state = makeInitialPhonePadState(documentID: documentID, tabID: tabID)

        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.activeTabID, tabID)
        XCTAssertEqual(state.activeTab.document.id, documentID)
        XCTAssertEqual(state.activeTab.document.title, "Untitled")
        XCTAssertEqual(state.activeTab.document.text, "")
        XCTAssertFalse(state.activeTab.document.isUnsaved)
        XCTAssertEqual(state.activeTab.document.recoveryState, .clean)
    }

    func testFirstEditCreatesCompleteProtectedRecoveryCheckpoint() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }

        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let tabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let editedAt = Date(timeIntervalSince1970: 1_786_646_400)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let initialState = makeInitialPhonePadState(documentID: documentID, tabID: tabID)

        let editedState = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "Protected text",
            editedAt: editedAt,
            recoveryStore: store
        )

        XCTAssertEqual(editedState.activeTab.document.text, "Protected text")
        XCTAssertTrue(editedState.activeTab.document.isUnsaved)
        XCTAssertEqual(editedState.activeTab.document.recoveryState, .protectedUnsaved)

        let envelope = try await store.load(documentID: documentID)
        XCTAssertEqual(envelope?.documentID, documentID)
        XCTAssertEqual(envelope?.title, "Untitled")
        XCTAssertEqual(envelope?.text, "Protected text")
        XCTAssertEqual(envelope?.editedAt, editedAt)

        let verification = try await store.verifyCheckpoint(documentID: documentID)
        XCTAssertTrue(verification.isExcludedFromBackup)
    }

    func testRecoveryCheckpointHasCompleteFileProtectionOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator does not report a reliable file-protection resource value.")
        #else
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }

        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        let tabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let initialState = makeInitialPhonePadState(documentID: documentID, tabID: tabID)

        _ = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "Protected text",
            editedAt: Date(timeIntervalSince1970: 1_786_646_400),
            recoveryStore: store
        )

        let verification = try await store.verifyCheckpoint(documentID: documentID)
        XCTAssertTrue(verification.hasCompleteFileProtection)
        #endif
    }

    func testFailedReplacementRestoresPreviousCanonicalCheckpoint() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }

        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!)
        let previousEnvelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Untitled",
            text: "Previous recovery text",
            editedAt: Date(timeIntervalSince1970: 1_786_646_400)
        )
        let replacementEnvelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Untitled",
            text: "Replacement recovery text",
            editedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )
        let stableStore = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await stableStore.save(envelope: previousEnvelope)

        let failingStore = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: { _ in
                throw ForcedPostPromotionValidationError()
            }
        )

        do {
            try await failingStore.save(envelope: replacementEnvelope)
            XCTFail("Expected post-promotion validation to fail.")
        } catch FileRecoveryStoreError.postPromotionValidationFailed {
            // Expected typed failure after rollback.
        } catch {
            XCTFail("Expected a post-promotion validation error, received \(error).")
        }

        let restoredEnvelope = try await stableStore.load(documentID: documentID)
        XCTAssertEqual(restoredEnvelope, previousEnvelope)
        XCTAssertNotEqual(restoredEnvelope, replacementEnvelope)
    }

    func testLoadRestoresPreviousGenerationAfterInterruptedPromotion() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!)
        let previousEnvelope = makeRecoveryEnvelope(
            documentID: documentID,
            text: "Previous verified text",
            editedAt: 1_786_646_400
        )
        let promotedEnvelope = makeRecoveryEnvelope(
            documentID: documentID,
            text: "Promoted but uncommitted text",
            editedAt: 1_786_646_500
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(envelope: previousEnvelope)

        let paths = recoveryPaths(rootURL: rootURL, documentID: documentID)
        try FileManager.default.copyItem(at: paths.canonical, to: paths.previous)
        try applyProtectedRecoveryMetadata(to: paths.previous)
        try writeProtectedRecoveryEnvelope(promotedEnvelope, to: paths.transaction)
        try writeProtectedRecoveryEnvelope(promotedEnvelope, to: paths.canonical)

        let restartedStore = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let loadedEnvelope = try await restartedStore.load(documentID: documentID)

        XCTAssertEqual(loadedEnvelope, previousEnvelope)
        XCTAssertEqual(
            try recoveryArtifactNames(rootURL: rootURL),
            [paths.canonical.lastPathComponent]
        )
    }

    func testLoadRestoresOrphanedPreviousGenerationWhenCanonicalIsMissing() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        let previousEnvelope = makeRecoveryEnvelope(
            documentID: documentID,
            text: "Only verified generation",
            editedAt: 1_786_646_400
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(envelope: previousEnvelope)

        let paths = recoveryPaths(rootURL: rootURL, documentID: documentID)
        try FileManager.default.moveItem(at: paths.canonical, to: paths.previous)

        let restartedStore = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let loadedEnvelope = try await restartedStore.load(documentID: documentID)

        XCTAssertEqual(loadedEnvelope, previousEnvelope)
        XCTAssertEqual(
            try recoveryArtifactNames(rootURL: rootURL),
            [paths.canonical.lastPathComponent]
        )
    }

    func testMetadataFailureRemovesRejectedPromotedGeneration() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
        let previousEnvelope = makeRecoveryEnvelope(
            documentID: documentID,
            text: "Previous protected text",
            editedAt: 1_786_646_400
        )
        let rejectedEnvelope = makeRecoveryEnvelope(
            documentID: documentID,
            text: "Rejected unprotected text",
            editedAt: 1_786_646_500
        )
        let stableStore = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await stableStore.save(envelope: previousEnvelope)

        let failingStore = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: { promotedURL in
                var values = URLResourceValues()
                values.isExcludedFromBackup = false
                var metadataURL = promotedURL
                try metadataURL.setResourceValues(values)
                throw ForcedPostPromotionValidationError()
            }
        )

        do {
            try await failingStore.save(envelope: rejectedEnvelope)
            XCTFail("Expected post-promotion validation to fail.")
        } catch FileRecoveryStoreError.postPromotionValidationFailed {
            // Expected typed failure after rollback.
        } catch {
            XCTFail("Expected a post-promotion validation error, received \(error).")
        }

        let restoredEnvelope = try await stableStore.load(documentID: documentID)
        let paths = recoveryPaths(rootURL: rootURL, documentID: documentID)
        XCTAssertEqual(restoredEnvelope, previousEnvelope)
        XCTAssertEqual(
            try recoveryArtifactNames(rootURL: rootURL),
            [paths.canonical.lastPathComponent]
        )
    }

    func testLoadRetainsCommittedCorruptCanonicalAndPreviousWithoutTransactionMarker() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let previousEnvelope = makeRecoveryEnvelope(
            documentID: documentID,
            text: "Previous verified text",
            editedAt: 1_786_646_400
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(envelope: previousEnvelope)

        let paths = recoveryPaths(rootURL: rootURL, documentID: documentID)
        try FileManager.default.copyItem(at: paths.canonical, to: paths.previous)
        try applyProtectedRecoveryMetadata(to: paths.previous)
        let corruptCanonicalData = Data("{".utf8)
        try corruptCanonicalData.write(
            to: paths.canonical,
            options: [.atomic, .completeFileProtection]
        )
        try applyProtectedRecoveryMetadata(to: paths.canonical)
        let previousData = try Data(contentsOf: paths.previous)

        let restartedStore = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        do {
            _ = try await restartedStore.load(documentID: documentID)
            XCTFail("Expected committed corrupt recovery data to remain unreadable.")
        } catch FileRecoveryStoreError.couldNotDecodeCheckpoint {
            // Expected: only an explicit recovery decision may replace committed corrupt data.
        } catch {
            XCTFail("Expected a decode failure, received \(error).")
        }

        XCTAssertEqual(try Data(contentsOf: paths.canonical), corruptCanonicalData)
        XCTAssertEqual(try Data(contentsOf: paths.previous), previousData)
        XCTAssertEqual(
            try recoveryArtifactNames(rootURL: rootURL),
            [paths.previous.lastPathComponent, paths.canonical.lastPathComponent].sorted()
        )
    }

    private func makeRecoveryRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        return rootURL
    }
}

private struct ForcedPostPromotionValidationError: Error, Sendable {}

private struct RecoveryPaths {
    let canonical: URL
    let staging: URL
    let transaction: URL
    let previous: URL
}

private func makeRecoveryEnvelope(
    documentID: DocumentID,
    text: String,
    editedAt: TimeInterval
) -> RecoveryEnvelope {
    RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: documentID,
        title: "Untitled",
        text: text,
        editedAt: Date(timeIntervalSince1970: editedAt)
    )
}

private func recoveryPaths(
    rootURL: URL,
    documentID: DocumentID
) -> RecoveryPaths {
    let identifier = documentID.rawValue.uuidString.lowercased()
    return RecoveryPaths(
        canonical: rootURL.appendingPathComponent(
            "\(identifier).recovery.json",
            isDirectory: false
        ),
        staging: rootURL.appendingPathComponent(
            ".\(identifier).recovery.staging",
            isDirectory: false
        ),
        transaction: rootURL.appendingPathComponent(
            ".\(identifier).recovery.transaction",
            isDirectory: false
        ),
        previous: rootURL.appendingPathComponent(
            ".\(identifier).recovery.previous",
            isDirectory: false
        )
    )
}

private func writeProtectedRecoveryEnvelope(
    _ envelope: RecoveryEnvelope,
    to url: URL
) throws {
    let data = try JSONEncoder().encode(envelope)
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    try applyProtectedRecoveryMetadata(to: url)
}

private func applyProtectedRecoveryMetadata(to url: URL) throws {
    try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: url.path
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var metadataURL = url
    try metadataURL.setResourceValues(values)
}

private func recoveryArtifactNames(rootURL: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: []
    )
    .map(\.lastPathComponent)
    .sorted()
}
