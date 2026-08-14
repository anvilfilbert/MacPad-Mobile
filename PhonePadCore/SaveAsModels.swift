import Foundation

public struct SaveAsTargetSnapshot: Equatable, Hashable, Sendable {
    public let identity: FileIdentity?
    public let digest: FileDigest

    public init(identity: FileIdentity?, digest: FileDigest) {
        self.identity = identity
        self.digest = digest
    }
}

public enum SaveAsTargetExpectation: Equatable, Hashable, Sendable {
    case absent
    case existing(SaveAsTargetSnapshot)
}

public struct SaveAsTargetPlan: Equatable, Hashable, Sendable {
    public let directoryBookmark: FileBookmark
    public let fileName: ValidatedFileName
    public let expectation: SaveAsTargetExpectation

    public init(
        directoryBookmark: FileBookmark,
        fileName: ValidatedFileName,
        expectation: SaveAsTargetExpectation
    ) {
        self.directoryBookmark = directoryBookmark
        self.fileName = fileName
        self.expectation = expectation
    }
}

public enum SaveAsTargetPreflight: Equatable, Hashable, Sendable {
    case ready(SaveAsTargetPlan)
    case replacementRequired(SaveAsTargetPlan)
    case currentFile(SaveAsTargetPlan)

    public var plan: SaveAsTargetPlan {
        switch self {
        case let .ready(plan),
             let .replacementRequired(plan),
             let .currentFile(plan):
            return plan
        }
    }
}

public struct RecoverySaveAsDestination: Codable, Equatable, Hashable, Sendable {
    public let directoryBookmark: FileBookmark
    public let fileName: ValidatedFileName

    public init(
        directoryBookmark: FileBookmark,
        fileName: ValidatedFileName
    ) {
        self.directoryBookmark = directoryBookmark
        self.fileName = fileName
    }
}

public struct FileCollisionReference: Equatable, Hashable, Sendable {
    public let bookmark: FileBookmark
    public let identity: FileIdentity?

    public init(bookmark: FileBookmark, identity: FileIdentity?) {
        self.bookmark = bookmark
        self.identity = identity
    }
}

public enum FileCollisionClaim: Equatable, Hashable, Sendable {
    case activeTab(documentID: DocumentID, reference: FileCollisionReference)
    case recoveryItem(documentID: DocumentID, reference: FileCollisionReference)
    case pendingSaveAs(
        documentID: DocumentID,
        destination: RecoverySaveAsDestination
    )

    public var documentID: DocumentID {
        switch self {
        case let .activeTab(documentID, _),
             let .recoveryItem(documentID, _),
             let .pendingSaveAs(documentID, _):
            return documentID
        }
    }

    public var fileReference: FileCollisionReference? {
        switch self {
        case let .activeTab(_, reference),
             let .recoveryItem(_, reference):
            return reference
        case .pendingSaveAs:
            return nil
        }
    }

    public var pendingSaveAsDestination: RecoverySaveAsDestination? {
        switch self {
        case .activeTab, .recoveryItem:
            return nil
        case let .pendingSaveAs(_, destination):
            return destination
        }
    }
}

public func activeTabFileCollisionClaims(
    state: PhonePadState
) -> [FileCollisionClaim] {
    state.tabs.compactMap { tab in
        guard let binding = tab.document.fileBinding else {
            return nil
        }
        return .activeTab(
            documentID: tab.document.id,
            reference: FileCollisionReference(
                bookmark: binding.bookmark,
                identity: binding.identity
            )
        )
    }
}
