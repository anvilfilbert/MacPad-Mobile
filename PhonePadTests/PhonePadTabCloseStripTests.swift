import Foundation
import PhonePadCore
import XCTest
@testable import PhonePad

final class PhonePadTabCloseStripTests: XCTestCase {
    func testActiveCloseControlMapsStableIdentifierAndCloseAction() throws {
        let tabID = try makeTabID()

        let control = phonePadActiveTabCloseControl(tabID: tabID)

        XCTAssertEqual(control.action, .close(tabID))
        XCTAssertEqual(
            control.accessibilityIdentifier,
            "phonepad.tab.close.abcdef00-1234-5678-90ab-cdef12345678"
        )
    }

    func testContextCloseControlUsesMenuSpecificIdentifier() throws {
        let tabID = try makeTabID()

        let control = phonePadTabContextCloseControl(tabID: tabID)

        XCTAssertEqual(control.action, .close(tabID))
        XCTAssertEqual(
            control.accessibilityIdentifier,
            "phonepad.tab.menu.close.abcdef00-1234-5678-90ab-cdef12345678"
        )
    }

    func testContextCloseOtherTabsControlMapsStableIdentifierAndAction() throws {
        let tabID = try makeTabID()

        let control = phonePadTabContextCloseOtherTabsControl(tabID: tabID)

        XCTAssertEqual(control.action, .closeOthers(tabID))
        XCTAssertEqual(
            control.accessibilityIdentifier,
            "phonepad.tab.close-others.abcdef00-1234-5678-90ab-cdef12345678"
        )
    }

    func testCloseActionsDispatchOnlyToTheirMatchingCallbacks() throws {
        let tabID = try makeTabID()
        var closedTabIDs: [TabID] = []
        var closeOtherTabIDs: [TabID] = []
        let recordClose: (TabID) -> Void = { closedTabIDs.append($0) }
        let recordCloseOthers: (TabID) -> Void = { closeOtherTabIDs.append($0) }

        performPhonePadTabCloseAction(
            .close(tabID),
            onClose: recordClose,
            onCloseOthers: recordCloseOthers
        )
        performPhonePadTabCloseAction(
            .closeOthers(tabID),
            onClose: recordClose,
            onCloseOthers: recordCloseOthers
        )

        XCTAssertEqual(closedTabIDs, [tabID])
        XCTAssertEqual(closeOtherTabIDs, [tabID])
    }

    private func makeTabID() throws -> TabID {
        TabID(
            rawValue: try XCTUnwrap(
                UUID(uuidString: "ABCDEF00-1234-5678-90AB-CDEF12345678")
            )
        )
    }
}
