import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadAppModelTests: XCTestCase {
    func testRecoveryCatalogDoesNotRestorePreservedWorkAtLaunch() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        )
        let editedAt = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Untitled 4",
                text: "Private preserved content",
                editedAt: editedAt
            )
        )
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let model = PhonePadAppModel(state: initialState, recoveryStore: store)

        await model.refreshRecoveryItems()

        XCTAssertEqual(model.state, initialState)
        XCTAssertEqual(model.state.tabs.count, 1)
        XCTAssertEqual(model.state.activeTab.document.title, "Untitled")
        XCTAssertEqual(model.recoveryItems.count, 1)
        XCTAssertEqual(model.recoveryItems[0].documentID, preservedDocumentID)
        XCTAssertEqual(model.recoveryItems[0].title, "Untitled 4")
        XCTAssertEqual(model.recoveryItems[0].lastEdited, .available(editedAt))
        XCTAssertEqual(model.recoveryItems[0].status, .recoverable)
    }

    func testRecoveryCatalogFailureClearsPreviouslyLoadedItems() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: DocumentID(rawValue: UUID()),
                title: "Preserved",
                text: "Private content",
                editedAt: Date(timeIntervalSince1970: 1_760_000_000)
            )
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()
        XCTAssertEqual(model.recoveryItems.count, 1)
        try FileManager.default.removeItem(at: rootURL)
        try Data("not a directory".utf8).write(to: rootURL)

        await model.refreshRecoveryItems()

        XCTAssertTrue(model.recoveryItems.isEmpty)
        XCTAssertNotNil(model.recoveryCatalogError)
    }

    func testRecoverCreatesNormalUnsavedTabAndRetainsCheckpoint() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        )
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: preservedDocumentID,
            title: "Untitled 2",
            text: "Recovered content",
            editedAt: Date(timeIntervalSince1970: 1_760_000_100)
        )
        try await store.save(envelope: envelope)
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()

        let didRecover = await model.recoverRecovery(documentID: preservedDocumentID)

        XCTAssertTrue(didRecover)
        XCTAssertEqual(model.state.tabs.count, 2)
        XCTAssertEqual(model.state.activeTab.document.id, preservedDocumentID)
        XCTAssertEqual(model.state.activeTab.document.text, "Recovered content")
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .protectedUnsaved)
        XCTAssertTrue(model.recoveryItems.isEmpty)
        let retainedEnvelope = try await store.load(documentID: preservedDocumentID)
        XCTAssertEqual(retainedEnvelope, envelope)
    }

    func testRecoverWaitsForCurrentCheckpointWithoutLosingEitherTab() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let currentDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        )
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        )
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Preserved",
                text: "Preserved content",
                editedAt: Date(timeIntervalSince1970: 1_760_000_300)
            )
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: currentDocumentID,
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()
        model.editActiveDocument(text: "Current unsaved content")

        let didRecover = await model.recoverRecovery(documentID: preservedDocumentID)

        XCTAssertTrue(didRecover)
        XCTAssertEqual(model.state.tabs.count, 2)
        XCTAssertEqual(model.state.tabs[0].document.id, currentDocumentID)
        XCTAssertEqual(model.state.tabs[0].document.text, "Current unsaved content")
        XCTAssertEqual(
            model.state.tabs[0].document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertEqual(model.state.activeTab.document.id, preservedDocumentID)
        let currentEnvelope = try await store.load(documentID: currentDocumentID)
        XCTAssertEqual(currentEnvelope?.text, "Current unsaved content")
    }

    func testDiscardRecoveryRemovesCatalogItemOnlyAfterTerminalStoreTransition() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        )
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Untitled 3",
                text: "Discard me",
                editedAt: Date(timeIntervalSince1970: 1_760_000_200)
            )
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()

        let didDiscard = await model.discardRecovery(documentID: preservedDocumentID)

        XCTAssertTrue(didDiscard)
        XCTAssertTrue(model.recoveryItems.isEmpty)
        let discardedEnvelope = try await store.load(documentID: preservedDocumentID)
        XCTAssertNil(discardedEnvelope)
    }

    func testRapidEditsCheckpointLatestGenerationWithoutSerializingEveryEdit() async throws {
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

        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        let tabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(documentID: documentID, tabID: tabID),
            recoveryStore: store,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )

        for generation in 1 ... 160 {
            model.editActiveDocument(text: "Generation \(generation)")
        }

        try await Task.sleep(for: .milliseconds(250))

        let envelope = try await store.load(documentID: documentID)
        XCTAssertEqual(envelope?.text, "Generation 160")
        XCTAssertEqual(model.activeText, "Generation 160")
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .protectedUnsaved)
    }

    private func makeModelRecoveryRoot() throws -> URL {
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
