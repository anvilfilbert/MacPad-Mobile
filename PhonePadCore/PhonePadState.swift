import Foundation

public struct DocumentID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct TabID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum DocumentRecoveryState: String, Codable, Equatable, Sendable {
    case clean
    case checkpointPending
    case protectedUnsaved
}

public struct PhonePadDocument: Equatable, Sendable {
    public let id: DocumentID
    public let title: String
    public let text: String
    public let fileBinding: FileBinding?
    public let isUnsaved: Bool
    public let recoveryState: DocumentRecoveryState

    init(
        id: DocumentID,
        title: String,
        text: String,
        isUnsaved: Bool,
        recoveryState: DocumentRecoveryState
    ) {
        self.init(
            id: id,
            title: title,
            text: text,
            fileBinding: nil,
            isUnsaved: isUnsaved,
            recoveryState: recoveryState
        )
    }

    init(
        id: DocumentID,
        title: String,
        text: String,
        fileBinding: FileBinding?,
        isUnsaved: Bool,
        recoveryState: DocumentRecoveryState
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.fileBinding = fileBinding
        self.isUnsaved = isUnsaved
        self.recoveryState = recoveryState
    }
}

public struct PhonePadTab: Equatable, Sendable {
    public let id: TabID
    public let document: PhonePadDocument

    init(id: TabID, document: PhonePadDocument) {
        self.id = id
        self.document = document
    }
}

public struct PhonePadState: Equatable, Sendable {
    public let tabs: [PhonePadTab]
    public let activeTabID: TabID

    public var activeTab: PhonePadTab {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else {
            preconditionFailure("PhonePadState invariant violated: active Tab does not exist.")
        }
        return tab
    }

    init(tabs: [PhonePadTab], activeTabID: TabID) {
        precondition(
            tabs.contains(where: { $0.id == activeTabID }),
            "PhonePadState requires its active Tab to exist."
        )
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

public enum PhonePadStateError: Error, Equatable, Sendable {
    case activeTabMissing(TabID)
}

public enum SavedDocumentTransitionError: Error, Equatable, Sendable {
    case bindingDigestDoesNotMatchOutput
    case bindingEncodingDoesNotMatchOutput
    case bindingLineEndingDoesNotMatchOutput
}

extension SavedDocumentTransitionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bindingDigestDoesNotMatchOutput:
            return "Saved File digest does not match the verified output. Keep the Document unsaved and verify the File again."
        case .bindingEncodingDoesNotMatchOutput:
            return "Saved File encoding does not match the verified output. Keep the Document unsaved and verify the File again."
        case .bindingLineEndingDoesNotMatchOutput:
            return "Saved File line ending does not match the verified output. Keep the Document unsaved and verify the File again."
        }
    }
}

public struct RecoveryEditTransition: Equatable, Sendable {
    public let state: PhonePadState
    public let envelope: RecoveryEnvelope

    public init(state: PhonePadState, envelope: RecoveryEnvelope) {
        self.state = state
        self.envelope = envelope
    }
}

public func makeInitialPhonePadState(
    documentID: DocumentID,
    tabID: TabID
) -> PhonePadState {
    let document = PhonePadDocument(
        id: documentID,
        title: "Untitled",
        text: "",
        isUnsaved: false,
        recoveryState: .clean
    )
    let tab = PhonePadTab(id: tabID, document: document)
    return PhonePadState(tabs: [tab], activeTabID: tabID)
}

public func recoverDocument(
    state: PhonePadState,
    envelope: RecoveryEnvelope,
    tabID: TabID
) -> PhonePadState {
    if let existingTab = state.tabs.first(where: {
        $0.document.id == envelope.documentID
    }) {
        return PhonePadState(tabs: state.tabs, activeTabID: existingTab.id)
    }

    let document = PhonePadDocument(
        id: envelope.documentID,
        title: envelope.title,
        text: envelope.text,
        isUnsaved: true,
        recoveryState: .protectedUnsaved
    )
    let recoveredTab = PhonePadTab(id: tabID, document: document)
    return PhonePadState(
        tabs: state.tabs + [recoveredTab],
        activeTabID: recoveredTab.id
    )
}

