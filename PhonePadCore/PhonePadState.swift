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

public enum TabPlacement: Equatable, Sendable {
    case before(TabID)
    case end
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
    public let fileConflict: FileConflict?
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
            fileConflict: nil,
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
            fileConflict: nil,
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
        self.init(
            id: id,
            title: title,
            text: text,
            fileBinding: fileBinding,
            recoveryFileReference: recoveryFileReference,
            fileConflict: nil,
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
        fileConflict: FileConflict?,
        isUnsaved: Bool,
        recoveryState: DocumentRecoveryState
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.fileBinding = fileBinding
        self.recoveryFileReference = recoveryFileReference
        self.fileConflict = fileConflict
        self.isUnsaved = isUnsaved
        self.recoveryState = recoveryState
    }
}

public struct PhonePadTab: Equatable, Sendable {
    public let id: TabID
    public let document: PhonePadDocument
    public let displaySettings: PhonePadTabDisplaySettings

    init(
        id: TabID,
        document: PhonePadDocument,
        displaySettings: PhonePadTabDisplaySettings
    ) {
        self.id = id
        self.document = document
        self.displaySettings = displaySettings
    }
}

public struct PreparedCleanTabClose: Equatable, Sendable {
    public let tab: PhonePadTab

    init(tab: PhonePadTab) {
        self.tab = tab
    }
}

public struct PreparedUnsavedTabClose: Equatable, Sendable {
    public let tab: PhonePadTab

    init(tab: PhonePadTab) {
        self.tab = tab
    }
}

public enum TabCloseRequirement: Equatable, Sendable {
    case clean(PreparedCleanTabClose)
    case unsaved(PreparedUnsavedTabClose)
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
        if let error = phonePadStateValidationError(
            tabs: tabs,
            activeTabID: activeTabID
        ) {
            preconditionFailure(
                "PhonePadState invariant violated: \(error.localizedDescription)"
            )
        }
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    init(
        validatingTabs tabs: [PhonePadTab],
        activeTabID: TabID
    ) throws {
        if let error = phonePadStateValidationError(
            tabs: tabs,
            activeTabID: activeTabID
        ) {
            throw error
        }
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

public enum PhonePadStateError: Error, Equatable, Sendable {
    case emptyTabWorkspace
    case duplicateTabID(TabID)
    case duplicateDocumentID(DocumentID)
    case tabMissing(TabID)
    case tabChangedSinceClosePreparation(TabID)
    case tabPlacementAnchorMissing(TabID)
    case activeTabMissing(TabID)
    case documentMissing(DocumentID)
    case documentIsNotBound(DocumentID)
    case documentTextChanged(DocumentID)
    case workspaceChangedSinceFileOpenPreparation(DocumentID)
    case fileBindingIdentityCollision(
        documentID: DocumentID,
        conflictingDocumentID: DocumentID
    )
    case fileBindingLocatorCollision(
        documentID: DocumentID,
        conflictingDocumentID: DocumentID
    )
}

extension PhonePadStateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyTabWorkspace:
            return "Tab workspace is empty. Keep at least one Tab open."
        case let .duplicateTabID(tabID):
            return "Tab identifier \(tabID.rawValue.uuidString) already belongs to an open Tab. Generate a unique Tab identifier and try again."
        case let .duplicateDocumentID(documentID):
            return "Document identifier \(documentID.rawValue.uuidString) already belongs to an open Document. Generate a unique Document identifier and try again."
        case let .tabMissing(tabID):
            return "Tab \(tabID.rawValue.uuidString) no longer exists. Refresh the Tab workspace and try again."
        case let .tabChangedSinceClosePreparation(tabID):
            return "Tab \(tabID.rawValue.uuidString) changed while Close was being resolved. Keep it open and retry Close."
        case let .tabPlacementAnchorMissing(tabID):
            return "Tab reorder destination \(tabID.rawValue.uuidString) no longer exists. Refresh the Tab workspace and try again."
        case .activeTabMissing:
            return "Active Tab no longer exists. Select an available Tab and try again."
        case .documentMissing:
            return "Document is no longer open. Select an available Tab and try again."
        case .documentIsNotBound:
            return "Document is not attached to an existing File. Use Save As."
        case .documentTextChanged:
            return "Document changed while its recovery checkpoint was being protected. Wait for the latest checkpoint and try again."
        case let .workspaceChangedSinceFileOpenPreparation(documentID):
            return "Tab workspace changed while File Open for Document \(documentID.rawValue.uuidString) was awaiting a decision. Keep current Documents open and retry Open."
        case .fileBindingIdentityCollision:
            return "Observed File identity belongs to another open Document. Switch to that Tab; no File binding changed."
        case .fileBindingLocatorCollision:
            return "Observed File location belongs to another open Document. Switch to that Tab; no File binding changed."
        }
    }
}

