import CryptoKit
import Foundation

public struct DecodedTextFile: Equatable, Sendable {
    public let text: String
    public let digest: FileDigest
    public let encoding: TextFileEncoding
    public let lineEnding: TextLineEnding

    init(
        text: String,
        digest: FileDigest,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding
    ) {
        self.text = text
        self.digest = digest
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

public enum UnsupportedTextFileKind: String, Equatable, Sendable {
    case utf32
    case richText
    case pdf
    case binaryPropertyList
    case zipArchive
    case gzipArchive
    case rasterImage
    case machOExecutable
}

public enum TextFileDecodingError: Error, Equatable, Sendable {
    case contentTooLarge(actualByteCount: Int, maximumByteCount: Int)
    case unsupportedContent(UnsupportedTextFileKind)
    case unsupportedEncoding
    case containsNullScalar
    case binaryLike(controlScalarCount: Int, totalScalarCount: Int)
}

extension TextFileDecodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .contentTooLarge(actualByteCount, maximumByteCount):
            return "Selected File is \(actualByteCount) bytes; PhonePad supports at most \(maximumByteCount) bytes. Choose a smaller plain-text File."
        case let .unsupportedContent(kind):
            return "Selected File has a recognized unsupported \(kind.description). Choose a plain-text File."
        case .unsupportedEncoding:
            return "Selected File is not lossless UTF-8, marked UTF-16, Windows-1252, or ISO-8859-1 text. Convert it to a supported text encoding first."
        case .containsNullScalar:
            return "Selected File contains a null character and is not accepted as plain text."
        case let .binaryLike(controlScalarCount, totalScalarCount):
            return "Selected File contains \(controlScalarCount) disallowed control characters among \(totalScalarCount) characters and appears to be binary data."
        }
    }
}

public enum TextFileEncodingError: Error, Equatable, Sendable {
    case unrepresentable(encoding: TextFileEncoding)
    case contentTooLarge(
        encoding: TextFileEncoding,
        actualByteCount: Int,
        maximumByteCount: Int
    )
    case unsupportedContent(UnsupportedTextFileKind)
    case containsNullScalar
    case binaryLike(controlScalarCount: Int, totalScalarCount: Int)
}

extension TextFileEncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unrepresentable(encoding):
            return "Document cannot be represented losslessly as \(encoding.description). Choose another encoding or remove unsupported characters."
        case let .contentTooLarge(encoding, actualByteCount, maximumByteCount):
            return "Document requires \(actualByteCount) bytes as \(encoding.description); PhonePad supports at most \(maximumByteCount) bytes. Shorten the Document or choose a smaller encoding."
        case let .unsupportedContent(kind):
            return "Encoded Document would be recognized as unsupported \(kind.description) instead of plain text. Change its leading content or choose another encoding."
        case .containsNullScalar:
            return "Document contains a null character, which PhonePad does not save as plain text. Remove it before saving."
        case let .binaryLike(controlScalarCount, totalScalarCount):
            return "Document contains \(controlScalarCount) disallowed control characters among \(totalScalarCount) characters and cannot be saved as plain text."
        }
    }
}

public enum EditableDocumentTextError: Error, Equatable, Sendable {
    case unsupportedContent(UnsupportedTextFileKind)
    case containsNullScalar
    case binaryLike(controlScalarCount: Int, totalScalarCount: Int)
    case contentTooLarge(
        minimumSupportedByteCount: Int,
        maximumByteCount: Int
    )
}

extension EditableDocumentTextError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedContent(kind):
            return "Document begins with recognized unsupported \(kind.description) content. Change it before editing as plain text."
        case .containsNullScalar:
            return "Document contains a null character, which PhonePad does not edit as plain text. Remove it before continuing."
        case let .binaryLike(controlScalarCount, totalScalarCount):
            return "Document contains \(controlScalarCount) disallowed control characters among \(totalScalarCount) characters and is not accepted as plain text."
        case let .contentTooLarge(minimumSupportedByteCount, maximumByteCount):
            return "Document requires at least \(minimumSupportedByteCount) bytes in a supported encoding; PhonePad supports at most \(maximumByteCount) bytes. Shorten it before continuing."
        }
    }
}

