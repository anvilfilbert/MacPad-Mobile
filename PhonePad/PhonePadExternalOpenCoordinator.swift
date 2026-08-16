import Foundation
import PhonePadCore

func uniqueImportedCopyCleanupTokens(
    _ tokens: [ImportedCopyCleanupToken]
) -> [ImportedCopyCleanupToken] {
    var seen: Set<ImportedCopyCleanupToken> = []
    return tokens.filter { token in
        seen.insert(token).inserted
    }
}

func externalOpenCandidate(
    _ candidate: FileOpenCandidate,
    matches claim: FileOpenCandidate
) -> Bool {
    candidate.locatorURL.standardizedFileURL
        == claim.locatorURL.standardizedFileURL
        && candidate.identity == claim.identity
        && candidate.digest == claim.digest
        && candidate.providerConflictVersions
            == claim.providerConflictVersions
}

enum PhonePadExternalOpenActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case commitRequestMissing
    case activeLocatorCollisionAmbiguous([DocumentID])
    case durableDetachedSourceIdentityChanged(DocumentID)
    case durableDetachedSourceContentChanged(DocumentID)
    case durableDetachedSourceHasUnresolvedProviderVersions(
        documentID: DocumentID,
        count: Int
    )
    case recoveryCollisionAmbiguous([DocumentID])
    case recoveryItemMissing(DocumentID)
    case recoveryMatchChanged(DocumentID)
    case rejectedFileCleanupFailed(
        rejection: FileAccessConnectorError,
        cleanup: ImportedCopyCleanupFailure
    )
    case cleanupMustFinishBeforeDismissal
    case cleanupNotRequired
    case cleanupRequiresRecoveryProtection(DocumentID)

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            return "Another File, recovery, or Tab action is still running. Wait for it to finish and retry External Open."
        case .commitRequestMissing:
            return "External Open no longer matches the pending editor commit. Keep the current Document open and retry."
        case let .activeLocatorCollisionAmbiguous(documentIDs):
            let identifiers = documentIDs
                .map { $0.rawValue.uuidString }
                .joined(separator: ", ")
            return "Selected File matches multiple open Documents (\(identifiers)). Close duplicate Tabs before retrying Open."
        case let .durableDetachedSourceIdentityChanged(documentID):
            return "Selected File identity changed since protected Document \(documentID.rawValue.uuidString) was opened. Existing edits were preserved; use Save As or close that Document before opening this File version."
        case let .durableDetachedSourceContentChanged(documentID):
            return "Selected File content changed since this protected Document was opened (Document \(documentID.rawValue.uuidString)). Existing edits were preserved; use Save As or close that Document before opening this File version."
        case let .durableDetachedSourceHasUnresolvedProviderVersions(
            documentID,
            count
        ):
            return "Selected File has \(count) unresolved provider version(s) for protected Document \(documentID.rawValue.uuidString). Existing edits were preserved; resolve provider versions before retrying Open."
        case let .recoveryCollisionAmbiguous(documentIDs):
            let identifiers = documentIDs
                .map { $0.rawValue.uuidString }
                .joined(separator: ", ")
            return "External File matches multiple preserved Documents (\(identifiers)). Resolve those recovery items before retrying Open."
        case let .recoveryItemMissing(documentID):
            return "Preserved work for Document \(documentID.rawValue.uuidString) is no longer available. Refresh recovery data and retry External Open."
        case let .recoveryMatchChanged(documentID):
            return "External File no longer matches preserved Document \(documentID.rawValue.uuidString). Review the File and retry the Open decision."
        case let .rejectedFileCleanupFailed(rejection, cleanup):
            return rejection.localizedDescription + " "
                + importedCopyCleanupFailureMessage(cleanup)
        case .cleanupMustFinishBeforeDismissal:
            return "Imported File cleanup must finish before External Open can be dismissed. Retry Cleanup."
        case .cleanupNotRequired:
            return "No imported File copy cleanup is waiting. Open another supplied File to continue."
        case let .cleanupRequiresRecoveryProtection(documentID):
            return "Imported File copy cleanup for Document \(documentID.rawValue.uuidString) is deferred until its recovery checkpoint is protected. Retry Recovery before retrying cleanup."
        }
    }
}

