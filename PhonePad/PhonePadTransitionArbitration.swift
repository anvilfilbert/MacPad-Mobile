struct PhonePadTransitionActivity: Equatable, Sendable {
    let fileSaveInProgress: Bool
    let fileSaveCleanupRequired: Bool
    let saveAsReplacementPending: Bool
    let recoveryActionInProgress: Bool
    let tabTransitionInProgress: Bool
    let tabClosePending: Bool
    let activeDocumentTransitionInProgress: Bool
    let externalOpenInProgress: Bool
    let externalOpenCleanupInProgress: Bool
    let externalOpenOwnsWorkspace: Bool
    let externalOpenHasQueuedRequestOrDecision: Bool
    let externalOpenHasPendingDecision: Bool
    let fileConflictPresented: Bool
}

struct PhonePadTransitionArbiter {
    let activity: PhonePadTransitionActivity

    var editorInteractionDisabled: Bool {
        activity.fileSaveInProgress
            || activity.saveAsReplacementPending
            || activity.recoveryActionInProgress
            || activity.activeDocumentTransitionInProgress
            || activity.externalOpenInProgress
    }

    var fileMutationDisabled: Bool {
        editorInteractionDisabled
            || activity.fileSaveCleanupRequired
            || activity.tabClosePending
            || activity.tabTransitionInProgress
            || activity.externalOpenHasQueuedRequestOrDecision
    }

    func editorMutationDisabled(
        checkpointAllowsEditing: Bool
    ) -> Bool {
        editorInteractionDisabled
            || activity.fileSaveCleanupRequired
            || activity.tabClosePending
            || !checkpointAllowsEditing
            || activity.externalOpenHasPendingDecision
    }

    var canBeginTabTransition: Bool {
        !activity.tabTransitionInProgress
            && !activity.fileSaveInProgress
            && !activity.fileSaveCleanupRequired
            && !activity.saveAsReplacementPending
            && !activity.recoveryActionInProgress
            && !activity.tabClosePending
            && !activity.externalOpenOwnsWorkspace
    }

    var canBeginExternalOpen: Bool {
        !activity.externalOpenInProgress
            && !activity.externalOpenCleanupInProgress
            && !activity.tabTransitionInProgress
            && !activity.fileSaveInProgress
            && !activity.fileSaveCleanupRequired
            && !activity.saveAsReplacementPending
            && !activity.recoveryActionInProgress
            && !activity.tabClosePending
            && !activity.externalOpenHasPendingDecision
            && !activity.fileConflictPresented
    }

    var canReconcilePresentedFiles: Bool {
        !activity.fileSaveInProgress
            && !activity.tabTransitionInProgress
            && !activity.recoveryActionInProgress
            && !activity.fileSaveCleanupRequired
            && !activity.tabClosePending
            && !activity.externalOpenOwnsWorkspace
    }
}

extension PhonePadAppModel {
    var transitionArbiter: PhonePadTransitionArbiter {
        PhonePadTransitionArbiter(
            activity: PhonePadTransitionActivity(
                fileSaveInProgress: fileSaveInProgress,
                fileSaveCleanupRequired: fileSaveCleanupRequired,
                saveAsReplacementPending: pendingSaveAsReplacement != nil,
                recoveryActionInProgress: activeRecoveryAction != nil,
                tabTransitionInProgress: tabTransitionInProgress,
                tabClosePending: pendingTabCloseSession != nil,
                activeDocumentTransitionInProgress:
                    activeDocumentTransitionInProgress,
                externalOpenInProgress: externalOpenInProgress,
                externalOpenCleanupInProgress:
                    externalOpenCoordinator.externalOpenCleanupInProgress,
                externalOpenOwnsWorkspace:
                    externalOpenTransitionOwnsWorkspace,
                externalOpenHasQueuedRequestOrDecision:
                    externalOpenCoordinator.hasQueuedRequestOrDecision,
                externalOpenHasPendingDecision:
                    externalOpenCoordinator.hasPendingDecision,
                fileConflictPresented:
                    fileConflictResolutionIsPresented
            )
        )
    }
}