public func decodeSupportedTextFile(data: Data) throws -> DecodedTextFile {
    let decoded = try decodeTextFileData(data: data)
    return DecodedTextFile(
        text: decoded.text,
        digest: try digest(data: data),
        encoding: decoded.encoding,
        lineEnding: decoded.lineEnding
    )
}

public func encodeTextFile(
    text: String,
    encoding: TextFileEncoding,
    lineEnding: TextLineEnding
) throws -> EncodedTextFile {
    let normalized = normalizeLineEndings(text: text)
    do {
        try validateTextContent(text: normalized.text)
    } catch let error as TextContentValidationError {
        throw encodingError(validationError: error)
    }
    let renderedText = renderLineEndings(
        normalizedText: normalized.text,
        lineEnding: lineEnding
    )
    guard let data = encodeExactly(text: renderedText, encoding: encoding) else {
        throw TextFileEncodingError.unrepresentable(encoding: encoding)
    }
    guard data.count <= maximumSupportedTextFileByteCount else {
        throw TextFileEncodingError.contentTooLarge(
            encoding: encoding,
            actualByteCount: data.count,
            maximumByteCount: maximumSupportedTextFileByteCount
        )
    }
    if isUTF32Marked(data: data) {
        throw TextFileEncodingError.unsupportedContent(.utf32)
    }
    if let kind = unsupportedTextFileKind(data: data) {
        throw TextFileEncodingError.unsupportedContent(kind)
    }
    switch encoding {
    case .utf8, .windows1252, .iso88591:
        if startsWithSupportedByteOrderMark(data: data) {
            throw TextFileEncodingError.unrepresentable(encoding: encoding)
        }
    case .utf8WithBOM,
         .utf16LittleEndianWithBOM,
         .utf16BigEndianWithBOM:
        break
    }
    guard decodeExplicitlyEncodedText(data: data, encoding: encoding) == renderedText else {
        throw TextFileEncodingError.unrepresentable(encoding: encoding)
    }
    return EncodedTextFile(
        text: normalized.text,
        data: data,
        digest: try digest(data: data),
        encoding: encoding,
        lineEnding: lineEnding
    )
}

public func validateEditableDocumentText(text: String) throws -> String {
    let analysis: EditableTextAnalysis
    do {
        analysis = try analyzeEditableText(text: text)
    } catch let error as TextContentValidationError {
        throw editableTextError(validationError: error)
    }
    guard analysis.hasBoundedSupportedRepresentation else {
        throw EditableDocumentTextError.contentTooLarge(
            minimumSupportedByteCount: analysis.minimumSupportedByteCount,
            maximumByteCount: maximumSupportedTextFileByteCount
        )
    }
    return normalizeLineEndings(text: text).text
}

private struct TextFileDataDecoding {
    let text: String
    let encoding: TextFileEncoding
    let lineEnding: TextLineEnding
}

private enum TextContentValidationError: Error {
    case unsupportedContent(UnsupportedTextFileKind)
    case containsNullScalar
    case binaryLike(controlScalarCount: Int, totalScalarCount: Int)
}

private struct NormalizedLineEndings {
    let text: String
    let dominantLineEnding: TextLineEnding
}

private struct EditableTextAnalysis {
    let minimumSupportedByteCount: Int
    let hasBoundedSupportedRepresentation: Bool
}

private struct EditableTextContentMetrics {
    let normalizedUTF8ByteCount: Int
}

private struct TextContentScan {
    let utf8ByteCount: Int
    let scalarCount: Int
    let crlfCount: Int
    let controlScalarCount: Int
    let containsNullScalar: Bool
    let leadingContentScalars: [UInt32]
}

