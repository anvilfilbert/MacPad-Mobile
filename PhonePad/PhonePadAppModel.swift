import Foundation
import PhonePadCore
import SwiftUI

@MainActor
final class PhonePadAppModel: ObservableObject {
    @Published private(set) var state: PhonePadState
    @Published private(set) var recoveryError: String?

    private let recoveryStore: FileRecoveryStore
    private var checkpointTask: Task<Void, Never>?

    init(
        state: PhonePadState,
        recoveryStore: FileRecoveryStore
    ) {
        self.state = state
        self.recoveryStore = recoveryStore
        recoveryError = nil
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

        let previousTask = checkpointTask
        let store = recoveryStore
        checkpointTask = Task { [weak self] in
            _ = await previousTask?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                let updatedState = try await editActiveDocumentAndCheckpoint(
                    state: previousState,
                    newText: text,
                    editedAt: transition.envelope.editedAt,
                    recoveryStore: store
                )
                guard !Task.isCancelled else {
                    return
                }
                if self?.state.activeTab.document.text == updatedState.activeTab.document.text {
                    self?.state = updatedState
                    self?.recoveryError = nil
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.recoveryError = error.localizedDescription
            }
        }
    }
}
