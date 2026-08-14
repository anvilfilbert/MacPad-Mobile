import Foundation
import XCTest
@testable import PhonePadCore

final class SaveAsModelsTests: XCTestCase {
    func testPreflightPreservesAbsentAndExistingTargetExpectations() throws {
        let directoryBookmark = try FileBookmark(data: Data([0x10, 0x20]))
        let fileName = try ValidatedFileName(validating: "Draft.txt")
        let absentPlan = SaveAsTargetPlan(
            directoryBookmark: directoryBookmark,
            fileName: fileName,
            expectation: .absent
        )
        let snapshot = SaveAsTargetSnapshot(
            identity: FileIdentity(
                volumeUUID: UUID(
                    uuidString: "71000000-0000-0000-0000-000000000001"
                )!,
                documentIdentifier: 71
            ),
            digest: try FileDigest(bytes: Data(repeating: 0x71, count: 32))
        )
        let existingPlan = SaveAsTargetPlan(
            directoryBookmark: directoryBookmark,
            fileName: fileName,
            expectation: .existing(snapshot)
        )

        XCTAssertEqual(SaveAsTargetPreflight.ready(absentPlan).plan, absentPlan)
        XCTAssertEqual(
            SaveAsTargetPreflight.replacementRequired(existingPlan).plan,
            existingPlan
        )
        XCTAssertEqual(
            SaveAsTargetPreflight.currentFile(existingPlan).plan,
            existingPlan
        )
    }

    func testActiveTabClaimsRetainBookmarkWhenStableIdentityIsUnavailable() throws {
        let excludedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
        )
        let claimedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "72000000-0000-0000-0000-000000000002")!
        )
        let initialState = makeInitialPhonePadState(
            documentID: excludedDocumentID,
            tabID: TabID(
                rawValue: UUID(uuidString: "72000000-0000-0000-0000-000000000011")!
            )
        )
        let excludedBinding = try makeBinding(
            path: "/private/provider/Current.txt",
            bookmarkByte: 0x71,
            identity: FileIdentity(
                volumeUUID: UUID(
                    uuidString: "72000000-0000-0000-0000-000000000003"
                )!,
                documentIdentifier: 71
            )
        )
        let stateWithCurrentFile = openBoundDocument(
            state: initialState,
            documentID: excludedDocumentID,
            tabID: TabID(
                rawValue: UUID(uuidString: "72000000-0000-0000-0000-000000000011")!
            ),
            text: "Current",
            fileBinding: excludedBinding
        )
        let claimedBinding = try makeBinding(
            path: "/private/provider/Claimed.txt",
            bookmarkByte: 0x72,
            identity: nil
        )
        let state = openBoundDocument(
            state: stateWithCurrentFile,
            documentID: claimedDocumentID,
            tabID: TabID(
                rawValue: UUID(uuidString: "72000000-0000-0000-0000-000000000012")!
            ),
            text: "Claimed",
            fileBinding: claimedBinding
        )

        let claims = activeTabFileCollisionClaims(state: state)

        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims.first?.documentID, excludedDocumentID)
        XCTAssertEqual(
            claims.last,
            .activeTab(
                documentID: claimedDocumentID,
                reference: FileCollisionReference(
                    bookmark: claimedBinding.bookmark,
                    identity: nil
                )
            )
        )
        XCTAssertEqual(claims.last?.documentID, claimedDocumentID)
        XCTAssertEqual(claims.last?.fileReference?.bookmark, claimedBinding.bookmark)
        XCTAssertNil(claims.last?.fileReference?.identity)
        XCTAssertNil(claims.last?.pendingSaveAsDestination)
    }

    func testPendingSaveAsClaimCarriesOnlyDurableDestination() throws {
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!
        )
        let destination = RecoverySaveAsDestination(
            directoryBookmark: try FileBookmark(data: Data([0x73])),
            fileName: try ValidatedFileName(validating: "Pending.txt")
        )
        let claim = FileCollisionClaim.pendingSaveAs(
            documentID: documentID,
            destination: destination
        )

        XCTAssertEqual(claim.documentID, documentID)
        XCTAssertNil(claim.fileReference)
        XCTAssertEqual(claim.pendingSaveAsDestination, destination)
    }

    private func makeBinding(
        path: String,
        bookmarkByte: UInt8,
        identity: FileIdentity?
    ) throws -> FileBinding {
        FileBinding(
            locatorURL: URL(fileURLWithPath: path),
            bookmark: try FileBookmark(data: Data([bookmarkByte])),
            identity: identity,
            displayName: try ValidatedFileName(validating: "Claimed.txt"),
            digest: try FileDigest(bytes: Data(repeating: bookmarkByte, count: 32)),
            encoding: .utf8,
            lineEnding: .lf
        )
    }
}
