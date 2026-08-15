import UIKit
import XCTest
import PhonePadCore
@testable import PhonePad

final class PhonePadExternalOpenLifecycleTests: XCTestCase {
    @MainActor
    func testBatchOrdersSameCallbackByURLThenAccessIntent() {
        let alphaInPlace = PhonePadExternalOpenRequest(
            url: URL(fileURLWithPath: "/provider/alpha.txt"),
            accessIntent: .inPlace
        )
        let alphaCopyRequired = PhonePadExternalOpenRequest(
            url: URL(fileURLWithPath: "/provider/alpha.txt"),
            accessIntent: .copyRequired
        )
        let zetaInPlace = PhonePadExternalOpenRequest(
            url: URL(fileURLWithPath: "/provider/zeta.txt"),
            accessIntent: .inPlace
        )

        let batch = makePhonePadExternalOpenBatch(
            requests: [zetaInPlace, alphaCopyRequired, alphaInPlace]
        )

        XCTAssertEqual(
            batch.requests,
            [alphaInPlace, alphaCopyRequired, zetaInPlace]
        )
    }

    @MainActor
    func testSceneDelegateBuffersColdAndWarmBatchesUntilConsumerTakesThem() {
        let lifecycle = PhonePadExternalOpenSceneDelegate()
        var coldRequests = [
            PhonePadExternalOpenRequest(
                url: URL(fileURLWithPath: "/provider/cold-b.txt"),
                accessIntent: .inPlace
            ),
            PhonePadExternalOpenRequest(
                url: URL(fileURLWithPath: "/provider/cold-a.txt"),
                accessIntent: .copyRequired
            ),
        ]
        let warmRequests = [
            PhonePadExternalOpenRequest(
                url: URL(fileURLWithPath: "/provider/warm.txt"),
                accessIntent: .inPlace
            ),
        ]

        lifecycle.bufferExternalOpenRequests(coldRequests)
        coldRequests.removeAll()
        lifecycle.bufferExternalOpenRequests(warmRequests)

        XCTAssertEqual(
            lifecycle.pendingExternalOpenBatches,
            [
                makePhonePadExternalOpenBatch(
                    requests: [
                        PhonePadExternalOpenRequest(
                            url: URL(fileURLWithPath: "/provider/cold-a.txt"),
                            accessIntent: .copyRequired
                        ),
                        PhonePadExternalOpenRequest(
                            url: URL(fileURLWithPath: "/provider/cold-b.txt"),
                            accessIntent: .inPlace
                        ),
                    ]
                ),
                makePhonePadExternalOpenBatch(requests: warmRequests),
            ]
        )

        let takenBatches = lifecycle.takePendingExternalOpenBatches()

        XCTAssertEqual(takenBatches.count, 2)
        XCTAssertTrue(lifecycle.pendingExternalOpenBatches.isEmpty)
        XCTAssertTrue(lifecycle.takePendingExternalOpenBatches().isEmpty)
    }

    @MainActor
    func testSceneDelegateDoesNotPublishEmptySystemCallback() {
        let lifecycle = PhonePadExternalOpenSceneDelegate()

        lifecycle.bufferExternalOpenRequests([])

        XCTAssertTrue(lifecycle.pendingExternalOpenBatches.isEmpty)
    }

    @MainActor
    func testWindowApplicationConfigurationInstallsObservableSceneDelegate() {
        let configuration = makePhonePadSceneConfiguration(
            sessionRole: .windowApplication
        )

        XCTAssertTrue(
            configuration.delegateClass
                === PhonePadExternalOpenSceneDelegate.self
        )
        XCTAssertNil(configuration.sceneClass)
        XCTAssertNil(configuration.storyboard)
    }

