import Foundation

public enum FileOpenAccessIntent: Equatable, Sendable {
    case inPlace
    case copyRequired
}

public struct FileOpenCandidate: Equatable, Sendable {
    public let locatorURL: URL
    public let identity: FileIdentity?
    public let digest: FileDigest
    public let providerConflictVersions: FileProviderConflictVersions

    public init(
        locatorURL: URL,
        identity: FileIdentity?,
        digest: FileDigest,
        providerConflictVersions: FileProviderConflictVersions
    ) {
        self.locatorURL = locatorURL
        self.identity = identity
        self.digest = digest
        self.providerConflictVersions = providerConflictVersions
    }
}

public struct DetachedFileSnapshot: Equatable, Sendable {
    public let candidate: FileOpenCandidate
    public let displayName: ValidatedFileName
    public let text: String
    public let recoveryFileReference: RecoveryFileReference?

    public init(
        candidate: FileOpenCandidate,
        displayName: ValidatedFileName,
        text: String,
        recoveryFileReference: RecoveryFileReference?
    ) {
        self.candidate = candidate
        self.displayName = displayName
        self.text = text
        self.recoveryFileReference = recoveryFileReference
    }
}

public enum RecoveryFileClaimKind: Equatable, Hashable, Sendable {
    case sourceFile
    case pendingSaveAsDestination
}

public struct ResolvedRecoveryFileClaim: Equatable, Sendable {
    public let documentID: DocumentID
    public let kind: RecoveryFileClaimKind
    public let locatorURL: URL
    public let identity: FileIdentity?

    public init(
        documentID: DocumentID,
        kind: RecoveryFileClaimKind,
        locatorURL: URL,
        identity: FileIdentity?
    ) {
        self.documentID = documentID
        self.kind = kind
        self.locatorURL = locatorURL
        self.identity = identity
    }
}

public struct RecoveryFileOpenMatch: Equatable, Sendable {
    public let documentID: DocumentID
    public let kinds: [RecoveryFileClaimKind]

    public init(
        documentID: DocumentID,
        kinds: [RecoveryFileClaimKind]
    ) {
        self.documentID = documentID
        self.kinds = kinds
    }
}

public enum RecoveryFileOpenCollision: Equatable, Sendable {
    case none
    case item(RecoveryFileOpenMatch)
    case ambiguous([DocumentID])
}

public struct PreparedBoundDocumentOpen: Equatable, Sendable {
    public let expectedState: PhonePadState
    public let openedState: PhonePadState
    public let documentID: DocumentID
    public let tabID: TabID
    public let candidate: FileOpenCandidate

    init(
        expectedState: PhonePadState,
        openedState: PhonePadState,
        documentID: DocumentID,
        tabID: TabID,
        candidate: FileOpenCandidate
    ) {
        self.expectedState = expectedState
        self.openedState = openedState
        self.documentID = documentID
        self.tabID = tabID
        self.candidate = candidate
    }
}

public enum BoundDocumentOpenPreparation: Equatable, Sendable {
    case activateExisting(PhonePadState)
    case prepared(PreparedBoundDocumentOpen)
}

public struct PreparedDetachedDocumentOpen: Equatable, Sendable {
    public let expectedState: PhonePadState
    public let transition: RecoveryEditTransition
    public let documentID: DocumentID
    public let tabID: TabID
    public let candidate: FileOpenCandidate

    init(
        expectedState: PhonePadState,
        transition: RecoveryEditTransition,
        documentID: DocumentID,
        tabID: TabID,
        candidate: FileOpenCandidate
    ) {
        self.expectedState = expectedState
        self.transition = transition
        self.documentID = documentID
        self.tabID = tabID
        self.candidate = candidate
    }
}

public enum DetachedDocumentOpenPreparation: Equatable, Sendable {
    case activateExisting(PhonePadState)
    case prepared(PreparedDetachedDocumentOpen)
}

public enum RecoveredFileOpenError: Error, Equatable, Sendable {
    case fileReferenceMissing(DocumentID)
}

extension RecoveredFileOpenError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .fileReferenceMissing(documentID):
            return "Recovered Document \(documentID.rawValue.uuidString) has no durable original File reference. Open its edits detached and use Save As."
        }
    }
}

