import Foundation
import XCTest
@testable import PhonePadCore

final class PhonePadFileOpenCoreTests: XCTestCase {
    func testRecoveryCollisionMatchesSourceClaimByStableIdentity() throws {
        let candidate = try makeOpenCandidate(
            path: "/private/provider/Moved Plan.txt",
            identity: openIdentity(1),
            text: "Current File\n"
        )
        let claim = ResolvedRecoveryFileClaim(
            documentID: openDocumentID(1),
            kind: .sourceFile,
            locatorURL: URL(fileURLWithPath: "/private/provider/Plan.txt"),
            identity: openIdentity(1)
        )

        let collision = recoveryFileOpenCollision(
            candidate: candidate,
            claims: [claim]
        )

        XCTAssertEqual(
            collision,
            .item(
                RecoveryFileOpenMatch(
                    documentID: openDocumentID(1),
                    kinds: [.sourceFile]
                )
            )
        )
    }

    func testRecoveryCollisionMatchesSameLocatorAfterStableIdentityReplacement() throws {
        let candidate = try makeOpenCandidate(
            path: "/private/provider/Plan.txt",
            identity: openIdentity(2),
            text: "Replacement File\n"
        )
        let claim = ResolvedRecoveryFileClaim(
            documentID: openDocumentID(2),
            kind: .sourceFile,
            locatorURL: URL(fileURLWithPath: "/private/provider/Plan.txt"),
            identity: openIdentity(1)
        )

        let collision = recoveryFileOpenCollision(
            candidate: candidate,
            claims: [claim]
        )

        XCTAssertEqual(
            collision,
            .item(
                RecoveryFileOpenMatch(
                    documentID: openDocumentID(2),
                    kinds: [.sourceFile]
                )
            )
        )
    }

    func testRecoveryCollisionDeduplicatesKindsForOneRecoveryItem() throws {
        let candidate = try makeOpenCandidate(
            path: "/private/provider/Plan.txt",
            identity: openIdentity(1),
            text: "Current File\n"
        )
        let claims = [
            ResolvedRecoveryFileClaim(
                documentID: openDocumentID(3),
                kind: .pendingSaveAsDestination,
                locatorURL: candidate.locatorURL,
                identity: nil
            ),
            ResolvedRecoveryFileClaim(
                documentID: openDocumentID(3),
                kind: .sourceFile,
                locatorURL: candidate.locatorURL,
                identity: openIdentity(1)
            ),
        ]

        let collision = recoveryFileOpenCollision(
            candidate: candidate,
            claims: claims
        )

        XCTAssertEqual(
            collision,
            .item(
                RecoveryFileOpenMatch(
                    documentID: openDocumentID(3),
                    kinds: [.sourceFile, .pendingSaveAsDestination]
                )
            )
        )
    }

    func testRecoveryCollisionReportsAmbiguousItemsInDeterministicOrder() throws {
        let candidate = try makeOpenCandidate(
            path: "/private/provider/Plan.txt",
            identity: openIdentity(1),
            text: "Current File\n"
        )
        let claims = [
            ResolvedRecoveryFileClaim(
                documentID: openDocumentID(5),
                kind: .pendingSaveAsDestination,
                locatorURL: candidate.locatorURL,
                identity: nil
            ),
            ResolvedRecoveryFileClaim(
                documentID: openDocumentID(4),
                kind: .sourceFile,
                locatorURL: URL(fileURLWithPath: "/private/provider/Moved.txt"),
                identity: openIdentity(1)
            ),
        ]

        let collision = recoveryFileOpenCollision(
            candidate: candidate,
            claims: claims
        )

        XCTAssertEqual(
            collision,
            .ambiguous([openDocumentID(4), openDocumentID(5)])
        )
    }

    func testRecoveryCollisionReturnsNoneForUnrelatedClaims() throws {
        let candidate = try makeOpenCandidate(
            path: "/private/provider/Plan.txt",
            identity: openIdentity(1),
            text: "Current File\n"
        )
        let claim = ResolvedRecoveryFileClaim(
            documentID: openDocumentID(6),
            kind: .sourceFile,
            locatorURL: URL(fileURLWithPath: "/private/provider/Other.txt"),
            identity: openIdentity(2)
        )

        XCTAssertEqual(
            recoveryFileOpenCollision(candidate: candidate, claims: [claim]),
            .none
        )
    }