    @MainActor
    func testCopyRequiredExternalOpenIntakeCapturesCleanupBeforeInitialRecoveryRefreshFinishes() async throws {
        let resources = try await makeLifecycleExternalOpenResources()
        let recoveryGate = LifecycleRecoveryItemsGate()
        let recoveryStore = LifecycleBlockingRecoveryItemsStore(
            baseStore: resources.recoveryStore,
            gate: recoveryGate
        )
        let model = makeLifecycleExternalOpenModel(
            recoveryStore: recoveryStore,
            connector: resources.connector
        )
        let lifecycle = PhonePadExternalOpenSceneDelegate()
        addTeardownBlock {
            await recoveryGate.resume()
            await resources.connector.pausePresenters()
            try FileManager.default.removeItem(at: resources.rootURL)
        }
        let refresh = Task { @MainActor in
            await model.refreshRecoveryItems()
        }
        await recoveryGate.waitUntilEntered()
        lifecycle.bufferExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: resources.importedCopyURL,
                accessIntent: .copyRequired
            ),
        ])

        await intakePhonePadExternalOpenBatches(
            from: lifecycle,
            into: model
        )

        let report = try await resources.connector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertTrue(report.awaitingProtection.isEmpty)
        XCTAssertEqual(
            FileManager.default.fileExists(
                atPath: resources.importedCopyURL.path
            ),
            false
        )
        XCTAssertTrue(lifecycle.pendingExternalOpenBatches.isEmpty)
        XCTAssertNotNil(model.externalOpenCommitRequestID)
        await recoveryGate.resume()
        await refresh.value
        XCTAssertNil(model.recoveryCatalogError)
    }

    @MainActor
    func testCopyRequiredExternalOpenIntakeCapturesCleanupWhileFilePickerIsPresented() async throws {
        let resources = try await makeLifecycleExternalOpenResources()
        let model = makeLifecycleExternalOpenModel(
            recoveryStore: resources.recoveryStore,
            connector: resources.connector
        )
        let lifecycle = PhonePadExternalOpenSceneDelegate()
        addTeardownBlock {
            await resources.connector.pausePresenters()
            try FileManager.default.removeItem(at: resources.rootURL)
        }
        lifecycle.bufferExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: resources.importedCopyURL,
                accessIntent: .copyRequired
            ),
        ])

        await intakePhonePadExternalOpenBatches(
            from: lifecycle,
            into: model
        )

        let commitRequestID = try XCTUnwrap(
            model.externalOpenCommitRequestID
        )
        let blockedTrigger = PhonePadExternalOpenProcessingTrigger(
            commitRequestID: commitRequestID,
            initialRecoveryRefreshFinished: true,
            saveAsIsPresented: false,
            folderPickerIsPresented: false,
            filePickerIsPresented: true
        )
        let report = try await resources.connector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertTrue(report.awaitingProtection.isEmpty)
        XCTAssertEqual(
            FileManager.default.fileExists(
                atPath: resources.importedCopyURL.path
            ),
            false
        )
        XCTAssertNil(blockedTrigger.readyCommitRequestID)
        XCTAssertEqual(
            PhonePadExternalOpenProcessingTrigger(
                commitRequestID: commitRequestID,
                initialRecoveryRefreshFinished: true,
                saveAsIsPresented: false,
                folderPickerIsPresented: false,
                filePickerIsPresented: false
            ).readyCommitRequestID,
            commitRequestID
        )
    }

    @MainActor
    func testSceneCallbackIntakesCopyRequiredBatchBeforePresentationGate() async throws {
        let resources = try await makeLifecycleExternalOpenResources()
        let model = makeLifecycleExternalOpenModel(
            recoveryStore: resources.recoveryStore,
            connector: resources.connector
        )
        let lifecycle = PhonePadExternalOpenSceneDelegate()
        addTeardownBlock {
            await resources.connector.pausePresenters()
            try FileManager.default.removeItem(at: resources.rootURL)
        }
        lifecycle.bufferExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: resources.importedCopyURL,
                accessIntent: .copyRequired
            ),
        ])

        await intakePhonePadExternalOpenBatches(
            from: lifecycle,
            into: model
        )

        XCTAssertTrue(lifecycle.pendingExternalOpenBatches.isEmpty)
        XCTAssertNil(
            PhonePadExternalOpenProcessingTrigger(
                commitRequestID: model.externalOpenCommitRequestID,
                initialRecoveryRefreshFinished: false,
                saveAsIsPresented: false,
                folderPickerIsPresented: false,
                filePickerIsPresented: false
            ).readyCommitRequestID
        )
        await model.refreshInitialRecoveryItems()
        XCTAssertEqual(
            model.recoveryItems.map(\.documentID),
            [resources.recoveryDocumentID]
        )
        let report = try await resources.connector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertEqual(report.removed.count, 1)
        XCTAssertTrue(report.awaitingProtection.isEmpty)
        XCTAssertEqual(
            FileManager.default.fileExists(
                atPath: resources.importedCopyURL.path
            ),
            false
        )
        await intakePhonePadExternalOpenBatches(
            from: lifecycle,
            into: model
        )
        let secondReport = try await resources.connector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertTrue(secondReport.removed.isEmpty)
        XCTAssertTrue(secondReport.alreadyAbsent.isEmpty)
        XCTAssertTrue(secondReport.awaitingProtection.isEmpty)
        XCTAssertTrue(secondReport.residuals.isEmpty)
    }
}

@MainActor
private struct LifecycleExternalOpenResources {
    let rootURL: URL
    let importedCopyURL: URL
    let recoveryDocumentID: DocumentID
    let recoveryStore: FileRecoveryStore
    let connector: FileAccessConnector
}