func importedCopyCleanupFailureMessage(
    _ failure: ImportedCopyCleanupFailure
) -> String {
    switch failure {
    case .unknownToken:
        return "Imported File cleanup authorization expired. The protected Document remains available; reopen the supplied File only if cleanup is still needed."
    case .itemChanged:
        return "Imported File cleanup stopped because the Inbox item changed. The protected Document remains available; review the item before retrying cleanup."
    case let .verificationFailed(code):
        return "Imported File cleanup could not verify the Inbox item (system code \(code)). The protected Document remains available; retry cleanup."
    case let .fileCoordinationFailed(code):
        return "Imported File cleanup coordination failed (system code \(code)). The protected Document remains available; retry cleanup."
    case .fileCoordinationAccessorNotInvoked:
        return "Imported File cleanup did not receive the coordinated Inbox item. The protected Document remains available; retry cleanup."
    case let .deletionFailed(code):
        return "Imported File cleanup could not remove the verified Inbox copy (system code \(code)). The protected Document remains available; retry cleanup."
    case let .journal(error):
        return "Imported File cleanup journal failed. \(error.localizedDescription) Retry cleanup."
    }
}

func externalOpenDetachmentNotice(
    reason: FileOpenDetachmentReason
) -> String {
    switch reason {
    case .copyRequired:
        return "Opened supplied File copy as a protected unsaved Document. Use Save As to choose a durable location."
    case .notWritable:
        return "Opened read-only File as a protected unsaved Document. Use Save As to choose a writable location."
    case .writabilityNotReported:
        return "Opened File as a protected unsaved Document because its provider did not report write access. Use Save As to choose a durable location."
    case let .writabilityInspectionFailed(code):
        return "Opened File as a protected unsaved Document because write access could not be verified (system code \(code)). Use Save As to choose a durable location."
    case let .bookmarkCreationFailed(code):
        return "Opened File as a protected unsaved Document because durable access could not be created (system code \(code)). Use Save As to choose a durable location."
    case let .bookmarkResolutionFailed(code):
        return "Opened File as a protected unsaved Document because durable access could not be resolved (system code \(code)). Use Save As to choose a durable location."
    case .bookmarkIsStale:
        return "Opened File as a protected unsaved Document because its durable access reference is stale. Use Save As to choose a durable location."
    case let .bookmarkVerificationFailed(code):
        return "Opened File as a protected unsaved Document because durable access could not be verified (system code \(code)). Use Save As to choose a durable location."
    case .bookmarkResolvedToDifferentFile:
        return "Opened File as a protected unsaved Document because durable access resolved to a different File. Use Save As to choose a durable location."
    }
}

struct PendingExternalOpenRecoveryPrompt: Equatable, Sendable {
    let recoveryDocumentID: DocumentID
    let title: String
}

struct ExternalOpenDocumentNotice: Equatable, Sendable {
    let documentID: DocumentID
    let message: String
}

struct ExternalOpenRecoveryProtectionFailure: Equatable, Sendable {
    let documentID: DocumentID
    let message: String
}

struct ExternalOpenEphemeralClaim: Equatable, Sendable {
    let candidate: FileOpenCandidate
}

enum AuthoritativeEphemeralOpenMatch: Equatable, Sendable {
    case none
    case item(DocumentID)
    case ambiguous([DocumentID])
}

enum AuthoritativeActiveOpenMatch: Equatable, Sendable {
    case none
    case ephemeral([DocumentID])
    case durable(DocumentID)
}

struct QueuedExternalOpenRequest: Equatable, Sendable {
    let id: UUID
    let request: PhonePadExternalOpenRequest
    let documentID: DocumentID
    let tabID: TabID
    let importedCopyCleanupTokens: [ImportedCopyCleanupToken]
    let importedCopyCleanupCapture: ImportedCopyCleanupCapture
}

enum ImportedCopyCleanupCapture: Equatable, Sendable {
    case notRequired
    case candidate(ImportedCopyCleanupCandidate)
    case inspectionFailed(FileAccessConnectorError)
}

struct ExternalOpenCleanupPreflightFailure: Equatable, Sendable {
    let requestID: UUID
    let message: String
}

