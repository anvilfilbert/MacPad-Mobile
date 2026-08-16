import Foundation
import PhonePadCore
import SwiftUI

enum PhonePadRecoveryUnavailableActionError: Error, LocalizedError {
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

enum PhonePadEditorDisplayActionError: Error, LocalizedError {
    case actionAlreadyInProgress

    var errorDescription: String? {
        "Display settings cannot change while another File, recovery, or Tab action is running. Wait for it to finish and retry."
    }
}

enum PendingFileSaveCleanup {
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

struct PendingTabCloseSession {
    var requirements: [TabCloseRequirement]
    let originalActiveTabID: TabID
    let retainedTabID: TabID?
    var phase: PendingTabClosePhase
}

enum PendingTabClosePhase: Equatable {
    case processing
    case decision(TabID)
    case saveAs(TabID)
    case fileConflict(TabID)
    case cleanup(TabID)
}

struct PendingTabCloseCleanup {
    let preparedClose: PreparedUnsavedTabClose
    let replacementDocumentID: DocumentID
    let replacementTabID: TabID
}

enum PhonePadRecoveryActionError: Error, LocalizedError {
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
            "This preserved work is corrupt or unsupported. Keep it for a compatible MacPad Mobile version, or choose Discard Recovery."
        case .recoveryItemMissing:
            "Preserved work is no longer available. Refresh Document Recovery and retry."
        }
    }
}

enum PhonePadFileSaveActionError: Error, LocalizedError {
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

enum PhonePadTabTransitionError: Error, LocalizedError {
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

enum PhonePadTabCloseActionError: Error, LocalizedError {
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
    @Published var state: PhonePadState
    @Published var recoveryError: String?
    @Published var recoveryItems: [RecoveryItemSummary]
    @Published var recoveryCatalogError: String?
    @Published var activeRecoveryAction: DocumentID?
    @Published var fileSaveError: String?
    @Published var fileSaveNotice: String?
    @Published var fileSaveInProgress: Bool
    @Published var fileSaveCleanupRequired: Bool
    @Published var pendingSaveAsReplacement: PreparedSaveAsPreflight?
    @Published var fileConflictResolutionIsPresented: Bool
    @Published var fileConflictError: String?
    @Published var tabTransitionError: String?
    @Published var tabTransitionInProgress: Bool
    @Published var pendingTabClosePrompt: PendingTabClosePrompt?
    @Published var tabCloseError: String?
    @Published var tabCloseCleanupRequired: Bool
    private(set) lazy var externalOpenCoordinator =
        PhonePadExternalOpenCoordinator(
            workspace: self,
            recoveryStore: recoveryStore,
            fileAccessConnector: fileAccessConnector
        )

    let recoveryStore: any RecoveryStoring
    let fileAccessConnector: FileAccessConnector
    let recoveryCheckpointCoordinator:
        PhonePadRecoveryCheckpointCoordinator
    var pendingFileSaveCleanup: PendingFileSaveCleanup?
    private var presentationHintTask: Task<Void, Never>?
    var presentersShouldBeActive: Bool
    var presenterLifecycleGeneration: UInt64
    var presenterRefreshPending: Bool
    var activeDocumentTransitionInProgress: Bool
    var pendingTabCloseSession: PendingTabCloseSession?
    var pendingTabCloseCleanup: PendingTabCloseCleanup?
    private var pendingTabCloseBoundSaveDocumentID: DocumentID?
    var externalOpenCommitRequestID: UUID? {
        externalOpenCoordinator.presentation(state: state).commitRequestID
    }

    var externalOpenInProgress: Bool {
        externalOpenCoordinator.presentation(state: state).isInProgress
    }

    var pendingExternalOpenRecoveryPrompt:
        PendingExternalOpenRecoveryPrompt? {
        externalOpenCoordinator.presentation(state: state).recoveryPrompt
    }

    var externalOpenError: String? {
        externalOpenCoordinator.presentation(state: state).errorMessage
    }