private func analyzeEditableText(text: String) throws -> EditableTextAnalysis {
    let maximumPlusOne = maximumSupportedTextFileByteCount + 1
    let contentMetrics = try validateAndMeasureEditableTextContent(text: text)
    let utf8ByteCount = min(contentMetrics.normalizedUTF8ByteCount, maximumPlusOne)
    let utf8WithBOMByteCount = addCappedByteCount(
        utf8ByteCount,
        3,
        cap: maximumPlusOne
    )
    let utf8Prefix = normalizedUTF8Prefix(text: text)
    let utf8PrefixIsAllowed = rawMarkerlessPrefixIsAllowed(prefix: utf8Prefix)
    if (utf8ByteCount <= maximumSupportedTextFileByteCount && utf8PrefixIsAllowed)
        || utf8WithBOMByteCount <= maximumSupportedTextFileByteCount {
        return EditableTextAnalysis(
            minimumSupportedByteCount: min(utf8ByteCount, utf8WithBOMByteCount),
            hasBoundedSupportedRepresentation: true
        )
    }

    var utf16LittleEndianByteCount = 2
    var windows1252ByteCount = 0
    var iso88591ByteCount = 0
    var windows1252IsRepresentable = true
    var iso88591IsRepresentable = true
    var windows1252Prefix: [UInt8] = []
    var iso88591Prefix: [UInt8] = []
    var skipLineFeedAfterCarriageReturn = false
    for sourceScalar in text.unicodeScalars {
        if skipLineFeedAfterCarriageReturn,
           sourceScalar.value == 0x0a {
            skipLineFeedAfterCarriageReturn = false
            continue
        }
        skipLineFeedAfterCarriageReturn = sourceScalar.value == 0x0d
        let scalar: Unicode.Scalar
        if sourceScalar.value == 0x0d {
            scalar = "\n"
        } else {
            scalar = sourceScalar
        }
        utf16LittleEndianByteCount = addCappedByteCount(
            utf16LittleEndianByteCount,
            scalar.value <= 0xffff ? 2 : 4,
            cap: maximumPlusOne
        )

        if windows1252IsRepresentable,
           let byte = windows1252Byte(scalar: scalar) {
            windows1252ByteCount = addCappedByteCount(
                windows1252ByteCount,
                1,
                cap: maximumPlusOne
            )
            appendEncodedPrefix(byte: byte, prefix: &windows1252Prefix)
        } else {
            windows1252IsRepresentable = false
        }

        if iso88591IsRepresentable, scalar.value <= UInt8.max {
            let byte = UInt8(scalar.value)
            iso88591ByteCount = addCappedByteCount(
                iso88591ByteCount,
                1,
                cap: maximumPlusOne
            )
            appendEncodedPrefix(byte: byte, prefix: &iso88591Prefix)
        } else {
            iso88591IsRepresentable = false
        }
    }

    var candidateByteCounts: [Int] = [utf8WithBOMByteCount, utf16LittleEndianByteCount]
    if utf8PrefixIsAllowed {
        candidateByteCounts.append(utf8ByteCount)
    }
    var hasBoundedSupportedRepresentation =
        utf16LittleEndianByteCount <= maximumSupportedTextFileByteCount
    if windows1252IsRepresentable {
        if rawMarkerlessPrefixIsAllowed(prefix: windows1252Prefix) {
            candidateByteCounts.append(windows1252ByteCount)
            if windows1252ByteCount <= maximumSupportedTextFileByteCount {
                hasBoundedSupportedRepresentation = true
            }
        }
    }
    if iso88591IsRepresentable {
        if rawMarkerlessPrefixIsAllowed(prefix: iso88591Prefix) {
            candidateByteCounts.append(iso88591ByteCount)
            if iso88591ByteCount <= maximumSupportedTextFileByteCount {
                hasBoundedSupportedRepresentation = true
            }
        }
    }
    return EditableTextAnalysis(
        minimumSupportedByteCount: candidateByteCounts.min() ?? maximumPlusOne,
        hasBoundedSupportedRepresentation: hasBoundedSupportedRepresentation
    )
}

private func validateAndMeasureEditableTextContent(
    text: String
) throws -> EditableTextContentMetrics {
    let scan = scanTextContent(text: text)
    let normalizedScalarCount = scan.scalarCount - scan.crlfCount
    try validateTextContent(scan: scan, totalScalarCount: normalizedScalarCount)
    return EditableTextContentMetrics(
        normalizedUTF8ByteCount: scan.utf8ByteCount - scan.crlfCount
    )
}

private func scanTextContent(text: String) -> TextContentScan {
    var utf8ByteCount = 0
    var scalarCount = 0
    var crlfCount = 0
    var controlScalarCount = 0
    var containsNullScalar = false
    var previousByte: UInt8?

    for byte in text.utf8 {
        utf8ByteCount += 1
        if byte & 0xc0 != 0x80 {
            scalarCount += 1
        }
        if byte == 0 {
            containsNullScalar = true
        }
        switch byte {
        case 0x00...0x08, 0x0b, 0x0e...0x1f, 0x7f:
            controlScalarCount += 1
        case 0x80...0x9f where previousByte == 0xc2:
            controlScalarCount += 1
        default:
            break
        }
        if byte == 0x0a, previousByte == 0x0d {
            crlfCount += 1
        }
        previousByte = byte
    }
    return TextContentScan(
        utf8ByteCount: utf8ByteCount,
        scalarCount: scalarCount,
        crlfCount: crlfCount,
        controlScalarCount: controlScalarCount,
        containsNullScalar: containsNullScalar,
        leadingContentScalars: leadingContentPrefix(text: text)
    )
}