    func testPreparedBoundOpenReplacesPristineUntitledOnlyWhenCommitted() throws {
        let initialState = makeInitialPhonePadState(
            documentID: openDocumentID(10),
            tabID: openTabID(10)
        )
        let observation = try makeOpenObservation(
            path: "/private/provider/Plan.txt",
            identity: openIdentity(10),
            text: "Opened File\n"
        )

        let preparation = prepareBoundDocumentOpen(
            state: initialState,
            documentID: openDocumentID(11),
            tabID: openTabID(11),
            text: "Opened File\n",
            observation: observation
        )

        let prepared = try requirePreparedBoundOpen(preparation)
        XCTAssertEqual(prepared.expectedState, initialState)
        XCTAssertEqual(initialState.tabs.count, 1)
        XCTAssertEqual(initialState.activeTab.document.title, "Untitled")

        let openedState = try commitPreparedBoundDocumentOpen(
            state: initialState,
            prepared: prepared
        )

        XCTAssertEqual(openedState.tabs.count, 1)
        XCTAssertEqual(openedState.activeTabID, openTabID(11))
        XCTAssertEqual(openedState.activeTab.document.id, openDocumentID(11))
        XCTAssertEqual(openedState.activeTab.document.title, "Plan.txt")
        XCTAssertEqual(openedState.activeTab.document.text, "Opened File\n")
        XCTAssertEqual(openedState.activeTab.document.fileBinding, observation.binding)
        XCTAssertFalse(openedState.activeTab.document.isUnsaved)
        XCTAssertEqual(openedState.activeTab.document.recoveryState, .clean)
    }

    func testPreparedBoundOpenRejectsChangedWorkspace() throws {
        let initialState = makeInitialPhonePadState(
            documentID: openDocumentID(12),
            tabID: openTabID(12)
        )
        let observation = try makeOpenObservation(
            path: "/private/provider/Plan.txt",
            identity: openIdentity(12),
            text: "Opened File\n"
        )
        let prepared = try requirePreparedBoundOpen(
            prepareBoundDocumentOpen(
                state: initialState,
                documentID: openDocumentID(13),
                tabID: openTabID(13),
                text: "Opened File\n",
                observation: observation
            )
        )
        let changedState = try createUntitledTab(
            state: initialState,
            documentID: openDocumentID(14),
            tabID: openTabID(14)
        )

        XCTAssertThrowsError(
            try commitPreparedBoundDocumentOpen(
                state: changedState,
                prepared: prepared
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .workspaceChangedSinceFileOpenPreparation(openDocumentID(13))
            )
        }
    }

    func testPreparedBoundDuplicateActivatesExistingDocument() throws {
        let originalObservation = try makeOpenObservation(
            path: "/private/provider/Plan.txt",
            identity: openIdentity(15),
            text: "Original File\n"
        )
        let openedState = openObservedBoundDocument(
            state: makeInitialPhonePadState(
                documentID: openDocumentID(15),
                tabID: openTabID(15)
            ),
            documentID: openDocumentID(16),
            tabID: openTabID(16),
            text: "Original File\n",
            observation: originalObservation
        )
        let movedObservation = try makeOpenObservation(
            path: "/private/provider/Moved Plan.txt",
            identity: openIdentity(15),
            text: "Changed Externally\n"
        )

        let preparation = prepareBoundDocumentOpen(
            state: openedState,
            documentID: openDocumentID(17),
            tabID: openTabID(17),
            text: "Changed Externally\n",
            observation: movedObservation
        )

        guard case let .activateExisting(activatedState) = preparation else {
            return XCTFail("Expected an existing bound Document to activate.")
        }
        XCTAssertEqual(activatedState.tabs.count, 1)
        XCTAssertEqual(activatedState.activeTab.document.id, openDocumentID(16))
        XCTAssertEqual(activatedState.activeTab.document.text, "Original File\n")
        XCTAssertEqual(
            activatedState.activeTab.document.fileBinding?.locatorURL,
            movedObservation.binding.locatorURL
        )
        XCTAssertEqual(activatedState.activeTab.document.fileConflict, .contentChanged)
    }