struct PendingExternalOpenDecision: Equatable, Sendable {
    let request: QueuedExternalOpenRequest
    let recoveryMatch: RecoveryFileOpenMatch
    let importedCopyCleanupTokens: [ImportedCopyCleanupToken]
}

enum PreparedExternalOpenPayload: Equatable, Sendable {
    case bound(
        prepared: PreparedBoundDocumentOpen,
        snapshot: PresentedTextFileSnapshot
    )
    case detached(
        prepared: PreparedDetachedDocumentOpen,
        openedFile: OpenedDetachedTextFile
    )

    var candidate: FileOpenCandidate {
        switch self {
        case let .bound(prepared, _):
            return prepared.candidate
        case let .detached(prepared, _):
            return prepared.candidate
        }
    }

    var importedCopyCleanupToken: ImportedCopyCleanupToken? {
        switch self {
        case .bound:
            return nil
        case let .detached(_, openedFile):
            return openedFile.importedCopyCleanupToken
        }
    }

    var detachmentReason: FileOpenDetachmentReason? {
        switch self {
        case .bound:
            return nil
        case let .detached(_, openedFile):
            return openedFile.reason
        }
    }

    var provisionalDocumentID: DocumentID {
        switch self {
        case let .bound(prepared, _):
            return prepared.documentID
        case let .detached(prepared, _):
            return prepared.documentID
        }
    }
}

enum ExternalOpenPreparation: Equatable, Sendable {
    case activateExisting(
        state: PhonePadState,
        provisionalDocumentID: DocumentID,
        candidate: FileOpenCandidate,
        importedCopyCleanupToken: ImportedCopyCleanupToken?,
        detachmentReason: FileOpenDetachmentReason?
    )
    case prepared(PreparedExternalOpenPayload)

    var candidate: FileOpenCandidate {
        switch self {
        case let .activateExisting(_, _, candidate, _, _):
            return candidate
        case let .prepared(payload):
            return payload.candidate
        }
    }

    var importedCopyCleanupToken: ImportedCopyCleanupToken? {
        switch self {
        case let .activateExisting(_, _, _, cleanupToken, _):
            return cleanupToken
        case let .prepared(payload):
            return payload.importedCopyCleanupToken
        }
    }

    var detachmentReason: FileOpenDetachmentReason? {
        switch self {
        case let .activateExisting(_, _, _, _, reason):
            return reason
        case let .prepared(payload):
            return payload.detachmentReason
        }
    }
}

enum ExternalOpenCommitResult: Equatable, Sendable {
    case complete
    case recoveryProtectionFailed
}

struct PendingImportedCopyCleanup: Equatable, Sendable {
    let documentID: DocumentID?
    var tokens: [ImportedCopyCleanupToken]
}

struct PhonePadExternalOpenPresentation: Equatable, Sendable {
    let commitRequestID: UUID?
    let isInProgress: Bool
    let recoveryPrompt: PendingExternalOpenRecoveryPrompt?
    let errorMessage: String?
    let cleanupRequired: Bool
    let notice: String?
    let errorRequiresDismissal: Bool
}

struct PhonePadExternalOpenWorkspaceActivity: Equatable, Sendable {
    let presentersShouldBeActive: Bool
    let tabTransitionInProgress: Bool
    let fileSaveInProgress: Bool
    let fileSaveCleanupRequired: Bool
    let saveAsReplacementPending: Bool
    let recoveryActionInProgress: Bool
    let tabClosePending: Bool
    let fileConflictPresented: Bool

    var permitsExclusiveAction: Bool {
        !tabTransitionInProgress
            && !fileSaveInProgress
            && !fileSaveCleanupRequired
            && !saveAsReplacementPending
            && !recoveryActionInProgress
            && !tabClosePending
    }
}

@MainActor
protocol PhonePadExternalOpenWorkspace: AnyObject {
    var externalOpenWorkspaceState: PhonePadState { get }
    var externalOpenWorkspaceRecoveryItems: [RecoveryItemSummary] { get }
    var externalOpenWorkspaceRecoveryError: String? { get }
    var externalOpenWorkspaceActivity:
        PhonePadExternalOpenWorkspaceActivity { get }

