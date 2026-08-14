import PhonePadCore
import SwiftUI

private struct RecoveryDiscardCandidate: Identifiable {
    let item: RecoveryItemSummary

    var id: DocumentID {
        item.documentID
    }
}

struct PhonePadRootView: View {
    @ObservedObject private var model: PhonePadAppModel
    @State private var editorTransitionController: PhonePadEditorTransitionController
    @State private var recoveryIsPresented: Bool
    @State private var discardCandidate: RecoveryDiscardCandidate?

    init(model: PhonePadAppModel) {
        self.model = model
        editorTransitionController = PhonePadEditorTransitionController()
        recoveryIsPresented = false
        discardCandidate = nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabStrip
                Divider()
                PhonePadTextEditor(
                    text: Binding(
                        get: { model.activeText },
                        set: { model.editActiveDocument(text: $0) }
                    ),
                    transitionController: editorTransitionController
                )
            }
            .navigationTitle(model.state.activeTab.document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    actionMenu
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phonepad.root")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let recoveryError = model.recoveryError {
                Text(recoveryError)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red)
                    .accessibilityIdentifier("phonepad.recovery-error")
            }
        }
        .sheet(isPresented: $recoveryIsPresented) {
            recoverySheet
        }
        .task {
            await model.refreshRecoveryItems()
        }
    }

    private var actionMenu: some View {
        Menu {
            Button {
                recoveryIsPresented = true
            } label: {
                Label("Document Recovery", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("phonepad.action-menu.document-recovery")
            .disabled(model.recoveryItems.isEmpty && model.recoveryCatalogError == nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 44)

                if !model.recoveryItems.isEmpty {
                    Text(model.recoveryItems.count, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("phonepad.recovery-count-badge")
                }
            }
        }
        .accessibilityIdentifier("phonepad.action-menu")
        .accessibilityLabel("Actions")
        .accessibilityValue(actionMenuAccessibilityValue)
    }

    private var recoverySheet: some View {
        NavigationStack {
            Group {
                if model.recoveryItems.isEmpty {
                    ContentUnavailableView(
                        "No Preserved Work",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    List(model.recoveryItems, id: \.documentID) { item in
                        recoveryRow(item)
                    }
                }
            }
            .navigationTitle("Document Recovery")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        recoveryIsPresented = false
                    }
                    .accessibilityIdentifier("phonepad.recovery.done")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let recoveryCatalogError = model.recoveryCatalogError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recoveryCatalogError)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("phonepad.recovery-catalog-error")
                        Button("Retry") {
                            Task { @MainActor in
                                await model.refreshRecoveryItems()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("phonepad.recovery.retry")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.recovery.sheet")
        .sheet(item: $discardCandidate) { candidate in
            discardConfirmationSheet(candidate)
        }
    }

    private func recoveryRow(_ item: RecoveryItemSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            Text(recoveryLastEditedText(item.lastEdited))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(recoveryStatusText(item.status))
                .font(.subheadline)
                .foregroundStyle(recoveryStatusColor(item.status))

            HStack {
                if item.status == .recoverable {
                    Button("Recover") {
                        Task { @MainActor in
                            do {
                                try editorTransitionController.commitMarkedText()
                            } catch {
                                model.reportRecoveryTransitionError(error)
                                return
                            }
                            let recovered = await model.recoverRecovery(
                                documentID: item.documentID
                            )
                            if recovered {
                                recoveryIsPresented = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activeRecoveryAction != nil)
                    .accessibilityIdentifier(
                        recoveryIdentifier(
                            prefix: "phonepad.recovery.recover",
                            documentID: item.documentID
                        )
                    )
                }

                if item.status == .unavailable {
                    Button("Retry") {
                        Task { @MainActor in
                            await model.refreshRecoveryItems()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activeRecoveryAction != nil)
                    .accessibilityIdentifier(
                        recoveryIdentifier(
                            prefix: "phonepad.recovery.retry",
                            documentID: item.documentID
                        )
                    )
                }

                Button("Discard Recovery", role: .destructive) {
                    discardCandidate = RecoveryDiscardCandidate(item: item)
                }
                .buttonStyle(.bordered)
                .disabled(model.activeRecoveryAction != nil)
                .accessibilityIdentifier(
                    recoveryIdentifier(
                        prefix: "phonepad.recovery.discard",
                        documentID: item.documentID
                    )
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            recoveryIdentifier(
                prefix: "phonepad.recovery.item",
                documentID: item.documentID
            )
        )
    }

    private func discardConfirmationSheet(
        _ candidate: RecoveryDiscardCandidate
    ) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Discard Recovery?", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)

                Text("Permanently remove preserved work for \(candidate.item.title)?")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Discard Recovery", role: .destructive) {
                    Task { @MainActor in
                        _ = await model.discardRecovery(
                            documentID: candidate.item.documentID
                        )
                        discardCandidate = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
                .disabled(model.activeRecoveryAction != nil)
                .accessibilityIdentifier(
                    recoveryIdentifier(
                        prefix: "phonepad.recovery.discard-confirm",
                        documentID: candidate.item.documentID
                    )
                )

                Button("Cancel", role: .cancel) {
                    discardCandidate = nil
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(model.activeRecoveryAction != nil)
                .accessibilityIdentifier(
                    recoveryIdentifier(
                        prefix: "phonepad.recovery.discard-cancel",
                        documentID: candidate.item.documentID
                    )
                )
            }
            .padding()
            .navigationTitle("Confirm Discard")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            recoveryIdentifier(
                prefix: "phonepad.recovery.discard-confirmation",
                documentID: candidate.item.documentID
            )
        )
        .interactiveDismissDisabled(model.activeRecoveryAction != nil)
        .presentationDetents([.medium])
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.state.tabs, id: \.id) { tab in
                    Text(tab.document.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("phonepad.tab.item")
                        .accessibilityLabel(tab.document.title)
                        .accessibilityValue(
                            recoveryStateAccessibilityValue(tab.document.recoveryState)
                        )
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("phonepad.tab-strip")
    }

    private func recoveryLastEditedText(_ lastEdited: RecoveryItemLastEdited) -> String {
        switch lastEdited {
        case let .available(date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case .unavailable:
            return "Last edited unavailable"
        }
    }

    private func recoveryStatusText(_ status: RecoveryItemStatus) -> String {
        switch status {
        case .recoverable:
            return "Unsaved"
        case .unavailable:
            return "Recovery temporarily unavailable"
        case .corrupt:
            return "Corrupt recovery data"
        case let .unsupportedVersion(version):
            return "Requires support for recovery version \(version)"
        }
    }

    private func recoveryStatusColor(_ status: RecoveryItemStatus) -> Color {
        switch status {
        case .recoverable:
            return .secondary
        case .unavailable, .corrupt, .unsupportedVersion:
            return .red
        }
    }

    private func recoveryIdentifier(
        prefix: String,
        documentID: DocumentID
    ) -> String {
        prefix + "." + documentID.rawValue.uuidString.lowercased()
    }

    private var actionMenuAccessibilityValue: String {
        if !model.recoveryItems.isEmpty {
            return "\(model.recoveryItems.count) preserved work items"
        }
        if model.recoveryCatalogError != nil {
            return "Document Recovery needs attention"
        }
        return "No preserved work"
    }

    private func recoveryStateAccessibilityValue(
        _ recoveryState: DocumentRecoveryState
    ) -> String {
        switch recoveryState {
        case .clean:
            return "Clean"
        case .checkpointPending:
            return "Protecting edits"
        case .protectedUnsaved:
            return "Edits protected"
        }
    }
}