    func testPreparedDetachedOpenCreatesImmediateRecoveryAndReplacesPristineUntitled() throws {
        let initialState = makeInitialPhonePadState(
            documentID: openDocumentID(20),
            tabID: openTabID(20)
        )
        let observation = try makeOpenObservation(
            path: "/private/provider/Read Only.txt",
            identity: openIdentity(20),
            text: "Read-only File\n"
        )
        let candidate = FileOpenCandidate(
            locatorURL: observation.binding.locatorURL,
            identity: observation.binding.identity,
            digest: observation.binding.digest,
            providerConflictVersions: observation.providerConflictVersions
        )
        let recoveryReference = makeRecoveryFileReference(
            fileBinding: observation.binding
        )
        let editedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = DetachedFileSnapshot(
            candidate: candidate,
            displayName: observation.binding.displayName,
            text: "Read-only File\n",
            recoveryFileReference: recoveryReference
        )

        let preparation = try prepareDetachedDocumentOpen(
            state: initialState,
            documentID: openDocumentID(21),
            tabID: openTabID(21),
            snapshot: snapshot,
            editedAt: editedAt
        )

        let prepared = try requirePreparedDetachedOpen(preparation)
        XCTAssertEqual(prepared.expectedState, initialState)
        XCTAssertEqual(prepared.candidate, candidate)
        XCTAssertEqual(prepared.transition.envelope.documentID, openDocumentID(21))
        XCTAssertEqual(prepared.transition.envelope.title, "Read Only.txt")
        XCTAssertEqual(prepared.transition.envelope.text, "Read-only File\n")
        XCTAssertEqual(prepared.transition.envelope.editedAt, editedAt)
        XCTAssertEqual(prepared.transition.envelope.fileReference, recoveryReference)
        XCTAssertNil(prepared.transition.envelope.pendingSave)

        let transition = try commitPreparedDetachedDocumentOpen(
            state: initialState,
            prepared: prepared
        )

        XCTAssertEqual(transition.envelope, prepared.transition.envelope)
        XCTAssertEqual(transition.state.tabs.count, 1)
        XCTAssertEqual(transition.state.activeTab.document.id, openDocumentID(21))
        XCTAssertEqual(transition.state.activeTab.document.title, "Read Only.txt")
        XCTAssertEqual(transition.state.activeTab.document.text, "Read-only File\n")
        XCTAssertNil(transition.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            transition.state.activeTab.document.recoveryFileReference,
            recoveryReference
        )
        XCTAssertTrue(transition.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            transition.state.activeTab.document.recoveryState,
            .checkpointPending
        )
    }

    func testPreparedDetachedOpenRejectsChangedWorkspace() throws {
        let initialState = makeInitialPhonePadState(
            documentID: openDocumentID(22),
            tabID: openTabID(22)
        )
        let candidate = try makeOpenCandidate(
            path: "/private/provider/Ephemeral.txt",
            identity: nil,
            text: "Ephemeral File\n"
        )
        let snapshot = DetachedFileSnapshot(
            candidate: candidate,
            displayName: try ValidatedFileName(validating: "Ephemeral.txt"),
            text: "Ephemeral File\n",
            recoveryFileReference: nil
        )
        let prepared = try requirePreparedDetachedOpen(
            prepareDetachedDocumentOpen(
                state: initialState,
                documentID: openDocumentID(23),
                tabID: openTabID(23),
                snapshot: snapshot,
                editedAt: Date(timeIntervalSince1970: 1_800_000_001)
            )
        )
        let changedState = try createUntitledTab(
            state: initialState,
            documentID: openDocumentID(24),
            tabID: openTabID(24)
        )

        XCTAssertThrowsError(
            try commitPreparedDetachedDocumentOpen(
                state: changedState,
                prepared: prepared
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .workspaceChangedSinceFileOpenPreparation(openDocumentID(23))
            )
        }
    }

    func testExternalRecoveredDetachedOpenReplacesPristineUntitled() throws {
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: openDocumentID(30),
            title: "Recovered.txt",
            text: "Recovered edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_002)
        )
        let initialState = makeInitialPhonePadState(
            documentID: openDocumentID(31),
            tabID: openTabID(31)
        )

        let recoveredState = try openExternallyRecoveredDetachedDocument(
            state: initialState,
            envelope: envelope,
            tabID: openTabID(30)
        )

