import Foundation
import PhonePadCore
import SwiftUI

private struct PendingRecoveryCheckpoint {
    let generation: UInt64
    let checkpointBaseState: PhonePadState
    let recoveryBaselineState: PhonePadState?
    let text: String
    let editedAt: Date
    let firstPendingAt: ContinuousClock.Instant
    let lastEditAt: ContinuousClock.Instant
    let requiresImmediateCheckpoint: Bool
}

private enum PhonePadRecoveryUnavailableActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case recoveryIsAvailable

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            return "Another File, recovery, or Tab action is running. Wait for it to finish and retry Recovery."
        case .recoveryIsAvailable:
            return "Recovery is available for the current Document. Retry Recovery is only needed after a checkpoint fails."
        }
    }
}

struct PendingExternalOpenRecoveryPrompt: Equatable, Sendable {
    let recoveryDocumentID: DocumentID
    let title: String
}

private struct ExternalOpenDocumentNotice: Equatable, Sendable {
    let documentID: DocumentID
    let message: String
}

private struct ExternalOpenRecoveryProtectionFailure: Equatable, Sendable {
    let documentID: DocumentID
    let message: String
}

private struct ExternalOpenEphemeralClaim: Equatable, Sendable {
    let candidate: FileOpenCandidate
}

private enum AuthoritativeEphemeralOpenMatch: Equatable, Sendable {
    case none
    case item(DocumentID)
    case ambiguous([DocumentID])
}

private enum AuthoritativeActiveOpenMatch: Equatable, Sendable {
    case none
    case ephemeral([DocumentID])
    case durable(DocumentID)
}

private struct QueuedExternalOpenRequest: Equatable, Sendable {
    let id: UUID
    let request: PhonePadExternalOpenRequest
    let documentID: DocumentID
    let tabID: TabID
    let importedCopyCleanupTokens: [ImportedCopyCleanupToken]
    let importedCopyCleanupCapture: ImportedCopyCleanupCapture
}

private enum ImportedCopyCleanupCapture: Equatable, Sendable {
    case notRequired
    case candidate(ImportedCopyCleanupCandidate)
    case inspectionFailed(FileAccessConnectorError)
}

private struct ExternalOpenCleanupPreflightFailure: Equatable, Sendable {
    let requestID: UUID
    let message: String
}

private struct PendingExternalOpenDecision: Equatable, Sendable {
    let request: QueuedExternalOpenRequest
    let recoveryMatch: RecoveryFileOpenMatch
    let importedCopyCleanupTokens: [ImportedCopyCleanupToken]
}

private enum PreparedExternalOpenPayload: Equatable, Sendable {
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

private enum ExternalOpenPreparation: Equatable, Sendable {
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

private enum ExternalOpenCommitResult: Equatable, Sendable {
    case complete
    case recoveryProtectionFailed
}

private struct PendingImportedCopyCleanup: Equatable, Sendable {
    let documentID: DocumentID?
    var tokens: [ImportedCopyCleanupToken]
}

private func uniqueImportedCopyCleanupTokens(
    _ tokens: [ImportedCopyCleanupToken]
) -> [ImportedCopyCleanupToken] {
    var seen: Set<ImportedCopyCleanupToken> = []
    return tokens.filter { token in
        seen.insert(token).inserted
    }
}

private func externalOpenCandidate(
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

private enum PhonePadExternalOpenActionError: Error, LocalizedError {
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

private enum PhonePadEditorDisplayActionError: Error, LocalizedError {
    case actionAlreadyInProgress

    var errorDescription: String? {
        "Display settings cannot change while another File, recovery, or Tab action is running. Wait for it to finish and retry."
    }
}

private enum RecoveryCheckpointPersistenceOutcome: Equatable {
    case persisted
    case superseded
    case failed
}

private enum PendingFileSaveCleanup {
    case standard(NewDocumentSaveResult)
    case saveAs(SaveAsResult)

    var documentID: DocumentID {
        switch self {
        case let .standard(result):
            return result.state.activeTab.document.id
        case let .saveAs(result):
            return result.state.activeTab.document.id
        }
    }
}

struct PendingTabClosePrompt: Equatable, Sendable {
    let tabID: TabID
    let documentID: DocumentID
    let title: String
}

enum TabCloseSaveRoute: Equatable, Sendable {
    case completed
    case saveAsRequired(DocumentID)
    case fileConflictRequired(DocumentID)
    case failed
}

private struct PendingTabCloseSession {
    var requirements: [TabCloseRequirement]
    let originalActiveTabID: TabID
    let retainedTabID: TabID?
    var phase: PendingTabClosePhase
}

private enum PendingTabClosePhase: Equatable {
    case processing
    case decision(TabID)
    case saveAs(TabID)
    case fileConflict(TabID)
    case cleanup(TabID)
}

private struct PendingTabCloseCleanup {
    let preparedClose: PreparedUnsavedTabClose
    let replacementDocumentID: DocumentID
    let replacementTabID: TabID
}

private enum PhonePadRecoveryActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case checkpointHeldForFileConflictReload
    case recoveryDocumentAlreadyOpen(DocumentID)
    case recoveryItemCannotBeRecovered
    case recoveryItemMissing

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another recovery action is still running. Wait for it to finish and retry."
        case .checkpointHeldForFileConflictReload:
            "Current edits remain locked until Reload Current finishes. Retry Reload Current or retry recovery before editing."
        case let .recoveryDocumentAlreadyOpen(documentID):
            "Document \(documentID.rawValue.uuidString) is already open. Use its existing Tab instead of changing its protected recovery item."
        case .recoveryItemCannotBeRecovered:
            "This preserved work is corrupt or unsupported. Keep it for a compatible PhonePad version, or choose Discard Recovery."
        case .recoveryItemMissing:
            "Preserved work is no longer available. Refresh Document Recovery and retry."
        }
    }
}

private enum PhonePadFileSaveActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case activeDocumentIsNotBound
    case checkpointMustFinishBeforeFileAction
    case cleanupRequired
    case cleanupNotRequired

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another File action is still running. Wait for it to finish and retry."
        case .activeDocumentIsNotBound:
            "Current Document has no existing File. Choose Save As instead."
        case .checkpointMustFinishBeforeFileAction:
            "Current edits could not be protected. Resolve the recovery error before opening or saving a File."
        case .cleanupRequired:
            "File output is verified, but recovery cleanup is still required. Choose Retry Cleanup before editing or saving again."
        case .cleanupNotRequired:
            "No recovery cleanup is waiting. Choose Save to start a new File action."
        }
    }
}

private enum PhonePadTabTransitionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case committedDocumentIsNotActive
    case committedTextWasRejected
    case checkpointMustFinishBeforeTransition
    case activeDocumentChangedDuringTransition

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another File, recovery, or Tab action is still running. Wait for it to finish and retry."
        case .committedDocumentIsNotActive:
            "Editor content belongs to a different Document. Keep the current Tab active and retry."
        case .committedTextWasRejected:
            "Editor content did not pass Document validation. Keep the current Tab active and correct the content before retrying."
        case .checkpointMustFinishBeforeTransition:
            "Current edits could not be protected. Resolve the recovery error before changing Tabs."
        case .activeDocumentChangedDuringTransition:
            "Current Document changed while its recovery checkpoint was being protected. Keep the current Tab active and retry."
        }
    }
}

private enum PhonePadTabCloseActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case cleanupNotRequired
    case cleanupRequired
    case noPendingDecision
    case pendingTabRemainsUnsaved
    case saveAsCancellationDocumentMismatch(
        expected: DocumentID,
        actual: DocumentID
    )
    case saveAsCancellationNotPending

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another File, recovery, or Tab action is still running. Wait for it to finish and retry Close."
        case .cleanupNotRequired:
            "No Tab cleanup is waiting. Close an unsaved Tab and choose Discard before retrying cleanup."
        case .cleanupRequired:
            "Protected edit cleanup is still required. Choose Retry Cleanup before resolving another Tab."
        case .noPendingDecision:
            "No unsaved Tab is waiting for a Close decision. Request Close again."
        case .pendingTabRemainsUnsaved:
            "The pending Tab remains unsaved after the File action. Keep it open and retry Save."
        case let .saveAsCancellationDocumentMismatch(expected, actual):
            "Save As cancellation belongs to Document \(actual.rawValue.uuidString), but Close is waiting for Document \(expected.rawValue.uuidString). Keep the pending Tab open and cancel its Save As sheet."
        case .saveAsCancellationNotPending:
            "No Close-triggered Save As sheet is waiting for cancellation. Keep the current Close decision open."
        }
    }
}

@MainActor
final class PhonePadAppModel: ObservableObject {
    @Published private(set) var state: PhonePadState
    @Published private(set) var recoveryError: String?
    @Published private(set) var recoveryItems: [RecoveryItemSummary]
    @Published private(set) var recoveryCatalogError: String?
    @Published private(set) var activeRecoveryAction: DocumentID?
    @Published private(set) var fileSaveError: String?
    @Published private(set) var fileSaveNotice: String?
    @Published private(set) var fileSaveInProgress: Bool
    @Published private(set) var fileSaveCleanupRequired: Bool
    @Published private(set) var pendingSaveAsReplacement: PreparedSaveAsPreflight?
    @Published private(set) var fileConflictResolutionIsPresented: Bool
    @Published private(set) var fileConflictError: String?
    @Published private(set) var tabTransitionError: String?
    @Published private(set) var tabTransitionInProgress: Bool
    @Published private(set) var pendingTabClosePrompt: PendingTabClosePrompt?
    @Published private(set) var tabCloseError: String?
    @Published private(set) var tabCloseCleanupRequired: Bool
    @Published private(set) var externalOpenCommitRequestID: UUID?
    @Published private(set) var externalOpenInProgress: Bool
    @Published private(set) var pendingExternalOpenRecoveryPrompt: PendingExternalOpenRecoveryPrompt?
    @Published private(set) var externalOpenError: String?
    @Published private(set) var externalOpenCleanupRequired: Bool
    @Published private var externalOpenGeneralNotice: String?
    @Published private var externalOpenDocumentNotice:
        ExternalOpenDocumentNotice?
    @Published private var importedCopyCleanupJournalNotice: String?

    private let recoveryStore: any RecoveryStoring
    private let fileAccessConnector: FileAccessConnector
    private let checkpointQuietPeriod: Duration
    private let checkpointMaximumInterval: Duration
    private let checkpointClock: ContinuousClock
    private var checkpointTask: Task<Void, Never>?
    private var pendingCheckpoint: PendingRecoveryCheckpoint?
    private var failedCheckpoint: PendingRecoveryCheckpoint?
    private var pendingFileSaveCleanup: PendingFileSaveCleanup?
    private var presentationHintTask: Task<Void, Never>?
    private var presentersShouldBeActive: Bool
    private var presenterLifecycleGeneration: UInt64
    private var presenterRefreshPending: Bool
    private var editGeneration: UInt64
    private var activeDocumentTransitionInProgress: Bool
    private var pendingTabCloseSession: PendingTabCloseSession?
    private var pendingTabCloseCleanup: PendingTabCloseCleanup?
    private var pendingTabCloseBoundSaveDocumentID: DocumentID?
    private var externalOpenQueue: [QueuedExternalOpenRequest]
    private var externalOpenCleanupPreflightBatchIDs: Set<UUID>
    private var externalOpenCleanupPreflightFailures: [
        UUID: ExternalOpenCleanupPreflightFailure
    ]
    private var pendingExternalOpenDecision: PendingExternalOpenDecision?
    private var pendingExternalOpenCleanups: [PendingImportedCopyCleanup]
    private var externalOpenCleanupInProgress: Bool
    private var externalOpenEphemeralClaims: [
        DocumentID: [ExternalOpenEphemeralClaim]
    ]
    private var terminalExternalOpenErrorPendingDismissal: Bool
    private var didReconcileImportedCopyCleanupJournalOnActivation: Bool
    private var importedCopyCleanupJournalRetryRequired: Bool
    private var importedCopyCleanupJournalErrorMessage: String?
    private var externalOpenRecoveryProtectionFailure:
        ExternalOpenRecoveryProtectionFailure?

    init(
        state: PhonePadState,
        recoveryStore: any RecoveryStoring,
        fileAccessConnector: FileAccessConnector,
        checkpointQuietPeriod: Duration,
        checkpointMaximumInterval: Duration
    ) {
        precondition(checkpointQuietPeriod > .zero, "Checkpoint quiet period must be positive.")
        precondition(checkpointMaximumInterval > .zero, "Checkpoint maximum interval must be positive.")
        self.state = state
        self.recoveryStore = recoveryStore
        self.fileAccessConnector = fileAccessConnector
        self.checkpointQuietPeriod = checkpointQuietPeriod
        self.checkpointMaximumInterval = checkpointMaximumInterval
        checkpointClock = ContinuousClock()
        recoveryError = nil
        recoveryItems = []
        recoveryCatalogError = nil
        activeRecoveryAction = nil
        fileSaveError = nil
        fileSaveNotice = nil
        fileSaveInProgress = false
        fileSaveCleanupRequired = false
        pendingSaveAsReplacement = nil
        fileConflictResolutionIsPresented = false
        fileConflictError = nil
        tabTransitionError = nil
        tabTransitionInProgress = false
        pendingTabClosePrompt = nil
        tabCloseError = nil
        tabCloseCleanupRequired = false
        externalOpenCommitRequestID = nil
        externalOpenInProgress = false
        pendingExternalOpenRecoveryPrompt = nil
        externalOpenError = nil
        externalOpenCleanupRequired = false
        externalOpenGeneralNotice = nil
        externalOpenDocumentNotice = nil
        importedCopyCleanupJournalNotice = nil
        pendingCheckpoint = nil
        failedCheckpoint = nil
        pendingFileSaveCleanup = nil
        presentationHintTask = nil
        presentersShouldBeActive = true
        presenterLifecycleGeneration = 0
        presenterRefreshPending = false
        editGeneration = 0
        activeDocumentTransitionInProgress = false
        pendingTabCloseSession = nil
        pendingTabCloseCleanup = nil
        pendingTabCloseBoundSaveDocumentID = nil
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
        startPresentationHintTask()
    }

    var externalOpenNotice: String? {
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

    var externalOpenErrorRequiresDismissal: Bool {
        terminalExternalOpenErrorPendingDismissal
    }

    var recoveryUnavailableNotice: RecoveryUnavailableNotice? {
        guard let checkpoint = failedCheckpoint,
              state.activeTab.document.id
                == checkpoint.checkpointBaseState.activeTab.document.id,
              state.activeTab.document.recoveryState
                == .recoveryUnavailable else {
            return nil
        }
        let baselineDocument = checkpoint.recoveryBaselineState?
            .tabs
            .first(where: { tab in
                tab.document.id == state.activeTab.document.id
            })?
            .document
        return RecoveryUnavailableNotice(
            documentID: state.activeTab.document.id,
            hasNewerUnprotectedText: baselineDocument?.text
                != state.activeTab.document.text,
            hasLastVerifiedCheckpoint: baselineDocument?.recoveryState
                == .protectedUnsaved
        )
    }

    deinit {
        presentationHintTask?.cancel()
    }

    convenience init(
        state: PhonePadState,
        recoveryStore: any RecoveryStoring,
        checkpointQuietPeriod: Duration,
        checkpointMaximumInterval: Duration
    ) {
        self.init(
            state: state,
            recoveryStore: recoveryStore,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: checkpointQuietPeriod,
            checkpointMaximumInterval: checkpointMaximumInterval
        )
    }

    convenience init(
        state: PhonePadState,
        recoveryStore: any RecoveryStoring
    ) {
        self.init(
            state: state,
            recoveryStore: recoveryStore,
            checkpointQuietPeriod: .milliseconds(300),
            checkpointMaximumInterval: .seconds(2)
        )
    }

    convenience init(recoveryRootURL: URL) {
        self.init(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryRootURL,
                fileManager: .default
            )
        )
    }

    var activeText: String {
        state.activeTab.document.text
    }

    var activeDisplaySettings: PhonePadTabDisplaySettings {
        state.activeTab.displaySettings
    }

    func chooseActiveTabFont(_ fontFamily: PhonePadFontFamily) throws {
        try requireDisplaySettingsMutationAvailable()
        state = try setActiveTabFontFamily(
            state: state,
            fontFamily: fontFamily
        )
    }

    func chooseActiveTabZoom(_ zoomPercent: Int) throws {
        try requireDisplaySettingsMutationAvailable()
        state = try setActiveTabZoomPercent(
            state: state,
            zoomPercent: zoomPercent
        )
    }

    func toggleActiveTabWordWrap() throws {
        try requireDisplaySettingsMutationAvailable()
        state = try setActiveTabWordWrapEnabled(
            state: state,
            isEnabled: !state.activeTab.displaySettings.wordWrapEnabled
        )
    }

    func toggleActiveTabStatusVisibility() throws {
        try requireDisplaySettingsMutationAvailable()
        state = try setActiveTabStatusVisible(
            state: state,
            isVisible: !state.activeTab.displaySettings.statusVisible
        )
    }