public func prepareBoundDocumentOpen(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID,
    text: String,
    observation: ObservedBoundFile
) -> BoundDocumentOpenPreparation {
    let openedState = openObservedBoundDocument(
        state: state,
        documentID: documentID,
        tabID: tabID,
        text: text,
        observation: observation
    )
    guard openedState.tabs.contains(where: {
        $0.id == tabID && $0.document.id == documentID
    }) else {
        return .activateExisting(openedState)
    }
    return .prepared(
        PreparedBoundDocumentOpen(
            expectedState: state,
            openedState: openedState,
            documentID: documentID,
            tabID: tabID,
            candidate: FileOpenCandidate(
                locatorURL: observation.binding.locatorURL,
                identity: observation.binding.identity,
                digest: observation.binding.digest,
                providerConflictVersions: observation.providerConflictVersions
            )
        )
    )
}

public func commitPreparedBoundDocumentOpen(
    state: PhonePadState,
    prepared: PreparedBoundDocumentOpen
) throws -> PhonePadState {
    guard state == prepared.expectedState else {
        throw PhonePadStateError.workspaceChangedSinceFileOpenPreparation(
            prepared.documentID
        )
    }
    return prepared.openedState
}

public func activateAuthoritativelyMatchedBoundFileOpen(
    state: PhonePadState,
    documentID: DocumentID,
    candidate: FileOpenCandidate
) throws -> PhonePadState {
    guard let index = state.tabs.firstIndex(where: { tab in
        tab.document.id == documentID
    }) else {
        throw PhonePadStateError.documentMissing(documentID)
    }
    let tab = state.tabs[index]
    guard let baseline = tab.document.fileBinding else {
        throw PhonePadStateError.documentIsNotBound(documentID)
    }
    let observation = ObservedBoundFile(
        binding: FileBinding(
            locatorURL: candidate.locatorURL,
            bookmark: baseline.bookmark,
            identity: candidate.identity,
            displayName: baseline.displayName,
            digest: candidate.digest,
            encoding: baseline.encoding,
            lineEnding: baseline.lineEnding
        ),
        providerConflictVersions: candidate.providerConflictVersions
    )
    let result = reconcileFileBinding(
        baseline: baseline,
        observation: observation
    )
    let retainedBinding: FileBinding
    let conflict: FileConflict?
    switch result {
    case let .continuous(updatedBinding):
        retainedBinding = updatedBinding
        conflict = tab.document.fileConflict
    case let .conflicted(binding, fileConflict):
        retainedBinding = binding
        conflict = fileConflict
    }
    let document = PhonePadDocument(
        id: tab.document.id,
        title: tab.document.title,
        text: tab.document.text,
        fileBinding: retainedBinding,
        recoveryFileReference: makeRecoveryFileReference(
            fileBinding: retainedBinding
        ),
        fileConflict: conflict,
        isUnsaved: tab.document.isUnsaved,
        recoveryState: tab.document.recoveryState
    )
    var tabs = state.tabs
    tabs[index] = PhonePadTab(
        id: tab.id,
        document: document,
        displaySettings: tab.displaySettings
    )
    return PhonePadState(tabs: tabs, activeTabID: tab.id)
}

public func prepareDetachedDocumentOpen(
    state: PhonePadState,
    documentID: DocumentID,
    tabID: TabID,
    snapshot: DetachedFileSnapshot,
    editedAt: Date
) throws -> DetachedDocumentOpenPreparation {
    let validatedText = try validateEditableDocumentText(text: snapshot.text)
    if let activatedState = activatingExistingFileOpen(
        state: state,
        candidate: snapshot.candidate
    ) {
        return .activateExisting(activatedState)
    }
    guard !state.tabs.contains(where: { $0.id == tabID }) else {
        throw PhonePadStateError.duplicateTabID(tabID)
    }
    guard !state.tabs.contains(where: {
        $0.document.id == documentID
    }) else {
        throw PhonePadStateError.duplicateDocumentID(documentID)
    }

    let document = PhonePadDocument(
        id: documentID,
        title: snapshot.displayName.value,
        text: validatedText,
        fileBinding: nil,
        recoveryFileReference: snapshot.recoveryFileReference,
        isUnsaved: true,
        recoveryState: .checkpointPending
    )
    let tab = PhonePadTab(
        id: tabID,
        document: document,
        displaySettings: .initial
    )
    let openedState = installingExternallyOpenedTab(state: state, tab: tab)
    let envelope = try RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: documentID,
        title: document.title,
        text: document.text,
        editedAt: editedAt,
        fileReference: snapshot.recoveryFileReference,
        pendingSave: nil
    )
    let transition = RecoveryEditTransition(
        state: openedState,
        envelope: envelope
    )
    return .prepared(
        PreparedDetachedDocumentOpen(
            expectedState: state,
            transition: transition,
            documentID: documentID,
            tabID: tabID,
            candidate: snapshot.candidate
        )
    )
}

