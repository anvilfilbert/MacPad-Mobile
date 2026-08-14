import Foundation

public struct RecoveryPendingSave: Codable, Equatable, Hashable, Sendable {
    public let intendedOutputDigest: FileDigest

    public init(intendedOutputDigest: FileDigest) {
        self.intendedOutputDigest = intendedOutputDigest
    }
}

public enum RecoveryEnvelopeValidationError: Error, Equatable, Sendable {
    case pendingSaveRequiresFileReference
}

extension RecoveryEnvelopeValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pendingSaveRequiresFileReference:
            return "Pending Save recovery metadata requires a durable File reference."
        }
    }
}

public struct RecoveryEnvelope: Codable, Equatable, Sendable {
    public static let currentFormatVersion: UInt = 1

    public let formatVersion: UInt
    public let documentID: DocumentID
    public let title: String
    public let text: String
    public let editedAt: Date
    public let fileReference: RecoveryFileReference?
    public let pendingSave: RecoveryPendingSave?

    public init(
        formatVersion: UInt,
        documentID: DocumentID,
        title: String,
        text: String,
        editedAt: Date
    ) {
        self.formatVersion = formatVersion
        self.documentID = documentID
        self.title = title
        self.text = text
        self.editedAt = editedAt
        self.fileReference = nil
        self.pendingSave = nil
    }

    public init(
        formatVersion: UInt,
        documentID: DocumentID,
        title: String,
        text: String,
        editedAt: Date,
        fileReference: RecoveryFileReference?,
        pendingSave: RecoveryPendingSave?
    ) throws {
        guard pendingSave == nil || fileReference != nil else {
            throw RecoveryEnvelopeValidationError.pendingSaveRequiresFileReference
        }
        self.formatVersion = formatVersion
        self.documentID = documentID
        self.title = title
        self.text = text
        self.editedAt = editedAt
        self.fileReference = fileReference
        self.pendingSave = pendingSave
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            formatVersion: container.decode(UInt.self, forKey: .formatVersion),
            documentID: container.decode(DocumentID.self, forKey: .documentID),
            title: container.decode(String.self, forKey: .title),
            text: container.decode(String.self, forKey: .text),
            editedAt: container.decode(Date.self, forKey: .editedAt),
            fileReference: container.decodeIfPresent(
                RecoveryFileReference.self,
                forKey: .fileReference
            ),
            pendingSave: container.decodeIfPresent(
                RecoveryPendingSave.self,
                forKey: .pendingSave
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(title, forKey: .title)
        try container.encode(text, forKey: .text)
        try container.encode(editedAt, forKey: .editedAt)
        try container.encodeIfPresent(fileReference, forKey: .fileReference)
        try container.encodeIfPresent(pendingSave, forKey: .pendingSave)
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case documentID
        case title
        case text
        case editedAt
        case fileReference
        case pendingSave
    }
}

public struct RecoveryCheckpointVerification: Equatable, Sendable {
    public let hasCompleteFileProtection: Bool
    public let isExcludedFromBackup: Bool

    public init(
        hasCompleteFileProtection: Bool,
        isExcludedFromBackup: Bool
    ) {
        self.hasCompleteFileProtection = hasCompleteFileProtection
        self.isExcludedFromBackup = isExcludedFromBackup
    }
}