private func phonePadStateValidationError(
    tabs: [PhonePadTab],
    activeTabID: TabID
) -> PhonePadStateError? {
    guard !tabs.isEmpty else {
        return .emptyTabWorkspace
    }
    var tabIDs = Set<TabID>()
    var documentIDs = Set<DocumentID>()
    var boundIdentities: [FileIdentity: DocumentID] = [:]
    var boundLocators: [URL: DocumentID] = [:]
    for tab in tabs {
        guard tabIDs.insert(tab.id).inserted else {
            return .duplicateTabID(tab.id)
        }
        guard documentIDs.insert(tab.document.id).inserted else {
            return .duplicateDocumentID(tab.document.id)
        }
        guard let binding = tab.document.fileBinding else {
            continue
        }
        if let identity = binding.identity,
           let conflictingDocumentID = boundIdentities[identity] {
            return .fileBindingIdentityCollision(
                documentID: tab.document.id,
                conflictingDocumentID: conflictingDocumentID
            )
        }
        if let identity = binding.identity {
            boundIdentities[identity] = tab.document.id
        }
        let standardizedLocator = binding.locatorURL.standardizedFileURL
        if let conflictingDocumentID = boundLocators[standardizedLocator] {
            return .fileBindingLocatorCollision(
                documentID: tab.document.id,
                conflictingDocumentID: conflictingDocumentID
            )
        }
        boundLocators[standardizedLocator] = tab.document.id
    }
    guard tabIDs.contains(activeTabID) else {
        return .activeTabMissing(activeTabID)
    }
    return nil
}

public enum SavedDocumentTransitionError: Error, Equatable, Sendable {
    case bindingDigestDoesNotMatchOutput
    case bindingEncodingDoesNotMatchOutput
    case bindingLineEndingDoesNotMatchOutput
    case fileConflictRequiresExplicitResolution(FileConflict)
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
        case .fileConflictRequiresExplicitResolution:
            return "File Conflict blocks Save to the original File. Reload Current or use Save As."
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
    let tab = PhonePadTab(
        id: tabID,
        document: document,
        displaySettings: .initial
    )
    return PhonePadState(tabs: [tab], activeTabID: tabID)
}

public func createUntitledTab(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID
) throws -> PhonePadState {
    guard !state.tabs.contains(where: { $0.id == tabID }) else {
        throw PhonePadStateError.duplicateTabID(tabID)
    }
    guard !state.tabs.contains(where: { $0.document.id == documentID }) else {
        throw PhonePadStateError.duplicateDocumentID(documentID)
    }
    let document = PhonePadDocument(
        id: documentID,
        title: nextUntitledTitle(tabs: state.tabs),
        text: "",
        isUnsaved: false,
        recoveryState: .clean
    )
    let tab = PhonePadTab(
        id: tabID,
        document: document,
        displaySettings: .initial
    )
    return PhonePadState(
        tabs: state.tabs + [tab],
        activeTabID: tab.id
    )
}

private func nextUntitledTitle(tabs: [PhonePadTab]) -> String {
    let existingTitles = Set(tabs.map(\.document.title))
    guard existingTitles.contains("Untitled") else {
        return "Untitled"
    }
    var suffix = 2
    while existingTitles.contains("Untitled \(suffix)") {
        suffix += 1
    }
    return "Untitled \(suffix)"
}