    func replaceExternalOpenWorkspaceState(_ state: PhonePadState)
    func replaceExternalOpenWorkspaceRecoveryItems(
        _ recoveryItems: [RecoveryItemSummary]
    )
    func setExternalOpenWorkspaceRecoveryError(_ message: String?)
    func markExternalOpenPresenterRefreshPending()
    func notifyExternalOpenPresentationChanged()
    func validateExternalOpenCommittedDocument(
        _ committedDocument: CommittedEditorDocument
    ) throws
    func protectExternalOpenCommittedDocument(
        _ committedDocument: CommittedEditorDocument
    ) async throws
    func presentExternalOpenFileConflictIfNeeded()
    func resumeActivationWorkAfterExternalOpen() async
    func applyExternalOpenCheckpointCompletion(
        _ completion: RecoveryCheckpointCompletion
    ) async -> Bool
    func protectExternalOpenRecovery(
        _ transition: RecoveryEditTransition
    ) async -> RecoveryCheckpointCompletion
}

@MainActor
final class PhonePadExternalOpenCoordinator {
    private unowned let workspace: any PhonePadExternalOpenWorkspace
    let recoveryStore: any RecoveryStoring
    let fileAccessConnector: FileAccessConnector

    var externalOpenCommitRequestID: UUID? {
        willSet { publishChange() }
    }
    var externalOpenInProgress: Bool {
        willSet { publishChange() }
    }
    var pendingExternalOpenRecoveryPrompt: PendingExternalOpenRecoveryPrompt? {
        willSet { publishChange() }
    }
    var externalOpenError: String? {
        willSet { publishChange() }
    }
    var externalOpenCleanupRequired: Bool {
        willSet { publishChange() }
    }
    var externalOpenGeneralNotice: String? {
        willSet { publishChange() }
    }
    var externalOpenDocumentNotice: ExternalOpenDocumentNotice? {
        willSet { publishChange() }
    }
    var importedCopyCleanupJournalNotice: String? {
        willSet { publishChange() }
    }
    var externalOpenQueue: [QueuedExternalOpenRequest] {
        willSet { publishChange() }
    }
    var externalOpenCleanupPreflightBatchIDs: Set<UUID> {
        willSet { publishChange() }
    }
    var externalOpenCleanupPreflightFailures: [
        UUID: ExternalOpenCleanupPreflightFailure
    ] {
        willSet { publishChange() }
    }
    var pendingExternalOpenDecision: PendingExternalOpenDecision? {
        willSet { publishChange() }
    }
    var pendingExternalOpenCleanups: [PendingImportedCopyCleanup] {
        willSet { publishChange() }
    }
    var externalOpenCleanupInProgress: Bool {
        willSet { publishChange() }
    }
    var externalOpenEphemeralClaims: [
        DocumentID: [ExternalOpenEphemeralClaim]
    ] {
        willSet { publishChange() }
    }
    var terminalExternalOpenErrorPendingDismissal: Bool {
        willSet { publishChange() }
    }
    var didReconcileImportedCopyCleanupJournalOnActivation: Bool {
        willSet { publishChange() }
    }
    var importedCopyCleanupJournalRetryRequired: Bool {
        willSet { publishChange() }
    }
    var importedCopyCleanupJournalErrorMessage: String? {
        willSet { publishChange() }
    }
    var externalOpenRecoveryProtectionFailure:
        ExternalOpenRecoveryProtectionFailure? {
        willSet { publishChange() }
    }

    init(
        workspace: any PhonePadExternalOpenWorkspace,
        recoveryStore: any RecoveryStoring,
        fileAccessConnector: FileAccessConnector
    ) {
        self.workspace = workspace
        self.recoveryStore = recoveryStore
        self.fileAccessConnector = fileAccessConnector
        externalOpenCommitRequestID = nil
        externalOpenInProgress = false
        pendingExternalOpenRecoveryPrompt = nil
        externalOpenError = nil
        externalOpenCleanupRequired = false
        externalOpenGeneralNotice = nil
        externalOpenDocumentNotice = nil
        importedCopyCleanupJournalNotice = nil
        externalOpenQueue = []
        externalOpenCleanupPreflightBatchIDs = []
        externalOpenCleanupPreflightFailures = [:]
        pendingExternalOpenDecision = nil
        pendingExternalOpenCleanups = []
        externalOpenCleanupInProgress = false
        externalOpenEphemeralClaims = [:]
        terminalExternalOpenErrorPendingDismissal = false
        didReconcileImportedCopyCleanupJournalOnActivation = true
        importedCopyCleanupJournalRetryRequired = false
        importedCopyCleanupJournalErrorMessage = nil
        externalOpenRecoveryProtectionFailure = nil
    }