public func commitPreparedDetachedDocumentOpen(
    state: PhonePadState,
    prepared: PreparedDetachedDocumentOpen
) throws -> RecoveryEditTransition {
    guard state == prepared.expectedState else {
        throw PhonePadStateError.workspaceChangedSinceFileOpenPreparation(
            prepared.documentID
        )
    }
    return prepared.transition
}

public func openExternallyRecoveredDetachedDocument(
    state: PhonePadState,
    envelope: RecoveryEnvelope,
    tabID: TabID
) throws -> PhonePadState {
    if let existingTab = state.tabs.first(where: {
        $0.document.id == envelope.documentID
    }) {
        return PhonePadState(tabs: state.tabs, activeTabID: existingTab.id)
    }
    guard !state.tabs.contains(where: { $0.id == tabID }) else {
        throw PhonePadStateError.duplicateTabID(tabID)
    }
    let validatedText = try validateEditableDocumentText(text: envelope.text)
    let document = PhonePadDocument(
        id: envelope.documentID,
        title: envelope.title,
        text: validatedText,
        fileBinding: nil,
        recoveryFileReference: envelope.fileReference,
        isUnsaved: true,
        recoveryState: .protectedUnsaved
    )
    let tab = PhonePadTab(
        id: tabID,
        document: document,
        displaySettings: .initial
    )
    return installingExternallyOpenedTab(state: state, tab: tab)
}

public func openExternallyRecoveredBoundDocument(
    state: PhonePadState,
    envelope: RecoveryEnvelope,
    tabID: TabID,
    observation: ObservedBoundFile
) throws -> PhonePadState {
    if let existingTab = state.tabs.first(where: {
        $0.document.id == envelope.documentID
    }) {
        return PhonePadState(tabs: state.tabs, activeTabID: existingTab.id)
    }
    guard !state.tabs.contains(where: { $0.id == tabID }) else {
        throw PhonePadStateError.duplicateTabID(tabID)
    }
    guard let fileReference = envelope.fileReference else {
        throw RecoveredFileOpenError.fileReferenceMissing(
            envelope.documentID
        )
    }
    try requireFileBindingAvailableToDocument(
        state: state,
        documentID: envelope.documentID,
        candidate: observation.binding
    )
    let validatedText = try validateEditableDocumentText(text: envelope.text)
    let baseline = recoveryBaselineBinding(
        fileReference: fileReference,
        observation: observation
    )
    let reconciliation = reconcileFileBinding(
        baseline: baseline,
        observation: observation
    )
    let retainedBinding: FileBinding
    let fileConflict: FileConflict?
    switch reconciliation {
    case let .continuous(updatedBinding):
        retainedBinding = updatedBinding
        fileConflict = nil
    case let .conflicted(binding, conflict):
        retainedBinding = binding
        fileConflict = conflict
    }
    let document = PhonePadDocument(
        id: envelope.documentID,
        title: envelope.title,
        text: validatedText,
        fileBinding: retainedBinding,
        recoveryFileReference: makeRecoveryFileReference(
            fileBinding: retainedBinding
        ),
        fileConflict: fileConflict,
        isUnsaved: true,
        recoveryState: .protectedUnsaved
    )
    let tab = PhonePadTab(
        id: tabID,
        document: document,
        displaySettings: .initial
    )
    return installingExternallyOpenedTab(state: state, tab: tab)
}

public func recoveryFileOpenCollision(
    candidate: FileOpenCandidate,
    claims: [ResolvedRecoveryFileClaim]
) -> RecoveryFileOpenCollision {
    var matchedKindsByDocumentID: [DocumentID: Set<RecoveryFileClaimKind>] = [:]
    for claim in claims where fileOpenCandidate(candidate, matches: claim) {
        matchedKindsByDocumentID[claim.documentID, default: []].insert(
            claim.kind
        )
    }
    let matchedDocumentIDs = matchedKindsByDocumentID.keys.sorted {
        $0.rawValue.uuidString < $1.rawValue.uuidString
    }
    guard let documentID = matchedDocumentIDs.first else {
        return .none
    }
    guard matchedDocumentIDs.count == 1 else {
        return .ambiguous(matchedDocumentIDs)
    }
    let kinds = matchedKindsByDocumentID[documentID, default: []].sorted(
        by: recoveryFileClaimKindComesBefore
    )
    return .item(
        RecoveryFileOpenMatch(
            documentID: documentID,
            kinds: kinds
        )
    )
}

