import Foundation
import PhonePadCore
import SwiftUI

@main
struct PhonePadApp: App {
    @UIApplicationDelegateAdaptor(PhonePadApplicationDelegate.self)
    private var applicationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: PhonePadAppModel
    #if DEBUG
    @State private var didPrepareFileConflictFixture: Bool = false
    #endif
    @State private var latestScenePhaseTransitionID: UUID = UUID()

    init() {
        let environment = ProcessInfo.processInfo.environment
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        _model = StateObject(
            wrappedValue: makePhonePadAppModel(
                recoveryRootURL: phonePadRecoveryRootURL(
                    applicationSupportURL: applicationSupportURL,
                    environment: environment
                ),
                environment: environment
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            PhonePadRootView(model: model)
                .onChange(of: scenePhase) { _, updatedPhase in
                    let transitionID = UUID()
                    latestScenePhaseTransitionID = transitionID
                    Task { @MainActor in
                        guard latestScenePhaseTransitionID == transitionID else {
                            return
                        }
                        switch updatedPhase {
                        case .active:
                            await model.sceneBecameActive()
                        case .inactive, .background:
                            await model.sceneBecameInactive()
                        @unknown default:
                            await model.sceneBecameInactive()
                        }
                    }
                }
                #if DEBUG
                    .task {
                        await prepareFileConflictFixtureIfRequested()
                    }
                #endif
        }
    }

    #if DEBUG
    @MainActor
    private func prepareFileConflictFixtureIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PHONEPAD_UI_TEST_FILE_CONFLICT"] == "1",
              !didPrepareFileConflictFixture else {
            return
        }
        didPrepareFileConflictFixture = true

        do {
            try await prepareFileConflictFixture(
                model: model,
                applicationSupportURL: FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0],
                environment: environment
            )
        } catch {
            model.reportFileConflictTransitionError(error)
        }
    }
    #endif
}

@MainActor
private func makePhonePadAppModel(
    recoveryRootURL: URL,
    environment: [String: String]
) -> PhonePadAppModel {
    #if DEBUG
    if environment["PHONEPAD_UI_TEST_RECOVERY_FAILURE"] == "1" {
        return PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryRootURL,
                fileManager: .default,
                postPromotionValidation: { _ in
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        )
    }
    #endif
    return PhonePadAppModel(recoveryRootURL: recoveryRootURL)
}

#if DEBUG
private enum PhonePadUITestFixtureError: Error, LocalizedError {
    case recoveryNamespaceMissing
    case fileOpenFailed
    case recoveryCheckpointFailed
    case conflictWasNotDetected

    var errorDescription: String? {
        switch self {
        case .recoveryNamespaceMissing:
            return "File Conflict UI fixture needs a valid recovery namespace. Relaunch the test with its stable environment value."
        case .fileOpenFailed:
            return "File Conflict UI fixture could not open its File. Relaunch the test and inspect the Open error."
        case .recoveryCheckpointFailed:
            return "File Conflict UI fixture could not protect its edit. Relaunch the test and inspect the recovery error."
        case .conflictWasNotDetected:
            return "File Conflict UI fixture changed its File, but reconciliation did not detect a conflict."
        }
    }
}

@MainActor
private func prepareFileConflictFixture(
    model: PhonePadAppModel,
    applicationSupportURL: URL,
    environment: [String: String]
) async throws {
    guard let namespace = environment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"],
          let identifier = UUID(uuidString: namespace) else {
        throw PhonePadUITestFixtureError.recoveryNamespaceMissing
    }
    let fixtureDirectoryURL = applicationSupportURL
        .appendingPathComponent("UITestFileConflict", isDirectory: true)
        .appendingPathComponent(
            identifier.uuidString.lowercased(),
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: fixtureDirectoryURL,
        withIntermediateDirectories: true,
        attributes: nil
    )
    let fileURL = fixtureDirectoryURL.appendingPathComponent(
        String(repeating: "Long File Name ", count: 12) + "Conflict.txt",
        isDirectory: false
    )
    try Data("Original conflict baseline\n".utf8).write(
        to: fileURL,
        options: .withoutOverwriting
    )
    let activeDocument = model.state.activeTab.document
    guard await model.openDocument(
        selectedURL: fileURL,
        after: CommittedEditorDocument(
            documentID: activeDocument.id,
            text: activeDocument.text
        )
    ) else {
        throw PhonePadUITestFixtureError.fileOpenFailed
    }

    model.editActiveDocument(text: "Protected conflict edit\n")
    await model.sceneBecameInactive()
    guard model.state.activeTab.document.recoveryState == .protectedUnsaved else {
        await model.sceneBecameActive()
        throw PhonePadUITestFixtureError.recoveryCheckpointFailed
    }
    await model.sceneBecameActive()

    try Data("External conflict content\n".utf8).write(
        to: fileURL,
        options: []
    )
    await model.reconcilePresentedFile(
        documentID: model.state.activeTab.document.id
    )
    guard model.activeFileConflict != nil else {
        throw PhonePadUITestFixtureError.conflictWasNotDetected
    }
}
#endif

private func phonePadRecoveryRootURL(
    applicationSupportURL: URL,
    environment: [String: String]
) -> URL {
    #if DEBUG
    if let namespace = environment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"],
       let identifier = UUID(uuidString: namespace) {
        return applicationSupportURL
            .appendingPathComponent("UITestRecovery", isDirectory: true)
            .appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: true)
    }
    #endif

    return applicationSupportURL
        .appendingPathComponent("Recovery", isDirectory: true)
}