public func selectTab(
    state: PhonePadState,
    tabID: TabID
) throws -> PhonePadState {
    guard state.tabs.contains(where: { $0.id == tabID }) else {
        throw PhonePadStateError.tabMissing(tabID)
    }
    return PhonePadState(tabs: state.tabs, activeTabID: tabID)
}

public func moveTab(
    state: PhonePadState,
    tabID: TabID,
    placement: TabPlacement
) throws -> PhonePadState {
    guard let sourceIndex = state.tabs.firstIndex(where: {
        $0.id == tabID
    }) else {
        throw PhonePadStateError.tabMissing(tabID)
    }
    if case let .before(anchorTabID) = placement {
        guard state.tabs.contains(where: { $0.id == anchorTabID }) else {
            throw PhonePadStateError.tabPlacementAnchorMissing(anchorTabID)
        }
        guard anchorTabID != tabID else {
            return state
        }
    }

    var tabs = state.tabs
    let movedTab = tabs.remove(at: sourceIndex)
    switch placement {
    case let .before(anchorTabID):
        guard let destinationIndex = tabs.firstIndex(where: {
            $0.id == anchorTabID
        }) else {
            throw PhonePadStateError.tabPlacementAnchorMissing(anchorTabID)
        }
        tabs.insert(movedTab, at: destinationIndex)
    case .end:
        tabs.append(movedTab)
    }
    return PhonePadState(tabs: tabs, activeTabID: state.activeTabID)
}

public func prepareTabClose(
    state: PhonePadState,
    tabID: TabID
) throws -> TabCloseRequirement {
    guard let tab = state.tabs.first(where: { $0.id == tabID }) else {
        throw PhonePadStateError.tabMissing(tabID)
    }
    return tabCloseRequirement(tab: tab)
}

public func prepareOtherTabCloses(
    state: PhonePadState,
    keepingTabID: TabID
) throws -> [TabCloseRequirement] {
    guard state.tabs.contains(where: { $0.id == keepingTabID }) else {
        throw PhonePadStateError.tabMissing(keepingTabID)
    }
    return state.tabs.compactMap { tab in
        guard tab.id != keepingTabID else {
            return nil
        }
        return tabCloseRequirement(tab: tab)
    }
}

public func closePreparedCleanTab(
    state: PhonePadState,
    preparedClose: PreparedCleanTabClose,
    replacementDocumentID: DocumentID,
    replacementTabID: TabID
) throws -> PhonePadState {
    try closePreparedTab(
        state: state,
        expectedTab: preparedClose.tab,
        replacementDocumentID: replacementDocumentID,
        replacementTabID: replacementTabID
    )
}

public func closePreparedDiscardedTab(
    state: PhonePadState,
    preparedClose: PreparedUnsavedTabClose,
    replacementDocumentID: DocumentID,
    replacementTabID: TabID
) throws -> PhonePadState {
    try closePreparedTab(
        state: state,
        expectedTab: preparedClose.tab,
        replacementDocumentID: replacementDocumentID,
        replacementTabID: replacementTabID
    )
}

private func tabCloseRequirement(
    tab: PhonePadTab
) -> TabCloseRequirement {
    guard !tab.document.isUnsaved,
          tab.document.recoveryState == .clean else {
        return .unsaved(PreparedUnsavedTabClose(tab: tab))
    }
    return .clean(PreparedCleanTabClose(tab: tab))
}

