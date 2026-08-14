import Foundation
import XCTest
@testable import PhonePadCore

final class PhonePadTabCloseCoreTests: XCTestCase {
    func testPrepareTabCloseClassifiesCleanTab() throws {
        let state = makeInitialPhonePadState(
            documentID: closeDocumentID(1),
            tabID: closeTabID(1)
        )

        let requirement = try prepareTabClose(
            state: state,
            tabID: closeTabID(1)
        )

        let preparedClose = try requirePreparedCleanClose(requirement)
        XCTAssertEqual(preparedClose.tab, state.activeTab)
    }

    func testPrepareTabCloseClassifiesProtectedUnsavedTab() throws {
        let state = makeInitialPhonePadState(
            documentID: closeDocumentID(1),
            tabID: closeTabID(1)
        )
        let editedState = try makeProtectedEdit(
            state: state,
            text: "Protected edit"
        )

        let requirement = try prepareTabClose(
            state: editedState,
            tabID: closeTabID(1)
        )

        let preparedClose = try requirePreparedUnsavedClose(requirement)
        XCTAssertEqual(preparedClose.tab, editedState.activeTab)
    }

    func testPrepareOtherTabClosesRetainsOriginalOrderAndRequirements() throws {
        let threeTabs = try makeThreeCleanTabs()
        let secondSelected = try selectTab(
            state: threeTabs,
            tabID: closeTabID(2)
        )
        let secondEdited = try makeProtectedEdit(
            state: secondSelected,
            text: "Second Tab edit"
        )
        let state = try selectTab(
            state: secondEdited,
            tabID: closeTabID(3)
        )

        let requirements = try prepareOtherTabCloses(
            state: state,
            keepingTabID: closeTabID(3)
        )

        XCTAssertEqual(requirements.count, 2)
        XCTAssertEqual(
            try requirePreparedCleanClose(requirements[0]).tab.id,
            closeTabID(1)
        )
        XCTAssertEqual(
            try requirePreparedUnsavedClose(requirements[1]).tab.id,
            closeTabID(2)
        )
    }

    func testPrepareOtherTabClosesRejectsMissingRetainedTab() throws {
        let state = try makeThreeCleanTabs()

        XCTAssertThrowsError(
            try prepareOtherTabCloses(
                state: state,
                keepingTabID: closeTabID(9)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .tabMissing(closeTabID(9))
            )
        }
    }

    func testClosePreparedCleanInactiveTabPreservesActiveTabAndRemainingTabs() throws {
        let state = try makeThreeCleanTabs()
        let originalTabs = state.tabs
        let preparedClose = try requirePreparedCleanClose(
            prepareTabClose(state: state, tabID: closeTabID(1))
        )

        let closedState = try closePreparedCleanTab(
            state: state,
            preparedClose: preparedClose,
            replacementDocumentID: closeDocumentID(8),
            replacementTabID: closeTabID(8)
        )

        XCTAssertEqual(closedState.tabs, [originalTabs[1], originalTabs[2]])
        XCTAssertEqual(closedState.activeTabID, closeTabID(3))
    }

    func testClosePreparedCleanActiveTabSelectsRightSuccessor() throws {
        let state = try selectTab(
            state: makeThreeCleanTabs(),
            tabID: closeTabID(2)
        )
        let preparedClose = try requirePreparedCleanClose(
            prepareTabClose(state: state, tabID: closeTabID(2))
        )

        let closedState = try closePreparedCleanTab(
            state: state,
            preparedClose: preparedClose,
            replacementDocumentID: closeDocumentID(8),
            replacementTabID: closeTabID(8)
        )

        XCTAssertEqual(closedState.tabs.map(\.id), [closeTabID(1), closeTabID(3)])
        XCTAssertEqual(closedState.activeTabID, closeTabID(3))
    }

    func testClosePreparedCleanActiveLastTabSelectsLeftPredecessor() throws {
        let state = try makeThreeCleanTabs()
        let preparedClose = try requirePreparedCleanClose(
            prepareTabClose(state: state, tabID: closeTabID(3))
        )

        let closedState = try closePreparedCleanTab(
            state: state,
            preparedClose: preparedClose,
            replacementDocumentID: closeDocumentID(8),
            replacementTabID: closeTabID(8)
        )

        XCTAssertEqual(closedState.tabs.map(\.id), [closeTabID(1), closeTabID(2)])
        XCTAssertEqual(closedState.activeTabID, closeTabID(2))
    }