private func validateTextContent(
    scan: TextContentScan,
    totalScalarCount: Int
) throws {
    if scan.containsNullScalar {
        throw TextContentValidationError.containsNullScalar
    }
    if scan.leadingContentScalars.starts(with: [0x7b, 0x5c, 0x72, 0x74, 0x66])
        || scan.leadingContentScalars.starts(with: [0x7b, 0x5c, 0x75, 0x72, 0x74, 0x66]) {
        throw TextContentValidationError.unsupportedContent(.richText)
    }
    if scan.controlScalarCount > 8,
       scan.controlScalarCount * 100 > totalScalarCount {
        throw TextContentValidationError.binaryLike(
            controlScalarCount: scan.controlScalarCount,
            totalScalarCount: totalScalarCount
        )
    }
}

private func leadingContentPrefix(text: String) -> [UInt32] {
    var prefix: [UInt32] = []
    for scalar in text.unicodeScalars {
        if prefix.isEmpty,
           CharacterSet.whitespacesAndNewlines.contains(scalar) {
            continue
        }
        prefix.append(scalar.value)
        if prefix.count == 6 {
            break
        }
    }
    return prefix
}

private func normalizedUTF8Prefix(text: String) -> [UInt8] {
    var prefix: [UInt8] = []
    let scalars = text.unicodeScalars
    var index = scalars.startIndex
    while index != scalars.endIndex, prefix.count < 12 {
        let sourceScalar = scalars[index]
        let scalar: Unicode.Scalar
        if sourceScalar.value == 0x0d {
            scalar = "\n"
            let nextIndex = scalars.index(after: index)
            if nextIndex != scalars.endIndex,
               scalars[nextIndex].value == 0x0a {
                index = nextIndex
            }
        } else {
            scalar = sourceScalar
        }
        appendUTF8Prefix(scalar: scalar, prefix: &prefix)
        index = scalars.index(after: index)
    }
    return prefix
}

private func addCappedByteCount(_ count: Int, _ increment: Int, cap: Int) -> Int {
    min(count + increment, cap)
}

private func appendUTF8Prefix(
    scalar: Unicode.Scalar,
    prefix: inout [UInt8]
) {
    guard prefix.count < 12 else {
        return
    }
    let value = scalar.value
    let bytes: [UInt8]
    switch value {
    case 0x00...0x7f:
        bytes = [UInt8(value)]
    case 0x80...0x7ff:
        bytes = [
            0xc0 | UInt8(value >> 6),
            0x80 | UInt8(value & 0x3f),
        ]
    case 0x800...0xffff:
        bytes = [
            0xe0 | UInt8(value >> 12),
            0x80 | UInt8((value >> 6) & 0x3f),
            0x80 | UInt8(value & 0x3f),
        ]
    default:
        bytes = [
            0xf0 | UInt8(value >> 18),
            0x80 | UInt8((value >> 12) & 0x3f),
            0x80 | UInt8((value >> 6) & 0x3f),
            0x80 | UInt8(value & 0x3f),
        ]
    }
    for byte in bytes where prefix.count < 12 {
        prefix.append(byte)
    }
}

private func appendEncodedPrefix(byte: UInt8, prefix: inout [UInt8]) {
    guard prefix.count < 12 else {
        return
    }
    prefix.append(byte)
}

private func rawMarkerlessPrefixIsAllowed(prefix: [UInt8]) -> Bool {
    let data = Data(prefix)
    return !isUTF32Marked(data: data)
        && unsupportedTextFileKind(data: data) == nil
        && !startsWithSupportedByteOrderMark(data: data)
}

private func startsWithSupportedByteOrderMark(data: Data) -> Bool {
    data.starts(with: [0xef, 0xbb, 0xbf])
        || data.starts(with: [0xff, 0xfe])
        || data.starts(with: [0xfe, 0xff])
}