private func closePreparedTab(
    state: PhonePadState,
    expectedTab: PhonePadTab,
    replacementDocumentID: DocumentID,
    replacementTabID: TabID
) throws -> PhonePadState {
    guard let closingIndex = state.tabs.firstIndex(where: {
        $0.id == expectedTab.id
    }) else {
        throw PhonePadStateError.tabMissing(expectedTab.id)
    }
    guard state.tabs[closingIndex] == expectedTab else {
        throw PhonePadStateError.tabChangedSinceClosePreparation(
            expectedTab.id
        )
    }
    guard state.tabs.count > 1 else {
        guard replacementTabID != expectedTab.id else {
            throw PhonePadStateError.duplicateTabID(replacementTabID)
        }
        guard replacementDocumentID != expectedTab.document.id else {
            throw PhonePadStateError.duplicateDocumentID(
                replacementDocumentID
            )
        }
        return makeInitialPhonePadState(
            documentID: replacementDocumentID,
            tabID: replacementTabID
        )
    }

    var tabs = state.tabs
    _ = tabs.remove(at: closingIndex)
    let activeTabID: TabID
    if state.activeTabID == expectedTab.id {
        activeTabID = tabs[min(closingIndex, tabs.count - 1)].id
    } else {
        activeTabID = state.activeTabID
    }
    return PhonePadState(tabs: tabs, activeTabID: activeTabID)
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
    let recoveredTab = PhonePadTab(
        id: tabID,
        document: document,
        displaySettings: .initial
    )
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
    let validatedText = try validateEditableDocumentText(text: newText)
    let recoveryFileReference = activeTab.document.fileBinding
        .map(makeRecoveryFileReference)
        ?? activeTab.document.recoveryFileReference
    let editedDocument = PhonePadDocument(
        id: activeTab.document.id,
        title: activeTab.document.title,
        text: validatedText,
        fileBinding: activeTab.document.fileBinding,
        recoveryFileReference: recoveryFileReference,
        fileConflict: activeTab.document.fileConflict,
        isUnsaved: true,
        recoveryState: .checkpointPending
    )
    let editedTab = PhonePadTab(
        id: activeTab.id,
        document: editedDocument,
        displaySettings: activeTab.displaySettings
    )
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
    return try markDocumentRecoveryProtected(
        state: state,
        documentID: activeTab.document.id,
        expectedText: activeTab.document.text
    )
}

public func markDocumentRecoveryProtected(
    state: PhonePadState,
    documentID: DocumentID,
    expectedText: String
) throws -> PhonePadState {
    let tab = try requireTabContainingDocument(
        state: state,
        documentID: documentID
    )
    guard tab.document.text == expectedText else {
        throw PhonePadStateError.documentTextChanged(documentID)
    }
    let protectedDocument = PhonePadDocument(
        id: tab.document.id,
        title: tab.document.title,
        text: tab.document.text,
        fileBinding: tab.document.fileBinding,
        recoveryFileReference: tab.document.recoveryFileReference,
        fileConflict: tab.document.fileConflict,
        isUnsaved: tab.document.isUnsaved,
        recoveryState: .protectedUnsaved
    )
    let protectedTab = PhonePadTab(
        id: tab.id,
        document: protectedDocument,
        displaySettings: tab.displaySettings
    )
    return try replacingTab(state: state, with: protectedTab)
}

public func requireBoundFileSaveAllowed(
    state: PhonePadState,
    documentID: DocumentID
) throws -> FileBinding {
    let tab = try requireTabContainingDocument(
        state: state,
        documentID: documentID
    )
    guard let fileBinding = tab.document.fileBinding else {
        throw PhonePadStateError.documentIsNotBound(documentID)
    }
    if let fileConflict = tab.document.fileConflict {
        throw SavedDocumentTransitionError
            .fileConflictRequiresExplicitResolution(fileConflict)
    }
    return fileBinding
}

public func markActiveDocumentSavedToBoundFile(
    state: PhonePadState,
    encodedFile: EncodedTextFile,
    fileBinding: FileBinding
) throws -> PhonePadState {
    let activeTab = try requireActiveTab(state: state)
    if let fileConflict = activeTab.document.fileConflict {
        throw SavedDocumentTransitionError
            .fileConflictRequiresExplicitResolution(fileConflict)
    }
    let savedDocument = try makeSavedBoundDocument(
        document: activeTab.document,
        encodedFile: encodedFile,
        fileBinding: fileBinding
    )
    let savedTab = PhonePadTab(
        id: activeTab.id,
        document: savedDocument,
        displaySettings: activeTab.displaySettings
    )
    return try replacingActiveTab(state: state, with: savedTab)
}

