import Foundation
import PhonePadCore
import XCTest
@testable import PhonePad

final class PhonePadTabCloseWorkflowTests: XCTestCase {
    func testDiscardClosesPreparedUnsavedTabAfterTerminalRecoveryCompletes() async throws {
        let rootURL = try makeTabCloseRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let fixture = try await makeProtectedTabCloseFixture(
            store: store,
            text: "Discarded User Content"
        )

        let result = try await discardAndClosePreparedUnsavedTab(
            state: fixture.state,
            preparedClose: fixture.preparedClose,
            replacementDocumentID: tabCloseWorkflowDocumentID(2),
            replacementTabID: tabCloseWorkflowTabID(2),
            recoveryStore: store
        )

        XCTAssertEqual(result.closedDocumentID, fixture.documentID)
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.state.tabs.count, 1)
        XCTAssertEqual(
            result.state.activeTab.document.id,
            tabCloseWorkflowDocumentID(2)
        )
        XCTAssertEqual(result.state.activeTab.id, tabCloseWorkflowTabID(2))
        XCTAssertEqual(result.state.activeTab.document.title, "Untitled")
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        let remainingRecovery = try await store.load(
            documentID: fixture.documentID
        )
        XCTAssertNil(remainingRecovery)
    }

    func testResidualMarkerRemovalStillClosesWithoutRecoverableUserContent() async throws {
        let rootURL = try makeTabCloseRecoveryRoot()
        let documentID = tabCloseWorkflowDocumentID(1)
        let canonicalURL = tabCloseCanonicalURL(
            rootURL: rootURL,
            documentID: documentID
        )
        let store = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: { _ in },
            terminalArtifactRemoval: { fileManager, url in
                guard url.standardizedFileURL != canonicalURL.standardizedFileURL else {
                    throw TabCloseWorkflowFixtureError.terminalMarkerRetained
                }
                try fileManager.removeItem(at: url)
            }
        )
        let fixture = try await makeProtectedTabCloseFixture(
            store: store,
            text: "User Content removed before residual cleanup"
        )

        let result = try await discardAndClosePreparedUnsavedTab(
            state: fixture.state,
            preparedClose: fixture.preparedClose,
            replacementDocumentID: tabCloseWorkflowDocumentID(2),
            replacementTabID: tabCloseWorkflowTabID(2),
            recoveryStore: store
        )

        XCTAssertEqual(result.closedDocumentID, fixture.documentID)
        XCTAssertEqual(result.notice, .residualRecoveryCleanupPending)
        XCTAssertEqual(
            result.state.activeTab.document.id,
            tabCloseWorkflowDocumentID(2)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        let markerData = try Data(contentsOf: canonicalURL)
        XCTAssertTrue(markerData.contains(Data("phonepad.recovery.cleanup".utf8)))
        XCTAssertFalse(markerData.contains(Data("User Content".utf8)))
        let recoveryItems = try await store.recoveryItems()
        let remainingRecovery = try await store.load(
            documentID: fixture.documentID
        )
        XCTAssertTrue(recoveryItems.isEmpty)
        XCTAssertNil(remainingRecovery)
    }

    func testPreMarkerFailureKeepsRecoveryAndSamePreparedCloseCanRetry() async throws {
        let rootURL = try makeTabCloseRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let fixture = try await makeProtectedTabCloseFixture(
            store: store,
            text: "Retry this discard"
        )
        let canonicalURL = tabCloseCanonicalURL(
            rootURL: rootURL,
            documentID: fixture.documentID
        )
        let canonicalData = try Data(contentsOf: canonicalURL)
        let transactionURL = tabCloseTransactionURL(
            rootURL: rootURL,
            documentID: fixture.documentID
        )
        try FileManager.default.createDirectory(
            at: transactionURL,
            withIntermediateDirectories: false
        )

        do {
            _ = try await discardAndClosePreparedUnsavedTab(
                state: fixture.state,
                preparedClose: fixture.preparedClose,
                replacementDocumentID: tabCloseWorkflowDocumentID(2),
                replacementTabID: tabCloseWorkflowTabID(2),
                recoveryStore: store
            )
            XCTFail("Expected recovery cleanup failure before marker verification.")
        } catch let error as TabCloseWorkflowError {
            guard case let .recoveryCleanupFailed(documentID, failure) = error else {
                return XCTFail("Unexpected workflow error: \(error)")
            }
            XCTAssertEqual(documentID, fixture.documentID)
            guard case .fileRecoveryStore = failure else {
                return XCTFail("Expected a typed FileRecoveryStore cleanup failure.")
            }
        }

        XCTAssertEqual(fixture.state.activeTab.document.text, "Retry this discard")
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        try FileManager.default.removeItem(at: transactionURL)
        let retainedEnvelope = try await store.load(documentID: fixture.documentID)
        XCTAssertEqual(retainedEnvelope?.text, "Retry this discard")

        let retryResult = try await discardAndClosePreparedUnsavedTab(
            state: fixture.state,
            preparedClose: fixture.preparedClose,
            replacementDocumentID: tabCloseWorkflowDocumentID(2),
            replacementTabID: tabCloseWorkflowTabID(2),
            recoveryStore: store
        )

        XCTAssertEqual(retryResult.closedDocumentID, fixture.documentID)
        XCTAssertNil(retryResult.notice)
        let remainingRecovery = try await store.load(
            documentID: fixture.documentID
        )
        XCTAssertNil(remainingRecovery)
    }

    func testStalePreparedCloseFailsBeforeDiscardAndPreservesLatestRecovery() async throws {
        let rootURL = try makeTabCloseRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let fixture = try await makeProtectedTabCloseFixture(
            store: store,
            text: "Prepared text"
        )
        let latestState = try await editActiveDocumentAndCheckpoint(
            state: fixture.state,
            newText: "Newer protected text",
            editedAt: Date(timeIntervalSince1970: 1_787_100_100),
            recoveryStore: store
        )

        do {
            _ = try await discardAndClosePreparedUnsavedTab(
                state: latestState,
                preparedClose: fixture.preparedClose,
                replacementDocumentID: tabCloseWorkflowDocumentID(2),
                replacementTabID: tabCloseWorkflowTabID(2),
                recoveryStore: store
            )
            XCTFail("Expected stale prepared close to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? PhonePadStateError,
                .tabChangedSinceClosePreparation(fixture.tabID)
            )
        }

        XCTAssertEqual(latestState.activeTab.document.text, "Newer protected text")
        let retainedEnvelope = try await store.load(documentID: fixture.documentID)
        XCTAssertEqual(retainedEnvelope?.text, "Newer protected text")
    }

    func testInvalidFinalReplacementFailsBeforeDiscardAndPreservesRecovery() async throws {
        let rootURL = try makeTabCloseRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let fixture = try await makeProtectedTabCloseFixture(
            store: store,
            text: "Keep recovery when replacement is invalid"
        )

        do {
            _ = try await discardAndClosePreparedUnsavedTab(
                state: fixture.state,
                preparedClose: fixture.preparedClose,
                replacementDocumentID: tabCloseWorkflowDocumentID(2),
                replacementTabID: fixture.tabID,
                recoveryStore: store
            )
            XCTFail("Expected reused replacement Tab identifier to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateTabID(fixture.tabID)
            )
        }

        let retainedEnvelope = try await store.load(documentID: fixture.documentID)
        XCTAssertEqual(
            retainedEnvelope?.text,
            "Keep recovery when replacement is invalid"
        )
    }

    func testMissingPreparedTargetFailsBeforeDiscardAndPreservesRecovery() async throws {
        let rootURL = try makeTabCloseRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let fixture = try await makeProtectedTabCloseFixture(
            store: store,
            text: "Keep recovery for missing target"
        )
        let stateWithoutPreparedTab = makeInitialPhonePadState(
            documentID: tabCloseWorkflowDocumentID(3),
            tabID: tabCloseWorkflowTabID(3)
        )

        do {
            _ = try await discardAndClosePreparedUnsavedTab(
                state: stateWithoutPreparedTab,
                preparedClose: fixture.preparedClose,
                replacementDocumentID: tabCloseWorkflowDocumentID(4),
                replacementTabID: tabCloseWorkflowTabID(4),
                recoveryStore: store
            )
            XCTFail("Expected missing prepared Tab to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? PhonePadStateError,
                .tabMissing(fixture.tabID)
            )
        }

        let retainedEnvelope = try await store.load(documentID: fixture.documentID)
        XCTAssertEqual(retainedEnvelope?.text, "Keep recovery for missing target")
    }

    func testReusedReplacementDocumentFailsBeforeDiscardAndPreservesRecovery() async throws {
        let rootURL = try makeTabCloseRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let fixture = try await makeProtectedTabCloseFixture(
            store: store,
            text: "Keep recovery for invalid replacement Document"
        )

        do {
            _ = try await discardAndClosePreparedUnsavedTab(
                state: fixture.state,
                preparedClose: fixture.preparedClose,
                replacementDocumentID: fixture.documentID,
                replacementTabID: tabCloseWorkflowTabID(2),
                recoveryStore: store
            )
            XCTFail("Expected reused replacement Document identifier to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateDocumentID(fixture.documentID)
            )
        }

        let retainedEnvelope = try await store.load(documentID: fixture.documentID)
        XCTAssertEqual(
            retainedEnvelope?.text,
            "Keep recovery for invalid replacement Document"
        )
    }

    private func makeTabCloseRecoveryRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                try FileManager.default.removeItem(at: rootURL)
            }
        }
        return rootURL
    }
}

