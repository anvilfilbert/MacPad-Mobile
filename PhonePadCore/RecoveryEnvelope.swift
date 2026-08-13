import Foundation

public struct RecoveryEnvelope: Codable, Equatable, Sendable {
    public static let currentFormatVersion: UInt = 1

    public let formatVersion: UInt
    public let documentID: DocumentID
    public let title: String
    public let text: String
    public let editedAt: Date

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
