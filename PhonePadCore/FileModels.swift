import Foundation

public let maximumSupportedTextFileByteCount: Int = 25 * 1024 * 1024

public struct FileIdentity: Codable, Equatable, Hashable, Sendable {
    public let volumeUUID: UUID
    public let documentIdentifier: Int

    public init(volumeUUID: UUID, documentIdentifier: Int) {
        self.volumeUUID = volumeUUID
        self.documentIdentifier = documentIdentifier
    }
}

public enum TextFileEncoding: String, Codable, Equatable, Hashable, Sendable {
    case utf8
    case utf8WithBOM
    case utf16LittleEndianWithBOM
    case utf16BigEndianWithBOM
    case windows1252
    case iso88591
}

public enum TextLineEnding: String, Codable, Equatable, Hashable, Sendable {
    case crlf
    case lf
    case cr
}

public enum FileDigestValidationError: Error, Equatable, Sendable {
    case invalidByteCount(actualByteCount: Int, requiredByteCount: Int)
}

extension FileDigestValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidByteCount(actualByteCount, requiredByteCount):
            return "File digest contains \(actualByteCount) bytes; SHA-256 requires exactly \(requiredByteCount) bytes."
        }
    }
}

public struct FileDigest: Codable, Equatable, Hashable, Sendable {
    public static let requiredByteCount: Int = 32

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.requiredByteCount else {
            throw FileDigestValidationError.invalidByteCount(
                actualByteCount: bytes.count,
                requiredByteCount: Self.requiredByteCount
            )
        }
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(bytes: container.decode(Data.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

public enum FileBookmarkValidationError: Error, Equatable, Sendable {
    case empty
}

extension FileBookmarkValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "File bookmark is empty and cannot provide durable access to the saved File."
        }
    }
}

public struct FileBookmark: Codable, Equatable, Hashable, Sendable {
    public let data: Data

    public init(data: Data) throws {
        guard !data.isEmpty else {
            throw FileBookmarkValidationError.empty
        }
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(data: container.decode(Data.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

public enum FileNameValidationError: Error, Equatable, Sendable {
    case empty
    case reservedComponent(String)
    case multipleComponents
    case containsNullByte
}

extension FileNameValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "File name is empty. Enter a name before saving."
        case let .reservedComponent(component):
            return "\(component) cannot be used as a File name. Enter a regular name before saving."
        case .multipleComponents:
            return "File name contains a path separator. Choose the folder separately and enter one File name."
        case .containsNullByte:
            return "File name contains an unsupported null character. Remove it before saving."
        }
    }
}

public struct ValidatedFileName: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(validating value: String) throws {
        guard !value.isEmpty else {
            throw FileNameValidationError.empty
        }
        guard value != ".", value != ".." else {
            throw FileNameValidationError.reservedComponent(value)
        }
        guard !value.contains("/") else {
            throw FileNameValidationError.multipleComponents
        }
        guard !value.contains("\0") else {
            throw FileNameValidationError.containsNullByte
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct EncodedTextFile: Equatable, Sendable {
    public let text: String
    public let data: Data
    public let digest: FileDigest
    public let encoding: TextFileEncoding
    public let lineEnding: TextLineEnding

    init(
        text: String,
        data: Data,
        digest: FileDigest,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding
    ) {
        self.text = text
        self.data = data
        self.digest = digest
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

public enum NewTextFileEncodingError: Error, Equatable, Sendable {
    case contentTooLarge(actualByteCount: Int, maximumByteCount: Int)
}

extension NewTextFileEncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .contentTooLarge(actualByteCount, maximumByteCount):
            return "Encoded File is \(actualByteCount) bytes; PhonePad supports at most \(maximumByteCount) bytes. Shorten the Document before saving."
        }
    }
}

public struct FileBinding: Equatable, Sendable {
    public let locatorURL: URL
    public let bookmark: FileBookmark
    public let identity: FileIdentity?
    public let displayName: ValidatedFileName
    public let digest: FileDigest
    public let encoding: TextFileEncoding
    public let lineEnding: TextLineEnding

    public init(
        locatorURL: URL,
        bookmark: FileBookmark,
        identity: FileIdentity?,
        displayName: ValidatedFileName,
        digest: FileDigest,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding
    ) {
        self.locatorURL = locatorURL
        self.bookmark = bookmark
        self.identity = identity
        self.displayName = displayName
        self.digest = digest
        self.encoding = encoding
        self.lineEnding = lineEnding
    }