    private func requireDisplaySettingsMutationAvailable() throws {
        guard !fileMutationDisabled else {
            throw PhonePadEditorDisplayActionError.actionAlreadyInProgress
        }
    }

    var activeFileConflict: FileConflict? {
        state.activeTab.document.fileConflict
    }

    var pendingTabCloseDocumentID: DocumentID? {
        guard let session = pendingTabCloseSession,
              let tabID = pendingTabCloseCandidateTabID,
              let requirement = session.requirements.first(where: {
                  tabCloseRequirementTab($0).id == tabID
              }) else {
            return nil
        }
        return tabCloseRequirementTab(requirement).document.id
    }

    var fileMutationDisabled: Bool {
        editorInteractionDisabled
            || fileSaveCleanupRequired
            || pendingTabCloseSession != nil
            || tabTransitionInProgress
            || !externalOpenQueue.isEmpty
            || pendingExternalOpenDecision != nil
    }

    var editorInteractionDisabled: Bool {
        fileSaveInProgress
            || pendingSaveAsReplacement != nil
            || activeRecoveryAction != nil
            || activeDocumentTransitionInProgress
            || externalOpenInProgress
    }

    var editorMutationDisabled: Bool {
        editorInteractionDisabled
            || fileSaveCleanupRequired
            || pendingTabCloseSession != nil
            || failedCheckpoint != nil
            || pendingExternalOpenDecision != nil
    }

    private var pendingTabCloseCandidateTabID: TabID? {
        guard let session = pendingTabCloseSession else {
            return nil
        }
        switch session.phase {
        case .processing:
            return nil
        case let .decision(tabID),
             let .saveAs(tabID),
             let .fileConflict(tabID),
             let .cleanup(tabID):
            return tabID
        }
    }

    private var activePendingTabClosePhase: PendingTabClosePhase? {
        guard pendingTabCloseSession != nil else {
            return nil
        }
        guard let candidateTabID = pendingTabCloseCandidateTabID,
              state.activeTabID == candidateTabID else {
            return nil
        }
        return pendingTabCloseSession?.phase
    }

    private var pendingTabCloseAllowsBoundSave: Bool {
        guard pendingTabCloseSession != nil else {
            return true
        }
        guard !tabCloseCleanupRequired,
              let phase = activePendingTabClosePhase,
              case .decision = phase,
              pendingTabCloseBoundSaveDocumentID
                == state.activeTab.document.id else {
            return false
        }
        return true
    }

    private var pendingTabCloseAllowsSaveAsAction: Bool {
        guard pendingTabCloseSession != nil else {
            return true
        }
        guard !tabCloseCleanupRequired,
              let phase = activePendingTabClosePhase,
              case .saveAs = phase else {
            return false
        }
        return true
    }

    private var pendingTabCloseAllowsFileConflictAction: Bool {
        guard pendingTabCloseSession != nil else {
            return true
        }
        guard !tabCloseCleanupRequired,
              let phase = activePendingTabClosePhase,
              case .fileConflict = phase else {
            return false
        }
        return true
    }

    private var pendingTabCloseAllowsFileSaveCleanup: Bool {
        guard pendingTabCloseSession != nil else {
            return true
        }
        guard !tabCloseCleanupRequired,
              fileSaveCleanupRequired,
              let phase = activePendingTabClosePhase,
              case .cleanup = phase else {
            return false
        }
        return true
    }

    private var externalOpenTransitionOwnsWorkspace: Bool {
        !externalOpenQueue.isEmpty
            || externalOpenCommitRequestID != nil
            || externalOpenInProgress
            || pendingExternalOpenDecision != nil
    }

    func clearTabTransitionFeedback() {
        tabTransitionError = nil
    }

    func reportTabTransitionError(_ error: Error) {
        tabTransitionError = error.localizedDescription
    }