    func testClosePreparedDiscardedTabRemovesExactUnsavedSnapshot() throws {
        let threeTabs = try makeThreeCleanTabs()
        let secondSelected = try selectTab(
            state: threeTabs,
            tabID: closeTabID(2)
        )
        let state = try makeProtectedEdit(
            state: secondSelected,
            text: "Discard this edit"
        )
        let preparedClose = try requirePreparedUnsavedClose(
            prepareTabClose(state: state, tabID: closeTabID(2))
        )

        let closedState = try closePreparedDiscardedTab(
            state: state,
            preparedClose: preparedClose,
            replacementDocumentID: closeDocumentID(8),
            replacementTabID: closeTabID(8)
        )

        XCTAssertEqual(closedState.tabs.map(\.id), [closeTabID(1), closeTabID(3)])
        XCTAssertEqual(closedState.activeTabID, closeTabID(3))
    }

    func testClosePreparedDiscardedTabRejectsNewerEdit() throws {
        let initialState = makeInitialPhonePadState(
            documentID: closeDocumentID(1),
            tabID: closeTabID(1)
        )
        let preparedState = try makeProtectedEdit(
            state: initialState,
            text: "Prepared text"
        )
        let preparedClose = try requirePreparedUnsavedClose(
            prepareTabClose(
                state: preparedState,
                tabID: closeTabID(1)
            )
        )
        let newerState = try makeProtectedEdit(
            state: preparedState,
            text: "Newer text"
        )

        XCTAssertThrowsError(
            try closePreparedDiscardedTab(
                state: newerState,
                preparedClose: preparedClose,
                replacementDocumentID: closeDocumentID(8),
                replacementTabID: closeTabID(8)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .tabChangedSinceClosePreparation(closeTabID(1))
            )
        }
        XCTAssertEqual(newerState.activeTab.document.text, "Newer text")
    }

    func testClosePreparedCleanFinalTabCreatesFreshUntitledTab() throws {
        let state = makeInitialPhonePadState(
            documentID: closeDocumentID(1),
            tabID: closeTabID(1)
        )
        let preparedClose = try requirePreparedCleanClose(
            prepareTabClose(state: state, tabID: closeTabID(1))
        )

        let closedState = try closePreparedCleanTab(
            state: state,
            preparedClose: preparedClose,
            replacementDocumentID: closeDocumentID(2),
            replacementTabID: closeTabID(2)
        )

        assertFreshUntitled(
            state: closedState,
            expectedDocumentID: closeDocumentID(2),
            expectedTabID: closeTabID(2),
            file: #filePath,
            line: #line
        )
    }

    func testClosePreparedDiscardedFinalTabCreatesFreshUntitledTab() throws {
        let initialState = makeInitialPhonePadState(
            documentID: closeDocumentID(1),
            tabID: closeTabID(1)
        )
        let state = try makeProtectedEdit(
            state: initialState,
            text: "Discard final edit"
        )
        let preparedClose = try requirePreparedUnsavedClose(
            prepareTabClose(state: state, tabID: closeTabID(1))
        )

        let closedState = try closePreparedDiscardedTab(
            state: state,
            preparedClose: preparedClose,
            replacementDocumentID: closeDocumentID(2),
            replacementTabID: closeTabID(2)
        )

        assertFreshUntitled(
            state: closedState,
            expectedDocumentID: closeDocumentID(2),
            expectedTabID: closeTabID(2),
            file: #filePath,
            line: #line
        )
    }