public func markActiveDocumentSavedAsBoundFile(
    state: PhonePadState,
    encodedFile: EncodedTextFile,
    fileBinding: FileBinding
) throws -> PhonePadState {
    let activeTab = try requireActiveTab(state: state)
    let savedDocument = try makeSavedBoundDocument(
        document: activeTab.document,
        encodedFile: encodedFile,
        fileBinding: fileBinding
    )
    let savedTab = PhonePadTab(
        id: activeTab.id,
        document: savedDocument,
        displaySettings: activeTab.displaySettings
    )
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
    let savedTab = PhonePadTab(
        id: activeTab.id,
        document: savedDocument,
        displaySettings: activeTab.displaySettings
    )
    return try replacingActiveTab(state: state, with: savedTab)
}

public func markDocumentFileConflict(
    state: PhonePadState,
    documentID: DocumentID,
    conflict: FileConflict
) throws -> PhonePadState {
    let tab = try requireTabContainingDocument(
        state: state,
        documentID: documentID
    )
    guard tab.document.fileBinding != nil else {
        throw PhonePadStateError.documentIsNotBound(documentID)
    }
    let conflictedDocument = PhonePadDocument(
        id: tab.document.id,
        title: tab.document.title,
        text: tab.document.text,
        fileBinding: tab.document.fileBinding,
        recoveryFileReference: tab.document.recoveryFileReference,
        fileConflict: conflict,
        isUnsaved: tab.document.isUnsaved,
        recoveryState: tab.document.recoveryState
    )
    return try replacingTab(
        state: state,
        with: PhonePadTab(
            id: tab.id,
            document: conflictedDocument,
            displaySettings: tab.displaySettings
        )
    )
}

public func reconcileBoundDocument(
    state: PhonePadState,
    documentID: DocumentID,
    observation: ObservedBoundFile
) throws -> PhonePadState {
    let tab = try requireTabContainingDocument(
        state: state,
        documentID: documentID
    )
    guard let baseline = tab.document.fileBinding else {
        throw PhonePadStateError.documentIsNotBound(documentID)
    }
    try requireFileBindingAvailableToDocument(
        state: state,
        documentID: documentID,
        candidate: observation.binding
    )
    let result = reconcileFileBinding(
        baseline: baseline,
        observation: observation
    )
    let retainedBinding: FileBinding
    let fileConflict: FileConflict?
    switch result {
    case let .continuous(updatedBinding):
        retainedBinding = updatedBinding
        fileConflict = tab.document.fileConflict
    case let .conflicted(binding, conflict):
        retainedBinding = binding
        fileConflict = conflict
    }
    let reconciledDocument = PhonePadDocument(
        id: tab.document.id,
        title: tab.document.title,
        text: tab.document.text,
        fileBinding: retainedBinding,
        recoveryFileReference: makeRecoveryFileReference(
            fileBinding: retainedBinding
        ),
        fileConflict: fileConflict,
        isUnsaved: tab.document.isUnsaved,
        recoveryState: tab.document.recoveryState
    )
    return try replacingTab(
        state: state,
        with: PhonePadTab(
            id: tab.id,
            document: reconciledDocument,
            displaySettings: tab.displaySettings
        )
    )
}

