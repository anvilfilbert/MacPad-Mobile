import Foundation
import XCTest

@testable import PhonePadCore

final class TextFileCodecTests: XCTestCase {
    func testDecodeStrictUTF8ReturnsNormalizedDocumentMetadata() throws {
        let source = Data([0x61, 0x62, 0x63])

        let decoded = try decodeSupportedTextFile(data: source)

        XCTAssertEqual(decoded.text, "abc")
        XCTAssertEqual(decoded.digest.bytes, Data([
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
            0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
            0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
            0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
        ]))
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertEqual(decoded.lineEnding, .lf)
    }

    func testDecodeNormalizesMixedEndingsAndUsesFirstObservedTie() throws {
        let source = Data([
            0x46, 0x69, 0x72, 0x73, 0x74, 0x0d, 0x0a,
            0x53, 0x65, 0x63, 0x6f, 0x6e, 0x64, 0x0d,
            0x54, 0x68, 0x69, 0x72, 0x64, 0x0a,
        ])

        let decoded = try decodeSupportedTextFile(data: source)

        XCTAssertEqual(decoded.text, "First\nSecond\nThird\n")
        XCTAssertEqual(decoded.lineEnding, .crlf)
    }

    func testDecodeUTF8BOMRemovesOnlyTheLeadingMarker() throws {
        let source = Data([
            0xef, 0xbb, 0xbf,
            0x41, 0x0d, 0x0a, 0x42,
            0xef, 0xbb, 0xbf,
        ])

        let decoded = try decodeSupportedTextFile(data: source)

        XCTAssertEqual(decoded.text, "A\nB\u{feff}")
        XCTAssertEqual(decoded.encoding, .utf8WithBOM)
        XCTAssertEqual(decoded.lineEnding, .crlf)
    }

    func testDecodeUTF8BOMPreservesDocumentLeadingBOMScalar() throws {
        let decoded = try decodeSupportedTextFile(
            data: Data([0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x41])
        )

        XCTAssertEqual(decoded.text, "\u{feff}A")
        XCTAssertEqual(decoded.encoding, .utf8WithBOM)
    }

    func testDecodeRejectsUTF32MarkersBeforeUTF16Detection() {
        let utf32BigEndian = Data([0x00, 0x00, 0xfe, 0xff, 0x00, 0x00, 0x00, 0x41])
        let utf32LittleEndian = Data([0xff, 0xfe, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])

        assertDecodeFails(
            data: utf32BigEndian,
            expectedError: .unsupportedContent(.utf32)
        )
        assertDecodeFails(
            data: utf32LittleEndian,
            expectedError: .unsupportedContent(.utf32)
        )
    }

    func testDecodeMarkedUTF16LittleEndianRequiresExactBodyRoundTrip() throws {
        let source = Data([
            0xff, 0xfe,
            0x41, 0x00,
            0xac, 0x20,
            0x0d, 0x00, 0x0a, 0x00,
            0x42, 0x00,
        ])

        let decoded = try decodeSupportedTextFile(data: source)

        XCTAssertEqual(decoded.text, "A€\nB")
        XCTAssertEqual(decoded.encoding, .utf16LittleEndianWithBOM)
        XCTAssertEqual(decoded.lineEnding, .crlf)
    }

    func testDecodeMarkedUTF16BigEndianRequiresExactBodyRoundTrip() throws {
        let source = Data([
            0xfe, 0xff,
            0x00, 0x41,
            0x20, 0xac,
            0x00, 0x0d,
            0x00, 0x42,
        ])

        let decoded = try decodeSupportedTextFile(data: source)

        XCTAssertEqual(decoded.text, "A€\nB")
        XCTAssertEqual(decoded.encoding, .utf16BigEndianWithBOM)
        XCTAssertEqual(decoded.lineEnding, .cr)
    }

    func testDecodeLegacyBytesUsesWindows1252BeforeISO88591Fallback() throws {
        let windows = try decodeSupportedTextFile(
            data: Data([0x43, 0x61, 0x66, 0xe9, 0x20, 0x80])
        )
        let iso = try decodeSupportedTextFile(data: Data([0x41, 0x81, 0x42]))

        XCTAssertEqual(windows.text, "Café €")
        XCTAssertEqual(windows.encoding, .windows1252)
        XCTAssertEqual(iso.text, "A\u{0081}B")
        XCTAssertEqual(iso.encoding, .iso88591)
    }

