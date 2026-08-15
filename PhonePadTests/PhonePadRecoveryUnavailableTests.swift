import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadRecoveryUnavailableTests: XCTestCase {
    func testFailedCheckpointPublishesPersistentBannerAndRetryProtectsCurrentText() async throws {
        let fixture = try makeFixture()
        let unprotectedText = "Newest in-memory text\n"

        fixture.model.editActiveDocument(text: unprotectedText)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .recoveryUnavailable
        )
        XCTAssertEqual(
            fixture.model.recoveryUnavailableNotice,
            RecoveryUnavailableNotice(
                documentID: fixture.documentID,
                hasNewerUnprotectedText: true,
                hasLastVerifiedCheckpoint: false
            )
        )
        XCTAssertTrue(fixture.model.editorMutationDisabled)
        XCTAssertFalse(fixture.model.editorInteractionDisabled)

        fixture.model.editActiveDocument(text: "Rejected mutation\n")
        XCTAssertEqual(fixture.model.activeText, unprotectedText)
        let failedRetry = await fixture.model.retryActiveDocumentRecovery()
        XCTAssertFalse(failedRetry)

        fixture.validationGate.repair()
        let successfulRetry = await fixture.model.retryActiveDocumentRecovery()
        XCTAssertTrue(successfulRetry)

        XCTAssertNil(fixture.model.recoveryUnavailableNotice)
        XCTAssertNil(fixture.model.recoveryError)
        XCTAssertFalse(fixture.model.editorMutationDisabled)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        let protectedEnvelope = try await fixture.store.load(
            documentID: fixture.documentID
        )
        XCTAssertEqual(protectedEnvelope?.text, unprotectedText)
    }

    func testDiscardRecoveryUnavailableRestoresLastVerifiedGeneration() async throws {
        let recoveryRootURL = try makeRecoveryRoot()
        let stableStore = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        let documentID = DocumentID(rawValue: UUID())
        let tabID = TabID(rawValue: UUID())
        let verifiedText = "Last verified generation\n"
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: tabID
            ),
            newText: verifiedText,
            editedAt: Date(timeIntervalSince1970: 1_780_000_000),
            recoveryStore: stableStore
        )
        let validationGate = RecoveryUnavailableValidationGate()
        let failingStore = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default,
            postPromotionValidation: validationGate.validate
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: failingStore,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )

        model.editActiveDocument(text: "Intermediate unprotected generation\n")
        model.editActiveDocument(text: "Newer unprotected generation\n")
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            model.recoveryUnavailableNotice,
            RecoveryUnavailableNotice(
                documentID: documentID,
                hasNewerUnprotectedText: true,
                hasLastVerifiedCheckpoint: true
            )
        )
        let didDiscard = await model.discardRecoveryUnavailableEdits()
        XCTAssertTrue(didDiscard)

        XCTAssertEqual(model.activeText, verifiedText)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertNil(model.recoveryUnavailableNotice)
        XCTAssertNil(model.recoveryError)
        let retainedEnvelope = try await stableStore.load(
            documentID: documentID
        )
        XCTAssertEqual(retainedEnvelope?.text, verifiedText)
    }

    func testDiscardFirstFailedCheckpointRestoresCleanDocument() async throws {
        let fixture = try makeFixture()

        fixture.model.editActiveDocument(text: "First unprotected text\n")
        try await Task.sleep(for: .milliseconds(250))

        let didDiscard = await fixture.model.discardRecoveryUnavailableEdits()
        XCTAssertTrue(didDiscard)
        XCTAssertEqual(fixture.model.activeText, "")
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .clean
        )
        XCTAssertFalse(fixture.model.state.activeTab.document.isUnsaved)
        XCTAssertNil(fixture.model.recoveryUnavailableNotice)
        let absentEnvelope = try await fixture.store.load(
            documentID: fixture.documentID
        )
        XCTAssertNil(absentEnvelope)
    }

    func testBoundSaveDoesNotWriteUntilFailedCheckpointRetrySucceeds() async throws {
        let recoveryRootURL = try makeRecoveryRoot()
        let sourceRootURL = try makeRecoveryRoot()
        let sourceURL = sourceRootURL.appendingPathComponent(
            "Bound.txt",
            isDirectory: false
        )
        let originalData = Data("Original\n".utf8)
        try originalData.write(to: sourceURL, options: .withoutOverwriting)
        let validationGate = RecoveryUnavailableValidationGate()
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default,
            postPromotionValidation: validationGate.validate
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpen = await model.openRecoveryUnavailableTestFile(sourceURL)
        XCTAssertTrue(didOpen)
        model.editActiveDocument(text: "New protected output\n")
        try await Task.sleep(for: .milliseconds(250))

        let failedSave = await model.saveActiveDocument()
        XCTAssertFalse(failedSave)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)

        validationGate.repair()
        let successfulSave = await model.saveActiveDocument()
        XCTAssertTrue(successfulSave)
        XCTAssertEqual(
            try Data(contentsOf: sourceURL),
            Data("New protected output\n".utf8)
        )
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .clean
        )
    }

    private func makeFixture() throws -> RecoveryUnavailableFixture {
        let recoveryRootURL = try makeRecoveryRoot()
        let validationGate = RecoveryUnavailableValidationGate()
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default,
            postPromotionValidation: validationGate.validate
        )
        let documentID = DocumentID(rawValue: UUID())
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        return RecoveryUnavailableFixture(
            documentID: documentID,
            model: model,
            store: store,
            validationGate: validationGate
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

@MainActor
private struct RecoveryUnavailableFixture {
    let documentID: DocumentID
    let model: PhonePadAppModel
    let store: FileRecoveryStore
    let validationGate: RecoveryUnavailableValidationGate
}

private final class RecoveryUnavailableValidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail: Bool = true

    func validate(promotedURL _: URL) throws {
        let mustFail = lock.withLock { shouldFail }
        guard mustFail else {
            return
        }
        throw CocoaError(.fileWriteUnknown)
    }

    func repair() {
        lock.withLock {
            shouldFail = false
        }
    }
}

private extension PhonePadAppModel {
    func openRecoveryUnavailableTestFile(_ selectedURL: URL) async -> Bool {
        let document = state.activeTab.document
        return await openDocument(
            selectedURL: selectedURL,
            after: CommittedEditorDocument(
                documentID: document.id,
                text: document.text
            )
        )
    }
}