    @discardableResult
    func createTab(
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard beginActiveDocumentTransition() else {
            return false
        }
        defer { finishTabTransition() }

        let documentID = DocumentID(rawValue: UUID())
        let tabID = TabID(rawValue: UUID())
        do {
            try validateCommittedDocument(committedDocument)
            _ = try PhonePadCore.createUntitledTab(
                state: state,
                documentID: documentID,
                tabID: tabID
            )
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            state = try PhonePadCore.createUntitledTab(
                state: state,
                documentID: documentID,
                tabID: tabID
            )
            tabTransitionError = nil
            presentActiveFileConflictIfNeeded()
            return true
        } catch {
            tabTransitionError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func selectTab(
        _ tabID: TabID,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard beginActiveDocumentTransition() else {
            return false
        }
        defer { finishTabTransition() }

        do {
            try validateCommittedDocument(committedDocument)
            _ = try PhonePadCore.selectTab(state: state, tabID: tabID)
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            state = try PhonePadCore.selectTab(state: state, tabID: tabID)
            tabTransitionError = nil
            presentActiveFileConflictIfNeeded()
            return true
        } catch {
            tabTransitionError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func moveTab(
        _ tabID: TabID,
        to placement: PhonePadCore.TabPlacement
    ) async -> Bool {
        guard beginTabReorder() else {
            return false
        }
        defer { finishTabTransition() }

        let activeDocumentID = state.activeTab.document.id
        let activeDocumentText = state.activeTab.document.text
        do {
            _ = try PhonePadCore.moveTab(
                state: state,
                tabID: tabID,
                placement: placement
            )
            guard await retryCurrentCheckpointIfNeeded(),
                  pendingCheckpoint == nil,
                  failedCheckpoint == nil,
                  state.activeTab.document.recoveryState != .checkpointPending,
                  state.activeTab.document.recoveryState != .recoveryUnavailable else {
                throw PhonePadTabTransitionError
                    .checkpointMustFinishBeforeTransition
            }
            guard state.activeTab.document.id == activeDocumentID,
                  state.activeTab.document.text == activeDocumentText else {
                throw PhonePadTabTransitionError
                    .activeDocumentChangedDuringTransition
            }
            state = try PhonePadCore.moveTab(
                state: state,
                tabID: tabID,
                placement: placement
            )
            tabTransitionError = nil
            return true
        } catch {
            tabTransitionError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func requestCloseTab(
        _ tabID: TabID,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard beginTabCloseRequest() else {
            return false
        }
        defer { finishTabTransition() }

        do {
            try validateCommittedDocument(committedDocument)
            let requirement = try prepareTabClose(
                state: state,
                tabID: tabID
            )
            return try await beginPendingTabCloseSession(
                requirements: [requirement],
                retainedTabID: nil,
                committedDocument: committedDocument
            )
        } catch {
            cancelPendingTabCloseSessionAfterFailure()
            tabCloseError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func requestCloseOtherTabs(
        keeping retainedTabID: TabID,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard beginTabCloseRequest() else {
            return false
        }
        defer { finishTabTransition() }

        do {
            try validateCommittedDocument(committedDocument)
            let requirements = try prepareOtherTabCloses(
                state: state,
                keepingTabID: retainedTabID
            )
            return try await beginPendingTabCloseSession(
                requirements: requirements,
                retainedTabID: retainedTabID,
                committedDocument: committedDocument
            )
        } catch {
            cancelPendingTabCloseSessionAfterFailure()
            tabCloseError = error.localizedDescription
            return false
        }
    }

    func cancelPendingTabClose() {
        guard let session = pendingTabCloseSession,
              case .decision = session.phase,
              !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil,
              !tabCloseCleanupRequired else {
            return
        }
        do {
            try restoreStableTabSelectionForPendingClose()
        } catch {
            tabCloseError = error.localizedDescription
            return
        }
        pendingTabCloseSession = nil
        pendingTabClosePrompt = nil
        pendingTabCloseCleanup = nil
        tabCloseError = nil
        resumePendingPresentersAfterExclusiveAction()
    }

    @discardableResult
    func discardPendingTabClose() async -> Bool {
        guard beginPendingTabCloseDecisionResolution() else {
            return false
        }
        defer { finishTabTransition() }

        guard let prompt = pendingTabClosePrompt,
              let requirementIndex = pendingTabCloseRequirementIndex(
                tabID: prompt.tabID
              ),
              let preparedClose = pendingUnsavedTabClose(
                at: requirementIndex
              ) else {
            tabCloseError = PhonePadTabCloseActionError
                .noPendingDecision
                .localizedDescription
            return false
        }

        await cancelAndAwaitCheckpointTask()
        let replacementDocumentID = DocumentID(rawValue: UUID())
        let replacementTabID = TabID(rawValue: UUID())
        do {
            let result = try await discardAndClosePreparedUnsavedTab(
                state: state,
                preparedClose: preparedClose,
                replacementDocumentID: replacementDocumentID,
                replacementTabID: replacementTabID,
                recoveryStore: recoveryStore
            )
            try await applyDiscardedTabClose(
                result,
                requirementIndex: requirementIndex
            )
            return true
        } catch let error as TabCloseWorkflowError {
            if case .recoveryCleanupFailed = error {
                pendingTabCloseCleanup = PendingTabCloseCleanup(
                    preparedClose: preparedClose,
                    replacementDocumentID: replacementDocumentID,
                    replacementTabID: replacementTabID
                )
                pendingTabClosePrompt = nil
                tabCloseCleanupRequired = true
                pendingTabCloseSession?.phase = .cleanup(
                    preparedClose.tab.id
                )
            }
            tabCloseError = error.localizedDescription
            return false
        } catch {
            tabCloseError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func retryPendingTabCloseCleanup() async -> Bool {
        guard beginPendingTabCloseCleanupResolution() else {
            return false
        }
        defer { finishTabTransition() }

        guard let cleanup = pendingTabCloseCleanup,
              let requirementIndex = pendingTabCloseRequirementIndex(
                tabID: cleanup.preparedClose.tab.id
              ) else {
            tabCloseError = PhonePadTabCloseActionError
                .cleanupNotRequired
                .localizedDescription
            return false
        }

        await cancelAndAwaitCheckpointTask()
        do {
            let result = try await discardAndClosePreparedUnsavedTab(
                state: state,
                preparedClose: cleanup.preparedClose,
                replacementDocumentID: cleanup.replacementDocumentID,
                replacementTabID: cleanup.replacementTabID,
                recoveryStore: recoveryStore
            )
            try await applyDiscardedTabClose(
                result,
                requirementIndex: requirementIndex
            )
            return true
        } catch {
            tabCloseError = error.localizedDescription
            return false
        }
    }

    func savePendingTabClose() async -> TabCloseSaveRoute {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil,
              !tabCloseCleanupRequired,
              let prompt = pendingTabClosePrompt,
              let requirementIndex = pendingTabCloseRequirementIndex(
                tabID: prompt.tabID
              ),
              pendingUnsavedTabClose(at: requirementIndex) != nil else {
            tabCloseError = PhonePadTabCloseActionError
                .noPendingDecision
                .localizedDescription
            return .failed
        }

        do {
            state = try PhonePadCore.selectTab(
                state: state,
                tabID: prompt.tabID
            )
        } catch {
            tabCloseError = error.localizedDescription
            return .failed
        }

        let document = state.activeTab.document
        guard document.id == prompt.documentID else {
            tabCloseError = PhonePadTabTransitionError
                .activeDocumentChangedDuringTransition
                .localizedDescription
            return .failed
        }
        guard document.fileBinding != nil else {
            setPendingTabClosePhase(.saveAs(prompt.tabID))
            pendingTabClosePrompt = nil
            tabCloseError = nil
            return .saveAsRequired(document.id)
        }
        guard document.fileConflict == nil else {
            setPendingTabClosePhase(.fileConflict(prompt.tabID))
            pendingTabClosePrompt = nil
            tabCloseError = nil
            fileConflictError = nil
            fileConflictResolutionIsPresented = true
            return .fileConflictRequired(document.id)
        }

        pendingTabCloseBoundSaveDocumentID = document.id
        let didSave = await saveActiveDocument()
        pendingTabCloseBoundSaveDocumentID = nil
        guard didSave else {
            if fileSaveCleanupRequired {
                setPendingTabClosePhase(.cleanup(prompt.tabID))
                pendingTabClosePrompt = nil
            } else if state.activeTab.document.fileConflict != nil {
                setPendingTabClosePhase(.fileConflict(prompt.tabID))
                pendingTabClosePrompt = nil
                tabCloseError = nil
                return .fileConflictRequired(document.id)
            } else {
                do {
                    let preparedClose = try refreshPendingUnsavedTabClose(
                        tabID: prompt.tabID
                    )
                    publishPendingTabClosePrompt(
                        preparedClose: preparedClose
                    )
                } catch {
                    tabCloseError = error.localizedDescription
                    return .failed
                }
            }
            tabCloseError = fileSaveError
            return .failed
        }
        guard await resumePendingTabCloseAfterSuccessfulSave(
            documentID: document.id
        ) else {
            return .failed
        }
        return .completed
    }

    @discardableResult
    func restorePendingTabCloseDecisionAfterSaveAsCancellation(
        documentID: DocumentID
    ) -> Bool {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil else {
            tabCloseError = PhonePadTabCloseActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard let session = pendingTabCloseSession,
              case let .saveAs(tabID) = session.phase,
              let requirementIndex = pendingTabCloseRequirementIndex(
                tabID: tabID
              ),
              let preparedClose = pendingUnsavedTabClose(
                at: requirementIndex
              ) else {
            tabCloseError = PhonePadTabCloseActionError
                .saveAsCancellationNotPending
                .localizedDescription
            return false
        }
        guard preparedClose.tab.document.id == documentID else {
            tabCloseError = PhonePadTabCloseActionError
                .saveAsCancellationDocumentMismatch(
                    expected: preparedClose.tab.document.id,
                    actual: documentID
                )
                .localizedDescription
            return false
        }
        do {
            let refreshedClose = try refreshPendingUnsavedTabClose(
                tabID: tabID
            )
            publishPendingTabClosePrompt(preparedClose: refreshedClose)
            tabCloseError = nil
            return true
        } catch {
            tabCloseError = error.localizedDescription
            return false
        }
    }

    private func restorePendingTabCloseDecisionAfterFileConflictCancellation() {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil else {
            tabCloseError = PhonePadTabCloseActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        guard let session = pendingTabCloseSession,
              case let .fileConflict(tabID) = session.phase else {
            return
        }
        do {
            let preparedClose = try refreshPendingUnsavedTabClose(
                tabID: tabID
            )
            publishPendingTabClosePrompt(preparedClose: preparedClose)
            tabCloseError = nil
        } catch {
            tabCloseError = error.localizedDescription
        }
    }

    func enqueueExternalOpenRequests(
        _ requests: [PhonePadExternalOpenRequest]
    ) async {
        let queuedRequests = requests.map { request in
            QueuedExternalOpenRequest(
                id: UUID(),
                request: request,
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID()),
                importedCopyCleanupTokens: [],
                importedCopyCleanupCapture:
                    importedCopyCleanupCapture(request: request)
            )
        }
        externalOpenQueue.append(contentsOf: queuedRequests)
        await preflightQueuedExternalOpenCleanup(
            requestIDs: queuedRequests.map(\.id)
        )
    }

    private func importedCopyCleanupCapture(
        request: PhonePadExternalOpenRequest
    ) -> ImportedCopyCleanupCapture {
        guard request.accessIntent == .copyRequired else {
            return .notRequired
        }
        do {
            guard let candidate = try fileAccessConnector
                .inspectImportedCopyCleanupCandidate(at: request.url) else {
                return .notRequired
            }
            return .candidate(candidate)
        } catch {
            return .inspectionFailed(error)
        }
    }

    private func preflightQueuedExternalOpenCleanup(
        requestIDs: [UUID]
    ) async {
        let batchID = UUID()
        externalOpenCleanupPreflightBatchIDs.insert(batchID)

        for requestID in requestIDs {
            do {
                _ = try await captureQueuedImportedCopyCleanup(
                    requestID: requestID
                )
                externalOpenCleanupPreflightFailures.removeValue(
                    forKey: requestID
                )
            } catch {
                let failure = ExternalOpenCleanupPreflightFailure(
                    requestID: requestID,
                    message: error.localizedDescription
                )
                externalOpenCleanupPreflightFailures[requestID] = failure
            }
        }
        await finishExternalOpenCleanupPreflight(batchID: batchID)
    }

    private func finishExternalOpenCleanupPreflight(batchID: UUID) async {
        externalOpenCleanupPreflightBatchIDs.remove(batchID)
        guard !externalOpenCleanupPreflightInProgress else {
            return
        }
        await resumePendingActivationWorkAfterExclusiveAction()
    }

    private var externalOpenCleanupPreflightInProgress: Bool {
        !externalOpenCleanupPreflightBatchIDs.isEmpty
    }

    private var liveExternalOpenCleanupTokens:
        Set<ImportedCopyCleanupToken> {
        Set(
            externalOpenQueue.flatMap(\.importedCopyCleanupTokens)
                + (pendingExternalOpenDecision?
                    .importedCopyCleanupTokens ?? [])
        )
    }

    private var externalOpenQueueRequiresCleanupPreflight: Bool {
        externalOpenQueue.contains { request in
            importedCopyCleanupPreflightRequired(request: request)
        }
    }

    private func importedCopyCleanupPreflightRequired(
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

    private func captureQueuedImportedCopyCleanup(
        requestID: UUID
    ) async throws -> QueuedExternalOpenRequest {
        guard let requestIndex = externalOpenQueue.firstIndex(where: {
            $0.id == requestID
        }) else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        var request = externalOpenQueue[requestIndex]
        guard request.importedCopyCleanupTokens.isEmpty else {
            return request
        }

        let capture: ImportedCopyCleanupCapture
        switch request.importedCopyCleanupCapture {
        case .notRequired, .candidate:
            capture = request.importedCopyCleanupCapture
        case .inspectionFailed:
            capture = importedCopyCleanupCapture(request: request.request)
            request = QueuedExternalOpenRequest(
                id: request.id,
                request: request.request,
                documentID: request.documentID,
                tabID: request.tabID,
                importedCopyCleanupTokens: request.importedCopyCleanupTokens,
                importedCopyCleanupCapture: capture
            )
            externalOpenQueue[requestIndex] = request
        }

        switch capture {
        case .notRequired:
            return request
        case let .inspectionFailed(error):
            throw error
        case let .candidate(candidate):
            let token = try await fileAccessConnector
                .captureImportedCopyCleanup(
                    at: request.request.url,
                    documentID: request.documentID,
                    matching: candidate
                )
            retainImportedCopyCleanupTokenForRetry(
                token,
                requestID: request.id
            )
            guard let capturedRequest = externalOpenQueue.first(where: {
                $0.id == request.id
            }) else {
                throw PhonePadExternalOpenActionError.commitRequestMissing
            }
            return capturedRequest
        }
    }

    private func prepareQueuedImportedCopyCleanup(
        requestID: UUID
    ) async throws -> QueuedExternalOpenRequest {
        guard externalOpenQueue.first?.id == requestID else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        return try await captureQueuedImportedCopyCleanup(
            requestID: requestID
        )
    }

    func reportExternalOpenCommitFailure(
        commitRequestID: UUID,
        error: Error
    ) {
        guard externalOpenCommitRequestID == commitRequestID else {
            return
        }
        externalOpenCommitRequestID = nil
        externalOpenError = error.localizedDescription
    }

    func retryExternalOpenCommit() async {
        guard !terminalExternalOpenErrorPendingDismissal,
              !externalOpenCleanupPreflightInProgress else {
            return
        }
        terminalExternalOpenErrorPendingDismissal = false
        externalOpenError = nil
        await preflightQueuedExternalOpenCleanup(
            requestIDs: externalOpenQueue.filter {
                importedCopyCleanupPreflightRequired(request: $0)
            }.map(\.id)
        )
    }

    func dismissTerminalExternalOpenError() {
        guard terminalExternalOpenErrorPendingDismissal,
              !externalOpenCleanupRequired else {
            return
        }
        terminalExternalOpenErrorPendingDismissal = false
        externalOpenError = nil
        requestExternalOpenEditorCommitIfPossible()
    }

    @discardableResult
    func processNextExternalOpen(
        after committedDocument: CommittedEditorDocument,
        commitRequestID: UUID
    ) async -> Bool {
        guard presentersShouldBeActive else {
            if externalOpenCommitRequestID == commitRequestID {
                externalOpenCommitRequestID = nil
            }
            return false
        }
        guard externalOpenCommitRequestID == commitRequestID,
              let queuedRequest = externalOpenQueue.first else {
            externalOpenError = PhonePadExternalOpenActionError
                .commitRequestMissing
                .localizedDescription
            return false
        }
        guard canBeginExternalOpenAction else {
            externalOpenCommitRequestID = nil
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        externalOpenInProgress = true
        if externalOpenError != importedCopyCleanupJournalErrorMessage {
            externalOpenError = nil
        }
        if !externalOpenCleanupRequired {
            externalOpenGeneralNotice = nil
        }
        terminalExternalOpenErrorPendingDismissal = false

        let opened: Bool
        do {
            try validateCommittedDocument(committedDocument)
            let request = try await prepareQueuedImportedCopyCleanup(
                requestID: queuedRequest.id
            )
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            opened = try await prepareAndResolveExternalOpen(request: request)
        } catch {
            externalOpenError = error.localizedDescription
            opened = false
        }
        await finishExternalOpenAction()
        return opened
    }

    func cancelPendingExternalOpen() async {
        guard !externalOpenCleanupRequired else {
            externalOpenError = PhonePadExternalOpenActionError
                .cleanupMustFinishBeforeDismissal
                .localizedDescription
            return
        }
        guard !externalOpenInProgress,
              !externalOpenCleanupPreflightInProgress,
              externalOpenCommitRequestID == nil,
              !tabTransitionInProgress,
              !fileSaveInProgress,
              !fileSaveCleanupRequired,
              pendingSaveAsReplacement == nil,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil else {
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        externalOpenInProgress = true

        if terminalExternalOpenErrorPendingDismissal {
            terminalExternalOpenErrorPendingDismissal = false
            externalOpenError = nil
        } else if let decision = pendingExternalOpenDecision {
            do {
                if try queuedImportedCopyCleanupCandidateChanged(
                    request: decision.request
                ) {
                    try await fileAccessConnector
                        .abandonImportedCopyCleanup(
                            tokens: decision.importedCopyCleanupTokens
                        )
                    pendingExternalOpenDecision = nil
                    pendingExternalOpenRecoveryPrompt = nil
                    completeExternalOpenRequest(
                        requestID: decision.request.id
                    )
                    terminalExternalOpenErrorPendingDismissal = true
                    externalOpenError = FileAccessConnectorError
                        .importedCopyCleanupCandidateChanged
                        .localizedDescription
                } else {
                    retainImportedCopyCleanup(
                        documentID: nil,
                        tokens: decision.importedCopyCleanupTokens
                    )
                    pendingExternalOpenDecision = nil
                    pendingExternalOpenRecoveryPrompt = nil
                    completeExternalOpenRequest(
                        requestID: decision.request.id
                    )
                    await retryExternalOpenCleanupIfNeeded()
                    externalOpenError = nil
                }
            } catch {
                externalOpenError = error.localizedDescription
            }
        } else if let request = externalOpenQueue.first {
            do {
                let capturedRequest = try await
                    prepareQueuedImportedCopyCleanup(requestID: request.id)
                if try queuedImportedCopyCleanupCandidateChanged(
                    request: capturedRequest
                ) {
                    try await fileAccessConnector
                        .abandonImportedCopyCleanup(
                            tokens: capturedRequest
                                .importedCopyCleanupTokens
                        )
                    completeExternalOpenRequest(requestID: capturedRequest.id)
                    terminalExternalOpenErrorPendingDismissal = true
                    externalOpenError = FileAccessConnectorError
                        .importedCopyCleanupCandidateChanged
                        .localizedDescription
                } else {
                    retainImportedCopyCleanup(
                        documentID: nil,
                        tokens: capturedRequest.importedCopyCleanupTokens
                    )
                    completeExternalOpenRequest(requestID: capturedRequest.id)
                    await retryExternalOpenCleanupIfNeeded()
                    externalOpenError = nil
                }
            } catch FileAccessConnectorError
                .importedCopyCleanupCandidateChanged {
                completeExternalOpenRequest(requestID: request.id)
                terminalExternalOpenErrorPendingDismissal = true
                externalOpenError = FileAccessConnectorError
                    .importedCopyCleanupCandidateChanged
                    .localizedDescription
            } catch {
                externalOpenError = error.localizedDescription
            }
        } else {
            externalOpenError = nil
        }
        await finishExternalOpenAction()
    }

    private func queuedImportedCopyCleanupCandidateChanged(
        request: QueuedExternalOpenRequest
    ) throws -> Bool {
        guard case let .candidate(candidate) =
                request.importedCopyCleanupCapture else {
            return false
        }
        let currentCandidate = try fileAccessConnector
            .inspectImportedCopyCleanupCandidate(at: request.request.url)
        return currentCandidate != candidate
    }

    @discardableResult
    func retryExternalOpenCleanup() async -> Bool {
        guard externalOpenCommitRequestID == nil,
              !externalOpenInProgress,
              pendingExternalOpenDecision == nil,
              !externalOpenCleanupInProgress else {
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard externalOpenCleanupRequired else {
            if let documentID = deferredImportedCopyCleanupDocumentID {
                let message = PhonePadExternalOpenActionError
                    .cleanupRequiresRecoveryProtection(documentID)
                    .localizedDescription
                externalOpenRecoveryProtectionFailure =
                    ExternalOpenRecoveryProtectionFailure(
                        documentID: documentID,
                        message: message
                    )
                externalOpenError = message
            } else {
                externalOpenError = PhonePadExternalOpenActionError
                    .cleanupNotRequired
                    .localizedDescription
            }
            return false
        }
        externalOpenCleanupInProgress = true
        defer { externalOpenCleanupInProgress = false }
        if importedCopyCleanupJournalRetryRequired {
            return await reconcileImportedCopyCleanupJournal()
        }
        return await retryExternalOpenCleanupIfNeeded()
    }

    @discardableResult
    func recoverPendingExternalOpen() async -> Bool {
        guard let decision = beginPendingExternalOpenDecisionAction() else {
            return false
        }

        let expectedState = state
        var preparation: ExternalOpenPreparation?
        let recovered: Bool
        do {
            let refreshedPreparation = try await readAndPrepareExternalOpen(
                request: decision.request.request,
                requestID: decision.request.id,
                documentID: decision.recoveryMatch.documentID,
                tabID: decision.request.tabID,
                capturedImportedCopyCleanupToken: decision
                    .importedCopyCleanupTokens.first
            )
            preparation = refreshedPreparation
            let refreshedMatch = try await revalidatedExternalOpenMatch(
                candidate: refreshedPreparation.candidate,
                decision: decision
            )
            guard state == expectedState else {
                throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                    decision.recoveryMatch.documentID
                )
            }
            guard let envelope = try await recoveryStore.load(
                documentID: refreshedMatch.documentID
            ) else {
                throw PhonePadExternalOpenActionError.recoveryItemMissing(
                    refreshedMatch.documentID
                )
            }
            guard state == expectedState else {
                throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                    decision.recoveryMatch.documentID
                )
            }

            let cleanupTokens = uniqueImportedCopyCleanupTokens(
                decision.importedCopyCleanupTokens
                    + [refreshedPreparation.importedCopyCleanupToken]
                        .compactMap { $0 }
            )
            switch refreshedPreparation {
            case let .activateExisting(
                _,
                provisionalDocumentID,
                _,
                _,
                _
            ):
                await fileAccessConnector.stopPresenting(
                    documentID: provisionalDocumentID
                )
                state = try openExternallyRecoveredDetachedDocument(
                    state: state,
                    envelope: envelope,
                    tabID: decision.request.tabID
                )
            case let .prepared(payload):
                try await applyRecoveredExternalOpen(
                    payload: payload,
                    match: refreshedMatch,
                    envelope: envelope,
                    tabID: decision.request.tabID
                )
            }
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: state.activeTab.document.id,
                candidate: refreshedPreparation.candidate
            )
            retainImportedCopyCleanup(
                documentID: decision.recoveryMatch.documentID,
                tokens: cleanupTokens
            )
            recoveryItems.removeAll {
                $0.documentID == decision.recoveryMatch.documentID
            }
            pendingExternalOpenDecision = nil
            pendingExternalOpenRecoveryPrompt = nil
            completeExternalOpenRequest(requestID: decision.request.id)
            _ = await retryExternalOpenCleanupIfNeeded()
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: refreshedPreparation.detachmentReason
            )
            externalOpenError = nil
            presentActiveFileConflictIfNeeded()
            recovered = true
        } catch {
            if let preparation {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: decision.request.id
                )
            }
            externalOpenError = error.localizedDescription
            recovered = false
        }
        await finishExternalOpenAction()
        return recovered
    }

    @discardableResult
    func discardRecoveryAndOpenPendingExternalOpen() async -> Bool {
        guard let decision = beginPendingExternalOpenDecisionAction() else {
            return false
        }

        let expectedState = state
        var preparation: ExternalOpenPreparation?
        let opened: Bool
        do {
            let refreshedDocumentID = decision
                .importedCopyCleanupTokens.isEmpty
                ? decision.request.documentID
                : decision.recoveryMatch.documentID
            let refreshedPreparation = try await readAndPrepareExternalOpen(
                request: decision.request.request,
                requestID: decision.request.id,
                documentID: refreshedDocumentID,
                tabID: decision.request.tabID,
                capturedImportedCopyCleanupToken: decision
                    .importedCopyCleanupTokens.first
            )
            preparation = refreshedPreparation
            _ = try await revalidatedExternalOpenMatch(
                candidate: refreshedPreparation.candidate,
                decision: decision
            )
            let cleanupTokens = uniqueImportedCopyCleanupTokens(
                decision.importedCopyCleanupTokens
                    + [refreshedPreparation.importedCopyCleanupToken]
                        .compactMap { $0 }
            )
            let recoveryNotice: DiscardedRecoveryDocumentOpenNotice?
            let commitResult: ExternalOpenCommitResult
            var decisionCleanupDocumentID: DocumentID? = nil
            switch refreshedPreparation {
            case let .activateExisting(
                activatedState,
                provisionalDocumentID,
                _,
                _,
                _
            ):
                decisionCleanupDocumentID = activatedState.activeTab.document.id
                try await fileAccessConnector.reassignImportedCopyCleanup(
                    tokens: cleanupTokens,
                    documentID: activatedState.activeTab.document.id
                )
                try dryRunExternalOpenCommit(
                    preparation: refreshedPreparation,
                    expectedState: expectedState
                )
                let terminalOutcome = try await recoveryStore.discardRecovery(
                    documentID: decision.recoveryMatch.documentID
                )
                guard state == expectedState else {
                    throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                        decision.recoveryMatch.documentID
                    )
                }
                try await activateExistingExternalOpen(
                    state: activatedState,
                    provisionalDocumentID: provisionalDocumentID
                )
                completeExternalOpenRequest(requestID: decision.request.id)
                recoveryNotice = terminalOutcome == .residualCleanupPending
                    ? .residualRecoveryCleanupPending
                    : nil
                commitResult = .complete
            case let .prepared(.bound(prepared, _)):
                let result = try await
                    discardRecoveryAndCommitPreparedBoundDocumentOpen(
                        state: expectedState,
                        recoveryDocumentID: decision.recoveryMatch.documentID,
                        preparedOpen: prepared,
                        recoveryStore: recoveryStore
                    )
                guard state == expectedState else {
                    throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                        decision.recoveryMatch.documentID
                    )
                }
                state = result.state
                presentActiveFileConflictIfNeeded()
                completeExternalOpenRequest(requestID: decision.request.id)
                recoveryNotice = result.notice
                commitResult = .complete
            case let .prepared(.detached(prepared, openedFile)):
                let result = try await
                    discardRecoveryAndCommitPreparedDetachedDocumentOpen(
                        state: expectedState,
                        recoveryDocumentID: decision.recoveryMatch.documentID,
                        preparedOpen: prepared,
                        recoveryStore: recoveryStore
                    )
                guard state == expectedState else {
                    throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                        decision.recoveryMatch.documentID
                    )
                }
                state = result.transition.state
                decisionCleanupDocumentID = result.transition.envelope.documentID
                retainExternalOpenDetachmentNoticeIfNeeded(
                    reason: openedFile.reason
                )
                let protected = await persistExternalOpenTransition(
                    result.transition
                )
                completeExternalOpenRequest(requestID: decision.request.id)
                recoveryNotice = result.notice
                commitResult = protected
                    ? .complete
                    : .recoveryProtectionFailed
            }
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: state.activeTab.document.id,
                candidate: refreshedPreparation.candidate
            )
            retainImportedCopyCleanup(
                documentID: decisionCleanupDocumentID,
                tokens: cleanupTokens
            )
            recoveryItems.removeAll {
                $0.documentID == decision.recoveryMatch.documentID
            }
            pendingExternalOpenDecision = nil
            pendingExternalOpenRecoveryPrompt = nil
            if commitResult == .complete {
                _ = await retryExternalOpenCleanupIfNeeded()
                retainExternalOpenDetachmentNoticeIfNeeded(
                    reason: refreshedPreparation.detachmentReason
                )
                if recoveryNotice == .residualRecoveryCleanupPending {
                    appendExternalOpenNotice(
                        "Preserved work was discarded and the supplied File opened. Protected recovery marker cleanup remains."
                    )
                }
                externalOpenError = nil
                opened = true
            } else {
                recordExternalOpenRecoveryProtectionFailure(
                    documentID: state.activeTab.document.id,
                    message: recoveryError
                )
                opened = false
            }
        } catch {
            if let preparation {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: decision.request.id
                )
            }
            externalOpenError = error.localizedDescription
            opened = false
        }
        await finishExternalOpenAction()
        return opened
    }

    private func beginPendingExternalOpenDecisionAction()
        -> PendingExternalOpenDecision? {
        guard let decision = pendingExternalOpenDecision,
              !externalOpenInProgress,
              !tabTransitionInProgress,
              !fileSaveInProgress,
              !fileSaveCleanupRequired,
              pendingSaveAsReplacement == nil,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil else {
            externalOpenError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return nil
        }
        externalOpenInProgress = true
        externalOpenError = nil
        return decision
    }

    private func revalidatedExternalOpenMatch(
        candidate: FileOpenCandidate,
        decision: PendingExternalOpenDecision
    ) async throws -> RecoveryFileOpenMatch {
        let claims = try await recoveryStore.recoveryFileCollisionClaims(
            excludingDocumentID: decision.request.documentID
        )
        let collision = try await fileAccessConnector.matchRecoveryFileClaims(
            candidate: candidate,
            claims: claims
        )
        switch collision {
        case let .item(match)
        where match.documentID == decision.recoveryMatch.documentID:
            return match
        case let .ambiguous(documentIDs):
            throw PhonePadExternalOpenActionError
                .recoveryCollisionAmbiguous(documentIDs)
        case .none, .item:
            throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                decision.recoveryMatch.documentID
            )
        }
    }

    private func applyRecoveredExternalOpen(
        payload: PreparedExternalOpenPayload,
        match: RecoveryFileOpenMatch,
        envelope: RecoveryEnvelope,
        tabID: TabID
    ) async throws {
        switch payload {
        case let .bound(prepared, snapshot)
        where match.kinds.contains(.sourceFile):
            state = try openExternallyRecoveredBoundDocument(
                state: state,
                envelope: envelope,
                tabID: tabID,
                observation: ObservedBoundFile(
                    binding: snapshot.openedFile.binding,
                    providerConflictVersions: snapshot.providerConflictVersions
                )
            )
            guard state.activeTab.document.id == envelope.documentID else {
                await fileAccessConnector.stopPresenting(
                    documentID: prepared.documentID
                )
                throw PhonePadExternalOpenActionError.recoveryMatchChanged(
                    envelope.documentID
                )
            }
        case .bound:
            await stopProvisionalPresenter(payload: payload)
            state = try openExternallyRecoveredDetachedDocument(
                state: state,
                envelope: envelope,
                tabID: tabID
            )
        case .detached:
            state = try openExternallyRecoveredDetachedDocument(
                state: state,
                envelope: envelope,
                tabID: tabID
            )
        }
    }

    private func dryRunExternalOpenCommit(
        preparation: ExternalOpenPreparation,
        expectedState: PhonePadState
    ) throws {
        guard state == expectedState else {
            throw PhonePadExternalOpenActionError.commitRequestMissing
        }
        switch preparation {
        case .activateExisting:
            return
        case let .prepared(.bound(prepared, _)):
            _ = try commitPreparedBoundDocumentOpen(
                state: state,
                prepared: prepared
            )
        case let .prepared(.detached(prepared, _)):
            _ = try commitPreparedDetachedDocumentOpen(
                state: state,
                prepared: prepared
            )
        }
    }

    private func prepareAndResolveExternalOpen(
        request: QueuedExternalOpenRequest
    ) async throws -> Bool {
        var authoritativeActiveOpenMatch: AuthoritativeActiveOpenMatch = .none
        var preliminaryCleanupToken = request.importedCopyCleanupTokens.first
        let activeLocatorMatch: ActiveFileOpenLocatorMatch
        do {
            activeLocatorMatch = try await fileAccessConnector
                .matchActiveOpenLocators(
                    selectedURL: request.request.url,
                    claims: activeExternalOpenLocatorClaims()
                )
        } catch {
            _ = try await captureImportedCopyCleanupForPreliminaryOpen(
                request: request,
                documentID: request.documentID
            )
            throw error
        }
        switch activeLocatorMatch {
        case .none:
            break
        case let .missingItem(documentID):
            let capturedCleanupToken = try await
                captureImportedCopyCleanupForPreliminaryOpen(
                    request: request,
                    documentID: request.documentID
                )
            preliminaryCleanupToken = capturedCleanupToken
                ?? preliminaryCleanupToken
            let nodePresence = try await fileAccessConnector
                .selectedFileNodePresence(at: request.request.url)
            if preliminaryCleanupToken == nil,
               nodePresence == .missing {
                return try await activateMatchedExternalOpen(
                    documentID: documentID,
                    tokens: request.importedCopyCleanupTokens,
                    requestID: request.id
                )
            }
            authoritativeActiveOpenMatch = try classifyAuthoritativeActiveOpenMatch(
                documentIDs: [documentID]
            )
        case let .requiresAuthoritativeRead(documentIDs):
            authoritativeActiveOpenMatch = try classifyAuthoritativeActiveOpenMatch(
                documentIDs: documentIDs
            )
        case let .ambiguous(documentIDs):
            _ = try await captureImportedCopyCleanupForPreliminaryOpen(
                request: request,
                documentID: request.documentID
            )
            throw PhonePadExternalOpenActionError
                .activeLocatorCollisionAmbiguous(documentIDs)
        }

        var preparation = try await readAndPrepareExternalOpen(
            request: request.request,
            requestID: request.id,
            documentID: request.documentID,
            tabID: request.tabID,
            capturedImportedCopyCleanupToken:
                preliminaryCleanupToken
        )
        if case .none = authoritativeActiveOpenMatch {
            do {
                authoritativeActiveOpenMatch = try
                    classifyAuthoritativeDurableDetachedIdentityMatch(
                        candidate: preparation.candidate
                    )
            } catch {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: request.id
                )
                throw error
            }
        }
        switch authoritativeActiveOpenMatch {
        case .none:
            break
        case let .ephemeral(authoritativeDocumentIDs):
            switch authoritativeEphemeralOpenMatch(
                candidate: preparation.candidate,
                documentIDs: authoritativeDocumentIDs
            ) {
            case .none:
                invalidateExternalOpenEphemeralClaims(
                    documentIDs: authoritativeDocumentIDs,
                    locatorURL: preparation.candidate.locatorURL
                )
            case let .item(documentID):
                if case let .activateExisting(activatedState, _, _, _, _) =
                    preparation,
                   activatedState.activeTab.document.id != documentID {
                    await retainExternalOpenPreparationForRetry(
                        preparation,
                        requestID: request.id
                    )
                    let ambiguousDocumentIDs = Set([
                        documentID,
                        activatedState.activeTab.document.id,
                    ]).sorted {
                        $0.rawValue.uuidString < $1.rawValue.uuidString
                    }
                    throw PhonePadExternalOpenActionError
                        .activeLocatorCollisionAmbiguous(
                            ambiguousDocumentIDs
                        )
                }
                await stopProvisionalPresenter(preparation: preparation)
                let cleanupTokens = uniqueImportedCopyCleanupTokens(
                    request.importedCopyCleanupTokens
                        + [preliminaryCleanupToken]
                            .compactMap { $0 }
                        + [preparation.importedCopyCleanupToken]
                            .compactMap { $0 }
                )
                try await fileAccessConnector.reassignImportedCopyCleanup(
                    tokens: cleanupTokens,
                    documentID: documentID
                )
                return try await activateMatchedExternalOpen(
                    documentID: documentID,
                    tokens: cleanupTokens,
                    requestID: request.id
                )
            case let .ambiguous(documentIDs):
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: request.id
                )
                throw PhonePadExternalOpenActionError
                    .activeLocatorCollisionAmbiguous(documentIDs)
            }
        case let .durable(documentID):
            do {
                preparation = try reconcileAuthoritativeDurableExternalOpen(
                    preparation: preparation,
                    documentID: documentID
                )
            } catch {
                await retainExternalOpenPreparationForRetry(
                    preparation,
                    requestID: request.id
                )
                throw error
            }
        }
        let payload: PreparedExternalOpenPayload
        switch preparation {
        case let .activateExisting(
            activatedState,
            provisionalDocumentID,
            candidate,
            cleanupToken,
            detachmentReason
        ):
            let cleanupDocumentID = activatedState.activeTab.document.id
            let cleanupTokens = uniqueImportedCopyCleanupTokens(
                request.importedCopyCleanupTokens
                    + [cleanupToken].compactMap { $0 }
            )
            try await fileAccessConnector.reassignImportedCopyCleanup(
                tokens: cleanupTokens,
                documentID: cleanupDocumentID
            )
            try await activateExistingExternalOpen(
                state: activatedState,
                provisionalDocumentID: provisionalDocumentID
            )
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: cleanupDocumentID,
                candidate: candidate
            )
            retainImportedCopyCleanup(
                documentID: cleanupDocumentID,
                tokens: cleanupTokens
            )
            completeExternalOpenRequest(requestID: request.id)
            _ = await retryExternalOpenCleanupIfNeeded()
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: detachmentReason
            )
            return true
        case let .prepared(preparedPayload):
            payload = preparedPayload
        }

        do {
            let claims = try await recoveryStore.recoveryFileCollisionClaims(
                excludingDocumentID: request.documentID
            )
            let collision = try await fileAccessConnector
                .matchRecoveryFileClaims(
                    candidate: payload.candidate,
                    claims: claims
                )
            switch collision {
            case .none:
                let result = try await commitExternalOpen(
                    payload: payload,
                    request: request
                )
                return result == .complete
            case let .item(match):
                guard let envelope = try await recoveryStore.load(
                    documentID: match.documentID
                ) else {
                    throw PhonePadExternalOpenActionError
                        .recoveryItemMissing(match.documentID)
                }
                let cleanupTokens = uniqueImportedCopyCleanupTokens(
                    request.importedCopyCleanupTokens
                        + [payload.importedCopyCleanupToken]
                            .compactMap { $0 }
                )
                try await fileAccessConnector.reassignImportedCopyCleanup(
                    tokens: cleanupTokens,
                    documentID: match.documentID
                )
                await stopProvisionalPresenter(payload: payload)
                if match.kinds == [.pendingSaveAsDestination],
                   state.tabs.contains(where: { tab in
                       tab.document.id == match.documentID
                   }) {
                    return try await activateMatchedExternalOpen(
                        documentID: match.documentID,
                        tokens: cleanupTokens,
                        requestID: request.id
                    )
                }
                pendingExternalOpenDecision = PendingExternalOpenDecision(
                    request: request,
                    recoveryMatch: match,
                    importedCopyCleanupTokens: cleanupTokens
                )
                pendingExternalOpenRecoveryPrompt = PendingExternalOpenRecoveryPrompt(
                    recoveryDocumentID: match.documentID,
                    title: envelope.title
                )
                externalOpenError = nil
                return true
            case let .ambiguous(documentIDs):
                throw PhonePadExternalOpenActionError
                    .recoveryCollisionAmbiguous(documentIDs)
            }
        } catch {
            await retainExternalOpenPreparationForRetry(
                .prepared(payload),
                requestID: request.id
            )
            throw error
        }
    }

