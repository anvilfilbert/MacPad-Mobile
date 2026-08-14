import Foundation
import XCTest
@testable import PhonePadCore

final class FileConflictModelsTests: XCTestCase {
    func testReconciliationClassifiesEveryConflictAndStableMoveContinuity() throws {
        let stableIdentity = FileIdentity(
            volumeUUID: UUID(uuidString: "61000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 201
        )
        let otherIdentity = FileIdentity(
            volumeUUID: stableIdentity.volumeUUID,
            documentIdentifier: 202
        )
        let baseline = try makeBinding(
            path: "/private/provider/Original.txt",
            bookmarkByte: 0x11,
            identity: stableIdentity,
            text: "Clean content"
        )
        let moved = try makeBinding(
            path: "/private/provider/Moved.txt",
            bookmarkByte: 0x12,
            identity: stableIdentity,
            text: "Clean content"
        )
        let movedBaseline = retainingBaselineContent(
            baseline: baseline,
            accessFrom: moved
        )
        let contentChanged = try makeBinding(
            path: "/private/provider/Moved.txt",
            bookmarkByte: 0x13,
            identity: stableIdentity,
            text: "External content"
        )
        let contentChangedBaseline = retainingBaselineContent(
            baseline: baseline,
            accessFrom: contentChanged
        )
        let identityChanged = try makeBinding(
            path: baseline.locatorURL.path,
            bookmarkByte: 0x14,
            identity: otherIdentity,
            text: "Clean content"
        )
        let unidentifiedBaseline = try makeBinding(
            path: "/private/provider/NoIdentity.txt",
            bookmarkByte: 0x15,
            identity: nil,
            text: "Clean content"
        )
        let unidentifiedMove = try makeBinding(
            path: "/private/provider/NoIdentityMoved.txt",
            bookmarkByte: 0x16,
            identity: nil,
            text: "Clean content"
        )
        let unresolved = try makeBinding(
            path: baseline.locatorURL.path,
            bookmarkByte: 0x17,
            identity: stableIdentity,
            text: "Clean content"
        )
        let unresolvedBaseline = retainingBaselineContent(
            baseline: baseline,
            accessFrom: unresolved
        )
        let cases: [(
            name: String,
            baseline: FileBinding,
            observation: ObservedBoundFile,
            expected: FileReconciliationResult
        )] = [
            (
                name: "stable move",
                baseline: baseline,
                observation: ObservedBoundFile(
                    binding: moved,
                    providerConflictVersions: .none
                ),
                expected: .continuous(updatedBinding: movedBaseline)
            ),
            (
                name: "digest change",
                baseline: baseline,
                observation: ObservedBoundFile(
                    binding: contentChanged,
                    providerConflictVersions: .none
                ),
                expected: .conflicted(
                    retainedBinding: contentChangedBaseline,
                    conflict: .contentChanged
                )
            ),
            (
                name: "stable identity change",
                baseline: baseline,
                observation: ObservedBoundFile(
                    binding: identityChanged,
                    providerConflictVersions: .none
                ),
                expected: .conflicted(
                    retainedBinding: baseline,
                    conflict: .stableIdentityChanged
                )
            ),
            (
                name: "ambiguous locator move",
                baseline: unidentifiedBaseline,
                observation: ObservedBoundFile(
                    binding: unidentifiedMove,
                    providerConflictVersions: .none
                ),
                expected: .conflicted(
                    retainedBinding: unidentifiedBaseline,
                    conflict: .ambiguousLocatorChange
                )
            ),
            (
                name: "unresolved provider versions",
                baseline: baseline,
                observation: ObservedBoundFile(
                    binding: unresolved,
                    providerConflictVersions: .unresolved(count: 2)
                ),
                expected: .conflicted(
                    retainedBinding: unresolvedBaseline,
                    conflict: .unresolvedProviderVersions(count: 2)
                )
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                reconcileFileBinding(
                    baseline: testCase.baseline,
                    observation: testCase.observation
                ),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testConflictIsStickyAcrossCleanReconciliation() throws {
        let binding = try makeBinding(
            path: "/private/provider/Sticky.txt",
            bookmarkByte: 0x21,
            identity: makeIdentity(documentIdentifier: 211),
            text: "Clean content"
        )
        let state = makeBoundState(binding: binding, text: "Clean content")
        let conflicted = try markDocumentFileConflict(
            state: state,
            documentID: state.activeTab.document.id,
            conflict: .contentChanged
        )

        let reconciled = try reconcileBoundDocument(
            state: conflicted,
            documentID: conflicted.activeTab.document.id,
            observation: ObservedBoundFile(
                binding: binding,
                providerConflictVersions: .none
            )
        )

        XCTAssertEqual(reconciled.activeTab.document.fileConflict, .contentChanged)
        XCTAssertEqual(reconciled.activeTab.document.text, "Clean content")
        XCTAssertEqual(reconciled.activeTab.document.fileBinding, binding)
    }

    func testRecoveryProtectionMergesByDocumentWithoutErasingConcurrentConflict() throws {
        let firstBinding = try makeBinding(
            path: "/private/provider/Checkpoint.txt",
            bookmarkByte: 0x25,
            identity: makeIdentity(documentIdentifier: 215),
            text: "Clean content"
        )
        let firstOpen = makeBoundState(binding: firstBinding, text: "Clean content")
        let firstDocumentID = firstOpen.activeTab.document.id
        let editedFirst = try beginActiveDocumentEdit(
            state: firstOpen,
            newText: "Local edit",
            editedAt: Date(timeIntervalSince1970: 1_786_649_900)
        ).state
        let secondBinding = try makeBinding(
            path: "/private/provider/Other.txt",
            bookmarkByte: 0x26,
            identity: makeIdentity(documentIdentifier: 216),
            text: "Other content"
        )
        let secondOpen = openBoundDocument(
            state: editedFirst,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "Other content",
            fileBinding: secondBinding
        )
        let movedBinding = try makeBinding(
            path: "/private/provider/Checkpoint Moved.txt",
            bookmarkByte: 0x27,
            identity: firstBinding.identity,
            text: "Clean content"
        )
        let movedState = try reconcileBoundDocument(
            state: secondOpen,
            documentID: firstDocumentID,
            observation: ObservedBoundFile(
                binding: movedBinding,
                providerConflictVersions: .none
            )
        )
        let conflictedState = try markDocumentFileConflict(
            state: movedState,
            documentID: firstDocumentID,
            conflict: .contentChanged
        )

        let protectedState = try markDocumentRecoveryProtected(
            state: conflictedState,
            documentID: firstDocumentID,
            expectedText: "Local edit"
        )

        let protectedDocument = try XCTUnwrap(
            protectedState.tabs.first(where: { $0.document.id == firstDocumentID })?
                .document
        )
        XCTAssertEqual(protectedState.activeTabID, secondOpen.activeTabID)
        XCTAssertEqual(protectedState.tabs.count, 2)
        XCTAssertEqual(protectedDocument.text, "Local edit")
        XCTAssertEqual(protectedDocument.recoveryState, .protectedUnsaved)
        XCTAssertEqual(protectedDocument.fileConflict, .contentChanged)
        XCTAssertEqual(
            protectedDocument.fileBinding,
            retainingBaselineContent(
                baseline: firstBinding,
                accessFrom: movedBinding
            )
        )
        XCTAssertThrowsError(
            try markDocumentRecoveryProtected(
                state: conflictedState,
                documentID: firstDocumentID,
                expectedText: "Stale edit"
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .documentTextChanged(firstDocumentID)
            )
        }
    }

    func testBoundSaveIsBlockedUntilExplicitVerifiedSaveAs() throws {
        let binding = try makeBinding(
            path: "/private/provider/Original.txt",
            bookmarkByte: 0x31,
            identity: makeIdentity(documentIdentifier: 221),
            text: "Original content"
        )
        let cleanState = makeBoundState(binding: binding, text: "Original content")
        let editedState = try beginActiveDocumentEdit(
            state: cleanState,
            newText: "Local edit",
            editedAt: Date(timeIntervalSince1970: 1_786_650_000)
        ).state
        let conflicted = try markDocumentFileConflict(
            state: editedState,
            documentID: editedState.activeTab.document.id,
            conflict: .contentChanged
        )
        let encodedEdit = try encodeNewTextFile(text: "Local edit")
        let originalOutputBinding = FileBinding(
            locatorURL: binding.locatorURL,
            bookmark: binding.bookmark,
            identity: binding.identity,
            displayName: binding.displayName,
            digest: encodedEdit.digest,
            encoding: encodedEdit.encoding,
            lineEnding: encodedEdit.lineEnding
        )

        XCTAssertThrowsError(
            try markActiveDocumentSavedToBoundFile(
                state: conflicted,
                encodedFile: encodedEdit,
                fileBinding: originalOutputBinding
            )
        ) { error in
            XCTAssertEqual(
                error as? SavedDocumentTransitionError,
                .fileConflictRequiresExplicitResolution(.contentChanged)
            )
        }

        let saveAsBinding = FileBinding(
            locatorURL: URL(fileURLWithPath: "/private/provider/Preserved Edit.txt"),
            bookmark: try FileBookmark(data: Data([0x32])),
            identity: makeIdentity(documentIdentifier: 222),
            displayName: try ValidatedFileName(validating: "Preserved Edit.txt"),
            digest: encodedEdit.digest,
            encoding: encodedEdit.encoding,
            lineEnding: encodedEdit.lineEnding
        )
        let savedAs = try markActiveDocumentSavedAsBoundFile(
            state: conflicted,
            encodedFile: encodedEdit,
            fileBinding: saveAsBinding
        )

        XCTAssertNil(savedAs.activeTab.document.fileConflict)
        XCTAssertEqual(savedAs.activeTab.document.fileBinding, saveAsBinding)
        XCTAssertFalse(savedAs.activeTab.document.isUnsaved)
        XCTAssertEqual(savedAs.activeTab.document.recoveryState, .clean)
    }

    func testPrewriteBoundSaveGateReturnsCleanBindingAndRejectsStickyConflict() throws {
        let binding = try makeBinding(
            path: "/private/provider/Gated.txt",
            bookmarkByte: 0x35,
            identity: makeIdentity(documentIdentifier: 225),
            text: "Clean content"
        )
        let cleanState = makeBoundState(binding: binding, text: "Clean content")
        let documentID = cleanState.activeTab.document.id

        XCTAssertEqual(
            try requireBoundFileSaveAllowed(
                state: cleanState,
                documentID: documentID
            ),
            binding
        )

        let conflictedState = try markDocumentFileConflict(
            state: cleanState,
            documentID: documentID,
            conflict: .contentChanged
        )
        XCTAssertThrowsError(
            try requireBoundFileSaveAllowed(
                state: conflictedState,
                documentID: documentID
            )
        ) { error in
            XCTAssertEqual(
                error as? SavedDocumentTransitionError,
                .fileConflictRequiresExplicitResolution(.contentChanged)
            )
        }
    }

    func testVerifiedReloadClearsPriorConflictButKeepsUnresolvedVersionsBlocked() throws {
        let baseline = try makeBinding(
            path: "/private/provider/Reload.txt",
            bookmarkByte: 0x41,
            identity: makeIdentity(documentIdentifier: 231),
            text: "Original content"
        )
        let cleanState = makeBoundState(binding: baseline, text: "Original content")
        let dirtyState = try beginActiveDocumentEdit(
            state: cleanState,
            newText: "Local edit",
            editedAt: Date(timeIntervalSince1970: 1_786_650_100)
        ).state
        let conflicted = try markDocumentFileConflict(
            state: dirtyState,
            documentID: dirtyState.activeTab.document.id,
            conflict: .contentChanged
        )
        let external = try makeBinding(
            path: baseline.locatorURL.path,
            bookmarkByte: 0x42,
            identity: baseline.identity,
            text: "External content"
        )

        let reloaded = try reloadDocumentFromBoundFile(
            state: conflicted,
            documentID: conflicted.activeTab.document.id,
            text: "External content",
            observation: ObservedBoundFile(
                binding: external,
                providerConflictVersions: .none
            )
        )
        let stillConflicted = try reloadDocumentFromBoundFile(
            state: conflicted,
            documentID: conflicted.activeTab.document.id,
            text: "External content",
            observation: ObservedBoundFile(
                binding: external,
                providerConflictVersions: .unresolved(count: 3)
            )
        )

        XCTAssertNil(reloaded.activeTab.document.fileConflict)
        XCTAssertEqual(reloaded.activeTab.document.text, "External content")
        XCTAssertEqual(reloaded.activeTab.document.fileBinding, external)
        XCTAssertFalse(reloaded.activeTab.document.isUnsaved)
        XCTAssertEqual(reloaded.activeTab.document.recoveryState, .clean)
        XCTAssertEqual(
            stillConflicted.activeTab.document.fileConflict,
            .unresolvedProviderVersions(count: 3)
        )
        XCTAssertEqual(stillConflicted.activeTab.document.text, "External content")
        XCTAssertFalse(stillConflicted.activeTab.document.isUnsaved)
    }

    func testDuplicateOpenReconcilesNonactiveStableIdentityWithoutReplacingText() throws {
        let firstIdentity = makeIdentity(documentIdentifier: 241)
        let firstBinding = try makeBinding(
            path: "/private/provider/First.txt",
            bookmarkByte: 0x51,
            identity: firstIdentity,
            text: "First open text"
        )
        let firstDocumentID = DocumentID(rawValue: UUID())
        let firstTabID = TabID(rawValue: UUID())
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let firstOpen = openObservedBoundDocument(
            state: initialState,
            documentID: firstDocumentID,
            tabID: firstTabID,
            text: "First open text",
            observation: ObservedBoundFile(
                binding: firstBinding,
                providerConflictVersions: .none
            )
        )
        let secondBinding = try makeBinding(
            path: "/private/provider/Second.txt",
            bookmarkByte: 0x52,
            identity: makeIdentity(documentIdentifier: 242),
            text: "Second open text"
        )
        let secondOpen = openObservedBoundDocument(
            state: firstOpen,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "Second open text",
            observation: ObservedBoundFile(
                binding: secondBinding,
                providerConflictVersions: .none
            )
        )
        let changedMovedBinding = try makeBinding(
            path: "/private/provider/First Moved.txt",
            bookmarkByte: 0x53,
            identity: firstIdentity,
            text: "External changed text"
        )

        let duplicateOpen = openObservedBoundDocument(
            state: secondOpen,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "External changed text",
            observation: ObservedBoundFile(
                binding: changedMovedBinding,
                providerConflictVersions: .none
            )
        )

        XCTAssertEqual(duplicateOpen.tabs.count, 2)
        XCTAssertEqual(duplicateOpen.activeTabID, firstTabID)
        XCTAssertEqual(duplicateOpen.activeTab.document.id, firstDocumentID)
        XCTAssertEqual(duplicateOpen.activeTab.document.text, "First open text")
        XCTAssertEqual(
            duplicateOpen.activeTab.document.fileConflict,
            .contentChanged
        )
        XCTAssertEqual(
            duplicateOpen.activeTab.document.fileBinding,
            retainingBaselineContent(
                baseline: firstBinding,
                accessFrom: changedMovedBinding
            )
        )
    }

    func testDuplicateOpenAtSameLocatorMarksIdentityConflictWithoutSecondBinding() throws {
        let originalBinding = try makeBinding(
            path: "/private/provider/Same.txt",
            bookmarkByte: 0x61,
            identity: makeIdentity(documentIdentifier: 251),
            text: "Original text"
        )
        let originalDocumentID = DocumentID(rawValue: UUID())
        let originalTabID = TabID(rawValue: UUID())
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let originalOpen = openObservedBoundDocument(
            state: initialState,
            documentID: originalDocumentID,
            tabID: originalTabID,
            text: "Original text",
            observation: ObservedBoundFile(
                binding: originalBinding,
                providerConflictVersions: .none
            )
        )
        let identityChangedBinding = try makeBinding(
            path: originalBinding.locatorURL.path,
            bookmarkByte: 0x62,
            identity: nil,
            text: "Replacement text"
        )

        let duplicateOpen = openObservedBoundDocument(
            state: originalOpen,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "Replacement text",
            observation: ObservedBoundFile(
                binding: identityChangedBinding,
                providerConflictVersions: .none
            )
        )

        XCTAssertEqual(duplicateOpen.tabs.count, 1)
        XCTAssertEqual(duplicateOpen.activeTabID, originalTabID)
        XCTAssertEqual(duplicateOpen.activeTab.document.id, originalDocumentID)
        XCTAssertEqual(duplicateOpen.activeTab.document.text, "Original text")
        XCTAssertEqual(
            duplicateOpen.activeTab.document.fileConflict,
            .stableIdentityChanged
        )
        XCTAssertEqual(duplicateOpen.activeTab.document.fileBinding, originalBinding)
    }

    func testDuplicateOpenWithCrossedIdentityAndLocatorPreservesBothBindings() throws {
        let firstIdentity = makeIdentity(documentIdentifier: 261)
        let firstBinding = try makeBinding(
            path: "/private/provider/Cross First.txt",
            bookmarkByte: 0x71,
            identity: firstIdentity,
            text: "First text"
        )
        let firstOpen = makeBoundState(binding: firstBinding, text: "First text")
        let firstDocumentID = firstOpen.activeTab.document.id
        let secondIdentity = makeIdentity(documentIdentifier: 262)
        let secondBinding = try makeBinding(
            path: "/private/provider/Cross Second.txt",
            bookmarkByte: 0x72,
            identity: secondIdentity,
            text: "Second text"
        )
        let secondTabID = TabID(rawValue: UUID())
        let secondOpen = openBoundDocument(
            state: firstOpen,
            documentID: DocumentID(rawValue: UUID()),
            tabID: secondTabID,
            text: "Second text",
            fileBinding: secondBinding
        )
        let crossedCandidate = try makeBinding(
            path: secondBinding.locatorURL.path,
            bookmarkByte: 0x73,
            identity: firstIdentity,
            text: "First text"
        )

        let duplicateOpen = openObservedBoundDocument(
            state: secondOpen,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "First text",
            observation: ObservedBoundFile(
                binding: crossedCandidate,
                providerConflictVersions: .none
            )
        )

        let firstDocument = try XCTUnwrap(
            duplicateOpen.tabs.first(where: {
                $0.document.id == firstDocumentID
            })?.document
        )
        XCTAssertEqual(duplicateOpen.tabs.count, 2)
        XCTAssertEqual(duplicateOpen.activeTabID, secondTabID)
        XCTAssertEqual(firstDocument.fileBinding, firstBinding)
        XCTAssertNil(firstDocument.fileConflict)
        XCTAssertEqual(duplicateOpen.activeTab.document.fileBinding, secondBinding)
        XCTAssertEqual(
            duplicateOpen.activeTab.document.fileConflict,
            .stableIdentityChanged
        )
    }

    func testStableMoveReconciliationRejectsLocatorOwnedByAnotherDocument() throws {
        let firstBinding = try makeBinding(
            path: "/private/provider/Reconcile First.txt",
            bookmarkByte: 0x81,
            identity: makeIdentity(documentIdentifier: 271),
            text: "First text"
        )
        let firstOpen = makeBoundState(binding: firstBinding, text: "First text")
        let firstDocumentID = firstOpen.activeTab.document.id
        let secondBinding = try makeBinding(
            path: "/private/provider/Reconcile Second.txt",
            bookmarkByte: 0x82,
            identity: makeIdentity(documentIdentifier: 272),
            text: "Second text"
        )
        let secondDocumentID = DocumentID(rawValue: UUID())
        let twoDocumentState = openBoundDocument(
            state: firstOpen,
            documentID: secondDocumentID,
            tabID: TabID(rawValue: UUID()),
            text: "Second text",
            fileBinding: secondBinding
        )
        let collidingMove = try makeBinding(
            path: secondBinding.locatorURL.path,
            bookmarkByte: 0x83,
            identity: firstBinding.identity,
            text: "First text"
        )

        XCTAssertThrowsError(
            try reconcileBoundDocument(
                state: twoDocumentState,
                documentID: firstDocumentID,
                observation: ObservedBoundFile(
                    binding: collidingMove,
                    providerConflictVersions: .none
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .fileBindingLocatorCollision(
                    documentID: firstDocumentID,
                    conflictingDocumentID: secondDocumentID
                )
            )
        }
        XCTAssertEqual(
            twoDocumentState.tabs.first(where: {
                $0.document.id == firstDocumentID
            })?.document.fileBinding,
            firstBinding
        )
        XCTAssertEqual(
            twoDocumentState.tabs.first(where: {
                $0.document.id == secondDocumentID
            })?.document.fileBinding,
            secondBinding
        )
    }

    func testReloadRejectsIdentityOwnedByAnotherDocument() throws {
        let firstBinding = try makeBinding(
            path: "/private/provider/Reload First.txt",
            bookmarkByte: 0x91,
            identity: makeIdentity(documentIdentifier: 281),
            text: "First text"
        )
        let firstOpen = makeBoundState(binding: firstBinding, text: "First text")
        let firstDocumentID = firstOpen.activeTab.document.id
        let secondBinding = try makeBinding(
            path: "/private/provider/Reload Second.txt",
            bookmarkByte: 0x92,
            identity: makeIdentity(documentIdentifier: 282),
            text: "Second text"
        )
        let secondDocumentID = DocumentID(rawValue: UUID())
        let twoDocumentState = openBoundDocument(
            state: firstOpen,
            documentID: secondDocumentID,
            tabID: TabID(rawValue: UUID()),
            text: "Second text",
            fileBinding: secondBinding
        )
        let collidingReload = try makeBinding(
            path: "/private/provider/Reload Candidate.txt",
            bookmarkByte: 0x93,
            identity: secondBinding.identity,
            text: "External text"
        )

        XCTAssertThrowsError(
            try reloadDocumentFromBoundFile(
                state: twoDocumentState,
                documentID: firstDocumentID,
                text: "External text",
                observation: ObservedBoundFile(
                    binding: collidingReload,
                    providerConflictVersions: .none
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .fileBindingIdentityCollision(
                    documentID: firstDocumentID,
                    conflictingDocumentID: secondDocumentID
                )
            )
        }
        XCTAssertEqual(
            twoDocumentState.tabs.first(where: {
                $0.document.id == firstDocumentID
            })?.document.fileBinding,
            firstBinding
        )
        XCTAssertEqual(
            twoDocumentState.tabs.first(where: {
                $0.document.id == secondDocumentID
            })?.document.fileBinding,
            secondBinding
        )
    }

    private func makeBoundState(
        binding: FileBinding,
        text: String
    ) -> PhonePadState {
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        return openBoundDocument(
            state: initialState,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: text,
            fileBinding: binding
        )
    }

    private func makeBinding(
        path: String,
        bookmarkByte: UInt8,
        identity: FileIdentity?,
        text: String
    ) throws -> FileBinding {
        let encodedFile = try encodeNewTextFile(text: text)
        return FileBinding(
            locatorURL: URL(fileURLWithPath: path),
            bookmark: try FileBookmark(data: Data([bookmarkByte])),
            identity: identity,
            displayName: try ValidatedFileName(
                validating: URL(fileURLWithPath: path).lastPathComponent
            ),
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
    }

    private func retainingBaselineContent(
        baseline: FileBinding,
        accessFrom observation: FileBinding
    ) -> FileBinding {
        FileBinding(
            locatorURL: observation.locatorURL,
            bookmark: observation.bookmark,
            identity: baseline.identity,
            displayName: baseline.displayName,
            digest: baseline.digest,
            encoding: baseline.encoding,
            lineEnding: baseline.lineEnding
        )
    }

    private func makeIdentity(documentIdentifier: Int) -> FileIdentity {
        FileIdentity(
            volumeUUID: UUID(
                uuidString: "61000000-0000-0000-0000-000000000002"
            )!,
            documentIdentifier: documentIdentifier
        )
    }
}