    private func publishChange() {
        workspace.notifyExternalOpenPresentationChanged()
    }

    var state: PhonePadState {
        get { workspace.externalOpenWorkspaceState }
        set { workspace.replaceExternalOpenWorkspaceState(newValue) }
    }

    var recoveryItems: [RecoveryItemSummary] {
        get { workspace.externalOpenWorkspaceRecoveryItems }
        set {
            workspace.replaceExternalOpenWorkspaceRecoveryItems(newValue)
        }
    }

    var recoveryError: String? {
        get { workspace.externalOpenWorkspaceRecoveryError }
        set { workspace.setExternalOpenWorkspaceRecoveryError(newValue) }
    }

    var workspaceActivity: PhonePadExternalOpenWorkspaceActivity {
        workspace.externalOpenWorkspaceActivity
    }

    var presentersShouldBeActive: Bool {
        workspaceActivity.presentersShouldBeActive
    }

    func markPresenterRefreshPending() {
        workspace.markExternalOpenPresenterRefreshPending()
    }

    func validateCommittedDocument(
        _ committedDocument: CommittedEditorDocument
    ) throws {
        try workspace.validateExternalOpenCommittedDocument(
            committedDocument
        )
    }

    func protectCommittedDocumentForActiveTransition(
        _ committedDocument: CommittedEditorDocument
    ) async throws {
        try await workspace.protectExternalOpenCommittedDocument(
            committedDocument
        )
    }

    func presentActiveFileConflictIfNeeded() {
        workspace.presentExternalOpenFileConflictIfNeeded()
    }

    func resumePendingActivationWorkAfterExclusiveAction() async {
        await workspace.resumeActivationWorkAfterExternalOpen()
    }

    func applyRecoveryCheckpointCompletion(
        _ completion: RecoveryCheckpointCompletion
    ) async -> Bool {
        await workspace.applyExternalOpenCheckpointCompletion(completion)
    }

    func protectRecoveryForExternalOpen(
        _ transition: RecoveryEditTransition
    ) async -> RecoveryCheckpointCompletion {
        await workspace.protectExternalOpenRecovery(transition)
    }

    var cleanupPreflightInProgress: Bool {
        !externalOpenCleanupPreflightBatchIDs.isEmpty
    }

    var liveCleanupTokens: Set<ImportedCopyCleanupToken> {
        Set(
            externalOpenQueue.flatMap(\.importedCopyCleanupTokens)
                + (pendingExternalOpenDecision?
                    .importedCopyCleanupTokens ?? [])
        )
    }

    var queueRequiresCleanupPreflight: Bool {
        externalOpenQueue.contains(where: cleanupPreflightRequired)
    }

    var ownsWorkspace: Bool {
        !externalOpenQueue.isEmpty
            || externalOpenCommitRequestID != nil
            || externalOpenInProgress
            || pendingExternalOpenDecision != nil
    }

    var hasQueuedRequestOrDecision: Bool {
        !externalOpenQueue.isEmpty || pendingExternalOpenDecision != nil
    }

    var errorRequiresDismissal: Bool {
        terminalExternalOpenErrorPendingDismissal
    }

    var hasPendingDecision: Bool {
        pendingExternalOpenDecision != nil
    }

    var blocksRecoveryCatalogMutation: Bool {
        pendingExternalOpenDecision != nil || externalOpenCleanupInProgress
    }

    var activationReconciliationPending: Bool {
        !didReconcileImportedCopyCleanupJournalOnActivation
    }