public func reloadDocumentFromBoundFile(
    state: PhonePadState,
    documentID: DocumentID,
    text: String,
    observation: ObservedBoundFile
) throws -> PhonePadState {
    let tab = try requireTabContainingDocument(
        state: state,
        documentID: documentID
    )
    guard tab.document.fileBinding != nil else {
        throw PhonePadStateError.documentIsNotBound(documentID)
    }
    try requireFileBindingAvailableToDocument(
        state: state,
        documentID: documentID,
        candidate: observation.binding
    )
    let fileConflict: FileConflict?
    switch observation.providerConflictVersions {
    case .none:
        fileConflict = nil
    case let .unresolved(count):
        fileConflict = .unresolvedProviderVersions(count: count)
    }
    let reloadedDocument = PhonePadDocument(
        id: tab.document.id,
        title: observation.binding.displayName.value,
        text: text,
        fileBinding: observation.binding,
        recoveryFileReference: makeRecoveryFileReference(
            fileBinding: observation.binding
        ),
        fileConflict: fileConflict,
        isUnsaved: false,
        recoveryState: .clean
    )
    return try replacingTab(
        state: state,
        with: PhonePadTab(
            id: tab.id,
            document: reloadedDocument,
            displaySettings: tab.displaySettings
        )
    )
}

public func openBoundDocument(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID,
    text: String,
    fileBinding: FileBinding
) -> PhonePadState {
    openObservedBoundDocument(
        state: state,
        documentID: documentID,
        tabID: tabID,
        text: text,
        observation: ObservedBoundFile(
            binding: fileBinding,
            providerConflictVersions: .none
        )
    )
}

