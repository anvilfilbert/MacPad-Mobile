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

private enum PhonePadRecoveryActionError: Error, LocalizedError {
    case actionAlreadyInProgress
    case checkpointMustFinishBeforeRecovering
    case recoveryItemCannotBeRecovered
    case recoveryItemMissing

    var errorDescription: String? {
        switch self {
        case .actionAlreadyInProgress:
            "Another recovery action is still running. Wait for it to finish and retry."
        case .checkpointMustFinishBeforeRecovering:
            "Current edits could not be protected. Resolve the recovery error before opening preserved work."
        case .recoveryItemCannotBeRecovered:
            "This preserved work is corrupt or unsupported. Keep it for a compatible PhonePad version, or choose Discard Recovery."
        case .recoveryItemMissing:
            "Preserved work is no longer available. Refresh Document Recovery and retry."
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

    private let recoveryStore: FileRecoveryStore
    private let checkpointQuietPeriod: Duration
    private let checkpointMaximumInterval: Duration
    private let checkpointClock: ContinuousClock
    private var checkpointTask: Task<Void, Never>?
    private var pendingCheckpoint: PendingRecoveryCheckpoint?
    private var editGeneration: UInt64

    init(
        state: PhonePadState,
        recoveryStore: FileRecoveryStore,
        checkpointQuietPeriod: Duration,
        checkpointMaximumInterval: Duration
    ) {
        precondition(checkpointQuietPeriod > .zero, "Checkpoint quiet period must be positive.")
        precondition(checkpointMaximumInterval > .zero, "Checkpoint maximum interval must be positive.")
        self.state = state
        self.recoveryStore = recoveryStore
        self.checkpointQuietPeriod = checkpointQuietPeriod
        self.checkpointMaximumInterval = checkpointMaximumInterval
        checkpointClock = ContinuousClock()
        recoveryError = nil
        recoveryItems = []
        recoveryCatalogError = nil
        activeRecoveryAction = nil
        pendingCheckpoint = nil
        editGeneration = 0
    }

    convenience init(
        state: PhonePadState,
        recoveryStore: FileRecoveryStore
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

    func reportRecoveryTransitionError(_ error: Error) {
        recoveryCatalogError = error.localizedDescription
    }

    func refreshRecoveryItems() async {
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
    func recoverRecovery(documentID: DocumentID) async -> Bool {
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { activeRecoveryAction = nil }

        guard await currentDocumentIsReadyForTransition() else {
            return false
        }

        do {
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
            let displayEnvelope = RecoveryEnvelope(
                formatVersion: envelope.formatVersion,
                documentID: envelope.documentID,
                title: summary.title,
                text: envelope.text,
                editedAt: envelope.editedAt
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
        guard activeRecoveryAction == nil else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .actionAlreadyInProgress
                .localizedDescription
            return false
        }

        activeRecoveryAction = documentID
        defer { activeRecoveryAction = nil }

        do {
            try await recoveryStore.discardRecovery(documentID: documentID)
            recoveryItems.removeAll { $0.documentID == documentID }
            recoveryCatalogError = nil
            return true
        } catch {
            recoveryCatalogError = error.localizedDescription
            return false
        }
    }

    func editActiveDocument(text: String) {
        guard text != state.activeTab.document.text else {
            return
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
            return
        }

        state = transition.state
        recoveryError = nil

        editGeneration += 1
        let now = checkpointClock.now
        let existingCheckpoint = pendingCheckpoint
        pendingCheckpoint = PendingRecoveryCheckpoint(
            generation: editGeneration,
            previousState: previousState,
            text: text,
            editedAt: transition.envelope.editedAt,
            firstPendingAt: existingCheckpoint?.firstPendingAt ?? now,
            lastEditAt: now,
            requiresImmediateCheckpoint: existingCheckpoint?.requiresImmediateCheckpoint
                ?? (previousState.activeTab.document.recoveryState == .clean)
        )
        startCheckpointTaskIfNeeded()
    }

    private func startCheckpointTaskIfNeeded() {
        guard checkpointTask == nil else {
            return
        }
        checkpointTask = Task { @MainActor [weak self] in
            await self?.runCheckpointLoop()
        }
    }

    private func currentDocumentIsReadyForTransition() async -> Bool {
        if let checkpointTask {
            await checkpointTask.value
        }

        guard pendingCheckpoint == nil,
              state.activeTab.document.recoveryState != .checkpointPending else {
            recoveryCatalogError = PhonePadRecoveryActionError
                .checkpointMustFinishBeforeRecovering
                .localizedDescription
            return false
        }
        return true
    }

    private func runCheckpointLoop() async {
        while !Task.isCancelled {
            guard let checkpoint = await nextReadyCheckpoint() else {
                break
            }
            guard pendingCheckpoint?.generation == checkpoint.generation else {
                continue
            }
            pendingCheckpoint = nil
            await persist(checkpoint: checkpoint)
        }

        checkpointTask = nil
        if !Task.isCancelled, pendingCheckpoint != nil {
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

    private func persist(checkpoint: PendingRecoveryCheckpoint) async {
        do {
            let updatedState = try await editActiveDocumentAndCheckpoint(
                state: checkpoint.previousState,
                newText: checkpoint.text,
                editedAt: checkpoint.editedAt,
                recoveryStore: recoveryStore
            )
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return
            }
            state = updatedState
            recoveryError = nil
        } catch {
            guard !Task.isCancelled, editGeneration == checkpoint.generation else {
                return
            }
            recoveryError = error.localizedDescription
        }
    }
}