    func presentation(state: PhonePadState) ->
        PhonePadExternalOpenPresentation {
        PhonePadExternalOpenPresentation(
            commitRequestID: externalOpenCommitRequestID,
            isInProgress: externalOpenInProgress,
            recoveryPrompt: pendingExternalOpenRecoveryPrompt,
            errorMessage: externalOpenError,
            cleanupRequired: externalOpenCleanupRequired,
            notice: notice(state: state),
            errorRequiresDismissal:
                terminalExternalOpenErrorPendingDismissal
        )
    }

    func pausePendingCommitForInactiveScene() {
        guard !externalOpenInProgress else {
            return
        }
        externalOpenCommitRequestID = nil
    }

    func markActivationReconciliationPending() {
        didReconcileImportedCopyCleanupJournalOnActivation = false
    }

    func reconcileCleanupForActiveSceneIfPossible(
        presentersShouldBeActive: Bool,
        fileSaveInProgress: Bool
    ) async {
        guard presentersShouldBeActive,
              !didReconcileImportedCopyCleanupJournalOnActivation,
              !externalOpenInProgress,
              !fileSaveInProgress,
              !cleanupPreflightInProgress,
              !queueRequiresCleanupPreflight,
              liveCleanupTokens.isEmpty else {
            return
        }
        didReconcileImportedCopyCleanupJournalOnActivation = true
        externalOpenCommitRequestID = nil
        externalOpenCleanupInProgress = true
        _ = await reconcileImportedCopyCleanupJournal()
        externalOpenCleanupInProgress = false
        didReconcileImportedCopyCleanupJournalOnActivation =
            !importedCopyCleanupJournalRetryRequired
    }

    func removeEphemeralClaims(documentID: DocumentID) {
        externalOpenEphemeralClaims.removeValue(forKey: documentID)
    }

    func notice(state: PhonePadState) -> String? {
        var messages: [String] = []
        if let externalOpenGeneralNotice {
            messages.append(externalOpenGeneralNotice)
        }
        if let importedCopyCleanupJournalNotice {
            messages.append(importedCopyCleanupJournalNotice)
        }
        if let notice = externalOpenDocumentNotice,
           let document = state.tabs.first(where: { tab in
               tab.document.id == notice.documentID
           })?.document,
           state.activeTab.document.id == notice.documentID,
           document.fileBinding == nil,
           document.isUnsaved,
           document.recoveryState == .protectedUnsaved {
            messages.append(notice.message)
        }
        guard !messages.isEmpty else {
            return nil
        }
        return messages.joined(separator: " ")
    }

    func cleanupPreflightRequired(
        request: QueuedExternalOpenRequest
    ) -> Bool {
        switch request.importedCopyCleanupCapture {
        case .notRequired:
            return false
        case .inspectionFailed:
            return true
        case .candidate:
            return request.importedCopyCleanupTokens.isEmpty
        }
    }

    func enqueue(requests: [QueuedExternalOpenRequest]) {
        externalOpenQueue.append(contentsOf: requests)
    }

    func beginningCleanupPreflight(
        batchID: UUID
    ) {
        externalOpenCleanupPreflightBatchIDs.insert(batchID)
    }

    func recordingCleanupPreflightFailure(
        _ failure: ExternalOpenCleanupPreflightFailure
    ) {
        externalOpenCleanupPreflightFailures[failure.requestID] = failure
    }

    func clearingCleanupPreflightFailure(
        requestID: UUID
    ) {
        externalOpenCleanupPreflightFailures.removeValue(
            forKey: requestID
        )
    }

    func completingCleanupPreflight(
        batchID: UUID
    ) {
        externalOpenCleanupPreflightBatchIDs.remove(batchID)
    }

    func replacingQueuedRequest(
        _ request: QueuedExternalOpenRequest
    ) throws {
        guard let requestIndex = externalOpenQueue.firstIndex(where: {
            $0.id == request.id
        }) else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        externalOpenQueue[requestIndex] = request
    }