public func openObservedBoundDocument(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID,
    text: String,
    observation: ObservedBoundFile
) -> PhonePadState {
    let identityMatchIndex = state.tabs.firstIndex(where: { tab in
        guard let existingBinding = tab.document.fileBinding else {
            return false
        }
        guard let existingIdentity = existingBinding.identity,
              let candidateIdentity = observation.binding.identity else {
            return false
        }
        return existingIdentity == candidateIdentity
    })
    let locatorMatchIndex = state.tabs.firstIndex(where: { tab in
        guard let existingBinding = tab.document.fileBinding else {
            return false
        }
        return existingBinding.locatorURL.standardizedFileURL
            == observation.binding.locatorURL.standardizedFileURL
    })
    if let identityMatchIndex,
       let locatorMatchIndex,
       identityMatchIndex != locatorMatchIndex {
        let locatorTab = state.tabs[locatorMatchIndex]
        let conflictedDocument = PhonePadDocument(
            id: locatorTab.document.id,
            title: locatorTab.document.title,
            text: locatorTab.document.text,
            fileBinding: locatorTab.document.fileBinding,
            recoveryFileReference: locatorTab.document.recoveryFileReference,
            fileConflict: .stableIdentityChanged,
            isUnsaved: locatorTab.document.isUnsaved,
            recoveryState: locatorTab.document.recoveryState
        )
        var tabs = state.tabs
        tabs[locatorMatchIndex] = PhonePadTab(
            id: locatorTab.id,
            document: conflictedDocument,
            displaySettings: locatorTab.displaySettings
        )
        return PhonePadState(tabs: tabs, activeTabID: locatorTab.id)
    }
    let existingIndex = identityMatchIndex ?? locatorMatchIndex
    if let existingIndex,
       let existingBinding = state.tabs[existingIndex].document.fileBinding {
        let existingTab = state.tabs[existingIndex]
        let result = reconcileFileBinding(
            baseline: existingBinding,
            observation: observation
        )
        let retainedBinding: FileBinding
        let fileConflict: FileConflict?
        switch result {
        case let .continuous(updatedBinding):
            retainedBinding = updatedBinding
            fileConflict = existingTab.document.fileConflict
        case let .conflicted(binding, conflict):
            retainedBinding = binding
            fileConflict = conflict
        }
        let reconciledDocument = PhonePadDocument(
            id: existingTab.document.id,
            title: existingTab.document.title,
            text: existingTab.document.text,
            fileBinding: retainedBinding,
            recoveryFileReference: makeRecoveryFileReference(
                fileBinding: retainedBinding
            ),
            fileConflict: fileConflict,
            isUnsaved: existingTab.document.isUnsaved,
            recoveryState: existingTab.document.recoveryState
        )
        var tabs = state.tabs
        tabs[existingIndex] = PhonePadTab(
            id: existingTab.id,
            document: reconciledDocument,
            displaySettings: existingTab.displaySettings
        )
        return PhonePadState(tabs: tabs, activeTabID: existingTab.id)
    }
    let fileConflict: FileConflict?
    switch observation.providerConflictVersions {
    case .none:
        fileConflict = nil
    case let .unresolved(count):
        fileConflict = .unresolvedProviderVersions(count: count)
    }
    let document = PhonePadDocument(
        id: documentID,
        title: observation.binding.displayName.value,
        text: text,
        fileBinding: observation.binding,
        recoveryFileReference: makeRecoveryFileReference(
            fileBinding: observation.binding
        ),
        fileConflict: fileConflict,
        isUnsaved: false,
        recoveryState: .clean
    )
    let tab = PhonePadTab(
        id: tabID,
        document: document,
        displaySettings: .initial
    )
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

func isPristineSoleUntitled(state: PhonePadState) -> Bool {
    guard state.tabs.count == 1, let document = state.tabs.first?.document else {
        return false
    }
    return document.title == "Untitled"
        && document.text.isEmpty
        && document.fileBinding == nil
        && document.fileConflict == nil
        && !document.isUnsaved
        && document.recoveryState == .clean
}

private func makeSavedBoundDocument(
    document: PhonePadDocument,
    encodedFile: EncodedTextFile,
    fileBinding: FileBinding
) throws -> PhonePadDocument {
    guard fileBinding.digest == encodedFile.digest else {
        throw SavedDocumentTransitionError.bindingDigestDoesNotMatchOutput
    }
    guard fileBinding.encoding == encodedFile.encoding else {
        throw SavedDocumentTransitionError.bindingEncodingDoesNotMatchOutput
    }
    guard fileBinding.lineEnding == encodedFile.lineEnding else {
        throw SavedDocumentTransitionError.bindingLineEndingDoesNotMatchOutput
    }
    return PhonePadDocument(
        id: document.id,
        title: fileBinding.displayName.value,
        text: encodedFile.text,
        fileBinding: fileBinding,
        isUnsaved: false,
        recoveryState: .clean
    )
}

private func requireActiveTab(state: PhonePadState) throws -> PhonePadTab {
    guard let tab = state.tabs.first(where: { $0.id == state.activeTabID }) else {
        throw PhonePadStateError.activeTabMissing(state.activeTabID)
    }
    return tab
}

private func requireTabContainingDocument(
    state: PhonePadState,
    documentID: DocumentID
) throws -> PhonePadTab {
    guard let tab = state.tabs.first(where: {
        $0.document.id == documentID
    }) else {
        throw PhonePadStateError.documentMissing(documentID)
    }
    return tab
}

func requireFileBindingAvailableToDocument(
    state: PhonePadState,
    documentID: DocumentID,
    candidate: FileBinding
) throws {
    if let candidateIdentity = candidate.identity,
       let conflictingDocumentID = state.tabs.first(where: { tab in
           guard tab.document.id != documentID,
                 let identity = tab.document.fileBinding?.identity else {
               return false
           }
           return identity == candidateIdentity
       })?.document.id {
        throw PhonePadStateError.fileBindingIdentityCollision(
            documentID: documentID,
            conflictingDocumentID: conflictingDocumentID
        )
    }
    if let conflictingDocumentID = state.tabs.first(where: { tab in
        guard tab.document.id != documentID,
              let locatorURL = tab.document.fileBinding?.locatorURL else {
            return false
        }
        return locatorURL.standardizedFileURL
            == candidate.locatorURL.standardizedFileURL
    })?.document.id {
        throw PhonePadStateError.fileBindingLocatorCollision(
            documentID: documentID,
            conflictingDocumentID: conflictingDocumentID
        )
    }
}

private func replacingTab(
    state: PhonePadState,
    with replacement: PhonePadTab
) throws -> PhonePadState {
    guard let index = state.tabs.firstIndex(where: {
        $0.document.id == replacement.document.id
    }) else {
        throw PhonePadStateError.documentMissing(replacement.document.id)
    }
    var tabs = state.tabs
    tabs[index] = replacement
    return PhonePadState(tabs: tabs, activeTabID: state.activeTabID)
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
