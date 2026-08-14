import Foundation
import XCTest
@testable import PhonePadCore

final class RecoveryPendingSaveTests: XCTestCase {
    func testLegacyPendingSaveDecodesAsBoundDestinationAndKeepsLegacyShape() throws {
        let legacyData = Data(
            #"{"intendedOutputDigest":"ERERERERERERERERERERERERERERERERERERERERERE="}"#.utf8
        )

        let pendingSave = try JSONDecoder().decode(
            RecoveryPendingSave.self,
            from: legacyData
        )
        let encoded = try JSONEncoder().encode(pendingSave)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(
            pendingSave.intendedOutputDigest,
            try FileDigest(bytes: Data(repeating: 0x11, count: 32))
        )
        XCTAssertEqual(pendingSave.destination, .boundFile)
        XCTAssertNil(object["saveAsDestination"])
    }

    func testSaveAsPendingSaveRoundTripsWithoutAFileReferenceOrRawLocator() throws {
        let destination = RecoverySaveAsDestination(
            directoryBookmark: try FileBookmark(
                data: Data("opaque-directory-bookmark".utf8)
            ),
            fileName: try ValidatedFileName(validating: "Recovered Draft.txt")
        )
        let pendingSave = RecoveryPendingSave(
            intendedOutputDigest: try FileDigest(
                bytes: Data(repeating: 0x22, count: 32)
            ),
            destination: .saveAs(destination)
        )
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: DocumentID(
                rawValue: UUID(
                    uuidString: "74000000-0000-0000-0000-000000000001"
                )!
            ),
            title: "Recovered Draft.txt",
            text: "Protected unsaved text",
            editedAt: Date(timeIntervalSince1970: 1_786_733_000),
            fileReference: nil,
            pendingSave: pendingSave
        )

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RecoveryEnvelope.self, from: encoded)
        let serializedText = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(decoded, envelope)
        XCTAssertNil(decoded.fileReference)
        XCTAssertEqual(decoded.pendingSave?.destination, .saveAs(destination))
        XCTAssertFalse(serializedText.contains("file://"))
        XCTAssertFalse(serializedText.contains("/private/"))
    }

    func testSaveAsDestinationRequiresBothBookmarkAndValidatedFileName() throws {
        let malformedData = Data(
            #"{"intendedOutputDigest":"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=","saveAsDestination":{"directoryBookmark":"cw=="}}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(RecoveryPendingSave.self, from: malformedData)
        ) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected missing filename to fail explicitly, received \(error).")
            }
        }
    }
}