private func decodeTextFileData(data: Data) throws -> TextFileDataDecoding {
    guard data.count <= maximumSupportedTextFileByteCount else {
        throw TextFileDecodingError.contentTooLarge(
            actualByteCount: data.count,
            maximumByteCount: maximumSupportedTextFileByteCount
        )
    }
    if isUTF32Marked(data: data) {
        throw TextFileDecodingError.unsupportedContent(.utf32)
    }
    if let kind = unsupportedTextFileKind(data: data) {
        throw TextFileDecodingError.unsupportedContent(kind)
    }

    let decoded: (text: String, encoding: TextFileEncoding)
    if data.starts(with: [0xef, 0xbb, 0xbf]) {
        guard let text = decodeExactly(
            data: Data(data.dropFirst(3)),
            encoding: .utf8
        ) else {
            throw TextFileDecodingError.unsupportedEncoding
        }
        decoded = (text, .utf8WithBOM)
    } else if data.starts(with: [0xff, 0xfe]) {
        guard let text = decodeUTF16BodyExactly(
            data: Data(data.dropFirst(2)),
            encoding: .utf16LittleEndian
        ) else {
            throw TextFileDecodingError.unsupportedEncoding
        }
        decoded = (text, .utf16LittleEndianWithBOM)
    } else if data.starts(with: [0xfe, 0xff]) {
        guard let text = decodeUTF16BodyExactly(
            data: Data(data.dropFirst(2)),
            encoding: .utf16BigEndian
        ) else {
            throw TextFileDecodingError.unsupportedEncoding
        }
        decoded = (text, .utf16BigEndianWithBOM)
    } else if let text = decodeExactly(data: data, encoding: .utf8) {
        decoded = (text, .utf8)
    } else if let text = decodeWindows1252Exactly(data: data) {
        decoded = (text, .windows1252)
    } else if let text = decodeISO88591(data: data) {
        decoded = (text, .iso88591)
    } else {
        throw TextFileDecodingError.unsupportedEncoding
    }

    do {
        try validateTextContent(text: decoded.text)
    } catch let error as TextContentValidationError {
        throw decodingError(validationError: error)
    }
    let normalized = normalizeLineEndings(text: decoded.text)
    return TextFileDataDecoding(
        text: normalized.text,
        encoding: decoded.encoding,
        lineEnding: normalized.dominantLineEnding
    )
}

private func validateTextContent(text: String) throws {
    let scan = scanTextContent(text: text)
    try validateTextContent(scan: scan, totalScalarCount: scan.scalarCount)
}

private func isUTF32Marked(data: Data) -> Bool {
    data.starts(with: [0x00, 0x00, 0xfe, 0xff])
        || data.starts(with: [0xff, 0xfe, 0x00, 0x00])
}

private func unsupportedTextFileKind(data: Data) -> UnsupportedTextFileKind? {
    if data.starts(with: [0x7b, 0x5c, 0x72, 0x74, 0x66])
        || data.starts(with: [0x7b, 0x5c, 0x75, 0x72, 0x74, 0x66]) {
        return .richText
    }
    if data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2d]) {
        return .pdf
    }
    if data.starts(with: [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30]) {
        return .binaryPropertyList
    }
    if data.starts(with: [0x50, 0x4b, 0x03, 0x04])
        || data.starts(with: [0x50, 0x4b, 0x05, 0x06])
        || data.starts(with: [0x50, 0x4b, 0x07, 0x08]) {
        return .zipArchive
    }
    if data.starts(with: [0x1f, 0x8b]) {
        return .gzipArchive
    }
    if hasRasterImageSignature(data: data) {
        return .rasterImage
    }
    if hasMachOSignature(data: data) {
        return .machOExecutable
    }
    return nil
}