        XCTAssertEqual(recoveredState.tabs.count, 1)
        XCTAssertEqual(recoveredState.activeTab.document.id, openDocumentID(30))
        XCTAssertNil(recoveredState.activeTab.document.fileBinding)
        XCTAssertTrue(recoveredState.activeTab.document.isUnsaved)
        XCTAssertEqual(
            recoveredState.activeTab.document.recoveryState,
            .protectedUnsaved
        )

        let manualRecoveryState = recoverDocument(
            state: initialState,
            envelope: envelope,
            tabID: openTabID(30)
        )
        XCTAssertEqual(manualRecoveryState.tabs.count, 2)
    }

    func testExternalRecoveredBoundOpenPreservesEditsAndMarksChangedOriginal() throws {
        let baselineObservation = try makeOpenObservation(
            path: "/private/provider/Recovered.txt",
            identity: openIdentity(32),
            text: "Clean baseline\n"
        )
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: openDocumentID(32),
            title: "Recovered.txt",
            text: "Recovered edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_003),
            fileReference: makeRecoveryFileReference(
                fileBinding: baselineObservation.binding
            ),
            pendingSave: nil
        )
        let changedObservation = try makeOpenObservation(
            path: "/private/provider/Recovered.txt",
            identity: openIdentity(32),
            text: "Changed externally\n"
        )

        let recoveredState = try openExternallyRecoveredBoundDocument(
            state: makeInitialPhonePadState(
                documentID: openDocumentID(33),
                tabID: openTabID(33)
            ),
            envelope: envelope,
            tabID: openTabID(32),
            observation: changedObservation
        )

        XCTAssertEqual(recoveredState.tabs.count, 1)
        XCTAssertEqual(recoveredState.activeTab.document.text, "Recovered edits\n")
        XCTAssertEqual(
            recoveredState.activeTab.document.fileBinding?.digest,
            baselineObservation.binding.digest
        )
        XCTAssertEqual(recoveredState.activeTab.document.fileConflict, .contentChanged)
        XCTAssertTrue(recoveredState.activeTab.document.isUnsaved)
        XCTAssertEqual(
            recoveredState.activeTab.document.recoveryState,
            .protectedUnsaved
        )
    }
}

private func makeOpenCandidate(
    path: String,
    identity: FileIdentity?,
    text: String
) throws -> FileOpenCandidate {
    FileOpenCandidate(
        locatorURL: URL(fileURLWithPath: path),
        identity: identity,
        digest: try encodeNewTextFile(text: text).digest,
        providerConflictVersions: .none
    )
}

private func makeOpenObservation(
    path: String,
    identity: FileIdentity?,
    text: String
) throws -> ObservedBoundFile {
    let encodedFile = try encodeNewTextFile(text: text)
    return ObservedBoundFile(
        binding: FileBinding(
            locatorURL: URL(fileURLWithPath: path),
            bookmark: try FileBookmark(data: Data([0xA1, 0x01])),
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

private func requirePreparedBoundOpen(
    _ preparation: BoundDocumentOpenPreparation
) throws -> PreparedBoundDocumentOpen {
    guard case let .prepared(prepared) = preparation else {
        throw UnexpectedFileOpenPreparation()
    }
    return prepared
}

private func requirePreparedDetachedOpen(
    _ preparation: DetachedDocumentOpenPreparation
) throws -> PreparedDetachedDocumentOpen {
    guard case let .prepared(prepared) = preparation else {
        throw UnexpectedFileOpenPreparation()
    }
    return prepared
}

private func openDocumentID(_ suffix: UInt8) -> DocumentID {
    DocumentID(rawValue: openUUID(suffix))
}

private func openTabID(_ suffix: UInt8) -> TabID {
    TabID(rawValue: openUUID(suffix))
}

private func openIdentity(_ suffix: UInt8) -> FileIdentity {
    FileIdentity(
        volumeUUID: UUID(
            uuidString: "A1000000-0000-0000-0000-000000000001"
        )!,
        documentIdentifier: Int(suffix)
    )
}

private func openUUID(_ suffix: UInt8) -> UUID {
    let value = String(format: "%02X", suffix)
    return UUID(
        uuidString: "A0000000-0000-0000-0000-0000000000\(value)"
    )!
}

private struct UnexpectedFileOpenPreparation: Error {}