    private func captureImportedCopyCleanupForPreliminaryOpen(
        request: QueuedExternalOpenRequest,
        documentID: DocumentID
    ) async throws -> ImportedCopyCleanupToken? {
        guard request.request.accessIntent == .copyRequired else {
            return nil
        }
        if let capturedToken = request.importedCopyCleanupTokens.first {
            return capturedToken
        }
        let token = try await fileAccessConnector.captureImportedCopyCleanup(
            at: request.request.url,
            documentID: documentID
        )
        retainImportedCopyCleanupTokenForRetry(
            token,
            requestID: request.id
        )
        return token
    }

    private func activateMatchedExternalOpen(
        documentID: DocumentID,
        tokens: [ImportedCopyCleanupToken],
        requestID: UUID
    ) async throws -> Bool {
        guard let tab = state.tabs.first(where: { tab in
            tab.document.id == documentID
        }) else {
            throw PhonePadStateError.documentMissing(documentID)
        }
        state = try PhonePadCore.selectTab(
            state: state,
            tabID: tab.id
        )
        retainImportedCopyCleanup(
            documentID: documentID,
            tokens: uniqueImportedCopyCleanupTokens(tokens)
        )
        completeExternalOpenRequest(requestID: requestID)
        _ = await retryExternalOpenCleanupIfNeeded()
        presentActiveFileConflictIfNeeded()
        return true
    }

    private func classifyAuthoritativeActiveOpenMatch(
        documentIDs: [DocumentID]
    ) throws -> AuthoritativeActiveOpenMatch {
        let orderedDocumentIDs = Array(Set(documentIDs)).sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        guard !orderedDocumentIDs.isEmpty else {
            return .none
        }
        let durableDocumentIDs = try orderedDocumentIDs.filter { documentID in
            guard let document = state.tabs.first(where: { tab in
                tab.document.id == documentID
            })?.document else {
                throw PhonePadStateError.documentMissing(documentID)
            }
            return document.fileBinding != nil
                || document.recoveryFileReference != nil
        }
        guard !durableDocumentIDs.isEmpty else {
            return .ephemeral(orderedDocumentIDs)
        }
        guard orderedDocumentIDs.count == 1,
              durableDocumentIDs.count == 1,
              let documentID = durableDocumentIDs.first else {
            throw PhonePadExternalOpenActionError
                .activeLocatorCollisionAmbiguous(orderedDocumentIDs)
        }
        return .durable(documentID)
    }

    private func classifyAuthoritativeDurableDetachedIdentityMatch(
        candidate: FileOpenCandidate
    ) throws -> AuthoritativeActiveOpenMatch {
        guard let candidateIdentity = candidate.identity else {
            return .none
        }
        let documentIDs = state.tabs.compactMap { tab -> DocumentID? in
            guard tab.document.fileBinding == nil,
                  tab.document.recoveryFileReference?.identity
                    == candidateIdentity else {
                return nil
            }
            return tab.document.id
        }
        return try classifyAuthoritativeActiveOpenMatch(
            documentIDs: documentIDs
        )
    }

    private func reconcileAuthoritativeDurableExternalOpen(
        preparation: ExternalOpenPreparation,
        documentID: DocumentID
    ) throws -> ExternalOpenPreparation {
        guard let tab = state.tabs.first(where: { tab in
            tab.document.id == documentID
        }) else {
            throw PhonePadStateError.documentMissing(documentID)
        }
        switch preparation {
        case let .activateExisting(
            activatedState,
            _,
            candidate,
            _,
            _
        ):
            guard activatedState.activeTab.document.id == documentID else {
                let documentIDs = Set([
                    documentID,
                    activatedState.activeTab.document.id,
                ]).sorted {
                    $0.rawValue.uuidString < $1.rawValue.uuidString
                }
                throw PhonePadExternalOpenActionError
                    .activeLocatorCollisionAmbiguous(documentIDs)
            }
            if tab.document.fileBinding == nil,
               let reference = tab.document.recoveryFileReference {
                try requireMatchingDurableDetachedSource(
                    reference: reference,
                    candidate: candidate,
                    documentID: documentID
                )
            }
            return preparation
        case let .prepared(payload):
            let activatedState: PhonePadState
            if tab.document.fileBinding != nil {
                switch payload {
                case let .bound(_, snapshot):
                    let reconciledState = try reconcileBoundDocument(
                        state: state,
                        documentID: documentID,
                        observation: ObservedBoundFile(
                            binding: snapshot.openedFile.binding,
                            providerConflictVersions:
                                snapshot.providerConflictVersions
                        )
                    )
                    activatedState = try PhonePadCore.selectTab(
                        state: reconciledState,
                        tabID: tab.id
                    )
                case .detached:
                    activatedState = try
                        activateAuthoritativelyMatchedBoundFileOpen(
                            state: state,
                            documentID: documentID,
                            candidate: payload.candidate
                        )
                }
            } else if let reference = tab.document.recoveryFileReference {
                try requireMatchingDurableDetachedSource(
                    reference: reference,
                    candidate: payload.candidate,
                    documentID: documentID
                )
                activatedState = try PhonePadCore.selectTab(
                    state: state,
                    tabID: tab.id
                )
            } else {
                throw RecoveredFileOpenError.fileReferenceMissing(documentID)
            }
            return .activateExisting(
                state: activatedState,
                provisionalDocumentID: payload.provisionalDocumentID,
                candidate: payload.candidate,
                importedCopyCleanupToken:
                    payload.importedCopyCleanupToken,
                detachmentReason: payload.detachmentReason
            )
        }
    }

    private func requireMatchingDurableDetachedSource(
        reference: RecoveryFileReference,
        candidate: FileOpenCandidate,
        documentID: DocumentID
    ) throws {
        switch (reference.identity, candidate.identity) {
        case let (.some(referenceIdentity), .some(candidateIdentity))
        where referenceIdentity == candidateIdentity:
            break
        case (.none, .none):
            break
        case (.some, .some), (.some, .none), (.none, .some):
            throw PhonePadExternalOpenActionError
                .durableDetachedSourceIdentityChanged(documentID)
        }
        switch candidate.providerConflictVersions {
        case .none:
            break
        case let .unresolved(count):
            throw PhonePadExternalOpenActionError
                .durableDetachedSourceHasUnresolvedProviderVersions(
                    documentID: documentID,
                    count: count
                )
        }
        guard reference.cleanDigest == candidate.digest else {
            throw PhonePadExternalOpenActionError
                .durableDetachedSourceContentChanged(documentID)
        }
    }

