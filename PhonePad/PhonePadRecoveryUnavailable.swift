import PhonePadCore
import SwiftUI

struct RecoveryUnavailableNotice: Equatable, Sendable {
    let documentID: DocumentID
    let hasNewerUnprotectedText: Bool
    let hasLastVerifiedCheckpoint: Bool

    var message: String {
        if hasNewerUnprotectedText, hasLastVerifiedCheckpoint {
            return "Recovery Unavailable. Newer in-memory text is not protected. The last verified checkpoint remains recoverable."
        }
        if hasNewerUnprotectedText {
            return "Recovery Unavailable. Current in-memory text is not protected, and no verified checkpoint exists yet."
        }
        if hasLastVerifiedCheckpoint {
            return "Recovery Unavailable. Current text matches the last verified checkpoint, but PhonePad could not refresh its protection."
        }
        return "Recovery Unavailable. Current text has no verified checkpoint."
    }
}

struct PhonePadRecoveryUnavailableBanner: View {
    let notice: RecoveryUnavailableNotice
    let saveAvailable: Bool
    let actionInProgress: Bool
    let onRetryRecovery: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recovery Unavailable", systemImage: "exclamationmark.shield")
                .font(.headline)

            Text(notice.message)
                .font(.footnote)
                .accessibilityIdentifier(
                    "phonepad.recovery-unavailable.message"
                )

            HStack(spacing: 10) {
                Button("Retry Recovery", action: onRetryRecovery)
                    .disabled(actionInProgress)
                    .accessibilityIdentifier(
                        "phonepad.recovery-unavailable.retry"
                    )

                Button("Save", action: onSave)
                    .disabled(actionInProgress || !saveAvailable)
                    .accessibilityIdentifier(
                        "phonepad.recovery-unavailable.save"
                    )

                Button("Save As", action: onSaveAs)
                    .disabled(actionInProgress)
                    .accessibilityIdentifier(
                        "phonepad.recovery-unavailable.save-as"
                    )

                Button("Discard", role: .destructive, action: onDiscard)
                    .disabled(actionInProgress)
                    .accessibilityIdentifier(
                        "phonepad.recovery-unavailable.discard"
                    )
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.red.opacity(0.16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.recovery-unavailable")
    }
}