private func hasRasterImageSignature(data: Data) -> Bool {
    data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        || data.starts(with: [0xff, 0xd8, 0xff])
        || data.starts(with: [0x47, 0x49, 0x46, 0x38, 0x37, 0x61])
        || data.starts(with: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        || data.starts(with: [0x49, 0x49, 0x2a, 0x00])
        || data.starts(with: [0x4d, 0x4d, 0x00, 0x2a])
        || data.starts(with: [0x42, 0x4d])
        || (data.starts(with: [0x52, 0x49, 0x46, 0x46])
            && data.dropFirst(8).starts(with: [0x57, 0x45, 0x42, 0x50]))
}

private func hasMachOSignature(data: Data) -> Bool {
    let signatures: [[UInt8]] = [
        [0xfe, 0xed, 0xfa, 0xce],
        [0xce, 0xfa, 0xed, 0xfe],
        [0xfe, 0xed, 0xfa, 0xcf],
        [0xcf, 0xfa, 0xed, 0xfe],
        [0xca, 0xfe, 0xba, 0xbe],
        [0xbe, 0xba, 0xfe, 0xca],
        [0xca, 0xfe, 0xba, 0xbf],
        [0xbf, 0xba, 0xfe, 0xca],
    ]
    return signatures.contains(where: data.starts)
}

private func decodeUTF16BodyExactly(
    data: Data,
    encoding: String.Encoding
) -> String? {
    guard data.count.isMultiple(of: 2) else {
        return nil
    }
    return decodeExactly(data: data, encoding: encoding)
}

private func decodeExactly(
    data: Data,
    encoding: String.Encoding
) -> String? {
    if encoding == .utf8 {
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else {
            return nil
        }
        return text
    }
    guard let text = String(data: data, encoding: encoding),
          let roundTrippedData = text.data(
              using: encoding,
              allowLossyConversion: false
          ),
          roundTrippedData == data else {
        return nil
    }
    return text
}

private func encodeExactly(
    text: String,
    encoding: TextFileEncoding
) -> Data? {
    switch encoding {
    case .windows1252:
        return encodeWindows1252Exactly(text: text)
    case .iso88591:
        return encodeISO88591Exactly(text: text)
    case .utf8, .utf8WithBOM,
         .utf16LittleEndianWithBOM, .utf16BigEndianWithBOM:
        break
    }
    let stringEncoding: String.Encoding
    let byteOrderMark: [UInt8]
    switch encoding {
    case .utf8:
        stringEncoding = .utf8
        byteOrderMark = []
    case .utf8WithBOM:
        stringEncoding = .utf8
        byteOrderMark = [0xef, 0xbb, 0xbf]
    case .utf16LittleEndianWithBOM:
        stringEncoding = .utf16LittleEndian
        byteOrderMark = [0xff, 0xfe]
    case .utf16BigEndianWithBOM:
        stringEncoding = .utf16BigEndian
        byteOrderMark = [0xfe, 0xff]
    case .windows1252, .iso88591:
        preconditionFailure("Legacy encodings return before Foundation encoding selection.")
    }
    guard let body = text.data(
        using: stringEncoding,
        allowLossyConversion: false
    ),
    decodeExactly(data: body, encoding: stringEncoding) == text else {
        return nil
    }
    return Data(byteOrderMark) + body
}

private func decodeExplicitlyEncodedText(
    data: Data,
    encoding: TextFileEncoding
) -> String? {
    switch encoding {
    case .utf8:
        return decodeExactly(data: data, encoding: .utf8)
    case .utf8WithBOM:
        guard data.starts(with: [0xef, 0xbb, 0xbf]) else {
            return nil
        }
        return decodeExactly(data: Data(data.dropFirst(3)), encoding: .utf8)
    case .utf16LittleEndianWithBOM:
        guard data.starts(with: [0xff, 0xfe]) else {
            return nil
        }
        return decodeUTF16BodyExactly(
            data: Data(data.dropFirst(2)),
            encoding: .utf16LittleEndian
        )
    case .utf16BigEndianWithBOM:
        guard data.starts(with: [0xfe, 0xff]) else {
            return nil
        }
        return decodeUTF16BodyExactly(
            data: Data(data.dropFirst(2)),
            encoding: .utf16BigEndian
        )
    case .windows1252:
        return decodeWindows1252Exactly(data: data)
    case .iso88591:
        return decodeISO88591(data: data)
    }
}

private func decodeWindows1252Exactly(data: Data) -> String? {
    var text = ""
    text.reserveCapacity(data.count)
    for byte in data {
        guard let scalar = windows1252Scalar(byte: byte) else {
            return nil
        }
        text.unicodeScalars.append(scalar)
    }
    return text
}

private func decodeISO88591(data: Data) -> String? {
    var text = ""
    text.reserveCapacity(data.count)
    for byte in data {
        guard let scalar = Unicode.Scalar(UInt32(byte)) else {
            return nil
        }
        text.unicodeScalars.append(scalar)
    }
    return text
}

private func encodeWindows1252Exactly(text: String) -> Data? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        guard let byte = windows1252Byte(scalar: scalar) else {
            return nil
        }
        bytes.append(byte)
    }
    return Data(bytes)
}

