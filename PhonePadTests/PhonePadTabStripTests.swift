import CoreGraphics
import PhonePadCore
import XCTest
@testable import PhonePad

final class PhonePadTabStripTests: XCTestCase {
    func testRegularSizeClassShowsOpenInToolbar() {
        XCTAssertTrue(
            phonePadShowsOpenInToolbar(horizontalSizeClass: .regular)
        )
    }

    func testCompactAndUnspecifiedSizeClassesKeepOpenInActions() {
        XCTAssertFalse(
            phonePadShowsOpenInToolbar(horizontalSizeClass: .compact)
        )
        XCTAssertFalse(
            phonePadShowsOpenInToolbar(horizontalSizeClass: nil)
        )
    }

    func testReorderAccessibilityValueIncludesCurrentPosition() {
        XCTAssertEqual(
            phonePadTabAccessibilityValue(
                title: "Notes",
                tabPosition: 2,
                tabCount: 4
            ),
            "Notes, Tab 2 of 4"
        )
    }

    func testActiveTabScrollAnimationRespectsReduceMotion() {
        XCTAssertNil(
            phonePadTabScrollAnimation(accessibilityReduceMotion: true)
        )
        XCTAssertNotNil(
            phonePadTabScrollAnimation(accessibilityReduceMotion: false)
        )
    }

    func testDropAfterLastRemainingTabMovesDraggedTabToEnd() throws {
        let firstTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let thirdTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

        let placement = try phonePadTabPlacement(
            draggedTabID: secondTabID,
            dropX: 300,
            orderedTabIDs: [firstTabID, secondTabID, thirdTabID],
            tabFrames: [
                firstTabID: CGRect(x: 0, y: 0, width: 100, height: 44),
                secondTabID: CGRect(x: 106, y: 0, width: 100, height: 44),
                thirdTabID: CGRect(x: 212, y: 0, width: 100, height: 44)
            ]
        )

        XCTAssertEqual(placement, .end)
    }

    func testDropBeforeFirstRemainingTabUsesStableAnchor() throws {
        let firstTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let thirdTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

        let placement = try phonePadTabPlacement(
            draggedTabID: thirdTabID,
            dropX: 20,
            orderedTabIDs: [firstTabID, secondTabID, thirdTabID],
            tabFrames: [
                firstTabID: CGRect(x: 0, y: 0, width: 100, height: 44),
                secondTabID: CGRect(x: 106, y: 0, width: 100, height: 44),
                thirdTabID: CGRect(x: 212, y: 0, width: 100, height: 44)
            ]
        )

        XCTAssertEqual(placement, .before(firstTabID))
    }

    func testDropFailsExplicitlyWhenLayoutFrameIsMissing() {
        let firstTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        XCTAssertThrowsError(
            try phonePadTabPlacement(
                draggedTabID: firstTabID,
                dropX: 100,
                orderedTabIDs: [firstTabID, secondTabID],
                tabFrames: [
                    firstTabID: CGRect(x: 0, y: 0, width: 100, height: 44)
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadTabPlacementError,
                .tabFrameMissing(secondTabID)
            )
        }
    }

    func testAccessibilityMoveEarlierUsesPreviousStableAnchor() throws {
        let firstTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let thirdTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

        let placement = try phonePadAdjacentTabPlacement(
            tabID: thirdTabID,
            direction: .earlier,
            orderedTabIDs: [firstTabID, secondTabID, thirdTabID]
        )

        XCTAssertEqual(placement, .before(secondTabID))
    }

    func testAccessibilityMoveLaterUsesFollowingStableAnchorOrEnd() throws {
        let firstTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let thirdTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let fourthTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

        let middlePlacement = try phonePadAdjacentTabPlacement(
            tabID: secondTabID,
            direction: .later,
            orderedTabIDs: [firstTabID, secondTabID, thirdTabID, fourthTabID]
        )
        let endPlacement = try phonePadAdjacentTabPlacement(
            tabID: secondTabID,
            direction: .later,
            orderedTabIDs: [firstTabID, secondTabID, thirdTabID]
        )

        XCTAssertEqual(middlePlacement, .before(fourthTabID))
        XCTAssertEqual(endPlacement, .end)
    }

    func testAccessibilityMoveAtBoundaryDoesNothing() throws {
        let firstTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        let earlierPlacement = try phonePadAdjacentTabPlacement(
            tabID: firstTabID,
            direction: .earlier,
            orderedTabIDs: [firstTabID, secondTabID]
        )
        let laterPlacement = try phonePadAdjacentTabPlacement(
            tabID: secondTabID,
            direction: .later,
            orderedTabIDs: [firstTabID, secondTabID]
        )

        XCTAssertNil(earlierPlacement)
        XCTAssertNil(laterPlacement)
    }

    func testAccessibilityMoveFailsExplicitlyWhenTabIsMissing() {
        let missingTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let existingTabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        XCTAssertThrowsError(
            try phonePadAdjacentTabPlacement(
                tabID: missingTabID,
                direction: .earlier,
                orderedTabIDs: [existingTabID]
            )
        ) { error in
            XCTAssertEqual(
                error as? PhonePadTabPlacementError,
                .draggedTabMissing(missingTabID)
            )
        }
    }
}
