import Foundation
import XCTest
@testable import PhonePadCore

final class PhonePadTabWorkspaceTests: XCTestCase {
    func testCreateUntitledTabAppendsAndActivatesCleanNumberedDocument() throws {
        let initialDocumentID = documentID(1)
        let initialTabID = tabID(1)
        let newDocumentID = documentID(2)
        let newTabID = tabID(2)
        let initialState = makeInitialPhonePadState(
            documentID: initialDocumentID,
            tabID: initialTabID
        )

        let createdState = try createUntitledTab(
            state: initialState,
            documentID: newDocumentID,
            tabID: newTabID
        )

        XCTAssertEqual(createdState.tabs.count, 2)
        XCTAssertEqual(createdState.tabs[0], initialState.tabs[0])
        XCTAssertEqual(createdState.activeTabID, newTabID)
        XCTAssertEqual(createdState.activeTab.document.id, newDocumentID)
        XCTAssertEqual(createdState.activeTab.document.title, "Untitled 2")
        XCTAssertEqual(createdState.activeTab.document.text, "")
        XCTAssertNil(createdState.activeTab.document.fileBinding)
        XCTAssertNil(createdState.activeTab.document.fileConflict)
        XCTAssertFalse(createdState.activeTab.document.isUnsaved)
        XCTAssertEqual(createdState.activeTab.document.recoveryState, .clean)
    }

    func testCreateUntitledTabIgnoresFileTabsWhenAllocatingTitle() throws {
        let state = PhonePadState(
            tabs: [
                makeNamedTab(
                    tabSuffix: 1,
                    documentSuffix: 1,
                    title: "Untitled"
                ),
                makeNamedTab(
                    tabSuffix: 2,
                    documentSuffix: 2,
                    title: "Notes.txt"
                )
            ],
            activeTabID: tabID(2)
        )

        let createdState = try createUntitledTab(
            state: state,
            documentID: documentID(3),
            tabID: tabID(3)
        )

        XCTAssertEqual(createdState.activeTab.document.title, "Untitled 2")
    }

    func testCreateUntitledTabUsesSmallestAvailableNumberedTitle() throws {
        let state = PhonePadState(
            tabs: [
                makeNamedTab(
                    tabSuffix: 1,
                    documentSuffix: 1,
                    title: "Untitled"
                ),
                makeNamedTab(
                    tabSuffix: 2,
                    documentSuffix: 2,
                    title: "Untitled 3"
                )
            ],
            activeTabID: tabID(1)
        )

        let createdState = try createUntitledTab(
            state: state,
            documentID: documentID(3),
            tabID: tabID(3)
        )

        XCTAssertEqual(createdState.activeTab.document.title, "Untitled 2")
    }