private func encodeISO88591Exactly(text: String) -> Data? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
        guard scalar.value <= UInt8.max else {
            return nil
        }
        bytes.append(UInt8(scalar.value))
    }
    return Data(bytes)
}

private func windows1252Scalar(byte: UInt8) -> Unicode.Scalar? {
    let scalarValue: UInt32
    switch byte {
    case 0x00...0x7f, 0xa0...0xff:
        scalarValue = UInt32(byte)
    case 0x80: scalarValue = 0x20ac
    case 0x82: scalarValue = 0x201a
    case 0x83: scalarValue = 0x0192
    case 0x84: scalarValue = 0x201e
    case 0x85: scalarValue = 0x2026
    case 0x86: scalarValue = 0x2020
    case 0x87: scalarValue = 0x2021
    case 0x88: scalarValue = 0x02c6
    case 0x89: scalarValue = 0x2030
    case 0x8a: scalarValue = 0x0160
    case 0x8b: scalarValue = 0x2039
    case 0x8c: scalarValue = 0x0152
    case 0x8e: scalarValue = 0x017d
    case 0x91: scalarValue = 0x2018
    case 0x92: scalarValue = 0x2019
    case 0x93: scalarValue = 0x201c
    case 0x94: scalarValue = 0x201d
    case 0x95: scalarValue = 0x2022
    case 0x96: scalarValue = 0x2013
    case 0x97: scalarValue = 0x2014
    case 0x98: scalarValue = 0x02dc
    case 0x99: scalarValue = 0x2122
    case 0x9a: scalarValue = 0x0161
    case 0x9b: scalarValue = 0x203a
    case 0x9c: scalarValue = 0x0153
    case 0x9e: scalarValue = 0x017e
    case 0x9f: scalarValue = 0x0178
    default:
        return nil
    }
    return Unicode.Scalar(scalarValue)
}

private func windows1252Byte(scalar: Unicode.Scalar) -> UInt8? {
    switch scalar.value {
    case 0x00...0x7f, 0xa0...0xff:
        return UInt8(scalar.value)
    case 0x20ac: return 0x80
    case 0x201a: return 0x82
    case 0x0192: return 0x83
    case 0x201e: return 0x84
    case 0x2026: return 0x85
    case 0x2020: return 0x86
    case 0x2021: return 0x87
    case 0x02c6: return 0x88
    case 0x2030: return 0x89
    case 0x0160: return 0x8a
    case 0x2039: return 0x8b
    case 0x0152: return 0x8c
    case 0x017d: return 0x8e
    case 0x2018: return 0x91
    case 0x2019: return 0x92
    case 0x201c: return 0x93
    case 0x201d: return 0x94
    case 0x2022: return 0x95
    case 0x2013: return 0x96
    case 0x2014: return 0x97
    case 0x02dc: return 0x98
    case 0x2122: return 0x99
    case 0x0161: return 0x9a
    case 0x203a: return 0x9b
    case 0x0153: return 0x9c
    case 0x017e: return 0x9e
    case 0x0178: return 0x9f
    default:
        return nil
    }
}

private func renderLineEndings(
    normalizedText: String,
    lineEnding: TextLineEnding
) -> String {
    switch lineEnding {
    case .crlf:
        return normalizedText.replacingOccurrences(of: "\n", with: "\r\n")
    case .lf:
        return normalizedText
    case .cr:
        return normalizedText.replacingOccurrences(of: "\n", with: "\r")
    }
}