    func testDecodeRejectsKnownRichAndBinarySignatures() {
        let fixtures: [(Data, UnsupportedTextFileKind)] = [
            (Data([0x7b, 0x5c, 0x72, 0x74, 0x66, 0x31]), .richText),
            (Data([0x7b, 0x5c, 0x75, 0x72, 0x74, 0x66, 0x31]), .richText),
            (Data([0x25, 0x50, 0x44, 0x46, 0x2d]), .pdf),
            (Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30]), .binaryPropertyList),
            (Data([0x50, 0x4b, 0x03, 0x04]), .zipArchive),
            (Data([0x50, 0x4b, 0x05, 0x06]), .zipArchive),
            (Data([0x50, 0x4b, 0x07, 0x08]), .zipArchive),
            (Data([0x1f, 0x8b]), .gzipArchive),
            (Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), .rasterImage),
            (Data([0xff, 0xd8, 0xff]), .rasterImage),
            (Data([0x47, 0x49, 0x46, 0x38, 0x37, 0x61]), .rasterImage),
            (Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]), .rasterImage),
            (Data([0x49, 0x49, 0x2a, 0x00]), .rasterImage),
            (Data([0x4d, 0x4d, 0x00, 0x2a]), .rasterImage),
            (Data([0x42, 0x4d]), .rasterImage),
            (Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]), .rasterImage),
            (Data([0xfe, 0xed, 0xfa, 0xce]), .machOExecutable),
            (Data([0xce, 0xfa, 0xed, 0xfe]), .machOExecutable),
            (Data([0xfe, 0xed, 0xfa, 0xcf]), .machOExecutable),
            (Data([0xcf, 0xfa, 0xed, 0xfe]), .machOExecutable),
            (Data([0xca, 0xfe, 0xba, 0xbe]), .machOExecutable),
            (Data([0xbe, 0xba, 0xfe, 0xca]), .machOExecutable),
            (Data([0xca, 0xfe, 0xba, 0xbf]), .machOExecutable),
            (Data([0xbf, 0xba, 0xfe, 0xca]), .machOExecutable),
        ]

        for fixture in fixtures {
            assertDecodeFails(
                data: fixture.0,
                expectedError: .unsupportedContent(fixture.1)
            )
        }
    }

    func testDecodeRejectsDecodedRichHeaderAfterLeadingWhitespace() {
        assertDecodeFails(
            data: Data(" \n\t{\\rtf1 ordinary legacy-looking text}".utf8),
            expectedError: .unsupportedContent(.richText)
        )
    }

    func testDecodeDoesNotRejectPlainTextThatOnlyStartsLikeAPropertyList() throws {
        let decoded = try decodeSupportedTextFile(data: Data("bplist notes".utf8))

        XCTAssertEqual(decoded.text, "bplist notes")
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testDecodeRejectsNullAndExactControlHeavyThreshold() throws {
        assertDecodeFails(
            data: Data([0x41, 0x00, 0x42]),
            expectedError: .containsNullScalar
        )
        let eightControls = Data(repeating: 0x01, count: 8) + Data(repeating: 0x41, count: 92)
        let nineControls = Data(repeating: 0x01, count: 9) + Data(repeating: 0x41, count: 91)

        XCTAssertNoThrow(try decodeSupportedTextFile(data: eightControls))
        assertDecodeFails(
            data: nineControls,
            expectedError: .binaryLike(controlScalarCount: 9, totalScalarCount: 100)
        )
        let exactlyOnePercent = Data(repeating: 0x01, count: 9)
            + Data(repeating: 0x41, count: 891)
        XCTAssertNoThrow(try decodeSupportedTextFile(data: exactlyOnePercent))
    }

    func testDecodeRejectsOnlyInputAboveExactMaximum() throws {
        let maximum = Data(repeating: 0x61, count: maximumSupportedTextFileByteCount)
        XCTAssertNoThrow(try decodeSupportedTextFile(data: maximum))
        assertDecodeFails(
            data: maximum + Data([0x61]),
            expectedError: .contentTooLarge(
                actualByteCount: maximumSupportedTextFileByteCount + 1,
                maximumByteCount: maximumSupportedTextFileByteCount
            )
        )
    }

    func testEncodeEverySupportedRepresentationUsesExactKnownBytes() throws {
        let fixtures: [(TextFileEncoding, TextLineEnding, String, Data)] = [
            (.utf8, .lf, "Café\n", Data([0x43, 0x61, 0x66, 0xc3, 0xa9, 0x0a])),
            (.utf8WithBOM, .crlf, "A\nB", Data([0xef, 0xbb, 0xbf, 0x41, 0x0d, 0x0a, 0x42])),
            (.utf16LittleEndianWithBOM, .cr, "A\n€", Data([0xff, 0xfe, 0x41, 0x00, 0x0d, 0x00, 0xac, 0x20])),
            (.utf16BigEndianWithBOM, .lf, "A\n€", Data([0xfe, 0xff, 0x00, 0x41, 0x00, 0x0a, 0x20, 0xac])),
            (.windows1252, .lf, "€\n", Data([0x80, 0x0a])),
            (.iso88591, .lf, "£\n", Data([0xa3, 0x0a])),
        ]

        for fixture in fixtures {
            let encoded = try encodeTextFile(
                text: fixture.2,
                encoding: fixture.0,
                lineEnding: fixture.1
            )
            XCTAssertEqual(encoded.text, fixture.2)
            XCTAssertEqual(encoded.data, fixture.3)
            XCTAssertEqual(encoded.encoding, fixture.0)
            XCTAssertEqual(encoded.lineEnding, fixture.1)
            XCTAssertEqual(try decodeSupportedTextFile(data: encoded.data).text, fixture.2)
        }
    }

    func testEncodeExplicitISO88591PreservesAmbiguousC1Scalar() throws {
        let encoded = try encodeTextFile(
            text: "\u{0080}",
            encoding: .iso88591,
            lineEnding: .lf
        )

        XCTAssertEqual(encoded.data, Data([0x80]))
        XCTAssertEqual(encoded.text, "\u{0080}")
        XCTAssertEqual(encoded.encoding, .iso88591)
    }

    func testEncodeExplicitWindows1252PreservesBytesThatAlsoFormUTF8() throws {
        let encoded = try encodeTextFile(
            text: "Ã©",
            encoding: .windows1252,
            lineEnding: .lf
        )

        XCTAssertEqual(encoded.data, Data([0xc3, 0xa9]))
        XCTAssertEqual(encoded.text, "Ã©")
    }

    func testEncodeDocumentLeadingBOMRequiresUTF8BOMRepresentation() throws {
        assertEncodeFails(
            text: "\u{feff}A",
            encoding: .utf8,
            lineEnding: .lf,
            expectedError: .unrepresentable(encoding: .utf8)
        )

        let encoded = try encodeTextFile(
            text: "\u{feff}A",
            encoding: .utf8WithBOM,
            lineEnding: .lf
        )
        XCTAssertEqual(
            encoded.data,
            Data([0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x41])
        )
        XCTAssertEqual(try decodeSupportedTextFile(data: encoded.data).text, "\u{feff}A")
    }

    func testEncodeMarkerlessRepresentationsRejectLeadingBOMBytes() {
        let fixtures: [(String, TextFileEncoding)] = [
            ("ï»¿A", .windows1252),
            ("ÿþA", .iso88591),
            ("þÿA", .iso88591),
        ]

        for fixture in fixtures {
            assertEncodeFails(
                text: fixture.0,
                encoding: fixture.1,
                lineEnding: .lf,
                expectedError: .unrepresentable(encoding: fixture.1)
            )
        }
    }

    func testEncodeRejectsUnrepresentableNullControlHeavyAndOversizedOutput() {
        assertEncodeFails(
            text: "Emoji 😀",
            encoding: .windows1252,
            lineEnding: .lf,
            expectedError: .unrepresentable(encoding: .windows1252)
        )
        assertEncodeFails(
            text: "A\0B",
            encoding: .utf8,
            lineEnding: .lf,
            expectedError: .containsNullScalar
        )
        let binaryLike = String(repeating: "\u{0001}", count: 9)
            + String(repeating: "A", count: 91)
        assertEncodeFails(
            text: binaryLike,
            encoding: .utf8,
            lineEnding: .lf,
            expectedError: .binaryLike(controlScalarCount: 9, totalScalarCount: 100)
        )
        assertEncodeFails(
            text: String(repeating: "a\n", count: maximumSupportedTextFileByteCount / 2),
            encoding: .utf8,
            lineEnding: .crlf,
            expectedError: .contentTooLarge(
                encoding: .utf8,
                actualByteCount: maximumSupportedTextFileByteCount
                    + maximumSupportedTextFileByteCount / 2,
                maximumByteCount: maximumSupportedTextFileByteCount
            )
        )
    }

    func testEncodeAcceptsExactMaximumAndRejectsOneByteMore() throws {
        let exactText = String(repeating: "a", count: maximumSupportedTextFileByteCount)
        let exact = try encodeTextFile(
            text: exactText,
            encoding: .utf8,
            lineEnding: .lf
        )

        XCTAssertEqual(exact.data.count, maximumSupportedTextFileByteCount)
        assertEncodeFails(
            text: exactText + "a",
            encoding: .utf8,
            lineEnding: .lf,
            expectedError: .contentTooLarge(
                encoding: .utf8,
                actualByteCount: maximumSupportedTextFileByteCount + 1,
                maximumByteCount: maximumSupportedTextFileByteCount
            )
        )
    }

    func testValidateEditableTextReturnsLFAndRequiresOneBoundedLosslessRepresentation() throws {
        XCTAssertEqual(
            try validateEditableDocumentText(text: "One\r\nTwo\rThree"),
            "One\nTwo\nThree"
        )
        XCTAssertThrowsError(
            try validateEditableDocumentText(
                text: String(repeating: "a", count: maximumSupportedTextFileByteCount + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? EditableDocumentTextError,
                .contentTooLarge(
                    minimumSupportedByteCount: maximumSupportedTextFileByteCount + 1,
                    maximumByteCount: maximumSupportedTextFileByteCount
                )
            )
        }

        let legacySizedText = String(
            repeating: "é",
            count: maximumSupportedTextFileByteCount
        )
        XCTAssertEqual(
            try validateEditableDocumentText(text: legacySizedText).count,
            maximumSupportedTextFileByteCount
        )
    }

    func testValidateEditableTextAcceptsSignatureLeadingTextThatFitsWithUTF8BOM() throws {
        let prefix = "%PDF-"
        let text = prefix + String(
            repeating: "a",
            count: maximumSupportedTextFileByteCount - 3 - prefix.utf8.count
        )

        XCTAssertEqual(
            try validateEditableDocumentText(text: text).utf8.count,
            maximumSupportedTextFileByteCount - 3
        )
    }

    func testValidateEditableTextDoesNotCountLeadingBOMAsMarkerlessUTF8() {
        let text = "\u{feff}" + String(
            repeating: "a",
            count: maximumSupportedTextFileByteCount - 5
        )

        XCTAssertThrowsError(try validateEditableDocumentText(text: text)) { error in
            XCTAssertEqual(
                error as? EditableDocumentTextError,
                .contentTooLarge(
                    minimumSupportedByteCount: maximumSupportedTextFileByteCount + 1,
                    maximumByteCount: maximumSupportedTextFileByteCount
                )
            )
        }
    }

    func testValidateEditableTextDoesNotCountBOMPrefixedLegacyRepresentation() {
        let text = "ï»¿" + String(
            repeating: "é",
            count: maximumSupportedTextFileByteCount - 3
        )

        XCTAssertThrowsError(try validateEditableDocumentText(text: text)) { error in
            XCTAssertEqual(
                error as? EditableDocumentTextError,
                .contentTooLarge(
                    minimumSupportedByteCount: maximumSupportedTextFileByteCount + 1,
                    maximumByteCount: maximumSupportedTextFileByteCount
                )
            )
        }
    }

    func testValidateEditableTextAcceptsMaximumAmbiguousLegacyRepresentation() throws {
        let text = String(
            repeating: "Ã©",
            count: maximumSupportedTextFileByteCount / 2
        )

        XCTAssertEqual(
            try validateEditableDocumentText(text: text).unicodeScalars.count,
            maximumSupportedTextFileByteCount
        )
    }

    func testValidateEditableTextRejectsNullRichAndControlHeavyContent() throws {
        XCTAssertThrowsError(try validateEditableDocumentText(text: "A\0B")) { error in
            XCTAssertEqual(error as? EditableDocumentTextError, .containsNullScalar)
        }
        XCTAssertThrowsError(
            try validateEditableDocumentText(text: " \n\t{\\rtf1 content}")
        ) { error in
            XCTAssertEqual(
                error as? EditableDocumentTextError,
                .unsupportedContent(.richText)
            )
        }
        let binaryLike = String(repeating: "\u{0080}", count: 9)
            + String(repeating: "A", count: 91)
        XCTAssertThrowsError(try validateEditableDocumentText(text: binaryLike)) { error in
            XCTAssertEqual(
                error as? EditableDocumentTextError,
                .binaryLike(controlScalarCount: 9, totalScalarCount: 100)
            )
        }
        let exactThreshold = String(repeating: "\u{0080}", count: 9)
            + String(repeating: "A", count: 891)
        XCTAssertNoThrow(try validateEditableDocumentText(text: exactThreshold))
    }

    private func assertDecodeFails(
        data: Data,
        expectedError: TextFileDecodingError
    ) {
        XCTAssertThrowsError(try decodeSupportedTextFile(data: data)) { error in
            XCTAssertEqual(error as? TextFileDecodingError, expectedError)
        }
    }

    private func assertEncodeFails(
        text: String,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding,
        expectedError: TextFileEncodingError
    ) {
        XCTAssertThrowsError(
            try encodeTextFile(
                text: text,
                encoding: encoding,
                lineEnding: lineEnding
            )
        ) { error in
            XCTAssertEqual(error as? TextFileEncodingError, expectedError)
        }
    }
}