    public init(
        locatorURL: URL,
        bookmark: FileBookmark,
        displayName: ValidatedFileName,
        digest: FileDigest,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding
    ) {
        self.init(
            locatorURL: locatorURL,
            bookmark: bookmark,
            identity: nil,
            displayName: displayName,
            digest: digest,
            encoding: encoding,
            lineEnding: lineEnding
        )
    }
}

public enum FileConflict: Equatable, Sendable {
    case contentChanged
    case stableIdentityChanged
    case ambiguousLocatorChange
    case unresolvedProviderVersions(count: Int)
}

public enum FileProviderConflictVersions: Equatable, Sendable {
    case none
    case unresolved(count: Int)
}

public struct ObservedBoundFile: Equatable, Sendable {
    public let binding: FileBinding
    public let providerConflictVersions: FileProviderConflictVersions

    public init(
        binding: FileBinding,
        providerConflictVersions: FileProviderConflictVersions
    ) {
        self.binding = binding
        self.providerConflictVersions = providerConflictVersions
    }
}

public enum FileReconciliationResult: Equatable, Sendable {
    case continuous(updatedBinding: FileBinding)
    case conflicted(retainedBinding: FileBinding, conflict: FileConflict)
}

public func reconcileFileBinding(
    baseline: FileBinding,
    observation: ObservedBoundFile
) -> FileReconciliationResult {
    let observedBinding = observation.binding
    let retainedBinding: FileBinding

    switch (baseline.identity, observedBinding.identity) {
    case let (.some(baselineIdentity), .some(observedIdentity)):
        guard baselineIdentity == observedIdentity else {
            return .conflicted(
                retainedBinding: baseline,
                conflict: .stableIdentityChanged
            )
        }
        retainedBinding = retainingBaselineContent(
            baseline: baseline,
            observedBinding: observedBinding
        )
    case (.none, .none):
        guard baseline.locatorURL.standardizedFileURL
                == observedBinding.locatorURL.standardizedFileURL else {
            return .conflicted(
                retainedBinding: baseline,
                conflict: .ambiguousLocatorChange
            )
        }
        retainedBinding = retainingBaselineContent(
            baseline: baseline,
            observedBinding: observedBinding
        )
    case (.some, .none), (.none, .some):
        return .conflicted(
            retainedBinding: baseline,
            conflict: .stableIdentityChanged
        )
    }

    switch observation.providerConflictVersions {
    case .none:
        break
    case let .unresolved(count):
        return .conflicted(
            retainedBinding: retainedBinding,
            conflict: .unresolvedProviderVersions(count: count)
        )
    }

    guard observedBinding.digest == baseline.digest else {
        return .conflicted(
            retainedBinding: retainedBinding,
            conflict: .contentChanged
        )
    }
    return .continuous(updatedBinding: retainedBinding)
}

private func retainingBaselineContent(
    baseline: FileBinding,
    observedBinding: FileBinding
) -> FileBinding {
    FileBinding(
        locatorURL: observedBinding.locatorURL,
        bookmark: observedBinding.bookmark,
        identity: baseline.identity,
        displayName: baseline.displayName,
        digest: baseline.digest,
        encoding: baseline.encoding,
        lineEnding: baseline.lineEnding
    )
}

public struct RecoveryFileReference: Codable, Equatable, Hashable, Sendable {
    public let bookmark: FileBookmark
    public let identity: FileIdentity?
    public let displayName: ValidatedFileName
    public let cleanDigest: FileDigest
    public let encoding: TextFileEncoding
    public let lineEnding: TextLineEnding

    public init(
        bookmark: FileBookmark,
        identity: FileIdentity?,
        displayName: ValidatedFileName,
        cleanDigest: FileDigest,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding
    ) {
        self.bookmark = bookmark
        self.identity = identity
        self.displayName = displayName
        self.cleanDigest = cleanDigest
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

public func makeRecoveryFileReference(
    fileBinding: FileBinding
) -> RecoveryFileReference {
    RecoveryFileReference(
        bookmark: fileBinding.bookmark,
        identity: fileBinding.identity,
        displayName: fileBinding.displayName,
        cleanDigest: fileBinding.digest,
        encoding: fileBinding.encoding,
        lineEnding: fileBinding.lineEnding
    )
}

public func encodeNewTextFile(text: String) throws -> EncodedTextFile {
    do {
        return try encodeTextFile(
            text: text,
            encoding: .utf8,
            lineEnding: .lf
        )
    } catch let error as TextFileEncodingError {
        switch error {
        case let .contentTooLarge(_, actualByteCount, maximumByteCount):
            throw NewTextFileEncodingError.contentTooLarge(
                actualByteCount: actualByteCount,
                maximumByteCount: maximumByteCount
            )
        case .unrepresentable, .unsupportedContent,
             .containsNullScalar, .binaryLike:
            throw error
        }
    }
}