private func normalizeLineEndings(text: String) -> NormalizedLineEndings {
    guard text.unicodeScalars.contains(where: { $0.value == 0x0d }) else {
        return NormalizedLineEndings(text: text, dominantLineEnding: .lf)
    }
    var normalizedText = ""
    normalizedText.reserveCapacity(text.utf8.count)
    var lineEndingOrder: [TextLineEnding] = []
    var crlfCount = 0
    var lfCount = 0
    var crCount = 0
    let scalars = text.unicodeScalars
    var index = scalars.startIndex

    while index != scalars.endIndex {
        let scalar = scalars[index]
        if scalar.value == 0x0d {
            let nextIndex = scalars.index(after: index)
            if nextIndex != scalars.endIndex,
               scalars[nextIndex].value == 0x0a {
                if crlfCount == 0 {
                    lineEndingOrder.append(.crlf)
                }
                crlfCount += 1
                normalizedText.append("\n")
                index = scalars.index(after: nextIndex)
                continue
            }
            if crCount == 0 {
                lineEndingOrder.append(.cr)
            }
            crCount += 1
            normalizedText.append("\n")
        } else if scalar.value == 0x0a {
            if lfCount == 0 {
                lineEndingOrder.append(.lf)
            }
            lfCount += 1
            normalizedText.append("\n")
        } else {
            normalizedText.unicodeScalars.append(scalar)
        }
        index = scalars.index(after: index)
    }

    let maximumCount = max(crlfCount, lfCount, crCount)
    guard maximumCount > 0 else {
        return NormalizedLineEndings(text: normalizedText, dominantLineEnding: .lf)
    }
    let dominantLineEnding = lineEndingOrder.first { lineEnding in
        lineEndingCount(
            lineEnding: lineEnding,
            crlfCount: crlfCount,
            lfCount: lfCount,
            crCount: crCount
        ) == maximumCount
    } ?? .lf
    return NormalizedLineEndings(
        text: normalizedText,
        dominantLineEnding: dominantLineEnding
    )
}

private func lineEndingCount(
    lineEnding: TextLineEnding,
    crlfCount: Int,
    lfCount: Int,
    crCount: Int
) -> Int {
    switch lineEnding {
    case .crlf:
        return crlfCount
    case .lf:
        return lfCount
    case .cr:
        return crCount
    }
}

private func digest(data: Data) throws -> FileDigest {
    try FileDigest(bytes: Data(SHA256.hash(data: data)))
}

private func decodingError(
    validationError: TextContentValidationError
) -> TextFileDecodingError {
    switch validationError {
    case let .unsupportedContent(kind):
        return .unsupportedContent(kind)
    case .containsNullScalar:
        return .containsNullScalar
    case let .binaryLike(controlScalarCount, totalScalarCount):
        return .binaryLike(
            controlScalarCount: controlScalarCount,
            totalScalarCount: totalScalarCount
        )
    }
}

private func encodingError(
    validationError: TextContentValidationError
) -> TextFileEncodingError {
    switch validationError {
    case let .unsupportedContent(kind):
        return .unsupportedContent(kind)
    case .containsNullScalar:
        return .containsNullScalar
    case let .binaryLike(controlScalarCount, totalScalarCount):
        return .binaryLike(
            controlScalarCount: controlScalarCount,
            totalScalarCount: totalScalarCount
        )
    }
}

private func editableTextError(
    validationError: TextContentValidationError
) -> EditableDocumentTextError {
    switch validationError {
    case let .unsupportedContent(kind):
        return .unsupportedContent(kind)
    case .containsNullScalar:
        return .containsNullScalar
    case let .binaryLike(controlScalarCount, totalScalarCount):
        return .binaryLike(
            controlScalarCount: controlScalarCount,
            totalScalarCount: totalScalarCount
        )
    }
}

private extension UnsupportedTextFileKind {
    var description: String {
        switch self {
        case .utf32:
            return "UTF-32"
        case .richText:
            return "rich-text"
        case .pdf:
            return "PDF"
        case .binaryPropertyList:
            return "binary property-list"
        case .zipArchive:
            return "ZIP archive"
        case .gzipArchive:
            return "gzip archive"
        case .rasterImage:
            return "raster-image"
        case .machOExecutable:
            return "Mach-O executable"
        }
    }
}

private extension TextFileEncoding {
    var description: String {
        switch self {
        case .utf8:
            return "UTF-8"
        case .utf8WithBOM:
            return "UTF-8 with BOM"
        case .utf16LittleEndianWithBOM:
            return "UTF-16 little-endian with BOM"
        case .utf16BigEndianWithBOM:
            return "UTF-16 big-endian with BOM"
        case .windows1252:
            return "Windows-1252"
        case .iso88591:
            return "ISO-8859-1"
        }
    }
}
