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
}

private struct ForcedPostPromotionValidationError: Error, Sendable {}