private func fileOpenCandidate(
    _ candidate: FileOpenCandidate,
    matches claim: ResolvedRecoveryFileClaim
) -> Bool {
    if let candidateIdentity = candidate.identity,
       let claimedIdentity = claim.identity,
       candidateIdentity == claimedIdentity {
        return true
    }
    return candidate.locatorURL.standardizedFileURL
        == claim.locatorURL.standardizedFileURL
}

private func recoveryFileClaimKindComesBefore(
    _ left: RecoveryFileClaimKind,
    _ right: RecoveryFileClaimKind
) -> Bool {
    switch (left, right) {
    case (.sourceFile, .pendingSaveAsDestination):
        return true
    case (.pendingSaveAsDestination, .sourceFile):
        return false
    case (.sourceFile, .sourceFile),
         (.pendingSaveAsDestination, .pendingSaveAsDestination):
        return false
    }
}

private func installingExternallyOpenedTab(
    state: PhonePadState,
    tab: PhonePadTab
) -> PhonePadState {
    guard !isPristineSoleUntitled(state: state) else {
        return PhonePadState(tabs: [tab], activeTabID: tab.id)
    }
    return PhonePadState(tabs: state.tabs + [tab], activeTabID: tab.id)
}

private func recoveryBaselineBinding(
    fileReference: RecoveryFileReference,
    observation: ObservedBoundFile
) -> FileBinding {
    FileBinding(
        locatorURL: observation.binding.locatorURL,
        bookmark: observation.binding.bookmark,
        identity: fileReference.identity,
        displayName: fileReference.displayName,
        digest: fileReference.cleanDigest,
        encoding: fileReference.encoding,
        lineEnding: fileReference.lineEnding
    )
}

private func activatingExistingFileOpen(
    state: PhonePadState,
    candidate: FileOpenCandidate
) -> PhonePadState? {
    let identityMatchIndex = state.tabs.firstIndex(where: { tab in
        guard let candidateIdentity = candidate.identity else {
            return false
        }
        let existingIdentity = tab.document.fileBinding?.identity
            ?? tab.document.recoveryFileReference?.identity
        return existingIdentity == candidateIdentity
    })
    let locatorMatchIndex = state.tabs.firstIndex(where: { tab in
        guard let locatorURL = tab.document.fileBinding?.locatorURL else {
            return false
        }
        return locatorURL.standardizedFileURL
            == candidate.locatorURL.standardizedFileURL
    })
    if let identityMatchIndex,
       let locatorMatchIndex,
       identityMatchIndex != locatorMatchIndex {
        return markingFileOpenConflict(
            state: state,
            index: locatorMatchIndex,
            conflict: .stableIdentityChanged
        )
    }
    guard let existingIndex = identityMatchIndex ?? locatorMatchIndex else {
        return nil
    }
    guard let binding = state.tabs[existingIndex].document.fileBinding else {
        return PhonePadState(
            tabs: state.tabs,
            activeTabID: state.tabs[existingIndex].id
        )
    }

    let conflict: FileConflict?
    if binding.locatorURL.standardizedFileURL
        == candidate.locatorURL.standardizedFileURL,
       binding.identity != candidate.identity {
        conflict = .stableIdentityChanged
    } else {
        switch candidate.providerConflictVersions {
        case .none where binding.digest != candidate.digest:
            conflict = .contentChanged
        case .none:
            conflict = state.tabs[existingIndex].document.fileConflict
        case let .unresolved(count):
            conflict = .unresolvedProviderVersions(count: count)
        }
    }
    guard let conflict else {
        return PhonePadState(
            tabs: state.tabs,
            activeTabID: state.tabs[existingIndex].id
        )
    }
    return markingFileOpenConflict(
        state: state,
        index: existingIndex,
        conflict: conflict
    )
}

private func markingFileOpenConflict(
    state: PhonePadState,
    index: Int,
    conflict: FileConflict
) -> PhonePadState {
    let tab = state.tabs[index]
    let document = PhonePadDocument(
        id: tab.document.id,
        title: tab.document.title,
        text: tab.document.text,
        fileBinding: tab.document.fileBinding,
        recoveryFileReference: tab.document.recoveryFileReference,
        fileConflict: conflict,
        isUnsaved: tab.document.isUnsaved,
        recoveryState: tab.document.recoveryState
    )
    var tabs = state.tabs
    tabs[index] = PhonePadTab(
        id: tab.id,
        document: document,
        displaySettings: tab.displaySettings
    )
    return PhonePadState(tabs: tabs, activeTabID: tab.id)
}
