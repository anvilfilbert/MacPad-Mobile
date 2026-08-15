import Foundation
import PhonePadCore
import XCTest
@testable import PhonePad

@MainActor
final class PhonePadTabAppModelTests: XCTestCase {
    func testCreateTabProtectsExactCommittedDocumentBeforeChangingActiveTab() async throws {
        let fixture = try makeFixture()
        let sourceDocumentID = fixture.model.state.activeTab.document.id
        fixture.model.editActiveDocument(text: "Current unsaved content")
        let committedDocument = CommittedEditorDocument(
            documentID: sourceDocumentID,
            text: "Current unsaved content"
        )

        let didCreate = await fixture.model.createTab(after: committedDocument)

        XCTAssertTrue(
            didCreate,
            fixture.model.tabTransitionError ?? "Create returned false without an error."
        )
        XCTAssertEqual(fixture.model.state.tabs.count, 2)
        XCTAssertNotEqual(fixture.model.state.activeTab.document.id, sourceDocumentID)
        XCTAssertEqual(
            fixture.model.state.tabs[0].document.recoveryState,
            .protectedUnsaved
        )
        let checkpoint = try await fixture.store.load(documentID: sourceDocumentID)
        XCTAssertEqual(checkpoint?.documentID, sourceDocumentID)
        XCTAssertEqual(checkpoint?.text, "Current unsaved content")
    }

    func testSelectTabProtectsExactCommittedDocumentBeforeSelection() async throws {
        let fixture = try makeTwoTabFixture()
        fixture.model.editActiveDocument(text: "Select after protection")
        let sourceDocument = fixture.model.state.activeTab.document
        let destinationTabID = fixture.model.state.tabs[1].id
        let committedDocument = CommittedEditorDocument(
            documentID: sourceDocument.id,
            text: sourceDocument.text
        )

        let didSelect = await fixture.model.selectTab(
            destinationTabID,
            after: committedDocument
        )

        XCTAssertTrue(
            didSelect,
            fixture.model.tabTransitionError ?? "Selection returned false without an error."
        )
        XCTAssertEqual(fixture.model.state.activeTabID, destinationTabID)
        XCTAssertEqual(
            fixture.model.state.tabs[0].document.recoveryState,
            .protectedUnsaved
        )
        let checkpoint = try await fixture.store.load(
            documentID: sourceDocument.id
        )
        XCTAssertEqual(checkpoint?.text, sourceDocument.text)
    }

    func testCreateFromCleanDocumentDoesNotCreateUnsavedRecovery() async throws {
        let fixture = try makeFixture()
        let sourceDocumentID = fixture.model.state.activeTab.document.id
        let committedDocument = CommittedEditorDocument(
            documentID: sourceDocumentID,
            text: ""
        )

        let didCreate = await fixture.model.createTab(after: committedDocument)

        XCTAssertTrue(didCreate)
        XCTAssertEqual(fixture.model.state.tabs[0].document.recoveryState, .clean)
        XCTAssertFalse(fixture.model.state.tabs[0].document.isUnsaved)
        let checkpoint = try await fixture.store.load(
            documentID: sourceDocumentID
        )
        XCTAssertNil(checkpoint)
    }

    func testCreateTabAcceptsCanonicalizedCommittedLineEndings() async throws {
        let fixture = try makeFixture()
        let documentID = fixture.model.state.activeTab.document.id
        fixture.model.editActiveDocument(text: "First\r\nSecond")

        let didCreate = await fixture.model.createTab(
            after: CommittedEditorDocument(
                documentID: documentID,
                text: "First\r\nSecond"
            )
        )

        XCTAssertTrue(
            didCreate,
            fixture.model.tabTransitionError
                ?? "Canonical committed text was rejected without an error."
        )
        XCTAssertEqual(fixture.model.state.tabs[0].document.text, "First\nSecond")
    }