    private func activeExternalOpenLocatorClaims()
        -> [ActiveFileOpenLocatorClaim] {
        let ephemeralDocumentIDs = Set(
            state.tabs.compactMap { tab -> DocumentID? in
                guard tab.document.fileBinding == nil,
                      tab.document.recoveryFileReference == nil else {
                    return nil
                }
                return tab.document.id
            }
        )
        externalOpenEphemeralClaims = externalOpenEphemeralClaims
            .filter { documentID, _ in
                ephemeralDocumentIDs.contains(documentID)
            }

        return state.tabs.flatMap { tab -> [ActiveFileOpenLocatorClaim] in
            if let binding = tab.document.fileBinding {
                return [
                    .bound(
                        documentID: tab.document.id,
                        binding: binding
                    ),
                ]
            }
            if let reference = tab.document.recoveryFileReference {
                return [
                    .detached(
                        documentID: tab.document.id,
                        reference: FileCollisionReference(
                            bookmark: reference.bookmark,
                            identity: reference.identity
                        )
                    ),
                ]
            }
            return externalOpenEphemeralClaims[tab.document.id, default: []]
                .sorted { lhs, rhs in
                    lhs.candidate.locatorURL.absoluteString
                        < rhs.candidate.locatorURL.absoluteString
                }
                .map { claim in
                    .ephemeral(
                        documentID: tab.document.id,
                        locatorURL: claim.candidate.locatorURL
                    )
                }
        }
    }

    private func retainExternalOpenEphemeralClaimIfNeeded(
        documentID: DocumentID,
        candidate: FileOpenCandidate
    ) {
        guard let document = state.tabs.first(where: { tab in
            tab.document.id == documentID
        })?.document,
        document.fileBinding == nil,
        document.recoveryFileReference == nil else {
            externalOpenEphemeralClaims.removeValue(forKey: documentID)
            return
        }
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

    private func authoritativeEphemeralOpenMatch(
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

    private func invalidateExternalOpenEphemeralClaims(
        documentIDs: [DocumentID],
        locatorURL: URL
    ) {
        let expectedDocumentIDs = Set(documentIDs)
        let standardizedLocator = locatorURL.standardizedFileURL
        for documentID in expectedDocumentIDs {
            guard let existingClaims = externalOpenEphemeralClaims[documentID]
            else {
                continue
            }
            let retainedClaims = existingClaims.filter { claim in
                claim.candidate.locatorURL.standardizedFileURL
                    != standardizedLocator
            }
            if retainedClaims.isEmpty {
                externalOpenEphemeralClaims.removeValue(forKey: documentID)
            } else {
                externalOpenEphemeralClaims[documentID] = retainedClaims
            }
        }
    }

    private func readAndPrepareExternalOpen(
        request: PhonePadExternalOpenRequest,
        requestID: UUID,
        documentID: DocumentID,
        tabID: TabID,
        capturedImportedCopyCleanupToken:
            ImportedCopyCleanupToken?
    ) async throws -> ExternalOpenPreparation {
        let outcome: OpenTextFileOutcome
        if let capturedImportedCopyCleanupToken {
            outcome = try await fileAccessConnector.openTextFile(
                at: request.url,
                documentID: documentID,
                capturedImportedCopyCleanupToken:
                    capturedImportedCopyCleanupToken
            )
        } else {
            outcome = try await fileAccessConnector.openTextFile(
                at: request.url,
                documentID: documentID,
                accessIntent: request.accessIntent
            )
        }
        switch outcome {
        case let .bound(snapshot):
            let preparation = prepareBoundDocumentOpen(
                state: state,
                documentID: documentID,
                tabID: tabID,
                text: snapshot.openedFile.text,
                observation: ObservedBoundFile(
                    binding: snapshot.openedFile.binding,
                    providerConflictVersions: snapshot.providerConflictVersions
                )
            )
            switch preparation {
            case let .activateExisting(activatedState):
                return .activateExisting(
                    state: activatedState,
                    provisionalDocumentID: documentID,
                    candidate: FileOpenCandidate(
                        locatorURL: snapshot.openedFile.binding.locatorURL,
                        identity: snapshot.openedFile.binding.identity,
                        digest: snapshot.openedFile.binding.digest,
                        providerConflictVersions: snapshot.providerConflictVersions
                    ),
                    importedCopyCleanupToken: nil,
                    detachmentReason: nil
                )
            case let .prepared(prepared):
                return .prepared(
                    .bound(prepared: prepared, snapshot: snapshot)
                )
            }
        case let .detached(openedFile):
            let preparation: DetachedDocumentOpenPreparation
            do {
                preparation = try prepareDetachedDocumentOpen(
                    state: state,
                    documentID: documentID,
                    tabID: tabID,
                    snapshot: openedFile.snapshot,
                    editedAt: Date()
                )
            } catch {
                retainImportedCopyCleanupTokenForRetry(
                    openedFile.importedCopyCleanupToken,
                    requestID: requestID
                )
                throw error
            }
            switch preparation {
            case let .activateExisting(activatedState):
                return .activateExisting(
                    state: activatedState,
                    provisionalDocumentID: documentID,
                    candidate: openedFile.snapshot.candidate,
                    importedCopyCleanupToken: openedFile
                        .importedCopyCleanupToken,
                    detachmentReason: openedFile.reason
                )
            case let .prepared(prepared):
                return .prepared(
                    .detached(
                        prepared: prepared,
                        openedFile: openedFile
                    )
                )
            }
        case let .rejected(rejection):
            guard let cleanupToken = rejection.importedCopyCleanupToken else {
                completeRejectedExternalOpenRequest(requestID: requestID)
                throw rejection.error
            }
            let cleanupOutcome = await fileAccessConnector
                .cleanupImportedCopy(token: cleanupToken)
            switch cleanupOutcome {
            case .removed, .alreadyAbsent:
                completeRejectedExternalOpenRequest(requestID: requestID)
                throw rejection.error
            case let .residual(failure):
                retainImportedCopyCleanup(
                    documentID: nil,
                    tokens: [cleanupToken]
                )
                let actionError = PhonePadExternalOpenActionError
                    .rejectedFileCleanupFailed(
                        rejection: rejection.error,
                        cleanup: failure
                    )
                externalOpenGeneralNotice = actionError.localizedDescription
                completeRejectedExternalOpenRequest(requestID: requestID)
                throw actionError
            }
        }
    }

    private func completeRejectedExternalOpenRequest(requestID: UUID) {
        if pendingExternalOpenDecision?.request.id == requestID {
            pendingExternalOpenDecision = nil
            pendingExternalOpenRecoveryPrompt = nil
        }
        completeExternalOpenRequest(requestID: requestID)
        terminalExternalOpenErrorPendingDismissal = true
    }

    private func activateExistingExternalOpen(
        state activatedState: PhonePadState,
        provisionalDocumentID: DocumentID
    ) async throws {
        let retainedDocument = activatedState.activeTab.document
        if let retainedBinding = retainedDocument.fileBinding {
            do {
                try await fileAccessConnector.startPresenting(
                    documentID: retainedDocument.id,
                    binding: retainedBinding
                )
            } catch {
                await fileAccessConnector.stopPresenting(
                    documentID: provisionalDocumentID
                )
                throw error
            }
        }
        await fileAccessConnector.stopPresenting(
            documentID: provisionalDocumentID
        )
        state = activatedState
        presenterRefreshPending = true
        presentActiveFileConflictIfNeeded()
    }

    private func commitExternalOpen(
        payload: PreparedExternalOpenPayload,
        request: QueuedExternalOpenRequest
    ) async throws -> ExternalOpenCommitResult {
        switch payload {
        case let .bound(prepared, _):
            retainImportedCopyCleanup(
                documentID: nil,
                tokens: request.importedCopyCleanupTokens
            )
            state = try commitPreparedBoundDocumentOpen(
                state: state,
                prepared: prepared
            )
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: state.activeTab.document.id,
                candidate: prepared.candidate
            )
            presentActiveFileConflictIfNeeded()
            completeExternalOpenRequest(requestID: request.id)
            _ = await retryExternalOpenCleanupIfNeeded()
            return .complete
        case let .detached(prepared, openedFile):
            let transition = try commitPreparedDetachedDocumentOpen(
                state: state,
                prepared: prepared
            )
            state = transition.state
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: openedFile.reason
            )
            retainExternalOpenEphemeralClaimIfNeeded(
                documentID: transition.envelope.documentID,
                candidate: openedFile.snapshot.candidate
            )
            retainImportedCopyCleanup(
                documentID: transition.envelope.documentID,
                tokens: uniqueImportedCopyCleanupTokens(
                    request.importedCopyCleanupTokens
                        + [openedFile.importedCopyCleanupToken]
                            .compactMap { $0 }
                )
            )
            let protected = await persistExternalOpenTransition(transition)
            completeExternalOpenRequest(requestID: request.id)
            guard protected else {
                recordExternalOpenRecoveryProtectionFailure(
                    documentID: transition.envelope.documentID,
                    message: recoveryError
                )
                return .recoveryProtectionFailed
            }
            _ = await retryExternalOpenCleanupIfNeeded()
            retainExternalOpenDetachmentNoticeIfNeeded(
                reason: openedFile.reason
            )
            return .complete
        }
    }

    private func retainExternalOpenDetachmentNoticeIfNeeded(
        reason: FileOpenDetachmentReason?
    ) {
        guard let reason,
              state.activeTab.document.fileBinding == nil,
              state.activeTab.document.isUnsaved else {
            return
        }
        externalOpenDocumentNotice = ExternalOpenDocumentNotice(
            documentID: state.activeTab.document.id,
            message: externalOpenDetachmentNotice(reason: reason)
        )
    }

    private func appendExternalOpenNotice(_ notice: String) {
        guard externalOpenGeneralNotice != notice,
              externalOpenGeneralNotice?.contains(notice) != true else {
            return
        }
        if let externalOpenGeneralNotice {
            self.externalOpenGeneralNotice = externalOpenGeneralNotice
                + " " + notice
        } else {
            externalOpenGeneralNotice = notice
        }
    }

    private func stopProvisionalPresenter(
        payload: PreparedExternalOpenPayload
    ) async {
        guard case let .bound(prepared, _) = payload else {
            return
        }
        await fileAccessConnector.stopPresenting(
            documentID: prepared.documentID
        )
    }

    private func stopProvisionalPresenter(
        preparation: ExternalOpenPreparation
    ) async {
        switch preparation {
        case let .activateExisting(_, provisionalDocumentID, _, _, _):
            await fileAccessConnector.stopPresenting(
                documentID: provisionalDocumentID
            )
        case let .prepared(payload):
            await stopProvisionalPresenter(payload: payload)
        }
    }

    private func retainExternalOpenPreparationForRetry(
        _ preparation: ExternalOpenPreparation,
        requestID: UUID
    ) async {
        await stopProvisionalPresenter(preparation: preparation)
        retainImportedCopyCleanupTokenForRetry(
            preparation.importedCopyCleanupToken,
            requestID: requestID
        )
    }