public func beginActiveDocumentEdit(
    state: PhonePadState,
    newText: String,
    editedAt: Date
) throws -> RecoveryEditTransition {
    let activeTab = try requireActiveTab(state: state)
    let editedDocument = PhonePadDocument(
        id: activeTab.document.id,
        title: activeTab.document.title,
        text: newText,
        fileBinding: activeTab.document.fileBinding,
        isUnsaved: true,
        recoveryState: .checkpointPending
    )
    let editedTab = PhonePadTab(id: activeTab.id, document: editedDocument)
    let editedState = try replacingActiveTab(state: state, with: editedTab)
    let envelope = RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: editedDocument.id,
        title: editedDocument.title,
        text: editedDocument.text,
        editedAt: editedAt
    )
    return RecoveryEditTransition(state: editedState, envelope: envelope)
}

public func markActiveDocumentRecoveryProtected(
    state: PhonePadState
) throws -> PhonePadState {
    let activeTab = try requireActiveTab(state: state)
    let protectedDocument = PhonePadDocument(
        id: activeTab.document.id,
        title: activeTab.document.title,
        text: activeTab.document.text,
        fileBinding: activeTab.document.fileBinding,
        isUnsaved: activeTab.document.isUnsaved,
        recoveryState: .protectedUnsaved
    )
    let protectedTab = PhonePadTab(id: activeTab.id, document: protectedDocument)
    return try replacingActiveTab(state: state, with: protectedTab)
}

public func markActiveDocumentSavedToBoundFile(
    state: PhonePadState,
    encodedFile: EncodedTextFile,
    fileBinding: FileBinding
) throws -> PhonePadState {
    guard fileBinding.digest == encodedFile.digest else {
        throw SavedDocumentTransitionError.bindingDigestDoesNotMatchOutput
    }
    guard fileBinding.encoding == encodedFile.encoding else {
        throw SavedDocumentTransitionError.bindingEncodingDoesNotMatchOutput
    }
    guard fileBinding.lineEnding == encodedFile.lineEnding else {
        throw SavedDocumentTransitionError.bindingLineEndingDoesNotMatchOutput
    }
    let activeTab = try requireActiveTab(state: state)
    let savedDocument = PhonePadDocument(
        id: activeTab.document.id,
        title: fileBinding.displayName.value,
        text: encodedFile.text,
        fileBinding: fileBinding,
        isUnsaved: false,
        recoveryState: .clean
    )
    let savedTab = PhonePadTab(id: activeTab.id, document: savedDocument)
    return try replacingActiveTab(state: state, with: savedTab)
}

public func markActiveDocumentSavedToDetachedFile(
    state: PhonePadState,
    encodedFile: EncodedTextFile,
    fileName: ValidatedFileName
) throws -> PhonePadState {
    let activeTab = try requireActiveTab(state: state)
    let savedDocument = PhonePadDocument(
        id: activeTab.document.id,
        title: fileName.value,
        text: encodedFile.text,
        fileBinding: nil,
        isUnsaved: false,
        recoveryState: .clean
    )
    let savedTab = PhonePadTab(id: activeTab.id, document: savedDocument)
    return try replacingActiveTab(state: state, with: savedTab)
}

private func requireActiveTab(state: PhonePadState) throws -> PhonePadTab {
    guard let tab = state.tabs.first(where: { $0.id == state.activeTabID }) else {
        throw PhonePadStateError.activeTabMissing(state.activeTabID)
    }
    return tab
}

private func replacingActiveTab(
    state: PhonePadState,
    with replacement: PhonePadTab
) throws -> PhonePadState {
    guard let activeIndex = state.tabs.firstIndex(where: { $0.id == state.activeTabID }) else {
        throw PhonePadStateError.activeTabMissing(state.activeTabID)
    }
    var tabs = state.tabs
    tabs[activeIndex] = replacement
    return PhonePadState(tabs: tabs, activeTabID: state.activeTabID)
}