    func testSelectFromProtectedDocumentRetainsExactVerifiedCheckpoint() async throws {
        let rootURL = try makeRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let sourceDocumentID = documentID(1)
        let editedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: sourceDocumentID,
                tabID: tabID(1)
            ),
            newText: "Already protected",
            editedAt: editedAt,
            recoveryStore: store
        )
        let twoTabs = try createUntitledTab(
            state: protectedState,
            documentID: documentID(2),
            tabID: tabID(2)
        )
        let selectedSource = try selectTab(state: twoTabs, tabID: tabID(1))
        let model = makeModel(state: selectedSource, store: store)
        let checkpointBefore = try await store.load(documentID: sourceDocumentID)

        let didSelect = await model.selectTab(
            tabID(2),
            after: CommittedEditorDocument(
                documentID: sourceDocumentID,
                text: "Already protected"
            )
        )

        XCTAssertTrue(didSelect)
        XCTAssertEqual(model.state.activeTabID, tabID(2))
        let checkpointAfter = try await store.load(documentID: sourceDocumentID)
        XCTAssertEqual(checkpointAfter, checkpointBefore)
        XCTAssertEqual(checkpointAfter?.editedAt, editedAt)
    }

    func testCreateTabRejectsEditorTextThatModelValidationDidNotAccept() async throws {
        let fixture = try makeFixture()
        let initialState = fixture.model.state
        let rejectedText = String(
            repeating: "a",
            count: maximumSupportedTextFileByteCount + 1
        )
        fixture.model.editActiveDocument(text: rejectedText)
        let committedDocument = CommittedEditorDocument(
            documentID: initialState.activeTab.document.id,
            text: rejectedText
        )

        let didCreate = await fixture.model.createTab(after: committedDocument)

        XCTAssertFalse(didCreate)
        XCTAssertEqual(fixture.model.state, initialState)
        XCTAssertNotNil(fixture.model.tabTransitionError)
        let checkpoint = try await fixture.store.load(
            documentID: initialState.activeTab.document.id
        )
        XCTAssertNil(checkpoint)
    }

    func testCheckpointFailureKeepsCurrentTabAndOrderUnchanged() async throws {
        let validationGate = RejectingCheckpointValidation()
        let fixture = try makeFixture(validation: validationGate.validate)
        fixture.model.editActiveDocument(text: "Must remain active")
        let initialState = fixture.model.state
        let committedDocument = CommittedEditorDocument(
            documentID: initialState.activeTab.document.id,
            text: initialState.activeTab.document.text
        )

        let didCreate = await fixture.model.createTab(after: committedDocument)

        XCTAssertFalse(didCreate)
        XCTAssertEqual(fixture.model.state.tabs.map(\.id), initialState.tabs.map(\.id))
        XCTAssertEqual(fixture.model.state.activeTabID, initialState.activeTabID)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.text,
            initialState.activeTab.document.text
        )
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .recoveryUnavailable
        )
        XCTAssertNotNil(fixture.model.tabTransitionError)
    }

    func testTwoQueuedCreatesUsingSameCommitCreateAtMostOneTab() async throws {
        let validationGate = BlockingCheckpointValidation()
        let fixture = try makeFixture(validation: validationGate.validate)
        fixture.model.editActiveDocument(text: "One protected transition")
        let committedDocument = CommittedEditorDocument(
            documentID: fixture.model.state.activeTab.document.id,
            text: fixture.model.state.activeTab.document.text
        )
        let firstCreate = Task {
            await fixture.model.createTab(after: committedDocument)
        }
        await validationGate.waitUntilEntered()
        XCTAssertTrue(fixture.model.editorInteractionDisabled)

        let secondDidCreate = await fixture.model.createTab(
            after: committedDocument
        )
        XCTAssertThrowsError(
            try fixture.model.prepareDocumentSaveAs(
                fileName: "Blocked.txt",
                encoding: .utf8
            )
        )
        await fixture.model.refreshRecoveryItems()
        XCTAssertNotNil(fixture.model.recoveryCatalogError)
        validationGate.resume()
        let firstDidCreate = await firstCreate.value

        XCTAssertTrue(firstDidCreate)
        XCTAssertFalse(secondDidCreate)
        XCTAssertEqual(fixture.model.state.tabs.count, 2)
    }

    func testSelectRejectsEditorChangesWhileCheckpointProtectionIsBlocked() async throws {
        let validationGate = BlockingCheckpointValidation()
        let fixture = try makeTwoTabFixture(validation: validationGate.validate)
        fixture.model.editActiveDocument(text: "Committed before selection")
        let sourceDocument = fixture.model.state.activeTab.document
        let destinationTabID = fixture.model.state.tabs[1].id
        let select = Task {
            await fixture.model.selectTab(
                destinationTabID,
                after: CommittedEditorDocument(
                    documentID: sourceDocument.id,
                    text: sourceDocument.text
                )
            )
        }
        await validationGate.waitUntilEntered()

        XCTAssertTrue(fixture.model.editorInteractionDisabled)
        let didEdit = fixture.model.editDocument(
            documentID: sourceDocument.id,
            text: "New composition during selection"
        )
        XCTAssertFalse(didEdit)
        XCTAssertEqual(fixture.model.activeText, sourceDocument.text)

        validationGate.resume()
        let didSelect = await select.value

        XCTAssertTrue(didSelect)
        XCTAssertEqual(fixture.model.state.activeTabID, destinationTabID)
    }

    func testMoveDrainsPendingCheckpointWithoutRevertingOrder() async throws {
        let fixture = try makeThreeTabFixture()
        let firstTabID = fixture.model.state.tabs[0].id
        let activeDocumentID = fixture.model.state.activeTab.document.id
        fixture.model.editActiveDocument(text: "Protected before reorder")

        let didMove = await fixture.model.moveTab(firstTabID, to: .end)

        XCTAssertTrue(
            didMove,
            fixture.model.tabTransitionError ?? "Move returned false without an error."
        )
        XCTAssertEqual(
            fixture.model.state.tabs.map(\.id),
            [fixture.secondTabID, fixture.thirdTabID, firstTabID]
        )
        XCTAssertEqual(fixture.model.state.activeTabID, fixture.thirdTabID)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        let checkpoint = try await fixture.store.load(
            documentID: activeDocumentID
        )
        XCTAssertEqual(checkpoint?.text, "Protected before reorder")
    }

    func testMoveAllowsActiveEditAndAbortsWithoutReordering() async throws {
        let validationGate = BlockingCheckpointValidation()
        let fixture = try makeThreeTabFixture(
            validation: validationGate.validate
        )
        let initialTabIDs = fixture.model.state.tabs.map(\.id)
        let firstTabID = try XCTUnwrap(initialTabIDs.first)
        fixture.model.editActiveDocument(text: "Before reorder")
        let move = Task {
            await fixture.model.moveTab(firstTabID, to: .end)
        }
        await validationGate.waitUntilEntered()
        XCTAssertFalse(fixture.model.editorInteractionDisabled)

        fixture.model.editActiveDocument(text: "Edit during reorder")
        validationGate.resume()
        let didMove = await move.value

        XCTAssertFalse(didMove)
        XCTAssertEqual(fixture.model.activeText, "Edit during reorder")
        XCTAssertEqual(fixture.model.state.tabs.map(\.id), initialTabIDs)
    }

    func testStaleEditorCallbackCannotMutateNewlySelectedDocument() async throws {
        let fixture = try makeTwoTabFixture()
        let sourceDocument = fixture.model.state.activeTab.document
        let destinationTabID = fixture.model.state.tabs[1].id
        let didSelect = await fixture.model.selectTab(
            destinationTabID,
            after: CommittedEditorDocument(
                documentID: sourceDocument.id,
                text: sourceDocument.text
            )
        )
        XCTAssertTrue(didSelect)
        let selectedState = fixture.model.state

        let didEdit = fixture.model.editDocument(
            documentID: sourceDocument.id,
            text: "Late callback from old editor"
        )

        XCTAssertFalse(didEdit)
        XCTAssertEqual(fixture.model.state, selectedState)
    }

    func testTabTransitionReplaysDeferredPresenterReconciliation() async throws {
        let recoveryRootURL = try makeRecoveryRoot()
        let sourceRootURL = try makeRecoveryRoot()
        let sourceURL = sourceRootURL.appendingPathComponent(
            "Presented.txt",
            isDirectory: false
        )
        try Data("Original\n".utf8).write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        let validationGate = BlockingCheckpointValidation()
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default,
            postPromotionValidation: validationGate.validate
        )
        let model = makeModel(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: tabID(1)
            ),
            store: store
        )
        let initialDocument = model.state.activeTab.document
        let didOpen = await model.openDocument(
            selectedURL: sourceURL,
            after: CommittedEditorDocument(
                documentID: initialDocument.id,
                text: initialDocument.text
            )
        )
        XCTAssertTrue(didOpen)
        let presentedDocumentID = model.state.activeTab.document.id
        model.editActiveDocument(text: "Protected local edit\n")
        let committedDocument = CommittedEditorDocument(
            documentID: presentedDocumentID,
            text: "Protected local edit\n"
        )
        let create = Task {
            await model.createTab(after: committedDocument)
        }
        await validationGate.waitUntilEntered()
        XCTAssertTrue(model.tabTransitionInProgress)
        try Data("External edit\n".utf8).write(to: sourceURL, options: [])

        await model.reconcilePresentedFile(documentID: presentedDocumentID)
        validationGate.resume()
        let didCreate = await create.value
        XCTAssertTrue(didCreate)

        let didDetectConflict = try await waitUntilDocumentConflict(
            model: model,
            documentID: presentedDocumentID,
            conflict: .contentChanged
        )
        XCTAssertTrue(didDetectConflict)
    }

    private func makeFixture() throws -> TabModelFixture {
        try makeFixture(validation: { _ in })
    }

    private func makeFixture(
        validation: @escaping FileRecoveryStore.PostPromotionValidation
    ) throws -> TabModelFixture {
        let rootURL = try makeRecoveryRoot()
        let store = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: validation
        )
        let state = makeInitialPhonePadState(
            documentID: documentID(1),
            tabID: tabID(1)
        )
        return TabModelFixture(
            model: makeModel(state: state, store: store),
            store: store
        )
    }

    private func makeTwoTabFixture() throws -> TabModelFixture {
        try makeTwoTabFixture(validation: { _ in })
    }

    private func makeTwoTabFixture(
        validation: @escaping FileRecoveryStore.PostPromotionValidation
    ) throws -> TabModelFixture {
        let fixture = try makeFixture(validation: validation)
        let secondTabID = tabID(2)
        let stateWithSecondTab = try createUntitledTab(
            state: fixture.model.state,
            documentID: documentID(2),
            tabID: secondTabID
        )
        let state = try selectTab(state: stateWithSecondTab, tabID: tabID(1))
        return TabModelFixture(
            model: makeModel(state: state, store: fixture.store),
            store: fixture.store
        )
    }

    private func makeThreeTabFixture() throws -> ThreeTabModelFixture {
        try makeThreeTabFixture(validation: { _ in })
    }

    private func makeThreeTabFixture(
        validation: @escaping FileRecoveryStore.PostPromotionValidation
    ) throws -> ThreeTabModelFixture {
        let rootURL = try makeRecoveryRoot()
        let store = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: validation
        )
        let secondTabID = tabID(2)
        let thirdTabID = tabID(3)
        let twoTabs = try createUntitledTab(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: tabID(1)
            ),
            documentID: documentID(2),
            tabID: secondTabID
        )
        let threeTabs = try createUntitledTab(
            state: twoTabs,
            documentID: documentID(3),
            tabID: thirdTabID
        )
        return ThreeTabModelFixture(
            model: makeModel(state: threeTabs, store: store),
            store: store,
            secondTabID: secondTabID,
            thirdTabID: thirdTabID
        )
    }

    private func makeModel(
        state: PhonePadState,
        store: FileRecoveryStore
    ) -> PhonePadAppModel {
        PhonePadAppModel(
            state: state,
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
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

    private func documentID(_ value: UInt8) -> DocumentID {
        DocumentID(rawValue: fixtureUUID(value))
    }

    private func tabID(_ value: UInt8) -> TabID {
        TabID(rawValue: fixtureUUID(value + 32))
    }

    private func fixtureUUID(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, value
        ))
    }
}