@MainActor
private func makeLifecycleExternalOpenResources() async throws
    -> LifecycleExternalOpenResources {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxURL = rootURL.appendingPathComponent(
        "Documents/Inbox",
        isDirectory: true
    )
    let journalRootURL = rootURL.appendingPathComponent(
        "Cleanup Journal",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: inboxURL,
        withIntermediateDirectories: true,
        attributes: nil
    )
    let importedCopyURL = inboxURL.appendingPathComponent(
        "Incoming.txt",
        isDirectory: false
    )
    try Data("Incoming copy\n".utf8).write(
        to: importedCopyURL,
        options: .withoutOverwriting
    )
    let recoveryStore = FileRecoveryStore(
        rootURL: rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        ),
        fileManager: .default
    )
    let recoveryDocumentID = DocumentID(rawValue: UUID())
    try await recoveryStore.save(
        envelope: RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: recoveryDocumentID,
            title: "Preserved",
            text: "Preserved edits",
            editedAt: Date(timeIntervalSince1970: 1_786_700_000)
        )
    )
    let connector = FileAccessConnector(
        fileManager: .default,
        bookmarkCreator: { url in
            try makeLifecycleBookmark(url: url)
        },
        bookmarkResolver: { bookmark in
            try resolveLifecycleBookmark(bookmark: bookmark)
        },
        identityReader: { _ in nil },
        replacer: { originalURL, stagingURL, fileManager in
            try replaceLifecycleFile(
                originalURL: originalURL,
                stagingURL: stagingURL,
                fileManager: fileManager
            )
        },
        fileWritabilityReader: { _ in true },
        applicationInboxURL: inboxURL,
        importedCopyCleanupJournalRootURL: journalRootURL,
        importedCopyRemover: { url, fileManager in
            try removeImportedCopy(url: url, fileManager: fileManager)
        },
        importedCopyCleanupJournalMetadataVerifier: {
            url,
            itemKind,
            fileManager in
            try verifyImportedCopyCleanupJournalMetadata(
                url: url,
                itemKind: itemKind,
                fileManager: fileManager
            )
        }
    )
    return LifecycleExternalOpenResources(
        rootURL: rootURL,
        importedCopyURL: importedCopyURL,
        recoveryDocumentID: recoveryDocumentID,
        recoveryStore: recoveryStore,
        connector: connector
    )
}

@MainActor
private func makeLifecycleExternalOpenModel(
    recoveryStore: any RecoveryStoring,
    connector: FileAccessConnector
) -> PhonePadAppModel {
    PhonePadAppModel(
        state: makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        ),
        recoveryStore: recoveryStore,
        fileAccessConnector: connector,
        checkpointQuietPeriod: .milliseconds(20),
        checkpointMaximumInterval: .milliseconds(100)
    )
}

private func makeLifecycleBookmark(url: URL) throws -> Data {
    guard let data = url.standardizedFileURL.path.data(using: .utf8) else {
        throw LifecycleExternalOpenTestError.bookmarkEncodingFailed
    }
    return data
}

private func resolveLifecycleBookmark(
    bookmark: FileBookmark
) throws -> ResolvedFileBookmark {
    guard let path = String(data: bookmark.data, encoding: .utf8) else {
        throw LifecycleExternalOpenTestError.bookmarkDecodingFailed
    }
    return ResolvedFileBookmark(
        url: URL(fileURLWithPath: path),
        isStale: false
    )
}

private func replaceLifecycleFile(
    originalURL: URL,
    stagingURL: URL,
    fileManager: FileManager
) throws -> URL? {
    try fileManager.replaceItemAt(
        originalURL,
        withItemAt: stagingURL,
        backupItemName: nil,
        options: []
    )
}

private enum LifecycleExternalOpenTestError: Error {
    case bookmarkEncodingFailed
    case bookmarkDecodingFailed
}

private struct LifecycleBlockingRecoveryItemsStore: RecoveryStoring {
    let baseStore: FileRecoveryStore
    let gate: LifecycleRecoveryItemsGate

    func save(envelope: RecoveryEnvelope) async throws {
        try await baseStore.save(envelope: envelope)
    }

    func load(documentID: DocumentID) async throws -> RecoveryEnvelope? {
        try await baseStore.load(documentID: documentID)
    }

    func verifyCheckpoint(
        documentID: DocumentID
    ) async throws -> RecoveryCheckpointVerification {
        try await baseStore.verifyCheckpoint(documentID: documentID)
    }

    func recoveryItems() async throws -> [RecoveryItemSummary] {
        await gate.block()
        return try await baseStore.recoveryItems()
    }

    func recoveryFileCollisionClaims(
        excludingDocumentID: DocumentID
    ) async throws -> [FileCollisionClaim] {
        try await baseStore.recoveryFileCollisionClaims(
            excludingDocumentID: excludingDocumentID
        )
    }

    func discardRecovery(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        try await baseStore.discardRecovery(documentID: documentID)
    }

    func completeRecoveryAfterSave(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        try await baseStore.completeRecoveryAfterSave(
            documentID: documentID
        )
    }
}

private actor LifecycleRecoveryItemsGate {
    private var didEnter: Bool = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        didEnter = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            precondition(releaseContinuation == nil)
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else {
            return
        }
        await withCheckedContinuation { continuation in
            precondition(entryContinuation == nil)
            entryContinuation = continuation
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