    var externalOpenCleanupRequired: Bool {
        externalOpenCoordinator.presentation(state: state).cleanupRequired
    }

    init(
        state: PhonePadState,
        recoveryStore: any RecoveryStoring,
        fileAccessConnector: FileAccessConnector,
        checkpointQuietPeriod: Duration,
        checkpointMaximumInterval: Duration
    ) {
        self.state = state
        self.recoveryStore = recoveryStore
        self.fileAccessConnector = fileAccessConnector
        recoveryCheckpointCoordinator = PhonePadRecoveryCheckpointCoordinator(
            recoveryStore: recoveryStore,
            quietPeriod: checkpointQuietPeriod,
            maximumInterval: checkpointMaximumInterval
        )
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
        pendingFileSaveCleanup = nil
        presentationHintTask = nil
        presentersShouldBeActive = true
        presenterLifecycleGeneration = 0
        presenterRefreshPending = false
        activeDocumentTransitionInProgress = false
        pendingTabCloseSession = nil
        pendingTabCloseCleanup = nil
        pendingTabCloseBoundSaveDocumentID = nil
        startPresentationHintTask()
    }

    var externalOpenNotice: String? {
        externalOpenCoordinator.presentation(state: state).notice
    }

    var externalOpenErrorRequiresDismissal: Bool {
        externalOpenCoordinator.presentation(state: state)
            .errorRequiresDismissal
    }

    var activeDocumentCanLocateOriginal: Bool {
        let document = state.activeTab.document
        return document.fileBinding == nil
            && document.recoveryFileReference != nil
            && document.isUnsaved
    }