@MainActor
private func waitUntilDocumentConflict(
    model: PhonePadAppModel,
    documentID: DocumentID,
    conflict: FileConflict
) async throws -> Bool {
    for _ in 0 ..< 100 {
        if model.state.tabs.first(where: {
            $0.document.id == documentID
        })?.document.fileConflict == conflict {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private struct TabModelFixture {
    let model: PhonePadAppModel
    let store: FileRecoveryStore
}

private struct ThreeTabModelFixture {
    let model: PhonePadAppModel
    let store: FileRecoveryStore
    let secondTabID: TabID
    let thirdTabID: TabID
}

private final class RejectingCheckpointValidation: @unchecked Sendable {
    func validate(promotedURL _: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class BlockingCheckpointValidation: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didEnter: Bool = false
    private var shouldBlock: Bool = true
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func validate(promotedURL _: URL) throws {
        let blockedEntry: (
            shouldBlock: Bool,
            continuation: CheckedContinuation<Void, Never>?
        ) = lock.withLock {
            guard shouldBlock else {
                return (false, nil)
            }
            shouldBlock = false
            didEnter = true
            let continuation = entryContinuation
            entryContinuation = nil
            return (true, continuation)
        }
        guard blockedEntry.shouldBlock else {
            return
        }
        blockedEntry.continuation?.resume()
        release.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if didEnter {
                    return true
                }
                precondition(entryContinuation == nil)
                entryContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        release.signal()
    }
}
