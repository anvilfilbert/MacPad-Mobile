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
    public let recoveryFileReference: RecoveryFileReference?
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
            recoveryFileReference: nil,
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
        self.init(
            id: id,
            title: title,
            text: text,
            fileBinding: fileBinding,
            recoveryFileReference: fileBinding.map(makeRecoveryFileReference),
            isUnsaved: isUnsaved,
            recoveryState: recoveryState
        )
    }

    init(
        id: DocumentID,
        title: String,
        text: String,
        fileBinding: FileBinding?,
        recoveryFileReference: RecoveryFileReference?,
        isUnsaved: Bool,
        recoveryState: DocumentRecoveryState
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.fileBinding = fileBinding
        self.recoveryFileReference = recoveryFileReference
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
        fileBinding: nil,
        recoveryFileReference: envelope.fileReference,
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
    let recoveryFileReference = activeTab.document.fileBinding
        .map(makeRecoveryFileReference)
        ?? activeTab.document.recoveryFileReference
    let editedDocument = PhonePadDocument(
        id: activeTab.document.id,
        title: activeTab.document.title,
        text: newText,
        fileBinding: activeTab.document.fileBinding,
        recoveryFileReference: recoveryFileReference,
        isUnsaved: true,
        recoveryState: .checkpointPending
    )
    let editedTab = PhonePadTab(id: activeTab.id, document: editedDocument)
    let editedState = try replacingActiveTab(state: state, with: editedTab)
    let envelope = try RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: editedDocument.id,
        title: editedDocument.title,
        text: editedDocument.text,
        editedAt: editedAt,
        fileReference: recoveryFileReference,
        pendingSave: nil
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
        recoveryFileReference: activeTab.document.recoveryFileReference,
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

public func openBoundDocument(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID,
    text: String,
    fileBinding: FileBinding
) -> PhonePadState {
    if let existingTab = state.tabs.first(where: { tab in
        guard let existingBinding = tab.document.fileBinding else {
            return false
        }
        return fileBindingsReferToSameFile(
            existing: existingBinding,
            candidate: fileBinding
        )
    }) {
        return PhonePadState(tabs: state.tabs, activeTabID: existingTab.id)
    }
    let document = PhonePadDocument(
        id: documentID,
        title: fileBinding.displayName.value,
        text: text,
        fileBinding: fileBinding,
        isUnsaved: false,
        recoveryState: .clean
    )
    let tab = PhonePadTab(id: tabID, document: document)
    guard !isPristineSoleUntitled(state: state) else {
        return PhonePadState(tabs: [tab], activeTabID: tab.id)
    }
    return PhonePadState(tabs: state.tabs + [tab], activeTabID: tab.id)
}

public func fileBindingsReferToSameFile(
    existing: FileBinding,
    candidate: FileBinding
) -> Bool {
    switch (existing.identity, candidate.identity) {
    case let (.some(existingIdentity), .some(candidateIdentity)):
        return existingIdentity == candidateIdentity
    case (.none, .none):
        return existing.locatorURL.standardizedFileURL
            == candidate.locatorURL.standardizedFileURL
    case (.some, .none), (.none, .some):
        return false
    }
}

private func isPristineSoleUntitled(state: PhonePadState) -> Bool {
    guard state.tabs.count == 1, let document = state.tabs.first?.document else {
        return false
    }
    return document.title == "Untitled"
        && document.text.isEmpty
        && document.fileBinding == nil
        && !document.isUnsaved
        && document.recoveryState == .clean
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
