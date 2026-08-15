@testable import PhonePadCore
import XCTest

final class EditorDisplayModelsTests: XCTestCase {
    func testDisplaySettingsDefaultAndRemainIndependentPerTab() throws {
        let firstDocumentID = displayDocumentID(1)
        let firstTabID = displayTabID(1)
        let secondDocumentID = displayDocumentID(2)
        let secondTabID = displayTabID(2)
        let initialState = makeInitialPhonePadState(
            documentID: firstDocumentID,
            tabID: firstTabID
        )

        XCTAssertEqual(
            initialState.activeTab.displaySettings,
            PhonePadTabDisplaySettings.initial
        )

        var state = try createUntitledTab(
            state: initialState,
            documentID: secondDocumentID,
            tabID: secondTabID
        )
        state = try setActiveTabFontFamily(
            state: state,
            fontFamily: .named(postScriptName: "HelveticaNeue")
        )
        state = try setActiveTabZoomPercent(state: state, zoomPercent: 150)
        state = try setActiveTabWordWrapEnabled(state: state, isEnabled: false)
        state = try setActiveTabStatusVisible(state: state, isVisible: false)

        XCTAssertEqual(
            state.activeTab.displaySettings,
            PhonePadTabDisplaySettings(
                fontFamily: .named(postScriptName: "HelveticaNeue"),
                zoomPercent: 150,
                wordWrapEnabled: false,
                statusVisible: false
            )
        )

        state = try selectTab(state: state, tabID: firstTabID)
        XCTAssertEqual(
            state.activeTab.displaySettings,
            PhonePadTabDisplaySettings.initial
        )
    }

    func testZoomValidationAndRenderedPointSizeUseDocumentedBounds() throws {
        let state = makeInitialPhonePadState(
            documentID: displayDocumentID(3),
            tabID: displayTabID(3)
        )

        XCTAssertThrowsError(
            try setActiveTabZoomPercent(state: state, zoomPercent: 70)
        ) { error in
            XCTAssertEqual(
                error as? PhonePadEditorDisplayError,
                .invalidZoomPercent(70)
            )
        }
        XCTAssertThrowsError(
            try setActiveTabZoomPercent(state: state, zoomPercent: 105)
        ) { error in
            XCTAssertEqual(
                error as? PhonePadEditorDisplayError,
                .invalidZoomPercent(105)
            )
        }

        XCTAssertEqual(
            try renderedEditorPointSize(
                dynamicTypeBasePointSize: 10,
                zoomPercent: 80
            ),
            11
        )
        XCTAssertEqual(
            try renderedEditorPointSize(
                dynamicTypeBasePointSize: 14,
                zoomPercent: 150
            ),
            21
        )
        XCTAssertEqual(
            try renderedEditorPointSize(
                dynamicTypeBasePointSize: 30,
                zoomPercent: 500
            ),
            96
        )
    }

    func testTextPositionUsesOneBasedLinesAndColumnsAcrossLineEndings() throws {
        let text = "one\nβeta\r\nlast"

        XCTAssertEqual(
            try editorTextPosition(text: text, utf16Offset: 0),
            EditorTextPosition(line: 1, column: 1)
        )
        XCTAssertEqual(
            try editorTextPosition(text: text, utf16Offset: 6),
            EditorTextPosition(line: 2, column: 3)
        )
        XCTAssertEqual(
            try editorTextPosition(text: text, utf16Offset: 10),
            EditorTextPosition(line: 3, column: 1)
        )
        XCTAssertEqual(
            try editorTextPosition(
                text: text,
                utf16Offset: text.utf16.count
            ),
            EditorTextPosition(line: 3, column: 5)
        )

        XCTAssertThrowsError(
            try editorTextPosition(
                text: text,
                utf16Offset: text.utf16.count + 1
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadEditorDisplayError,
                .textOffsetOutOfBounds(text.utf16.count + 1)
            )
        }
    }

    func testGoToLineReturnsUTF16StartAndRejectsInvalidBounds() throws {
        let text = "one\nβeta\r\nlast"

        XCTAssertEqual(
            try editorUTF16OffsetForLine(text: text, oneBasedLine: 1),
            0
        )
        XCTAssertEqual(
            try editorUTF16OffsetForLine(text: text, oneBasedLine: 2),
            4
        )
        XCTAssertEqual(
            try editorUTF16OffsetForLine(text: text, oneBasedLine: 3),
            10
        )
        XCTAssertEqual(
            try editorUTF16OffsetForLine(text: "", oneBasedLine: 1),
            0
        )

        for invalidLine in [0, 4] {
            XCTAssertThrowsError(
                try editorUTF16OffsetForLine(
                    text: text,
                    oneBasedLine: invalidLine
                )
            ) { error in
                XCTAssertEqual(
                    error as? PhonePadEditorDisplayError,
                    .lineOutOfBounds(requested: invalidLine, available: 3)
                )
            }
        }
    }
}

private func displayDocumentID(_ byte: UInt8) -> DocumentID {
    DocumentID(
        rawValue: UUID(
            uuid: (
                0x73, 0x00, 0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, byte
            )
        )
    )
}

private func displayTabID(_ byte: UInt8) -> TabID {
    TabID(
        rawValue: UUID(
            uuid: (
                0x74, 0x00, 0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, byte
            )
        )
    )
}