    func testClosePreparedFinalTabRejectsReusedTabID() throws {
        let state = makeInitialPhonePadState(
            documentID: closeDocumentID(1),
            tabID: closeTabID(1)
        )
        let preparedClose = try requirePreparedCleanClose(
            prepareTabClose(state: state, tabID: closeTabID(1))
        )

        XCTAssertThrowsError(
            try closePreparedCleanTab(
                state: state,
                preparedClose: preparedClose,
                replacementDocumentID: closeDocumentID(2),
                replacementTabID: closeTabID(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateTabID(closeTabID(1))
            )
        }
    }

    func testClosePreparedFinalTabRejectsReusedDocumentID() throws {
        let state = makeInitialPhonePadState(
            documentID: closeDocumentID(1),
            tabID: closeTabID(1)
        )
        let preparedClose = try requirePreparedCleanClose(
            prepareTabClose(state: state, tabID: closeTabID(1))
        )

        XCTAssertThrowsError(
            try closePreparedCleanTab(
                state: state,
                preparedClose: preparedClose,
                replacementDocumentID: closeDocumentID(1),
                replacementTabID: closeTabID(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadStateError,
                .duplicateDocumentID(closeDocumentID(1))
            )
        }
    }

    func testClosingBoundTabReleasesBindingWithoutChangingRemainingBinding() throws {
        let firstBinding = try makeCloseFileBinding(
            suffix: 1,
            path: "/private/provider/First.txt"
        )
        let secondBinding = try makeCloseFileBinding(
            suffix: 2,
            path: "/private/provider/Second.txt"
        )
        let initialState = makeInitialPhonePadState(
            documentID: closeDocumentID(9),
            tabID: closeTabID(9)
        )
        let firstOpen = openBoundDocument(
            state: initialState,
            documentID: closeDocumentID(1),
            tabID: closeTabID(1),
            text: "First",
            fileBinding: firstBinding
        )
        let state = openBoundDocument(
            state: firstOpen,
            documentID: closeDocumentID(2),
            tabID: closeTabID(2),
            text: "Second",
            fileBinding: secondBinding
        )
        let preparedClose = try requirePreparedCleanClose(
            prepareTabClose(state: state, tabID: closeTabID(1))
        )

        let closedState = try closePreparedCleanTab(
            state: state,
            preparedClose: preparedClose,
            replacementDocumentID: closeDocumentID(8),
            replacementTabID: closeTabID(8)
        )
        let reopenedState = openBoundDocument(
            state: closedState,
            documentID: closeDocumentID(3),
            tabID: closeTabID(3),
            text: "Reopened First",
            fileBinding: firstBinding
        )

        XCTAssertEqual(closedState.tabs.count, 1)
        XCTAssertEqual(closedState.activeTab.document.fileBinding, secondBinding)
        XCTAssertEqual(reopenedState.tabs.count, 2)
        XCTAssertEqual(reopenedState.activeTab.document.fileBinding, firstBinding)
    }
}

private enum TabCloseCoreTestError: Error {
    case expectedCleanRequirement
    case expectedUnsavedRequirement
}

private func requirePreparedCleanClose(
    _ requirement: TabCloseRequirement
) throws -> PreparedCleanTabClose {
    guard case let .clean(preparedClose) = requirement else {
        throw TabCloseCoreTestError.expectedCleanRequirement
    }
    return preparedClose
}

private func requirePreparedUnsavedClose(
    _ requirement: TabCloseRequirement
) throws -> PreparedUnsavedTabClose {
    guard case let .unsaved(preparedClose) = requirement else {
        throw TabCloseCoreTestError.expectedUnsavedRequirement
    }
    return preparedClose
}

private func makeThreeCleanTabs() throws -> PhonePadState {
    let initialState = makeInitialPhonePadState(
        documentID: closeDocumentID(1),
        tabID: closeTabID(1)
    )
    let twoTabs = try createUntitledTab(
        state: initialState,
        documentID: closeDocumentID(2),
        tabID: closeTabID(2)
    )
    return try createUntitledTab(
        state: twoTabs,
        documentID: closeDocumentID(3),
        tabID: closeTabID(3)
    )
}

private func makeProtectedEdit(
    state: PhonePadState,
    text: String
) throws -> PhonePadState {
    let transition = try beginActiveDocumentEdit(
        state: state,
        newText: text,
        editedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    return try markActiveDocumentRecoveryProtected(state: transition.state)
}

private func assertFreshUntitled(
    state: PhonePadState,
    expectedDocumentID: DocumentID,
    expectedTabID: TabID,
    file: StaticString,
    line: UInt
) {
    XCTAssertEqual(state.tabs.count, 1, file: file, line: line)
    XCTAssertEqual(state.activeTabID, expectedTabID, file: file, line: line)
    XCTAssertEqual(state.activeTab.id, expectedTabID, file: file, line: line)
    XCTAssertEqual(
        state.activeTab.document.id,
        expectedDocumentID,
        file: file,
        line: line
    )
    XCTAssertEqual(
        state.activeTab.document.title,
        "Untitled",
        file: file,
        line: line
    )
    XCTAssertEqual(state.activeTab.document.text, "", file: file, line: line)
    XCTAssertNil(state.activeTab.document.fileBinding, file: file, line: line)
    XCTAssertNil(
        state.activeTab.document.recoveryFileReference,
        file: file,
        line: line
    )
    XCTAssertNil(
        state.activeTab.document.fileConflict,
        file: file,
        line: line
    )
    XCTAssertFalse(state.activeTab.document.isUnsaved, file: file, line: line)
    XCTAssertEqual(
        state.activeTab.document.recoveryState,
        .clean,
        file: file,
        line: line
    )
}

private func makeCloseFileBinding(
    suffix: UInt8,
    path: String
) throws -> FileBinding {
    let encodedFile = try encodeNewTextFile(text: "Bound content")
    return FileBinding(
        locatorURL: URL(fileURLWithPath: path),
        bookmark: try FileBookmark(data: Data([suffix])),
        identity: FileIdentity(
            volumeUUID: UUID(
                uuid: (0xA2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
            ),
            documentIdentifier: Int(suffix)
        ),
        displayName: try ValidatedFileName(
            validating: URL(fileURLWithPath: path).lastPathComponent
        ),
        digest: encodedFile.digest,
        encoding: encodedFile.encoding,
        lineEnding: encodedFile.lineEnding
    )
}

private func closeDocumentID(_ suffix: UInt8) -> DocumentID {
    DocumentID(
        rawValue: UUID(
            uuid: (0xA0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}

private func closeTabID(_ suffix: UInt8) -> TabID {
    TabID(
        rawValue: UUID(
            uuid: (0xA1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)
        )
    )
}
