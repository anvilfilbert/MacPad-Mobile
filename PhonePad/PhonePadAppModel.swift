import Foundation
import PhonePadCore
import SwiftUI

private struct PendingRecoveryCheckpoint {
    let generation: UInt64
    let previousState: PhonePadState
    let text: String
    let editedAt: Date
    let firstPendingAt: ContinuousClock.Instant
    let lastEditAt: ContinuousClock.Instant
    let requiresImmediateCheckpoint: Bool
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
    case recoveryItemCannotBeRecovered
    case recoveryItemMissing

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another recovery action is still running. Wait for it to finish and retry."
        case .checkpointHeldForFileConflictReload:
            "Current edits remain locked until Reload Current finishes. Retry Reload Current or retry recovery before editing."
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
        startPresentationHintTask()
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
    }

    var editorInteractionDisabled: Bool {
        fileSaveInProgress
            || pendingSaveAsReplacement != nil
            || activeRecoveryAction != nil
            || activeDocumentTransitionInProgress
    }

    var editorMutationDisabled: Bool {
        editorInteractionDisabled
            || fileSaveCleanupRequired
            || pendingTabCloseSession != nil
            || failedCheckpoint != nil
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
                  state.activeTab.document.recoveryState != .checkpointPending else {
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
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil else {
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

        fileSaveInProgress = true
        fileSaveError = nil
        fileSaveNotice = nil
        defer { finishFileMutation() }

        do {
            try validateCommittedDocument(committedDocument)
            try await protectCommittedDocumentForActiveTransition(
                committedDocument
            )
            try validateCommittedDocument(committedDocument)
            let documentID = DocumentID(rawValue: UUID())
            let snapshot = try await fileAccessConnector.openTextFile(
                at: selectedURL,
                documentID: documentID
            )
            let openedState = openObservedBoundDocument(
                state: state,
                documentID: documentID,
                tabID: TabID(rawValue: UUID()),
                text: snapshot.openedFile.text,
                observation: ObservedBoundFile(
                    binding: snapshot.openedFile.binding,
                    providerConflictVersions: snapshot.providerConflictVersions
                )
            )
            if !openedState.tabs.contains(where: {
                $0.document.id == documentID
            }) {
                let retainedDocument = openedState.activeTab.document
                guard let retainedBinding = retainedDocument.fileBinding else {
                    await fileAccessConnector.stopPresenting(
                        documentID: documentID
                    )
                    throw PhonePadStateError.documentIsNotBound(
                        retainedDocument.id
                    )
                }
                do {
                    try await fileAccessConnector.startPresenting(
                        documentID: retainedDocument.id,
                        binding: retainedBinding
                    )
                } catch {
                    await fileAccessConnector.stopPresenting(
                        documentID: documentID
                    )
                    throw error
                }
                presenterRefreshPending = true
                await fileAccessConnector.stopPresenting(documentID: documentID)
            }
            state = openedState
            presentActiveFileConflictIfNeeded()
            fileSaveError = nil
            fileSaveNotice = nil
            return true
        } catch {
            fileSaveError = error.localizedDescription
            return false
        }
    }

    func prepareDocumentSaveAs(
        fileName: String,
        encoding: TextFileEncoding
    ) throws -> PreparedSaveAs {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsSaveAsAction else {
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
              pendingTabCloseAllowsSaveAsAction else {
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
              pendingTabCloseAllowsFileConflictAction else {
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
    }

    @discardableResult
    func beginSaveAsFromFileConflict() -> Bool {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseAllowsFileConflictAction else {
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
              pendingTabCloseAllowsFileConflictAction else {
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
              pendingTabCloseSession == nil else {
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
                  pendingTabCloseSession == nil else {
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
              pendingTabCloseSession == nil else {
            return
        }
        _ = await retryCurrentCheckpointIfNeeded()
    }

    func sceneBecameActive() async {
        presenterLifecycleGeneration += 1
        let generation = presenterLifecycleGeneration
        presentersShouldBeActive = true
        await resumePresentersIfActive(generation: generation)
    }

    func retryActiveFileReconciliation() async {
        guard !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil else {
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
              pendingTabCloseSession == nil else {
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
              pendingTabCloseSession == nil else {
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
              pendingTabCloseAllowsSaveAsAction else {
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
              pendingTabCloseAllowsSaveAsAction else {
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
              pendingTabCloseAllowsBoundSave else {
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
              pendingTabCloseAllowsFileSaveCleanup else {
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
              pendingTabCloseSession == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return
        }
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
              pendingTabCloseSession == nil else {
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
              pendingTabCloseSession == nil else {
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
            guard let activeRequirement = requirements.first(where: {
                tabCloseRequirementTab($0).id == originalActiveTabID
            }), case let .unsaved(preparedClose) = activeRequirement else {
                throw error
            }
            pendingTabCloseSession = PendingTabCloseSession(
                requirements: requirements,
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
        if pendingCheckpoint?.previousState.activeTab.document.id
            == closedDocumentID {
            pendingCheckpoint = nil
        }
        if failedCheckpoint?.previousState.activeTab.document.id
            == closedDocumentID {
            failedCheckpoint = nil
        }
        if pendingCheckpoint == nil, failedCheckpoint == nil {
            recoveryError = nil
        }
    }

    private func prepareTabTransition() -> Bool {
        guard !tabTransitionInProgress,
              !fileSaveInProgress,
              !fileSaveCleanupRequired,
              pendingSaveAsReplacement == nil,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil else {
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
        case .checkpointPending:
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
              pendingTabCloseSession == nil else {
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
            previousState: previousState,
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
              state.activeTab.document.recoveryState != .checkpointPending else {
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
        guard presentersShouldBeActive,
              !fileSaveCleanupRequired,
              !fileSaveInProgress,
              !tabTransitionInProgress,
              activeRecoveryAction == nil,
              pendingTabCloseSession == nil,
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
                state: checkpoint.previousState,
                newText: checkpoint.text,
                editedAt: checkpoint.editedAt,
                recoveryStore: recoveryStore
            )
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return .superseded
            }
            let documentID = checkpoint.previousState.activeTab.document.id
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
            return .persisted
        } catch {
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return .superseded
            }
            if pendingCheckpoint?.generation == checkpoint.generation {
                pendingCheckpoint = nil
            }
            failedCheckpoint = checkpoint
            recoveryError = error.localizedDescription
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