    func retainingCleanupTokenForRetry(
        _ token: ImportedCopyCleanupToken?,
        requestID: UUID
    ) {
        guard let token else {
            return
        }
        if let decision = pendingExternalOpenDecision,
           decision.request.id == requestID {
            pendingExternalOpenDecision = PendingExternalOpenDecision(
                request: decision.request,
                recoveryMatch: decision.recoveryMatch,
                importedCopyCleanupTokens: uniqueImportedCopyCleanupTokens(
                    decision.importedCopyCleanupTokens + [token]
                )
            )
            return
        }
        guard let requestIndex = externalOpenQueue.firstIndex(where: {
            $0.id == requestID
        }) else {
            retainingCleanup(
                documentID: nil,
                tokens: [token]
            )
            return
        }
        let request = externalOpenQueue[requestIndex]
        externalOpenQueue[requestIndex] = QueuedExternalOpenRequest(
            id: request.id,
            request: request.request,
            documentID: request.documentID,
            tabID: request.tabID,
            importedCopyCleanupTokens: uniqueImportedCopyCleanupTokens(
                request.importedCopyCleanupTokens + [token]
            ),
            importedCopyCleanupCapture: request.importedCopyCleanupCapture
        )
    }

    func retainingCleanup(
        documentID: DocumentID?,
        tokens: [ImportedCopyCleanupToken]
    ) {
        guard !tokens.isEmpty else {
            return
        }
        pendingExternalOpenCleanups.append(
            PendingImportedCopyCleanup(
                documentID: documentID,
                tokens: tokens
            )
        )
    }

    func completingRequest(
        requestID: UUID
    ) throws {
        guard externalOpenQueue.first?.id == requestID else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        externalOpenQueue.removeFirst()
        externalOpenCleanupPreflightFailures.removeValue(
            forKey: requestID
        )
        if externalOpenError != importedCopyCleanupJournalErrorMessage {
            externalOpenError = nil
        }
    }

    func retainingEphemeralClaim(
        documentID: DocumentID,
        candidate: FileOpenCandidate
    ) {
        let standardizedCandidate = FileOpenCandidate(
            locatorURL: candidate.locatorURL.standardizedFileURL,
            identity: candidate.identity,
            digest: candidate.digest,
            providerConflictVersions: candidate.providerConflictVersions
        )
        var claims = externalOpenEphemeralClaims[documentID, default: []]
        claims.removeAll { claim in
            claim.candidate.locatorURL.standardizedFileURL
                == standardizedCandidate.locatorURL
        }
        claims.append(
            ExternalOpenEphemeralClaim(candidate: standardizedCandidate)
        )
        externalOpenEphemeralClaims[documentID] = claims
    }

    func removingEphemeralClaims(
        documentID: DocumentID
    ) {
        externalOpenEphemeralClaims.removeValue(forKey: documentID)
    }

    func authoritativeEphemeralMatch(
        candidate: FileOpenCandidate,
        documentIDs: [DocumentID]
    ) -> AuthoritativeEphemeralOpenMatch {
        let expectedDocumentIDs = Set(documentIDs)
        let matchingDocumentIDs = externalOpenEphemeralClaims.compactMap {
            documentID,
            claims -> DocumentID? in
            guard expectedDocumentIDs.contains(documentID),
                  claims.contains(where: { claim in
                      externalOpenCandidate(
                          candidate,
                          matches: claim.candidate
                      )
                  }) else {
                return nil
            }
            return documentID
        }.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        switch matchingDocumentIDs.count {
        case 0:
            return .none
        case 1:
            return .item(matchingDocumentIDs[0])
        default:
            return .ambiguous(matchingDocumentIDs)
        }
    }

    func invalidatingEphemeralClaims(
        documentIDs: [DocumentID],
        locatorURL: URL
    ) {
        let expectedDocumentIDs = Set(documentIDs)
        let standardizedLocator = locatorURL.standardizedFileURL
        for documentID in expectedDocumentIDs {
            guard let existingClaims =
                    externalOpenEphemeralClaims[documentID] else {
                continue
            }
            let retainedClaims = existingClaims.filter { claim in
                claim.candidate.locatorURL.standardizedFileURL
                    != standardizedLocator
            }
            if retainedClaims.isEmpty {
                externalOpenEphemeralClaims.removeValue(
                    forKey: documentID
                )
            } else {
                externalOpenEphemeralClaims[documentID] = retainedClaims
            }
        }
    }
}