    func testCreateUntitledTabRejectsDuplicateTabIDWithoutChangingState() {
        let initialState = makeInitialPhonePadState(
            documentID: documentID(1),
            tabID: tabID(1)
        )

        XCTAssertThrowsError(
            try createUntitledTab(
                state: initialState,
                documentID: documentID(2),
                tabID: tabID(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateTabID(tabID(1))
            )
        }
        XCTAssertEqual(initialState.tabs.count, 1)
        XCTAssertEqual(initialState.activeTabID, tabID(1))
    }

    func testCreateUntitledTabRejectsDuplicateDocumentIDWithoutChangingState() {
        let initialState = makeInitialPhonePadState(
            documentID: documentID(1),
            tabID: tabID(1)
        )

        XCTAssertThrowsError(
            try createUntitledTab(
                state: initialState,
                documentID: documentID(1),
                tabID: tabID(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateDocumentID(documentID(1))
            )
        }
        XCTAssertEqual(initialState.tabs.count, 1)
        XCTAssertEqual(initialState.activeTabID, tabID(1))
    }

    func testSelectTabChangesOnlyActiveTabID() throws {
        let initialState = makeInitialPhonePadState(
            documentID: documentID(1),
            tabID: tabID(1)
        )
        let twoTabState = try createUntitledTab(
            state: initialState,
            documentID: documentID(2),
            tabID: tabID(2)
        )

        let selectedState = try selectTab(
            state: twoTabState,
            tabID: tabID(1)
        )

        XCTAssertEqual(selectedState.tabs, twoTabState.tabs)
        XCTAssertEqual(selectedState.activeTabID, tabID(1))
    }

    func testSelectTabRejectsMissingTab() throws {
        let initialState = makeInitialPhonePadState(
            documentID: documentID(1),
            tabID: tabID(1)
        )

        XCTAssertThrowsError(
            try selectTab(state: initialState, tabID: tabID(9))
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .tabMissing(tabID(9))
            )
        }
    }

    func testMoveTabBeforeStableAnchorPreservesDocumentsAndActiveTab() throws {
        let state = try makeThreeTabState()
        let selectedState = try selectTab(state: state, tabID: tabID(2))
        let originalTabs = selectedState.tabs

        let movedState = try moveTab(
            state: selectedState,
            tabID: tabID(3),
            placement: .before(tabID(1))
        )

        XCTAssertEqual(
            movedState.tabs,
            [originalTabs[2], originalTabs[0], originalTabs[1]]
        )
        XCTAssertEqual(movedState.activeTabID, selectedState.activeTabID)
    }

    func testMoveTabToEndUsesStableTabIdentity() throws {
        let state = try makeThreeTabState()
        let originalTabs = state.tabs

        let movedState = try moveTab(
            state: state,
            tabID: tabID(1),
            placement: .end
        )

        XCTAssertEqual(
            movedState.tabs,
            [originalTabs[1], originalTabs[2], originalTabs[0]]
        )
        XCTAssertEqual(movedState.activeTabID, state.activeTabID)
    }

    func testMoveTabBeforeItselfIsNoOp() throws {
        let state = try makeThreeTabState()

        let movedState = try moveTab(
            state: state,
            tabID: tabID(2),
            placement: .before(tabID(2))
        )

        XCTAssertEqual(movedState, state)
    }

    func testMoveTabRejectsMissingSourceAndStaleDestinationAnchor() throws {
        let state = try makeThreeTabState()

        XCTAssertThrowsError(
            try moveTab(
                state: state,
                tabID: tabID(9),
                placement: .end
            )
        ) { error in
            XCTAssertEqual(error as? PhonePadStateError, .tabMissing(tabID(9)))
        }
        XCTAssertThrowsError(
            try moveTab(
                state: state,
                tabID: tabID(1),
                placement: .before(tabID(9))
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .tabPlacementAnchorMissing(tabID(9))
            )
        }
    }

    func testValidatedStateRejectsEmptyWorkspaceAndMissingActiveTab() {
        XCTAssertThrowsError(
            try PhonePadState(
                validatingTabs: [],
                activeTabID: tabID(1)
            )
        ) { error in
            XCTAssertEqual(error as? PhonePadStateError, .emptyTabWorkspace)
        }

        let tab = makeUntitledTab(tabSuffix: 1, documentSuffix: 1)
        XCTAssertThrowsError(
            try PhonePadState(
                validatingTabs: [tab],
                activeTabID: tabID(9)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .activeTabMissing(tabID(9))
            )
        }
    }

    func testValidatedStateRejectsDuplicateTabAndDocumentIDs() {
        let first = makeUntitledTab(tabSuffix: 1, documentSuffix: 1)
        let duplicateTab = makeUntitledTab(tabSuffix: 1, documentSuffix: 2)
        XCTAssertThrowsError(
            try PhonePadState(
                validatingTabs: [first, duplicateTab],
                activeTabID: tabID(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateTabID(tabID(1))
            )
        }

        let duplicateDocument = makeUntitledTab(
            tabSuffix: 2,
            documentSuffix: 1
        )
        XCTAssertThrowsError(
            try PhonePadState(
                validatingTabs: [first, duplicateDocument],
                activeTabID: tabID(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateDocumentID(documentID(1))
            )
        }
    }

    func testValidatedStateRejectsDuplicateBoundFileIdentity() throws {
        let identity = FileIdentity(
            volumeUUID: UUID(
                uuidString: "92000000-0000-0000-0000-000000000001"
            )!,
            documentIdentifier: 42
        )
        let first = try makeBoundTab(
            tabSuffix: 1,
            documentSuffix: 1,
            path: "/private/provider/First.txt",
            bookmarkByte: 0x01,
            identity: identity
        )
        let duplicateIdentity = try makeBoundTab(
            tabSuffix: 2,
            documentSuffix: 2,
            path: "/private/provider/Moved.txt",
            bookmarkByte: 0x02,
            identity: identity
        )

        XCTAssertThrowsError(
            try PhonePadState(
                validatingTabs: [first, duplicateIdentity],
                activeTabID: tabID(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .fileBindingIdentityCollision(
                    documentID: documentID(2),
                    conflictingDocumentID: documentID(1)
                )
            )
        }
    }

    func testValidatedStateRejectsDuplicateBoundFileLocator() throws {
        let first = try makeBoundTab(
            tabSuffix: 1,
            documentSuffix: 1,
            path: "/private/provider/Same.txt",
            bookmarkByte: 0x01,
            identity: nil
        )
        let duplicateLocator = try makeBoundTab(
            tabSuffix: 2,
            documentSuffix: 2,
            path: "/private/provider/../provider/Same.txt",
            bookmarkByte: 0x02,
            identity: nil
        )

        XCTAssertThrowsError(
            try PhonePadState(
                validatingTabs: [first, duplicateLocator],
                activeTabID: tabID(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .fileBindingLocatorCollision(
                    documentID: documentID(2),
                    conflictingDocumentID: documentID(1)
                )
            )
        }
    }

    private func makeThreeTabState() throws -> PhonePadState {
        let initialState = makeInitialPhonePadState(
            documentID: documentID(1),
            tabID: tabID(1)
        )
        let twoTabState = try createUntitledTab(
            state: initialState,
            documentID: documentID(2),
            tabID: tabID(2)
        )
        return try createUntitledTab(
            state: twoTabState,
            documentID: documentID(3),
            tabID: tabID(3)
        )
    }

    private func makeUntitledTab(
        tabSuffix: UInt8,
        documentSuffix: UInt8
    ) -> PhonePadTab {
        makeNamedTab(
            tabSuffix: tabSuffix,
            documentSuffix: documentSuffix,
            title: "Untitled"
        )
    }

    private func makeNamedTab(
        tabSuffix: UInt8,
        documentSuffix: UInt8,
        title: String
    ) -> PhonePadTab {
        PhonePadTab(
            id: tabID(tabSuffix),
            document: PhonePadDocument(
                id: documentID(documentSuffix),
                title: title,
                text: "",
                isUnsaved: false,
                recoveryState: .clean
            )
        )
    }

    private func makeBoundTab(
        tabSuffix: UInt8,
        documentSuffix: UInt8,
        path: String,
        bookmarkByte: UInt8,
        identity: FileIdentity?
    ) throws -> PhonePadTab {
        let encodedFile = try encodeNewTextFile(text: "Bound content")
        let binding = FileBinding(
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
        return PhonePadTab(
            id: tabID(tabSuffix),
            document: PhonePadDocument(
                id: documentID(documentSuffix),
                title: binding.displayName.value,
                text: encodedFile.text,
                fileBinding: binding,
                isUnsaved: false,
                recoveryState: .clean
            )
        )
    }
}

private func documentID(_ suffix: UInt8) -> DocumentID {
    DocumentID(
        rawValue: UUID(
            uuid: (0x90, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}

private func tabID(_ suffix: UInt8) -> TabID {
    TabID(
        rawValue: UUID(
            uuid: (0x91, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}