private struct ProtectedTabCloseFixture {
    let state: PhonePadState
    let preparedClose: PreparedUnsavedTabClose
    let documentID: DocumentID
    let tabID: TabID
}

private enum TabCloseWorkflowFixtureError: Error {
    case expectedUnsavedClose
    case terminalMarkerRetained
}

private func makeProtectedTabCloseFixture(
    store: FileRecoveryStore,
    text: String
) async throws -> ProtectedTabCloseFixture {
    let documentID = tabCloseWorkflowDocumentID(1)
    let tabID = tabCloseWorkflowTabID(1)
    let state = try await editActiveDocumentAndCheckpoint(
        state: makeInitialPhonePadState(
            documentID: documentID,
            tabID: tabID
        ),
        newText: text,
        editedAt: Date(timeIntervalSince1970: 1_787_100_000),
        recoveryStore: store
    )
    let requirement = try prepareTabClose(state: state, tabID: tabID)
    guard case let .unsaved(preparedClose) = requirement else {
        throw TabCloseWorkflowFixtureError.expectedUnsavedClose
    }
    return ProtectedTabCloseFixture(
        state: state,
        preparedClose: preparedClose,
        documentID: documentID,
        tabID: tabID
    )
}

private func tabCloseCanonicalURL(
    rootURL: URL,
    documentID: DocumentID
) -> URL {
    rootURL.appendingPathComponent(
        documentID.rawValue.uuidString.lowercased() + ".recovery.json",
        isDirectory: false
    )
}

private func tabCloseTransactionURL(
    rootURL: URL,
    documentID: DocumentID
) -> URL {
    rootURL.appendingPathComponent(
        ".\(documentID.rawValue.uuidString.lowercased()).recovery.transaction",
        isDirectory: false
    )
}

private func tabCloseWorkflowDocumentID(_ suffix: UInt8) -> DocumentID {
    DocumentID(
        rawValue: UUID(
            uuid: (0xB0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}

private func tabCloseWorkflowTabID(_ suffix: UInt8) -> TabID {
    TabID(
        rawValue: UUID(
            uuid: (0xB1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}