    var recoveryUnavailableNotice: RecoveryUnavailableNotice? {
        recoveryCheckpointCoordinator.recoveryUnavailableNotice(state: state)
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

    func requireDisplaySettingsMutationAvailable() throws {
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
        transitionArbiter.fileMutationDisabled
    }

    var editorInteractionDisabled: Bool {
        transitionArbiter.editorInteractionDisabled
    }

    var editorMutationDisabled: Bool {
        transitionArbiter.editorMutationDisabled(
            checkpointAllowsEditing:
                recoveryCheckpointCoordinator.allowsEditing
        )
    }

    var pendingTabCloseCandidateTabID: TabID? {
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

    var activePendingTabClosePhase: PendingTabClosePhase? {
        guard pendingTabCloseSession != nil else {
            return nil
        }
        guard let candidateTabID = pendingTabCloseCandidateTabID,
              state.activeTabID == candidateTabID else {
            return nil
        }
        return pendingTabCloseSession?.phase
    }

    var pendingTabCloseAllowsBoundSave: Bool {
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

    var pendingTabCloseAllowsSaveAsAction: Bool {
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

    var pendingTabCloseAllowsFileConflictAction: Bool {
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

    var pendingTabCloseAllowsFileSaveCleanup: Bool {
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

    var externalOpenTransitionOwnsWorkspace: Bool {
        externalOpenCoordinator.ownsWorkspace
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
                  recoveryCheckpointCoordinator.isIdle,
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

    func restorePendingTabCloseDecisionAfterFileConflictCancellation() {
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



    func startPresentationHintTask() {
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

    func finishFileMutation() {
        fileSaveInProgress = false
        guard presentersShouldBeActive,
              externalOpenCoordinator.activationReconciliationPending else {
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

    func resumePendingActivationWorkAfterExclusiveAction() async {
        await reconcileImportedCopyCleanupJournalForActiveSceneIfPossible()
        resumePendingPresentersAfterExclusiveAction()
    }

    func finishTabTransition() {
        activeDocumentTransitionInProgress = false
        tabTransitionInProgress = false
        resumePendingPresentersAfterExclusiveAction()
    }

    func finishRecoveryAction() {
        activeRecoveryAction = nil
        resumePendingPresentersAfterExclusiveAction()
    }

    func resumePendingPresentersAfterExclusiveAction() {
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

    func presentActiveFileConflictIfNeeded() {
        guard state.activeTab.document.fileConflict != nil else {
            return
        }
        fileConflictResolutionIsPresented = true
    }

    func applyDetectedFileConflict(
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


    func fileSaveNoticeText(_ notice: NewDocumentSaveNotice?) -> String? {
        switch notice {
        case .none:
            return nil
        case .durableFileAccessUnavailable:
            return "File was saved and verified, but MacPad Mobile could not retain durable access. The Document is clean and detached; its next edit will require Save As."
        case .recoveryCleanupPending:
            return "File was saved and verified. The Document is clean. Protected recovery cleanup remains and MacPad Mobile will retry it on next recovery access."
        case .durableFileAccessUnavailableAndRecoveryCleanupPending:
            return "File was saved and verified without durable access. The Document is clean and detached. Protected recovery cleanup remains and MacPad Mobile will retry it on next recovery access."
        }
    }

    func fileSaveNoticeText(_ notice: SaveAsNotice?) -> String? {
        guard let notice else {
            return nil
        }
        var messages: [String] = []
        if notice.durableFileAccessUnavailable {
            messages.append(
                "File was saved and verified, but MacPad Mobile could not retain durable access. The Document is clean and detached; its next edit will require Save As."
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
                "Protected recovery cleanup remains and MacPad Mobile will retry it on next recovery access."
            )
        }
        return messages.joined(separator: " ")
    }
}

extension PhonePadAppModel: PhonePadExternalOpenWorkspace {
    var externalOpenWorkspaceState: PhonePadState {
        state
    }

    var externalOpenWorkspaceRecoveryItems: [RecoveryItemSummary] {
        recoveryItems
    }

    var externalOpenWorkspaceRecoveryError: String? {
        recoveryError
    }

    var externalOpenWorkspaceActivity:
        PhonePadExternalOpenWorkspaceActivity {
        PhonePadExternalOpenWorkspaceActivity(
            presentersShouldBeActive: presentersShouldBeActive,
            tabTransitionInProgress: tabTransitionInProgress,
            fileSaveInProgress: fileSaveInProgress,
            fileSaveCleanupRequired: fileSaveCleanupRequired,
            saveAsReplacementPending: pendingSaveAsReplacement != nil,
            recoveryActionInProgress: activeRecoveryAction != nil,
            tabClosePending: pendingTabCloseSession != nil,
            fileConflictPresented: fileConflictResolutionIsPresented
        )
    }

    func replaceExternalOpenWorkspaceState(_ state: PhonePadState) {
        self.state = state
    }

    func replaceExternalOpenWorkspaceRecoveryItems(
        _ recoveryItems: [RecoveryItemSummary]
    ) {
        self.recoveryItems = recoveryItems
    }

    func setExternalOpenWorkspaceRecoveryError(_ message: String?) {
        recoveryError = message
    }

    func markExternalOpenPresenterRefreshPending() {
        presenterRefreshPending = true
    }

    func notifyExternalOpenPresentationChanged() {
        objectWillChange.send()
    }

    func validateExternalOpenCommittedDocument(
        _ committedDocument: CommittedEditorDocument
    ) throws {
        try validateCommittedDocument(committedDocument)
    }

    func protectExternalOpenCommittedDocument(
        _ committedDocument: CommittedEditorDocument
    ) async throws {
        try await protectCommittedDocumentForActiveTransition(
            committedDocument
        )
    }

    func presentExternalOpenFileConflictIfNeeded() {
        presentActiveFileConflictIfNeeded()
    }

    func resumeActivationWorkAfterExternalOpen() async {
        await resumePendingActivationWorkAfterExclusiveAction()
    }

    func applyExternalOpenCheckpointCompletion(
        _ completion: RecoveryCheckpointCompletion
    ) async -> Bool {
        await applyRecoveryCheckpointCompletion(completion)
    }

    func protectExternalOpenRecovery(
        _ transition: RecoveryEditTransition
    ) async -> RecoveryCheckpointCompletion {
        await recoveryCheckpointCoordinator
            .protectExternalOpenTransition(transition: transition)
    }
}

extension FileAccessConnectorError {
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
