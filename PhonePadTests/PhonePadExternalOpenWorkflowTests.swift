import Foundation
import PhonePadCore
import XCTest
@testable import PhonePad

@MainActor
final class PhonePadExternalOpenWorkflowTests: XCTestCase {
    func testBoundOpenDiscardsRecoveryBeforeReturningCommittedState() async throws {
        let fixture = try await makeExternalOpenWorkflowFixture(
            recoveryText: "Discarded recovery edits\n"
        )
        let prepared = try makePreparedBoundOpen(
            state: fixture.initialState,
            documentID: externalOpenDocumentID(11),
            tabID: externalOpenTabID(11)
        )

        let result = try await discardRecoveryAndCommitPreparedBoundDocumentOpen(
            state: fixture.initialState,
            recoveryDocumentID: fixture.recoveryEnvelope.documentID,
            preparedOpen: prepared,
            recoveryStore: fixture.store
        )

        XCTAssertEqual(
            result.discardedRecoveryDocumentID,
            fixture.recoveryEnvelope.documentID
        )
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.state.tabs.count, 1)
        XCTAssertEqual(result.state.activeTab.document.id, externalOpenDocumentID(11))
        XCTAssertNotNil(result.state.activeTab.document.fileBinding)
        XCTAssertEqual(fixture.initialState.activeTab.document.title, "Untitled")
        let remainingRecovery = try await fixture.store.load(
            documentID: fixture.recoveryEnvelope.documentID
        )
        XCTAssertNil(remainingRecovery)
    }

    func testDetachedOpenDiscardsRecoveryBeforeReturningExactTransition() async throws {
        let fixture = try await makeExternalOpenWorkflowFixture(
            recoveryText: "Discarded recovery edits\n"
        )
        let prepared = try makePreparedDetachedOpen(
            state: fixture.initialState,
            documentID: externalOpenDocumentID(12),
            tabID: externalOpenTabID(12)
        )

        let result = try await discardRecoveryAndCommitPreparedDetachedDocumentOpen(
            state: fixture.initialState,
            recoveryDocumentID: fixture.recoveryEnvelope.documentID,
            preparedOpen: prepared,
            recoveryStore: fixture.store
        )

        XCTAssertEqual(result.transition, prepared.transition)
        XCTAssertEqual(
            result.discardedRecoveryDocumentID,
            fixture.recoveryEnvelope.documentID
        )
        XCTAssertNil(result.notice)
        XCTAssertNil(result.transition.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            result.transition.state.activeTab.document.recoveryState,
            .checkpointPending
        )
        XCTAssertEqual(fixture.initialState.activeTab.document.title, "Untitled")
        let remainingRecovery = try await fixture.store.load(
            documentID: fixture.recoveryEnvelope.documentID
        )
        XCTAssertNil(remainingRecovery)
    }

    func testResidualCleanupStillReturnsDetachedTransitionWithTypedNotice() async throws {
        let rootURL = try makeExternalOpenRecoveryRoot()
        let recoveryDocumentID = externalOpenDocumentID(3)
        let canonicalURL = externalOpenCanonicalURL(
            rootURL: rootURL,
            documentID: recoveryDocumentID
        )
        let store = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: { _ in },
            terminalArtifactRemoval: { fileManager, url in
                guard url.standardizedFileURL
                        != canonicalURL.standardizedFileURL else {
                    throw ExternalOpenWorkflowFixtureError.terminalMarkerRetained
                }
                try fileManager.removeItem(at: url)
            }
        )
        let recoveryEnvelope = makeExternalOpenRecoveryEnvelope(
            documentID: recoveryDocumentID,
            text: "Removed before residual cleanup\n"
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: store
        )
        let initialState = makeExternalOpenInitialState()
        let prepared = try makePreparedDetachedOpen(
            state: initialState,
            documentID: externalOpenDocumentID(13),
            tabID: externalOpenTabID(13)
        )

        let result = try await discardRecoveryAndCommitPreparedDetachedDocumentOpen(
            state: initialState,
            recoveryDocumentID: recoveryDocumentID,
            preparedOpen: prepared,
            recoveryStore: store
        )

        XCTAssertEqual(result.transition, prepared.transition)
        XCTAssertEqual(result.notice, .residualRecoveryCleanupPending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        let markerData = try Data(contentsOf: canonicalURL)
        XCTAssertFalse(markerData.contains(Data("Removed before".utf8)))
        let remainingRecovery = try await store.load(
            documentID: recoveryDocumentID
        )
        XCTAssertNil(remainingRecovery)
    }

    func testCleanupFailureReturnsTypedErrorAndPreservesBoundCallerStateAndRecovery() async throws {
        let fixture = try await makeExternalOpenWorkflowFixture(
            recoveryText: "Keep after cleanup failure\n"
        )
        let transactionURL = externalOpenTransactionURL(
            rootURL: fixture.rootURL,
            documentID: fixture.recoveryEnvelope.documentID
        )
        try FileManager.default.createDirectory(
            at: transactionURL,
            withIntermediateDirectories: false
        )
        let prepared = try makePreparedBoundOpen(
            state: fixture.initialState,
            documentID: externalOpenDocumentID(14),
            tabID: externalOpenTabID(14)
        )

        do {
            _ = try await discardRecoveryAndCommitPreparedBoundDocumentOpen(
                state: fixture.initialState,
                recoveryDocumentID: fixture.recoveryEnvelope.documentID,
                preparedOpen: prepared,
                recoveryStore: fixture.store
            )
            XCTFail("Expected terminal recovery cleanup to fail.")
        } catch let error as ExternalOpenRecoveryWorkflowError {
            guard case let .recoveryCleanupFailed(documentID, failure) = error else {
                return XCTFail("Unexpected workflow error: \(error)")
            }
            XCTAssertEqual(documentID, fixture.recoveryEnvelope.documentID)
            guard case .fileRecoveryStore = failure else {
                return XCTFail("Expected typed FileRecoveryStore failure.")
            }
            XCTAssertTrue(
                error.localizedDescription.contains("Retry Open")
            )
        }

        XCTAssertEqual(fixture.initialState.activeTab.document.title, "Untitled")
        try FileManager.default.removeItem(at: transactionURL)
        let retainedRecovery = try await fixture.store.load(
            documentID: fixture.recoveryEnvelope.documentID
        )
        XCTAssertEqual(retainedRecovery, fixture.recoveryEnvelope)
    }

    func testStaleBoundPreparationFailsBeforeDiscardAndPreservesRecovery() async throws {
        let fixture = try await makeExternalOpenWorkflowFixture(
            recoveryText: "Keep after stale bound open\n"
        )
        let prepared = try makePreparedBoundOpen(
            state: fixture.initialState,
            documentID: externalOpenDocumentID(15),
            tabID: externalOpenTabID(15)
        )
        let changedState = try createUntitledTab(
            state: fixture.initialState,
            documentID: externalOpenDocumentID(16),
            tabID: externalOpenTabID(16)
        )

        do {
            _ = try await discardRecoveryAndCommitPreparedBoundDocumentOpen(
                state: changedState,
                recoveryDocumentID: fixture.recoveryEnvelope.documentID,
                preparedOpen: prepared,
                recoveryStore: fixture.store
            )
            XCTFail("Expected stale bound File Open preparation.")
        } catch {
            XCTAssertEqual(
                error as? PhonePadStateError,
                .workspaceChangedSinceFileOpenPreparation(
                    externalOpenDocumentID(15)
                )
            )
        }

        XCTAssertEqual(changedState.tabs.count, 2)
        let retainedRecovery = try await fixture.store.load(
            documentID: fixture.recoveryEnvelope.documentID
        )
        XCTAssertEqual(retainedRecovery, fixture.recoveryEnvelope)
    }

    func testStaleDetachedPreparationFailsBeforeDiscardAndPreservesRecovery() async throws {
        let fixture = try await makeExternalOpenWorkflowFixture(
            recoveryText: "Keep after stale detached open\n"
        )
        let prepared = try makePreparedDetachedOpen(
            state: fixture.initialState,
            documentID: externalOpenDocumentID(17),
            tabID: externalOpenTabID(17)
        )
        let changedState = try createUntitledTab(
            state: fixture.initialState,
            documentID: externalOpenDocumentID(18),
            tabID: externalOpenTabID(18)
        )

        do {
            _ = try await discardRecoveryAndCommitPreparedDetachedDocumentOpen(
                state: changedState,
                recoveryDocumentID: fixture.recoveryEnvelope.documentID,
                preparedOpen: prepared,
                recoveryStore: fixture.store
            )
            XCTFail("Expected stale detached File Open preparation.")
        } catch {
            XCTAssertEqual(
                error as? PhonePadStateError,
                .workspaceChangedSinceFileOpenPreparation(
                    externalOpenDocumentID(17)
                )
            )
        }

        XCTAssertEqual(changedState.tabs.count, 2)
        let retainedRecovery = try await fixture.store.load(
            documentID: fixture.recoveryEnvelope.documentID
        )
        XCTAssertEqual(retainedRecovery, fixture.recoveryEnvelope)
    }

    private func makeExternalOpenWorkflowFixture(
        recoveryText: String
    ) async throws -> ExternalOpenWorkflowFixture {
        let rootURL = try makeExternalOpenRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let recoveryEnvelope = makeExternalOpenRecoveryEnvelope(
            documentID: externalOpenDocumentID(2),
            text: recoveryText
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: store
        )
        return ExternalOpenWorkflowFixture(
            rootURL: rootURL,
            store: store,
            initialState: makeExternalOpenInitialState(),
            recoveryEnvelope: recoveryEnvelope
        )
    }

    private func makeExternalOpenRecoveryRoot() throws -> URL {
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

private struct ExternalOpenWorkflowFixture {
    let rootURL: URL
    let store: FileRecoveryStore
    let initialState: PhonePadState
    let recoveryEnvelope: RecoveryEnvelope
}

private enum ExternalOpenWorkflowFixtureError: Error {
    case expectedPreparedBoundOpen
    case expectedPreparedDetachedOpen
    case terminalMarkerRetained
}

private func makeExternalOpenInitialState() -> PhonePadState {
    makeInitialPhonePadState(
        documentID: externalOpenDocumentID(1),
        tabID: externalOpenTabID(1)
    )
}

private func makePreparedBoundOpen(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID
) throws -> PreparedBoundDocumentOpen {
    let observation = try externalOpenObservation(
        path: "/private/provider/External.txt",
        identity: externalOpenIdentity(1),
        text: "Opened external File\n"
    )
    let preparation = prepareBoundDocumentOpen(
        state: state,
        documentID: documentID,
        tabID: tabID,
        text: "Opened external File\n",
        observation: observation
    )
    guard case let .prepared(prepared) = preparation else {
        throw ExternalOpenWorkflowFixtureError.expectedPreparedBoundOpen
    }
    return prepared
}

private func makePreparedDetachedOpen(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID
) throws -> PreparedDetachedDocumentOpen {
    let observation = try externalOpenObservation(
        path: "/private/provider/Read Only.txt",
        identity: externalOpenIdentity(2),
        text: "Opened detached File\n"
    )
    let snapshot = DetachedFileSnapshot(
        candidate: FileOpenCandidate(
            locatorURL: observation.binding.locatorURL,
            identity: observation.binding.identity,
            digest: observation.binding.digest,
            providerConflictVersions: observation.providerConflictVersions
        ),
        displayName: observation.binding.displayName,
        text: "Opened detached File\n",
        recoveryFileReference: makeRecoveryFileReference(
            fileBinding: observation.binding
        )
    )
    let preparation = try prepareDetachedDocumentOpen(
        state: state,
        documentID: documentID,
        tabID: tabID,
        snapshot: snapshot,
        editedAt: Date(timeIntervalSince1970: 1_800_000_200)
    )
    guard case let .prepared(prepared) = preparation else {
        throw ExternalOpenWorkflowFixtureError.expectedPreparedDetachedOpen
    }
    return prepared
}

private func externalOpenObservation(
    path: String,
    identity: FileIdentity?,
    text: String
) throws -> ObservedBoundFile {
    let encodedFile = try encodeNewTextFile(text: text)
    return ObservedBoundFile(
        binding: FileBinding(
            locatorURL: URL(fileURLWithPath: path),
            bookmark: try FileBookmark(data: Data([0xA2, 0x01])),
            identity: identity,
            displayName: try ValidatedFileName(
                validating: URL(fileURLWithPath: path).lastPathComponent
            ),
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        ),
        providerConflictVersions: .none
    )
}

private func makeExternalOpenRecoveryEnvelope(
    documentID: DocumentID,
    text: String
) -> RecoveryEnvelope {
    RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: documentID,
        title: "Recovered.txt",
        text: text,
        editedAt: Date(timeIntervalSince1970: 1_800_000_150)
    )
}

private func externalOpenCanonicalURL(
    rootURL: URL,
    documentID: DocumentID
) -> URL {
    rootURL.appendingPathComponent(
        documentID.rawValue.uuidString.lowercased() + ".recovery.json",
        isDirectory: false
    )
}

private func externalOpenTransactionURL(
    rootURL: URL,
    documentID: DocumentID
) -> URL {
    rootURL.appendingPathComponent(
        ".\(documentID.rawValue.uuidString.lowercased()).recovery.transaction",
        isDirectory: false
    )
}

private func externalOpenDocumentID(_ suffix: UInt8) -> DocumentID {
    DocumentID(
        rawValue: UUID(
            uuid: (0xC0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}

private func externalOpenTabID(_ suffix: UInt8) -> TabID {
    TabID(
        rawValue: UUID(
            uuid: (0xC1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}

private func externalOpenIdentity(_ suffix: UInt8) -> FileIdentity {
    FileIdentity(
        volumeUUID: UUID(
            uuid: (0xC2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
        ),
        documentIdentifier: Int(suffix)
    )
}