    private func retainImportedCopyCleanupTokenForRetry(
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
                importedCopyCleanupTokens:
                    uniqueImportedCopyCleanupTokens(
                        decision.importedCopyCleanupTokens + [token]
                    )
            )
            return
        }
        guard let requestIndex = externalOpenQueue.firstIndex(where: {
            $0.id == requestID
        }) else {
            retainImportedCopyCleanup(
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
            importedCopyCleanupCapture:
                request.importedCopyCleanupCapture
        )
    }

    private var canBeginExternalOpenAction: Bool {
        !externalOpenInProgress
            && !externalOpenCleanupInProgress
            && !tabTransitionInProgress
            && !fileSaveInProgress
            && !fileSaveCleanupRequired
            && pendingSaveAsReplacement == nil
            && activeRecoveryAction == nil
            && pendingTabCloseSession == nil
            && pendingExternalOpenDecision == nil
            && !fileConflictResolutionIsPresented
    }

    private func requestExternalOpenEditorCommitIfPossible() {
        guard let request = externalOpenQueue.first else {
            return
        }
        guard !externalOpenCleanupPreflightInProgress else {
            return
        }
        guard !importedCopyCleanupPreflightRequired(request: request) else {
            if let failure = externalOpenCleanupPreflightFailures[request.id] {
                externalOpenError = failure.message
            }
            return
        }
        guard presentersShouldBeActive,
              externalOpenCommitRequestID == nil,
              externalOpenError == nil
                || externalOpenError
                    == importedCopyCleanupJournalErrorMessage,
              canBeginExternalOpenAction else {
            return
        }
        externalOpenCommitRequestID = UUID()
    }

    private func completeExternalOpenRequest(requestID: UUID) {
        guard externalOpenQueue.first?.id == requestID else {
            externalOpenError = PhonePadExternalOpenActionError
                .commitRequestMissing
                .localizedDescription
            return
        }
        externalOpenQueue.removeFirst()
        externalOpenCleanupPreflightFailures.removeValue(forKey: requestID)
        if externalOpenError != importedCopyCleanupJournalErrorMessage {
            externalOpenError = nil
        }
    }

    private func finishExternalOpenAction() async {
        if !presentersShouldBeActive {
            await fileAccessConnector.pausePresenters()
            presenterRefreshPending = true
        }
        externalOpenInProgress = false
        externalOpenCommitRequestID = nil
        await resumePendingActivationWorkAfterExclusiveAction()
    }

    private func persistExternalOpenTransition(
        _ transition: RecoveryEditTransition
    ) async -> Bool {
        await cancelAndAwaitCheckpointTask()
        guard pendingCheckpoint == nil, failedCheckpoint == nil else {
            recoveryError = PhonePadTabTransitionError
                .checkpointMustFinishBeforeTransition
                .localizedDescription
            return false
        }
        editGeneration += 1
        let now = checkpointClock.now
        let checkpoint = PendingRecoveryCheckpoint(
            generation: editGeneration,
            checkpointBaseState: transition.state,
            recoveryBaselineState: nil,
            text: transition.envelope.text,
            editedAt: transition.envelope.editedAt,
            firstPendingAt: now,
            lastEditAt: now,
            requiresImmediateCheckpoint: true
        )
        pendingCheckpoint = checkpoint
        let outcome = await persist(checkpoint: checkpoint)
        return outcome == .persisted
    }

    private func retainImportedCopyCleanup(
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
        refreshExternalOpenCleanupAvailability()
    }

    @discardableResult
    private func retryExternalOpenCleanupIfNeeded() async -> Bool {
        guard !pendingExternalOpenCleanups.isEmpty else {
            refreshExternalOpenCleanupAvailability()
            return true
        }
        var remainingCleanups: [PendingImportedCopyCleanup] = []
        var failureMessages: [String] = []
        for cleanup in pendingExternalOpenCleanups {
            guard importedCopyCleanupIsRunnable(cleanup) else {
                remainingCleanups.append(cleanup)
                continue
            }
            var remainingTokens: [ImportedCopyCleanupToken] = []
            for token in cleanup.tokens {
                let outcome = await fileAccessConnector.cleanupImportedCopy(
                    token: token
                )
                switch outcome {
                case .removed, .alreadyAbsent:
                    break
                case let .residual(failure):
                    remainingTokens.append(token)
                    failureMessages.append(
                        importedCopyCleanupFailureMessage(failure)
                    )
                }
            }
            if !remainingTokens.isEmpty {
                remainingCleanups.append(
                    PendingImportedCopyCleanup(
                        documentID: cleanup.documentID,
                        tokens: remainingTokens
                    )
                )
            }
        }
        pendingExternalOpenCleanups = remainingCleanups
        refreshExternalOpenCleanupAvailability()
        guard failureMessages.isEmpty else {
            externalOpenGeneralNotice = failureMessages.joined(separator: " ")
            return false
        }
        externalOpenGeneralNotice = remainingCleanups.isEmpty
            ? "Imported File copy cleanup finished."
            : nil
        return true
    }

    @discardableResult
    private func reconcileImportedCopyCleanupJournal() async -> Bool {
        do {
            let report = try await fileAccessConnector
                .reconcileImportedCopyCleanupJournal()
            let reportedItems = report.removed
                + report.alreadyAbsent
                + report.awaitingProtection
                + report.residuals.map(\.item)
            removePendingImportedCopyCleanupTokens(
                Set(reportedItems.map(\.token))
            )

            var retainedResiduals: [ImportedCopyCleanupResidual] = []
            for residual in report.residuals {
                if try await orphanedImportedCopyCandidateChange(
                    residual
                ) {
                    try await fileAccessConnector
                        .abandonImportedCopyCleanup(
                            tokens: [residual.item.token]
                        )
                } else {
                    retainedResiduals.append(residual)
                }
            }
            importedCopyCleanupJournalRetryRequired =
                !retainedResiduals.isEmpty
            var residualMessages = retainedResiduals.map { residual in
                retainImportedCopyCleanup(
                    documentID: residual.item.documentID,
                    tokens: [residual.item.token]
                )
                return importedCopyCleanupFailureMessage(residual.failure)
            }
            var awaitingProtectionMessages: [String] = []
            for item in report.awaitingProtection {
                guard try await importedCopyCleanupIsProtected(
                    documentID: item.documentID
                ) else {
                    importedCopyCleanupJournalRetryRequired = true
                    awaitingProtectionMessages.append(
                        "Interrupted imported File cleanup for Document \(item.documentID.rawValue.uuidString) is waiting for protected recovery data. Restore or protect that Document, then retry cleanup."
                    )
                    continue
                }

                let outcome = await fileAccessConnector.cleanupImportedCopy(
                    token: item.token
                )
                switch outcome {
                case .removed, .alreadyAbsent:
                    break
                case let .residual(failure):
                    importedCopyCleanupJournalRetryRequired = true
                    retainImportedCopyCleanup(
                        documentID: item.documentID,
                        tokens: [item.token]
                    )
                    residualMessages.append(
                        importedCopyCleanupFailureMessage(failure)
                    )
                }
            }

            setImportedCopyCleanupJournalError(
                residualMessages.isEmpty
                    ? nil
                    : residualMessages.joined(separator: " ")
            )
            importedCopyCleanupJournalNotice = awaitingProtectionMessages
                .isEmpty
                ? nil
                : awaitingProtectionMessages.joined(separator: " ")
            refreshExternalOpenCleanupAvailability()
            guard residualMessages.isEmpty,
                  awaitingProtectionMessages.isEmpty else {
                return false
            }
            return true
        } catch {
            importedCopyCleanupJournalRetryRequired = true
            importedCopyCleanupJournalNotice = nil
            refreshExternalOpenCleanupAvailability()
            setImportedCopyCleanupJournalError(
                "Interrupted imported File cleanup reconciliation failed. \(error.localizedDescription) Retry Cleanup."
            )
            return false
        }
    }

    private func setImportedCopyCleanupJournalError(_ message: String?) {
        if externalOpenError == importedCopyCleanupJournalErrorMessage {
            externalOpenError = nil
        }
        importedCopyCleanupJournalErrorMessage = message
        if let message {
            externalOpenError = message
        }
    }

    private func recordExternalOpenRecoveryProtectionFailure(
        documentID: DocumentID,
        message: String?
    ) {
        guard let message else {
            externalOpenRecoveryProtectionFailure = nil
            externalOpenError = nil
            return
        }
        externalOpenRecoveryProtectionFailure =
            ExternalOpenRecoveryProtectionFailure(
                documentID: documentID,
                message: message
            )
        externalOpenError = message
    }

    private func clearExternalOpenRecoveryProtectionFailure(
        documentID: DocumentID
    ) {
        guard let failure = externalOpenRecoveryProtectionFailure,
              failure.documentID == documentID else {
            return
        }
        if externalOpenError == failure.message {
            externalOpenError = nil
        }
        externalOpenRecoveryProtectionFailure = nil
    }

    private func removePendingImportedCopyCleanupTokens(
        _ tokens: Set<ImportedCopyCleanupToken>
    ) {
        guard !tokens.isEmpty else {
            return
        }
        pendingExternalOpenCleanups = pendingExternalOpenCleanups.compactMap {
            cleanup in
            let remainingTokens = cleanup.tokens.filter { token in
                !tokens.contains(token)
            }
            guard !remainingTokens.isEmpty else {
                return nil
            }
            return PendingImportedCopyCleanup(
                documentID: cleanup.documentID,
                tokens: remainingTokens
            )
        }
    }

    private func importedCopyCleanupIsProtected(
        documentID: DocumentID
    ) async throws -> Bool {
        if let document = state.tabs.first(where: { tab in
            tab.document.id == documentID
        })?.document {
            switch document.recoveryState {
            case .clean, .protectedUnsaved:
                return true
            case .checkpointPending, .recoveryUnavailable:
                break
            }
        }
        return try await recoveryStore.load(documentID: documentID) != nil
    }

    private func orphanedImportedCopyCandidateChange(
        _ residual: ImportedCopyCleanupResidual
    ) async throws -> Bool {
        guard residual.failure == .itemChanged else {
            return false
        }
        let isProtected = try await importedCopyCleanupIsProtected(
            documentID: residual.item.documentID
        )
        return !isProtected
    }

    private var deferredImportedCopyCleanupDocumentID: DocumentID? {
        pendingExternalOpenCleanups.first(where: { cleanup in
            cleanup.documentID != nil
                && !importedCopyCleanupIsRunnable(cleanup)
        })?.documentID
    }

    private func importedCopyCleanupIsRunnable(
        _ cleanup: PendingImportedCopyCleanup
    ) -> Bool {
        guard let documentID = cleanup.documentID,
              let document = state.tabs.first(where: { tab in
                  tab.document.id == documentID
              })?.document else {
            return true
        }
        switch document.recoveryState {
        case .clean, .protectedUnsaved:
            return true
        case .checkpointPending, .recoveryUnavailable:
            return false
        }
    }

    private func refreshExternalOpenCleanupAvailability() {
        externalOpenCleanupRequired = importedCopyCleanupJournalRetryRequired
            || pendingExternalOpenCleanups.contains(
                where: importedCopyCleanupIsRunnable
            )
    }

    func clearFileSaveFeedback() {
        guard !fileSaveCleanupRequired else {
            return
        }
        fileSaveError = nil
        fileSaveNotice = nil
    }

    func reportFileSaveTransitionError(_ error: Error) {
        fileSaveError = error.localizedDescription
        fileSaveNotice = nil
    }

    @discardableResult
    func openDocument(
        selectedURL: URL,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard presentersShouldBeActive,
              !externalOpenTransitionOwnsWorkspace,
              canBeginExternalOpenAction else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        fileSaveError = nil
        fileSaveNotice = nil
        await enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: selectedURL,
                accessIntent: .inPlace
            ),
        ])
        guard let commitRequestID = externalOpenCommitRequestID else {
            fileSaveError = PhonePadExternalOpenActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        let opened = await processNextExternalOpen(
            after: committedDocument,
            commitRequestID: commitRequestID
        )
        fileSaveError = opened ? nil : externalOpenError
        return opened
    }

    func prepareDocumentSaveAs(
        fileName: String,
        encoding: TextFileEncoding
    ) throws -> PreparedSaveAs {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            throw PhonePadFileSaveActionError.actionAlreadyInProgress
        }
        guard !fileSaveCleanupRequired else {
            throw PhonePadFileSaveActionError.cleanupRequired
        }
        guard !fileSaveInProgress, pendingSaveAsReplacement == nil else {
            throw PhonePadFileSaveActionError.actionAlreadyInProgress
        }
        let preparedSave = try prepareSaveAs(
            state: state,
            fileName: fileName,
            encoding: encoding,
            recoveryEditedAt: Date()
        )
        clearFileSaveFeedback()
        return preparedSave
    }

    func preflightDocumentSaveAs(
        preparation: PreparedSaveAs,
        selectedDirectoryURL: URL
    ) async -> PreparedSaveAsPreflight? {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return nil
        }
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return nil
        }
        guard !fileSaveInProgress, pendingSaveAsReplacement == nil else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return nil
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer { finishFileMutation() }

        do {
            let preflight = try await preflightPreparedSaveAs(
                state: state,
                preparedSave: preparation,
                selectedDirectoryURL: selectedDirectoryURL,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            switch preflight.target {
            case .ready, .currentFile:
                pendingSaveAsReplacement = nil
            case .replacementRequired:
                pendingSaveAsReplacement = preflight
            }
            return preflight
        } catch {
            pendingSaveAsReplacement = nil
            fileSaveError = error.localizedDescription
            return nil
        }
    }

    func cancelSaveAsReplacement() {
        pendingSaveAsReplacement = nil
    }

    func presentFileConflictResolution() {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileConflictAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        guard state.activeTab.document.fileConflict != nil else {
            return
        }
        fileConflictError = nil
        fileConflictResolutionIsPresented = true
    }

    func cancelFileConflictResolution() {
        fileConflictResolutionIsPresented = false
        fileConflictError = nil
        restorePendingTabCloseDecisionAfterFileConflictCancellation()
        requestExternalOpenEditorCommitIfPossible()
    }

    @discardableResult
    func beginSaveAsFromFileConflict() -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileConflictAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard state.activeTab.document.fileConflict != nil else {
            fileConflictError = FileConflictWorkflowError
                .fileConflictRequired(state.activeTab.document.id)
                .localizedDescription
            return false
        }
        fileConflictResolutionIsPresented = false
        fileConflictError = nil
        if let tabID = pendingTabCloseCandidateTabID,
           pendingTabCloseSession?.phase == .fileConflict(tabID) {
            setPendingTabClosePhase(.saveAs(tabID))
        }
        return true
    }

    func reportFileConflictTransitionError(_ error: Error) {
        fileConflictError = error.localizedDescription
    }

    @discardableResult
    func discardEditsAndReloadCurrentFile() async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileConflictAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileConflictError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        let documentID = state.activeTab.document.id
        guard state.activeTab.document.fileConflict != nil else {
            fileConflictError = FileConflictWorkflowError
                .fileConflictRequired(documentID)
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileConflictError = nil
        fileSaveError = nil
        fileSaveNotice = nil
        defer { finishFileMutation() }

        await holdCurrentCheckpointForFileConflictReload()

        do {
            let result = try await reloadCurrentFileAfterDiscardingEdits(
                state: state,
                documentID: documentID,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            state = result.state
            pendingCheckpoint = nil
            failedCheckpoint = nil
            recoveryError = nil
            presenterRefreshPending = true
            fileConflictError = nil
            fileSaveError = nil
            fileSaveNotice = result.recoveryCleanupPending
                ? "Edits were discarded and current File content was reloaded. Protected cleanup remains and PhonePad will retry it on next recovery access."
                : nil
            fileConflictResolutionIsPresented = state.activeTab.document.fileConflict != nil
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: documentID
            )
            return true
        } catch {
            fileConflictError = error.localizedDescription
            fileConflictResolutionIsPresented = true
            return false
        }
    }

    func reconcilePresentedFile(documentID: DocumentID) async {
        guard presentersShouldBeActive else {
            presenterRefreshPending = true
            return
        }
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              !fileSaveCleanupRequired,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            presenterRefreshPending = true
            return
        }
        let lifecycleGeneration = presenterLifecycleGeneration
        guard let document = state.tabs.first(where: {
            $0.document.id == documentID
        })?.document, let binding = document.fileBinding else {
            await fileAccessConnector.stopPresenting(documentID: documentID)
            return
        }
        let hadConflict = document.fileConflict != nil

        do {
            let observation = try await fileAccessConnector.reconcilePresentedFile(
                documentID: documentID,
                binding: binding
            )
            guard presentersShouldBeActive,
                  presenterLifecycleGeneration == lifecycleGeneration else {
                return
            }
            guard !fileSaveInProgress,
                  !tabTransitionInProgress,
                  activeRecoveryAction == nil,
                  !fileSaveCleanupRequired,
                  pendingTabCloseSession == nil,
                  !externalOpenTransitionOwnsWorkspace else {
                presenterRefreshPending = true
                return
            }
            guard state.tabs.first(where: {
                $0.document.id == documentID
            })?.document.fileBinding == binding else {
                return
            }
            state = try reconcileBoundDocument(
                state: state,
                documentID: documentID,
                observation: observation
            )
            if state.activeTab.document.id == documentID {
                fileConflictError = nil
                if !hadConflict,
                   state.activeTab.document.fileConflict != nil {
                    fileConflictResolutionIsPresented = true
                }
            }
        } catch {
            if state.activeTab.document.id == documentID {
                fileConflictError = error.localizedDescription
            }
        }
    }

    func sceneBecameInactive() async {
        presenterLifecycleGeneration += 1
        let generation = presenterLifecycleGeneration
        presentersShouldBeActive = false
        if !externalOpenInProgress {
            externalOpenCommitRequestID = nil
        }
        if !fileSaveCleanupRequired, pendingTabCloseSession == nil {
            presenterRefreshPending = false
        }
        await fileAccessConnector.pausePresenters()
        guard presenterLifecycleGeneration == generation,
              !presentersShouldBeActive else {
            return
        }
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenInProgress else {
            return
        }
        _ = await retryCurrentCheckpointIfNeeded()
    }

    func sceneBecameActive() async {
        presenterLifecycleGeneration += 1
        let generation = presenterLifecycleGeneration
        presentersShouldBeActive = true
        didReconcileImportedCopyCleanupJournalOnActivation = false
        await reconcileImportedCopyCleanupJournalForActiveSceneIfPossible()
        requestExternalOpenEditorCommitIfPossible()
        await resumePresentersIfActive(generation: generation)
    }

    private func reconcileImportedCopyCleanupJournalForActiveSceneIfPossible()
        async {
        guard presentersShouldBeActive,
              !didReconcileImportedCopyCleanupJournalOnActivation,
              !externalOpenInProgress,
              !fileSaveInProgress,
              !externalOpenCleanupPreflightInProgress,
              !externalOpenQueueRequiresCleanupPreflight,
              liveExternalOpenCleanupTokens.isEmpty else {
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

    func retryActiveFileReconciliation() async {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            fileConflictError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        fileConflictError = nil
        await sceneBecameActive()
    }

    private func resumePresentersIfActive(generation: UInt64) async {
        guard presentersShouldBeActive,
              presenterLifecycleGeneration == generation else {
            return
        }
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              !fileSaveCleanupRequired,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            presenterRefreshPending = true
            return
        }
        presenterRefreshPending = false
        let registrations = state.tabs.compactMap { tab -> PresentedFileRegistration? in
            guard let binding = tab.document.fileBinding else {
                return nil
            }
            return PresentedFileRegistration(
                documentID: tab.document.id,
                binding: binding
            )
        }
        let outcomes = await fileAccessConnector.resumePresenters(
            bindings: registrations
        )
        guard presentersShouldBeActive,
              presenterLifecycleGeneration == generation else {
            return
        }
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              !fileSaveCleanupRequired,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            presenterRefreshPending = true
            return
        }
        var detectedActiveConflict = false
        for registration in registrations {
            guard !fileSaveInProgress,
                  !tabTransitionInProgress,
                  activeRecoveryAction == nil,
                  !fileSaveCleanupRequired,
                  pendingTabCloseSession == nil,
                  !externalOpenTransitionOwnsWorkspace,
                  state.tabs.first(where: {
                      $0.document.id == registration.documentID
                  })?.document.fileBinding == registration.binding,
                  let outcome = outcomes[registration.documentID] else {
                continue
            }
            switch outcome {
            case let .observed(observation):
                do {
                    let hadConflict = state.tabs.first(where: {
                        $0.document.id == registration.documentID
                    })?.document.fileConflict != nil
                    state = try reconcileBoundDocument(
                        state: state,
                        documentID: registration.documentID,
                        observation: observation
                    )
                    if state.activeTab.document.id == registration.documentID {
                        fileConflictError = nil
                        if !hadConflict,
                           state.activeTab.document.fileConflict != nil {
                            detectedActiveConflict = true
                        }
                    }
                } catch {
                    if state.activeTab.document.id == registration.documentID {
                        fileConflictError = error.localizedDescription
                    }
                }
            case let .failed(error):
                if state.activeTab.document.id == registration.documentID {
                    fileConflictError = error.localizedDescription
                }
            }
        }
        if detectedActiveConflict {
            fileConflictResolutionIsPresented = true
        }
    }

    @discardableResult
    func completePreflightedSaveAs(
        _ preflight: PreparedSaveAsPreflight
    ) async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress, pendingSaveAsReplacement == nil else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer {
            finishFileMutation()
            pendingSaveAsReplacement = nil
        }

        guard await currentDocumentIsReadyForFileTransition() else {
            return false
        }

        do {
            let protectedState = try await protectPreparedSaveAs(
                state: state,
                preflight: preflight,
                recoveryStore: recoveryStore
            )
            state = protectedState
            recoveryError = nil

            let result: SaveAsResult
            switch preflight.target {
            case .ready:
                result = try await saveReadyProtectedSaveAs(
                    state: protectedState,
                    preflight: preflight,
                    fileAccessConnector: fileAccessConnector,
                    recoveryStore: recoveryStore
                )
            case .currentFile:
                result = try await saveCurrentFileProtectedSaveAs(
                    state: protectedState,
                    preflight: preflight,
                    fileAccessConnector: fileAccessConnector,
                    recoveryStore: recoveryStore
                )
            case .replacementRequired:
                throw SaveAsWorkflowError.targetRequiresReplacement
            }
            applyCompletedSaveAs(result)
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: preflight.preparedSave.documentID
            )
            return true
        } catch let error as FileAccessConnectorError {
            if case .currentFile = preflight.target,
               let conflict = error.underlyingFileConflict {
                applyDetectedFileConflict(
                    documentID: preflight.preparedSave.documentID,
                    conflict: conflict
                )
            } else {
                applySaveAsFailure(error)
            }
            return false
        } catch {
            applySaveAsFailure(error)
            return false
        }
    }

    @discardableResult
    func confirmReplacementAndCompleteSaveAs() async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard let replacement = pendingSaveAsReplacement else {
            fileSaveError = SaveAsWorkflowError
                .targetDoesNotRequireReplacement
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer {
            finishFileMutation()
            pendingSaveAsReplacement = nil
        }

        guard await currentDocumentIsReadyForFileTransition() else {
            return false
        }

        do {
            let protectedState = try await protectPreparedSaveAs(
                state: state,
                preflight: replacement,
                recoveryStore: recoveryStore
            )
            state = protectedState
            recoveryError = nil
            let result = try await saveConfirmedReplacementProtectedSaveAs(
                state: protectedState,
                preflight: replacement,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            applyCompletedSaveAs(result)
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: replacement.preparedSave.documentID
            )
            return true
        } catch {
            applySaveAsFailure(error)
            return false
        }
    }

    private func applyCompletedSaveAs(_ result: SaveAsResult) {
        state = result.state
        presenterRefreshPending = true
        pendingFileSaveCleanup = nil
        fileSaveCleanupRequired = false
        fileSaveError = nil
        fileSaveNotice = fileSaveNoticeText(result.notice)
        fileConflictResolutionIsPresented = false
        fileConflictError = nil
    }

    private func applySaveAsFailure(_ error: Error) {
        if let workflowError = error as? SaveAsWorkflowError,
           case let .outputVerifiedButRecoveryCleanupFailed(result, _) = workflowError {
            pendingFileSaveCleanup = .saveAs(result)
            fileSaveCleanupRequired = true
            if result.state.activeTab.document.id
                == pendingTabCloseDocumentID,
               let tabID = pendingTabCloseCandidateTabID {
                setPendingTabClosePhase(.cleanup(tabID))
                pendingTabClosePrompt = nil
            }
        }
        fileSaveError = error.localizedDescription
    }

    @discardableResult
    func saveActiveDocument() async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsBoundSave,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveCleanupRequired else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard state.activeTab.document.fileBinding != nil else {
            fileSaveError = PhonePadFileSaveActionError
                .activeDocumentIsNotBound
                .localizedDescription
            return false
        }
        guard state.activeTab.document.fileConflict == nil else {
            fileSaveError = nil
            fileSaveNotice = nil
            fileConflictError = nil
            fileConflictResolutionIsPresented = true
            return false
        }
        guard state.activeTab.document.isUnsaved else {
            clearFileSaveFeedback()
            return true
        }

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer { finishFileMutation() }

        do {
            let preparedSave = try prepareBoundFileSave(
                state: state,
                recoveryEditedAt: Date()
            )
            guard await currentDocumentIsReadyForFileTransition() else {
                return false
            }
            let protectedState = try await protectPreparedBoundFileSave(
                state: state,
                preparedSave: preparedSave,
                recoveryStore: recoveryStore
            )
            state = protectedState
            recoveryError = nil

            let result = try await saveProtectedBoundDocument(
                state: protectedState,
                preparedSave: preparedSave,
                fileAccessConnector: fileAccessConnector,
                recoveryStore: recoveryStore
            )
            state = result.state
            pendingFileSaveCleanup = nil
            fileSaveCleanupRequired = false
            fileSaveError = nil
            fileSaveNotice = fileSaveNoticeText(result.notice)
            return true
        } catch let error as BoundFileSaveWorkflowError {
            if case let .outputVerifiedButRecoveryCleanupFailed(
                result,
                _
            ) = error {
                pendingFileSaveCleanup = .standard(result)
                fileSaveCleanupRequired = true
                if result.state.activeTab.document.id
                    == pendingTabCloseDocumentID,
                   let tabID = pendingTabCloseCandidateTabID {
                    setPendingTabClosePhase(.cleanup(tabID))
                    pendingTabClosePrompt = nil
                }
            }
            fileSaveError = error.localizedDescription
            return false
        } catch let error as FileAccessConnectorError {
            if let conflict = error.underlyingFileConflict {
                applyDetectedFileConflict(
                    documentID: state.activeTab.document.id,
                    conflict: conflict
                )
                return false
            }
            fileSaveError = error.localizedDescription
            return false
        } catch {
            fileSaveError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func retryFileSaveCleanup() async -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileSaveCleanup,
              !externalOpenTransitionOwnsWorkspace else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard let pendingFileSaveCleanup else {
            fileSaveError = PhonePadFileSaveActionError
                .cleanupNotRequired
                .localizedDescription
            return false
        }

        fileSaveInProgress = true
        fileSaveError = nil
        defer { finishFileMutation() }

        do {
            let cleanupDocumentID = pendingFileSaveCleanup.documentID
            let terminalOutcome = try await recoveryStore.completeRecoveryAfterSave(
                documentID: cleanupDocumentID
            )
            switch pendingFileSaveCleanup {
            case let .standard(result):
                let completedResult = applyingRecoveryTerminalOutcome(
                    result: result,
                    terminalOutcome: terminalOutcome
                )
                state = completedResult.state
                presenterRefreshPending = true
                fileSaveNotice = fileSaveNoticeText(completedResult.notice)
            case let .saveAs(result):
                let completedResult = applyingSaveAsRecoveryTerminalOutcome(
                    result: result,
                    terminalOutcome: terminalOutcome
                )
                state = completedResult.state
                presenterRefreshPending = true
                fileSaveNotice = fileSaveNoticeText(completedResult.notice)
            }
            self.pendingFileSaveCleanup = nil
            fileSaveCleanupRequired = false
            fileSaveError = nil
            _ = await resumePendingTabCloseAfterSuccessfulSave(
                documentID: cleanupDocumentID
            )
            return true
        } catch {
            let cleanupFailure = RecoveryCleanupFailure(capturing: error)
            switch pendingFileSaveCleanup {
            case let .standard(result):
                fileSaveError = NewDocumentSaveWorkflowError
                    .outputVerifiedButRecoveryCleanupFailed(
                        result: result,
                        cleanupFailure: cleanupFailure
                    )
                    .localizedDescription
            case let .saveAs(result):
                fileSaveError = SaveAsWorkflowError
                    .outputVerifiedButRecoveryCleanupFailed(
                        result: result,
                        cleanupFailure: cleanupFailure
                    )
                    .localizedDescription
            }
            return false
        }
    }

    func reportRecoveryTransitionError(_ error: Error) {
        recoveryCatalogError = error.localizedDescription
    }

    func refreshRecoveryItems() async {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        await loadRecoveryItems()
    }

    func refreshInitialRecoveryItems() async {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenInProgress,
              pendingExternalOpenDecision == nil,
              !externalOpenCleanupInProgress else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
        await loadRecoveryItems()
    }

    private func loadRecoveryItems() async {
        do {
            let storedItems = try await recoveryStore.recoveryItems()
            let openDocumentIDs = Set(state.tabs.map(\.document.id))
            recoveryItems = storedItems.filter {
                !openDocumentIDs.contains($0.documentID)
            }
            recoveryCatalogError = nil
        } catch {
            recoveryItems = []
            recoveryCatalogError = error.localizedDescription
        }
    }

    @discardableResult
    func recoverRecovery(
        documentID: DocumentID,
        after committedDocument: CommittedEditorDocument
    ) async -> Bool {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !state.tabs.contains(where: { tab in
            tab.document.id == documentID
        }) else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .recoveryDocumentAlreadyOpen(documentID)
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { finishRecoveryAction() }

        do {
            try validateCommittedDocument(committedDocument)
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            guard let summary = recoveryItems.first(where: {
                $0.documentID == documentID
            }) else {
                throw PhonePadRecoveryActionError.recoveryItemMissing
            }
            guard summary.status == .recoverable else {
                throw PhonePadRecoveryActionError.recoveryItemCannotBeRecovered
            }
            guard let envelope = try await recoveryStore.load(documentID: documentID) else {
                throw PhonePadRecoveryActionError.recoveryItemMissing
            }
            let displayEnvelope = try RecoveryEnvelope(
                formatVersion: envelope.formatVersion,
                documentID: envelope.documentID,
                title: summary.title,
                text: envelope.text,
                editedAt: envelope.editedAt,
                fileReference: envelope.fileReference,
                pendingSave: envelope.pendingSave
            )
            state = recoverDocument(
                state: state,
                envelope: displayEnvelope,
                tabID: TabID(rawValue: UUID())
            )
            recoveryItems.removeAll { $0.documentID == documentID }
            recoveryCatalogError = nil
            return true
        } catch {
            recoveryCatalogError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func discardRecovery(documentID: DocumentID) async -> Bool {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard !state.tabs.contains(where: { tab in
            tab.document.id == documentID
        }) else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .recoveryDocumentAlreadyOpen(documentID)
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { finishRecoveryAction() }

        do {
            let terminalOutcome = try await recoveryStore.discardRecovery(
                documentID: documentID
            )
            recoveryItems.removeAll { $0.documentID == documentID }
            recoveryCatalogError = nil
            fileSaveError = nil
            switch terminalOutcome {
            case .complete:
                fileSaveNotice = nil
            case .residualCleanupPending:
                fileSaveNotice = "Preserved work was discarded. Protected cleanup remains and PhonePad will retry it on next recovery access."
            }
            return true
        } catch {
            recoveryCatalogError = error.localizedDescription
            return false
        }
    }

    private func beginTabCloseRequest() -> Bool {
        guard prepareTabTransition() else {
            tabCloseError = tabTransitionError
            return false
        }
        activeDocumentTransitionInProgress = true
        tabTransitionInProgress = true
        tabCloseError = nil
        return true
    }

    private func beginPendingTabCloseSession(
        requirements: [TabCloseRequirement],
        retainedTabID: TabID?,
        committedDocument: CommittedEditorDocument
    ) async throws -> Bool {
        guard !requirements.isEmpty else {
            tabCloseError = nil
            return true
        }

        let originalActiveTabID = state.activeTabID
        do {
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
        } catch {
            let refreshedRequirements = try requirements.map { requirement in
                try prepareTabClose(
                    state: state,
                    tabID: tabCloseRequirementTab(requirement).id
                )
            }
            guard let activeRequirement = refreshedRequirements.first(where: {
                tabCloseRequirementTab($0).id == originalActiveTabID
            }), case let .unsaved(preparedClose) = activeRequirement else {
                throw error
            }
            pendingTabCloseSession = PendingTabCloseSession(
                requirements: refreshedRequirements,
                originalActiveTabID: originalActiveTabID,
                retainedTabID: retainedTabID,
                phase: .processing
            )
            publishPendingTabClosePrompt(preparedClose: preparedClose)
            tabCloseError = nil
            return true
        }

        let refreshedRequirements = try requirements.map { requirement in
            try prepareTabClose(
                state: state,
                tabID: tabCloseRequirementTab(requirement).id
            )
        }
        pendingTabCloseSession = PendingTabCloseSession(
            requirements: refreshedRequirements,
            originalActiveTabID: originalActiveTabID,
            retainedTabID: retainedTabID,
            phase: .processing
        )
        try await advancePendingTabCloseSession()
        tabCloseError = nil
        return true
    }

    private func beginPendingTabCloseDecisionResolution() -> Bool {
        guard pendingTabCloseResolutionCanBegin() else {
            return false
        }
        guard !tabCloseCleanupRequired else {
            tabCloseError = PhonePadTabCloseActionError
                .cleanupRequired
                .localizedDescription
            return false
        }
        guard pendingTabClosePrompt != nil else {
            tabCloseError = PhonePadTabCloseActionError
                .noPendingDecision
                .localizedDescription
            return false
        }
        startPendingTabCloseResolution()
        return true
    }

    private func beginPendingTabCloseCleanupResolution() -> Bool {
        guard pendingTabCloseResolutionCanBegin() else {
            return false
        }
        guard tabCloseCleanupRequired,
              pendingTabCloseCleanup != nil else {
            tabCloseError = PhonePadTabCloseActionError
                .cleanupNotRequired
                .localizedDescription
            return false
        }
        startPendingTabCloseResolution()
        return true
    }

    private func pendingTabCloseResolutionCanBegin() -> Bool {
        guard pendingTabCloseSession != nil,
              !tabTransitionInProgress,
              !fileSaveInProgress,
              activeRecoveryAction == nil else {
            tabCloseError = PhonePadTabCloseActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        return true
    }

    private func startPendingTabCloseResolution() {
        activeDocumentTransitionInProgress = true
        tabTransitionInProgress = true
        tabCloseError = nil
    }

    private func advancePendingTabCloseSession() async throws {
        while let requirement = pendingTabCloseSession?.requirements.first {
            switch requirement {
            case let .clean(preparedClose):
                let closedState = try closePreparedCleanTab(
                    state: state,
                    preparedClose: preparedClose,
                    replacementDocumentID: DocumentID(rawValue: UUID()),
                    replacementTabID: TabID(rawValue: UUID())
                )
                await fileAccessConnector.stopPresenting(
                    documentID: preparedClose.tab.document.id
                )
                state = closedState
                pendingTabCloseSession?.requirements.removeFirst()
                pendingTabCloseSession?.phase = .processing
            case let .unsaved(preparedClose):
                publishPendingTabClosePrompt(preparedClose: preparedClose)
                return
            }
        }

        try restoreStableTabSelectionForPendingClose()
        pendingTabCloseSession = nil
        pendingTabClosePrompt = nil
        pendingTabCloseCleanup = nil
        tabCloseCleanupRequired = false
        tabCloseError = nil
        presentActiveFileConflictIfNeeded()
    }

    private func applyDiscardedTabClose(
        _ result: DiscardedTabCloseResult,
        requirementIndex: Int
    ) async throws {
        await fileAccessConnector.stopPresenting(
            documentID: result.closedDocumentID
        )
        state = result.state
        clearCheckpointState(closedDocumentID: result.closedDocumentID)
        pendingTabCloseSession?.requirements.remove(at: requirementIndex)
        pendingTabCloseSession?.phase = .processing
        pendingTabClosePrompt = nil
        pendingTabCloseCleanup = nil
        tabCloseCleanupRequired = false
        tabCloseError = nil
        switch result.notice {
        case .none:
            fileSaveNotice = nil
        case .residualRecoveryCleanupPending:
            fileSaveNotice = "Protected edits were discarded. Protected cleanup remains and PhonePad will retry it on next recovery access."
        }
        try await advancePendingTabCloseSession()
        _ = await retryExternalOpenCleanupIfNeeded()
    }

    private func resumePendingTabCloseAfterSuccessfulSave(
        documentID: DocumentID
    ) async -> Bool {
        guard let requirementIndex = pendingTabCloseRequirementIndex(
            documentID: documentID
        ) else {
            return true
        }
        let ownsTabTransition = !fileSaveInProgress
        if ownsTabTransition {
            guard !tabTransitionInProgress else {
                tabCloseError = PhonePadTabCloseActionError
                    .actionAlreadyInProgress
                    .localizedDescription
                return false
            }
            activeDocumentTransitionInProgress = true
            tabTransitionInProgress = true
        }
        defer {
            if ownsTabTransition {
                finishTabTransition()
            }
        }

        do {
            guard var session = pendingTabCloseSession,
                  session.requirements.indices.contains(requirementIndex) else {
                throw PhonePadTabCloseActionError.noPendingDecision
            }
            let pendingTabID = tabCloseRequirementTab(
                session.requirements[requirementIndex]
            ).id
            let requirement = try prepareTabClose(
                state: state,
                tabID: pendingTabID
            )
            guard case .clean = requirement else {
                throw PhonePadTabCloseActionError.pendingTabRemainsUnsaved
            }
            session.requirements[requirementIndex] = requirement
            session.phase = .processing
            pendingTabCloseSession = session
            pendingTabClosePrompt = nil
            try await advancePendingTabCloseSession()
            tabCloseError = nil
            return true
        } catch {
            tabCloseError = error.localizedDescription
            return false
        }
    }

    private func publishPendingTabClosePrompt(
        preparedClose: PreparedUnsavedTabClose
    ) {
        let tab = preparedClose.tab
        pendingTabClosePrompt = PendingTabClosePrompt(
            tabID: tab.id,
            documentID: tab.document.id,
            title: tab.document.title
        )
        pendingTabCloseSession?.phase = .decision(tab.id)
    }

    private func setPendingTabClosePhase(_ phase: PendingTabClosePhase) {
        pendingTabCloseSession?.phase = phase
    }

    private func pendingTabCloseRequirementIndex(
        tabID: TabID
    ) -> Int? {
        pendingTabCloseSession?.requirements.firstIndex(where: {
            tabCloseRequirementTab($0).id == tabID
        })
    }

    private func pendingTabCloseRequirementIndex(
        documentID: DocumentID
    ) -> Int? {
        pendingTabCloseSession?.requirements.firstIndex(where: {
            tabCloseRequirementTab($0).document.id == documentID
        })
    }

    private func pendingUnsavedTabClose(
        at requirementIndex: Int
    ) -> PreparedUnsavedTabClose? {
        guard let session = pendingTabCloseSession,
              session.requirements.indices.contains(requirementIndex),
              case let .unsaved(preparedClose) = session.requirements[
                  requirementIndex
              ] else {
            return nil
        }
        return preparedClose
    }

    private func refreshPendingUnsavedTabClose(
        tabID: TabID
    ) throws -> PreparedUnsavedTabClose {
        guard var session = pendingTabCloseSession,
              let requirementIndex = session.requirements.firstIndex(where: {
                  tabCloseRequirementTab($0).id == tabID
              }) else {
            throw PhonePadTabCloseActionError.noPendingDecision
        }
        let requirement = try prepareTabClose(
            state: state,
            tabID: tabID
        )
        guard case let .unsaved(preparedClose) = requirement else {
            throw PhonePadTabCloseActionError.noPendingDecision
        }
        session.requirements[requirementIndex] = requirement
        pendingTabCloseSession = session
        return preparedClose
    }

    private func tabCloseRequirementTab(
        _ requirement: TabCloseRequirement
    ) -> PhonePadTab {
        switch requirement {
        case let .clean(preparedClose):
            preparedClose.tab
        case let .unsaved(preparedClose):
            preparedClose.tab
        }
    }

    private func restoreStableTabSelectionForPendingClose() throws {
        guard let session = pendingTabCloseSession else {
            return
        }
        let preferredTabID = session.retainedTabID
            ?? session.originalActiveTabID
        guard state.tabs.contains(where: { $0.id == preferredTabID }) else {
            return
        }
        state = try PhonePadCore.selectTab(
            state: state,
            tabID: preferredTabID
        )
    }

    private func cancelPendingTabCloseSessionAfterFailure() {
        do {
            try restoreStableTabSelectionForPendingClose()
        } catch {
            tabCloseError = error.localizedDescription
        }
        pendingTabCloseSession = nil
        pendingTabClosePrompt = nil
        pendingTabCloseCleanup = nil
        tabCloseCleanupRequired = false
    }

    private func clearCheckpointState(closedDocumentID: DocumentID) {
        if pendingCheckpoint?.checkpointBaseState.activeTab.document.id
            == closedDocumentID {
            pendingCheckpoint = nil
        }
        if failedCheckpoint?.checkpointBaseState.activeTab.document.id
            == closedDocumentID {
            failedCheckpoint = nil
        }
        if pendingCheckpoint == nil, failedCheckpoint == nil {
            recoveryError = nil
        }
        refreshExternalOpenCleanupAvailability()
    }

    private func prepareTabTransition() -> Bool {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              !fileSaveCleanupRequired,
              pendingSaveAsReplacement == nil,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            tabTransitionError = PhonePadTabTransitionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        tabTransitionError = nil
        return true
    }

    private func beginActiveDocumentTransition() -> Bool {
        guard prepareTabTransition() else {
            return false
        }
        activeDocumentTransitionInProgress = true
        tabTransitionInProgress = true
        return true
    }

    private func beginTabReorder() -> Bool {
        guard prepareTabTransition() else {
            return false
        }
        tabTransitionInProgress = true
        return true
    }

    private func validateCommittedDocument(
        _ committedDocument: CommittedEditorDocument
    ) throws {
        guard state.activeTab.document.id == committedDocument.documentID else {
            throw PhonePadTabTransitionError.committedDocumentIsNotActive
        }
        let canonicalText = try validateEditableDocumentText(
            text: committedDocument.text
        )
        guard state.activeTab.document.text == canonicalText else {
            throw PhonePadTabTransitionError.committedTextWasRejected
        }
    }

    private func protectCommittedDocumentForActiveTransition(
        _ committedDocument: CommittedEditorDocument
    ) async throws {
        try validateCommittedDocument(committedDocument)
        switch state.activeTab.document.recoveryState {
        case .clean, .protectedUnsaved:
            return
        case .checkpointPending, .recoveryUnavailable:
            guard await retryCurrentCheckpointIfNeeded(),
                  pendingCheckpoint == nil,
                  failedCheckpoint == nil,
                  state.activeTab.document.recoveryState == .protectedUnsaved else {
                throw PhonePadTabTransitionError
                    .checkpointMustFinishBeforeTransition
            }
            try validateCommittedDocument(committedDocument)
        }
    }

    func editActiveDocument(text: String) {
        _ = editDocument(
            documentID: state.activeTab.document.id,
            text: text
        )
    }

    @discardableResult
    func editDocument(documentID: DocumentID, text: String) -> Bool {
        guard state.activeTab.document.id == documentID else {
            return false
        }
        guard !fileSaveCleanupRequired else {
            if fileSaveError == nil {
                fileSaveError = PhonePadFileSaveActionError
                    .cleanupRequired
                    .localizedDescription
            }
            return false
        }
        guard !fileSaveInProgress else {
            fileSaveError = PhonePadFileSaveActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard pendingSaveAsReplacement == nil,
              activeRecoveryAction == nil,
              !activeDocumentTransitionInProgress,
              pendingTabCloseSession == nil,
              !externalOpenInProgress,
              pendingExternalOpenDecision == nil else {
            return false
        }
        guard failedCheckpoint == nil else {
            return false
        }
        guard text != state.activeTab.document.text else {
            return true
        }

        let previousState = state
        let transition: RecoveryEditTransition
        do {
            transition = try beginActiveDocumentEdit(
                state: previousState,
                newText: text,
                editedAt: Date()
            )
        } catch {
            recoveryError = error.localizedDescription
            return false
        }

        state = transition.state
        recoveryError = nil

        editGeneration += 1
        let now = checkpointClock.now
        let existingCheckpoint = pendingCheckpoint
        pendingCheckpoint = PendingRecoveryCheckpoint(
            generation: editGeneration,
            checkpointBaseState: existingCheckpoint?.checkpointBaseState
                ?? previousState,
            recoveryBaselineState: existingCheckpoint?.recoveryBaselineState
                ?? previousState,
            text: transition.envelope.text,
            editedAt: transition.envelope.editedAt,
            firstPendingAt: existingCheckpoint?.firstPendingAt ?? now,
            lastEditAt: now,
            requiresImmediateCheckpoint: existingCheckpoint?.requiresImmediateCheckpoint
                ?? (previousState.activeTab.document.recoveryState == .clean)
        )
        startCheckpointTaskIfNeeded()
        return true
    }

    @discardableResult
    func retryActiveDocumentRecovery() async -> Bool {
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard failedCheckpoint != nil,
              state.activeTab.document.recoveryState
                == .recoveryUnavailable else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .recoveryIsAvailable
                .localizedDescription
            return false
        }
        activeRecoveryAction = state.activeTab.document.id
        defer { finishRecoveryAction() }
        return await retryCurrentCheckpointIfNeeded()
    }

    @discardableResult
    func discardRecoveryUnavailableEdits() async -> Bool {
        guard !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }
        guard let checkpoint = failedCheckpoint,
              state.activeTab.document.recoveryState
                == .recoveryUnavailable else {
            recoveryError = PhonePadRecoveryUnavailableActionError
                .recoveryIsAvailable
                .localizedDescription
            return false
        }
        activeRecoveryAction = state.activeTab.document.id
        defer { finishRecoveryAction() }
        await cancelAndAwaitCheckpointTask()
        let documentID = state.activeTab.document.id
        do {
            if let baselineState = checkpoint.recoveryBaselineState {
                state = try restoreDocumentAfterRecoveryFailure(
                    state: state,
                    baselineState: baselineState,
                    documentID: documentID,
                    expectedUnprotectedText: checkpoint.text
                )
            } else {
                let requirement = try prepareTabClose(
                    state: state,
                    tabID: state.activeTabID
                )
                guard case let .unsaved(preparedClose) = requirement else {
                    throw PhonePadRecoveryUnavailableActionError
                        .recoveryIsAvailable
                }
                let result = try await discardAndClosePreparedUnsavedTab(
                    state: state,
                    preparedClose: preparedClose,
                    replacementDocumentID: DocumentID(rawValue: UUID()),
                    replacementTabID: TabID(rawValue: UUID()),
                    recoveryStore: recoveryStore
                )
                state = result.state
                externalOpenEphemeralClaims.removeValue(forKey: documentID)
            }
            pendingCheckpoint = nil
            failedCheckpoint = nil
            recoveryError = nil
            clearExternalOpenRecoveryProtectionFailure(
                documentID: documentID
            )
            _ = await retryExternalOpenCleanupIfNeeded()
            presentActiveFileConflictIfNeeded()
            return true
        } catch {
            recoveryError = error.localizedDescription
            return false
        }
    }

    private func startCheckpointTaskIfNeeded() {
        guard checkpointTask == nil else {
            return
        }
        checkpointTask = Task { @MainActor [weak self] in
            await self?.runCheckpointLoop()
        }
    }

    private func retryCurrentCheckpointIfNeeded() async -> Bool {
        await cancelAndAwaitCheckpointTask()
        guard let checkpoint = failedCheckpoint ?? pendingCheckpoint else {
            return state.activeTab.document.recoveryState != .checkpointPending
                && state.activeTab.document.recoveryState
                    != .recoveryUnavailable
        }
        let outcome = await persist(checkpoint: checkpoint)
        return outcome == .persisted
    }

    private func holdCurrentCheckpointForFileConflictReload() async {
        await cancelAndAwaitCheckpointTask()
        guard let checkpoint = failedCheckpoint ?? pendingCheckpoint else {
            return
        }
        failedCheckpoint = checkpoint
        pendingCheckpoint = nil
        if recoveryError == nil {
            recoveryError = PhonePadRecoveryActionError
                .checkpointHeldForFileConflictReload
                .localizedDescription
        }
    }

    private func cancelAndAwaitCheckpointTask() async {
        let activeCheckpointTask = checkpointTask
        activeCheckpointTask?.cancel()
        if let activeCheckpointTask {
            await activeCheckpointTask.value
        }
        checkpointTask = nil
    }

    private func currentDocumentIsReadyForFileTransition() async -> Bool {
        guard await retryCurrentCheckpointIfNeeded(),
              pendingCheckpoint == nil,
              failedCheckpoint == nil,
              state.activeTab.document.recoveryState != .checkpointPending,
              state.activeTab.document.recoveryState != .recoveryUnavailable else {
            fileSaveError = PhonePadFileSaveActionError
                .checkpointMustFinishBeforeFileAction
                .localizedDescription
            return false
        }
        return true
    }

    private func startPresentationHintTask() {
        let hints = fileAccessConnector.presentationChangeHints
        presentationHintTask = Task { @MainActor [weak self] in
            for await documentID in hints {
                guard !Task.isCancelled else {
                    return
                }
                await self?.reconcilePresentedFile(documentID: documentID)
            }
        }
    }

    private func finishFileMutation() {
        fileSaveInProgress = false
        guard presentersShouldBeActive,
              !didReconcileImportedCopyCleanupJournalOnActivation else {
            resumePendingPresentersAfterExclusiveAction()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await resumePendingActivationWorkAfterExclusiveAction()
        }
    }

    private func resumePendingActivationWorkAfterExclusiveAction() async {
        await reconcileImportedCopyCleanupJournalForActiveSceneIfPossible()
        resumePendingPresentersAfterExclusiveAction()
    }

    private func finishTabTransition() {
        activeDocumentTransitionInProgress = false
        tabTransitionInProgress = false
        resumePendingPresentersAfterExclusiveAction()
    }

    private func finishRecoveryAction() {
        activeRecoveryAction = nil
        resumePendingPresentersAfterExclusiveAction()
    }

    private func resumePendingPresentersAfterExclusiveAction() {
        requestExternalOpenEditorCommitIfPossible()
        guard presentersShouldBeActive,
              !fileSaveCleanupRequired,
              !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
              !externalOpenTransitionOwnsWorkspace,
              presenterRefreshPending else {
            return
        }
        let generation = presenterLifecycleGeneration
        Task { @MainActor [weak self] in
            await self?.resumePresentersIfActive(generation: generation)
        }
    }

    private func presentActiveFileConflictIfNeeded() {
        guard state.activeTab.document.fileConflict != nil else {
            return
        }
        fileConflictResolutionIsPresented = true
    }

    private func applyDetectedFileConflict(
        documentID: DocumentID,
        conflict: FileConflict
    ) {
        do {
            state = try markDocumentFileConflict(
                state: state,
                documentID: documentID,
                conflict: conflict
            )
            fileSaveError = nil
            fileSaveNotice = nil
            fileConflictError = nil
            if state.activeTab.document.id == documentID {
                fileConflictResolutionIsPresented = true
            }
            if documentID == pendingTabCloseDocumentID,
               let tabID = pendingTabCloseCandidateTabID {
                setPendingTabClosePhase(.fileConflict(tabID))
                pendingTabClosePrompt = nil
            }
        } catch {
            fileSaveError = error.localizedDescription
        }
    }

    private func runCheckpointLoop() async {
        while !Task.isCancelled {
            guard let checkpoint = await nextReadyCheckpoint() else {
                break
            }
            guard pendingCheckpoint?.generation == checkpoint.generation else {
                continue
            }
            let outcome = await persist(checkpoint: checkpoint)
            if outcome == .failed {
                break
            }
        }

        checkpointTask = nil
        if !Task.isCancelled,
           failedCheckpoint == nil,
           pendingCheckpoint != nil {
            startCheckpointTaskIfNeeded()
        }
    }

    private func nextReadyCheckpoint() async -> PendingRecoveryCheckpoint? {
        while !Task.isCancelled, let checkpoint = pendingCheckpoint {
            if checkpoint.requiresImmediateCheckpoint {
                return checkpoint
            }

            let quietDeadline = checkpoint.lastEditAt.advanced(by: checkpointQuietPeriod)
            let maximumDeadline = checkpoint.firstPendingAt.advanced(by: checkpointMaximumInterval)
            let deadline = min(quietDeadline, maximumDeadline)
            guard checkpointClock.now < deadline else {
                return checkpoint
            }

            do {
                try await checkpointClock.sleep(until: deadline)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func persist(
        checkpoint: PendingRecoveryCheckpoint
    ) async -> RecoveryCheckpointPersistenceOutcome {
        do {
            _ = try await editActiveDocumentAndCheckpoint(
                state: checkpoint.checkpointBaseState,
                newText: checkpoint.text,
                editedAt: checkpoint.editedAt,
                recoveryStore: recoveryStore
            )
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return .superseded
            }
            let documentID = checkpoint.checkpointBaseState.activeTab.document.id
            state = try markDocumentRecoveryProtected(
                state: state,
                documentID: documentID,
                expectedText: checkpoint.text
            )
            if pendingCheckpoint?.generation == checkpoint.generation {
                pendingCheckpoint = nil
            }
            if failedCheckpoint?.generation == checkpoint.generation {
                failedCheckpoint = nil
            }
            recoveryError = nil
            _ = await retryExternalOpenCleanupIfNeeded()
            clearExternalOpenRecoveryProtectionFailure(
                documentID: documentID
            )
            return .persisted
        } catch {
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return .superseded
            }
            if pendingCheckpoint?.generation == checkpoint.generation {
                pendingCheckpoint = nil
            }
            do {
                state = try markDocumentRecoveryUnavailable(
                    state: state,
                    documentID: checkpoint.checkpointBaseState
                        .activeTab.document.id,
                    expectedText: checkpoint.text
                )
                failedCheckpoint = checkpoint
                recoveryError = error.localizedDescription
            } catch let stateError {
                failedCheckpoint = checkpoint
                recoveryError = "Recovery checkpoint failed: \(error.localizedDescription) PhonePad could not enter Recovery Unavailable: \(stateError.localizedDescription)"
            }
            return .failed
        }
    }

    private func fileSaveNoticeText(_ notice: NewDocumentSaveNotice?) -> String? {
        switch notice {
        case .none:
            return nil
        case .durableFileAccessUnavailable:
            return "File was saved and verified, but PhonePad could not retain durable access. The Document is clean and detached; its next edit will require Save As."
        case .recoveryCleanupPending:
            return "File was saved and verified. The Document is clean. Protected recovery cleanup remains and PhonePad will retry it on next recovery access."
        case .durableFileAccessUnavailableAndRecoveryCleanupPending:
            return "File was saved and verified without durable access. The Document is clean and detached. Protected recovery cleanup remains and PhonePad will retry it on next recovery access."
        }
    }

    private func fileSaveNoticeText(_ notice: SaveAsNotice?) -> String? {
        guard let notice else {
            return nil
        }
        var messages: [String] = []
        if notice.durableFileAccessUnavailable {
            messages.append(
                "File was saved and verified, but PhonePad could not retain durable access. The Document is clean and detached; its next edit will require Save As."
            )
        } else {
            messages.append("File was saved and verified. The Document is clean.")
        }
        if let stagingCleanupFailureCode = notice.stagingCleanupFailureCode {
            messages.append(
                "The saved File remains verified, but temporary staging cleanup could not finish (code \(stagingCleanupFailureCode))."
            )
        }
        if notice.recoveryCleanupPending {
            messages.append(
                "Protected recovery cleanup remains and PhonePad will retry it on next recovery access."
            )
        }
        return messages.joined(separator: " ")
    }
}

private extension FileAccessConnectorError {
    var underlyingFileConflict: FileConflict? {
        switch self {
        case let .fileConflict(conflict):
            return conflict
        case let .unsafeStagingCleanupRefused(_, precedingError),
             let .stagingCleanupFailed(_, precedingError),
             let .replacementStagingCleanupFailed(_, precedingError):
            return precedingError.underlyingFileConflict
        default:
            return nil
        }
    }
}

private func importedCopyCleanupFailureMessage(
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

private func externalOpenDetachmentNotice(
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
