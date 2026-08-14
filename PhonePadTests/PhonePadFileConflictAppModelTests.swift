import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadFileConflictAppModelTests: XCTestCase {
    func testSaveConflictIsStickyAndCancelMutatesNoDocumentOrRecovery() async throws {
        let fixture = try makeConflictModelFixture()
        let model = makeConflictModel(fixture: fixture)
        let didOpen = await model.openTestDocument(selectedURL: fixture.fileURL)
        XCTAssertTrue(didOpen)
        let documentID = model.state.activeTab.document.id
        model.editActiveDocument(text: "Protected PhonePad edit\n")
        let recoveryWasProtected = try await waitUntilRecoveryIsProtected(model: model)
        XCTAssertTrue(recoveryWasProtected)
        try replaceConflictTestFile(
            at: fixture.fileURL,
            with: Data("External writer content\n".utf8)
        )

        let didSave = await model.saveActiveDocument()

        XCTAssertFalse(didSave)
        XCTAssertEqual(model.activeFileConflict, .contentChanged)
        XCTAssertTrue(model.fileConflictResolutionIsPresented)
        XCTAssertEqual(model.activeText, "Protected PhonePad edit\n")
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data("External writer content\n".utf8)
        )
        let recoveryBeforeCancel = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        let stateBeforeCancel = model.state

        model.cancelFileConflictResolution()

        XCTAssertEqual(model.state, stateBeforeCancel)
        XCTAssertFalse(model.fileConflictResolutionIsPresented)
        let recoveryAfterCancel = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        XCTAssertEqual(recoveryAfterCancel, recoveryBeforeCancel)
        await model.reconcilePresentedFile(documentID: documentID)
        XCTAssertFalse(model.fileConflictResolutionIsPresented)
        XCTAssertEqual(model.activeText, "Protected PhonePad edit\n")
        XCTAssertEqual(model.activeFileConflict, .contentChanged)
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        let stateAfterReconciliation = model.state
        let didSaveAfterCancel = await model.saveActiveDocument()
        XCTAssertFalse(didSaveAfterCancel)
        XCTAssertTrue(model.fileConflictResolutionIsPresented)
        XCTAssertEqual(model.state, stateAfterReconciliation)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data("External writer content\n".utf8)
        )
    }

    func testDuplicateStableIdentityOpenRefreshesExistingPresenterBeforeSave() async throws {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let originalURL = filesURL.appendingPathComponent("Original.txt")
        let alternateURL = filesURL.appendingPathComponent("Alternate.txt")
        let originalBytes = Data("Stable identity baseline\n".utf8)
        try originalBytes.write(to: originalURL, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: originalURL, to: alternateURL)
        let identity = FileIdentity(
            volumeUUID: UUID(
                uuidString: "87000000-0000-0000-0000-000000000001"
            )!,
            documentIdentifier: 87
        )
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeConflictTestBookmark,
            bookmarkResolver: resolveConflictTestBookmark,
            identityReader: { _ in identity },
            replacer: replaceConflictTestItem
        )
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryURL,
                fileManager: .default
            ),
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpenOriginal = await model.openTestDocument(selectedURL: originalURL)
        XCTAssertTrue(didOpenOriginal)
        let documentID = model.state.activeTab.document.id

        let didOpenAlternate = await model.openTestDocument(selectedURL: alternateURL)
        XCTAssertTrue(didOpenAlternate)

        XCTAssertEqual(model.state.tabs.count, 1)
        XCTAssertEqual(
            model.state.activeTab.document.fileBinding?.locatorURL.standardizedFileURL,
            alternateURL.standardizedFileURL
        )
        guard try await waitUntilPresenterUsesLocator(
            documentID: documentID,
            locatorURL: alternateURL
        ) else {
            return XCTFail(
                "Duplicate Open must refresh the existing presenter to the observed locator."
            )
        }

        model.editActiveDocument(text: "Saved through alternate locator\n")
        let didProtectRecovery = try await waitUntilRecoveryIsProtected(model: model)
        XCTAssertTrue(didProtectRecovery)
        let didSave = await model.saveActiveDocument()

        XCTAssertTrue(didSave)
        XCTAssertNil(model.activeFileConflict)
        XCTAssertEqual(
            try Data(contentsOf: alternateURL),
            Data("Saved through alternate locator\n".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(
            model.state.activeTab.document.fileBinding?.locatorURL.standardizedFileURL,
            alternateURL.standardizedFileURL
        )
    }

    func testDuplicateStableIdentityOpenRefreshesPresenterBeforeImmediateSave() async throws {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let originalURL = filesURL.appendingPathComponent("Original.txt")
        let alternateURL = filesURL.appendingPathComponent("Alternate.txt")
        let originalBytes = Data("Immediate Save baseline\n".utf8)
        try originalBytes.write(to: originalURL, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: originalURL, to: alternateURL)
        let identity = FileIdentity(
            volumeUUID: UUID(
                uuidString: "88000000-0000-0000-0000-000000000001"
            )!,
            documentIdentifier: 88
        )
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeConflictTestBookmark,
            bookmarkResolver: resolveConflictTestBookmark,
            identityReader: { _ in identity },
            replacer: replaceConflictTestItem
        )
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryURL,
                fileManager: .default
            ),
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpenOriginal = await model.openTestDocument(selectedURL: originalURL)
        XCTAssertTrue(didOpenOriginal)

        let didOpenAlternate = await model.openTestDocument(selectedURL: alternateURL)
        XCTAssertTrue(didOpenAlternate)
        model.editActiveDocument(text: "Immediate Save through alternate locator\n")
        let didSave = await model.saveActiveDocument()

        XCTAssertTrue(didSave)
        XCTAssertNil(model.activeFileConflict)
        XCTAssertEqual(
            try Data(contentsOf: alternateURL),
            Data("Immediate Save through alternate locator\n".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(
            model.state.activeTab.document.fileBinding?.locatorURL.standardizedFileURL,
            alternateURL.standardizedFileURL
        )
    }

    func testBoundSaveCleanupDefersReconciliationAndRefreshesAfterRetry() async throws {
        let fixture = try await makeBoundSaveCleanupRaceFixture()
        let didSave = await fixture.model.saveActiveDocument()

        XCTAssertFalse(didSave)
        XCTAssertTrue(fixture.model.fileSaveCleanupRequired)
        XCTAssertNil(fixture.model.activeFileConflict)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            fixture.savedBytes
        )
        let cleanupLockedState = fixture.model.state

        await fixture.model.reconcilePresentedFile(
            documentID: fixture.documentID
        )
        await fixture.model.sceneBecameActive()

        XCTAssertNil(
            fixture.model.activeFileConflict,
            "Own verified Save must not conflict with its protected pre-cleanup binding."
        )
        XCTAssertEqual(fixture.model.state, cleanupLockedState)

        let externalBytes = Data("External edit during cleanup lock\n".utf8)
        try replaceConflictTestFile(
            at: fixture.fileURL,
            with: externalBytes
        )
        await fixture.model.reconcilePresentedFile(
            documentID: fixture.documentID
        )

        XCTAssertNil(fixture.model.activeFileConflict)
        XCTAssertEqual(fixture.model.state, cleanupLockedState)
        XCTAssertTrue(fixture.model.fileSaveCleanupRequired)

        try fixture.cleanupFailureControl.restoreRecovery()
        let didRetry = await fixture.model.retryFileSaveCleanup()

        XCTAssertTrue(didRetry)
        XCTAssertFalse(fixture.model.fileSaveCleanupRequired)
        let detectedExternalConflict = try await waitUntilActiveConflict(
            model: fixture.model,
            expectedConflict: .contentChanged
        )
        XCTAssertTrue(
            detectedExternalConflict,
            "Cleanup retry must refresh from the verified Save baseline and retain the external change as a conflict."
        )
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), externalBytes)
        XCTAssertEqual(fixture.model.activeText, fixture.savedText)

        await fixture.model.reconcilePresentedFile(
            documentID: fixture.documentID
        )
        XCTAssertEqual(fixture.model.activeFileConflict, .contentChanged)
    }

    func testBoundSaveExtractsConflictFromStagingCleanupFailure() async throws {
        let fixture = try await makeNestedCleanupConflictFixture()
        fixture.failureControl.arm()

        let didSave = await fixture.model.saveActiveDocument()

        XCTAssertFalse(didSave)
        try await assertNestedCleanupConflictIsSticky(fixture: fixture)
    }

    func testCurrentFileSaveAsExtractsConflictFromStagingCleanupFailure() async throws {
        let fixture = try await makeNestedCleanupConflictFixture()
        let preparation = try fixture.model.prepareDocumentSaveAs(
            fileName: fixture.fileURL.lastPathComponent,
            encoding: .utf8
        )
        let optionalPreflight = await fixture.model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: fixture.filesURL
        )
        let preflight = try XCTUnwrap(optionalPreflight)
        guard case .currentFile = preflight.target else {
            return XCTFail("Bound destination must use current-file Save As.")
        }
        fixture.failureControl.arm()

        let didSave = await fixture.model.completePreflightedSaveAs(preflight)

        XCTAssertFalse(didSave)
        try await assertNestedCleanupConflictIsSticky(fixture: fixture)
    }

    func testReloadSucceedsWithoutRetryingFailedCheckpoint() async throws {
        let fixture = try await makeFailedCheckpointFixture(
            recoveryFileManager: FileManager()
        )
        try replaceConflictTestFile(
            at: fixture.fileURL,
            with: Data("External reload winner\n".utf8)
        )
        await fixture.model.reconcilePresentedFile(
            documentID: fixture.documentID
        )
        XCTAssertEqual(fixture.model.activeFileConflict, .contentChanged)

        let didReload = await fixture.model.discardEditsAndReloadCurrentFile()

        XCTAssertTrue(didReload)
        XCTAssertEqual(fixture.model.activeText, "External reload winner\n")
        XCTAssertNil(fixture.model.activeFileConflict)
        XCTAssertNil(fixture.model.recoveryError)
        XCTAssertFalse(fixture.model.editorMutationDisabled)
        XCTAssertFalse(fixture.model.fileConflictResolutionIsPresented)
        let recoveryAfterReload = try await fixture.recoveryStore.load(
            documentID: fixture.documentID
        )
        XCTAssertNil(recoveryAfterReload)
    }

    func testReloadReadFailureRetainsFailedCheckpointLockAndRecovery() async throws {
        let fixture = try await makeFailedCheckpointFixture(
            recoveryFileManager: FileManager()
        )
        let binaryBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        try replaceConflictTestFile(at: fixture.fileURL, with: binaryBytes)
        await fixture.model.reconcilePresentedFile(
            documentID: fixture.documentID
        )
        XCTAssertEqual(fixture.model.activeFileConflict, .contentChanged)
        let stateBeforeReload = fixture.model.state

        let didReload = await fixture.model.discardEditsAndReloadCurrentFile()

        XCTAssertFalse(didReload)
        XCTAssertEqual(fixture.model.state, stateBeforeReload)
        XCTAssertEqual(
            fixture.model.recoveryError,
            fixture.failedCheckpointError
        )
        XCTAssertTrue(fixture.model.editorMutationDisabled)
        XCTAssertTrue(fixture.model.fileConflictResolutionIsPresented)
        XCTAssertEqual(
            fixture.model.fileConflictError,
            FileAccessConnectorError
                .textDecodingFailed(.unsupportedContent(.rasterImage))
                .localizedDescription
        )
        let recoveryAfterFailure = try await fixture.recoveryStore.load(
            documentID: fixture.documentID
        )
        XCTAssertEqual(recoveryAfterFailure, fixture.retainedRecovery)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), binaryBytes)
    }

    func testReloadCleanupFailureRetainsFailedCheckpointLockAndRecovery() async throws {
        let removalControl = ConflictRecoveryRemovalControl()
        let fixture = try await makeFailedCheckpointFixture(
            recoveryFileManager: ConflictRecoveryFileManager(
                removalControl: removalControl
            )
        )
        try replaceConflictTestFile(
            at: fixture.fileURL,
            with: Data("Valid external cleanup candidate\n".utf8)
        )
        await fixture.model.reconcilePresentedFile(
            documentID: fixture.documentID
        )
        XCTAssertEqual(fixture.model.activeFileConflict, .contentChanged)
        let stateBeforeReload = fixture.model.state
        let canonicalRecoveryURL = fixture.recoveryRootURL.appendingPathComponent(
            fixture.documentID.rawValue.uuidString.lowercased()
                + ".recovery.json",
            isDirectory: false
        )
        let recoveryBytesBeforeReload = try Data(
            contentsOf: canonicalRecoveryURL
        )
        fixture.checkpointControl.allowFutureValidations()
        removalControl.rejectRemoval(of: canonicalRecoveryURL)

        let didReload = await fixture.model.discardEditsAndReloadCurrentFile()

        XCTAssertFalse(didReload)
        XCTAssertEqual(fixture.model.state, stateBeforeReload)
        XCTAssertEqual(
            fixture.model.recoveryError,
            fixture.failedCheckpointError
        )
        XCTAssertTrue(fixture.model.editorMutationDisabled)
        XCTAssertTrue(fixture.model.fileConflictResolutionIsPresented)
        XCTAssertNotNil(fixture.model.fileConflictError)
        XCTAssertNotEqual(
            fixture.model.fileConflictError,
            fixture.failedCheckpointError
        )
        XCTAssertEqual(
            try Data(contentsOf: canonicalRecoveryURL),
            recoveryBytesBeforeReload
        )
    }

    func testCurrentFileSaveAsFinalAccessorConflictBecomesSticky() async throws {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("SaveAsRace.txt")
        let originalBytes = Data("Save As baseline\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let identityControl = ConflictIdentityControl(
            originalIdentity: FileIdentity(
                volumeUUID: UUID(
                    uuidString: "88000000-0000-0000-0000-000000000001"
                )!,
                documentIdentifier: 88
            ),
            conflictingIdentity: FileIdentity(
                volumeUUID: UUID(
                    uuidString: "88000000-0000-0000-0000-000000000002"
                )!,
                documentIdentifier: 89
            )
        )
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeConflictTestBookmark,
            bookmarkResolver: resolveConflictTestBookmark,
            identityReader: { _ in identityControl.currentIdentity() },
            replacer: replaceConflictTestItem
        )
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let recoveryStore = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: .default
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: recoveryStore,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpen = await model.openTestDocument(selectedURL: fileURL)
        XCTAssertTrue(didOpen)
        let documentID = model.state.activeTab.document.id
        model.editActiveDocument(text: "Save As local edit\n")
        let recoveryWasProtected = try await waitUntilRecoveryIsProtected(model: model)
        XCTAssertTrue(recoveryWasProtected)
        let preparation = try model.prepareDocumentSaveAs(
            fileName: fileURL.lastPathComponent,
            encoding: .utf8
        )
        let optionalPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: filesURL
        )
        let preflight = try XCTUnwrap(optionalPreflight)
        guard case .currentFile = preflight.target else {
            return XCTFail("Bound destination must use current-file Save As.")
        }
        identityControl.useConflictingIdentity()

        let didSave = await model.completePreflightedSaveAs(preflight)

        XCTAssertFalse(didSave)
        XCTAssertEqual(model.activeFileConflict, .stableIdentityChanged)
        XCTAssertTrue(model.fileConflictResolutionIsPresented)
        XCTAssertNil(model.fileSaveError)
        XCTAssertEqual(model.activeText, "Save As local edit\n")
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        let retainedRecovery = try await recoveryStore.load(
            documentID: documentID
        )
        XCTAssertEqual(retainedRecovery?.text, "Save As local edit\n")
    }

    func testCheckpointCompletionPreservesConcurrentPresenterConflictAndBinding() async throws {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("Checkpoint.txt")
        try Data("Original checkpoint baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let checkpointGate = ConflictCheckpointGate()
        let store = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: .default,
            postPromotionValidation: { promotedURL in
                checkpointGate.validate(afterPromoting: promotedURL)
            }
        )
        let connector = FileAccessConnector(fileManager: .default)
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpen = await model.openTestDocument(selectedURL: fileURL)
        XCTAssertTrue(didOpen)
        let documentID = model.state.activeTab.document.id
        model.editActiveDocument(text: "Checkpoint in flight\n")
        await checkpointGate.waitUntilEntered()
        try replaceConflictTestFile(
            at: fileURL,
            with: Data("External while checkpointing\n".utf8)
        )

        await model.reconcilePresentedFile(documentID: documentID)

        XCTAssertEqual(model.activeFileConflict, .contentChanged)
        let reconciledBinding = try XCTUnwrap(
            model.state.activeTab.document.fileBinding
        )
        checkpointGate.resume()
        let recoveryWasProtected = try await waitUntilRecoveryIsProtected(model: model)
        XCTAssertTrue(recoveryWasProtected)

        XCTAssertEqual(model.activeFileConflict, .contentChanged)
        XCTAssertEqual(
            model.state.activeTab.document.fileBinding,
            reconciledBinding
        )
        XCTAssertEqual(model.activeText, "Checkpoint in flight\n")
        let storedCheckpoint = try await store.load(documentID: documentID)
        XCTAssertEqual(storedCheckpoint?.text, "Checkpoint in flight\n")
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            Data("External while checkpointing\n".utf8)
        )
    }

    func testForegroundIntentReplaysAfterInFlightFileActionFinishes() async throws {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent(
            "Destination",
            isDirectory: true
        )
        let recoveryURL = rootURL.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("Lifecycle.txt")
        let originalBytes = Data("Lifecycle original\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let bookmarkGate = ConflictBookmarkGate(blockingURL: destinationURL)
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { url in
                try bookmarkGate.createBookmark(for: url)
            },
            bookmarkResolver: resolveConflictTestBookmark,
            identityReader: { _ in nil },
            replacer: replaceConflictTestItem
        )
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let store = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: .default
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpen = await model.openTestDocument(selectedURL: fileURL)
        XCTAssertTrue(didOpen)
        let documentID = model.state.activeTab.document.id
        let binding = try XCTUnwrap(model.state.activeTab.document.fileBinding)
        await model.sceneBecameInactive()
        XCTAssertFalse(
            NSFileCoordinator.filePresenters.contains(where: { presenter in
                guard let presentedFile = presenter as? PresentedFile else {
                    return false
                }
                return presentedFile.documentID == documentID
            })
        )
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Prepared.txt",
            encoding: .utf8
        )
        let preflightTask = Task { @MainActor in
            await model.preflightDocumentSaveAs(
                preparation: preparation,
                selectedDirectoryURL: destinationURL
            )
        }
        await bookmarkGate.waitUntilEntered()
        XCTAssertTrue(model.fileSaveInProgress)

        await model.sceneBecameActive()
        bookmarkGate.resume()
        let preflight = await preflightTask.value

        XCTAssertNotNil(preflight)
        let presenterWasRegistered = try await waitUntilPresenterIsRegistered(
            documentID: documentID
        )
        XCTAssertTrue(presenterWasRegistered)
        _ = try await connector.reconcilePresentedFile(
            documentID: documentID,
            binding: binding
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationURL
                    .appendingPathComponent("Prepared.txt")
                    .path
            )
        )
    }

    private func makeConflictModelFixture() throws -> ConflictModelFixture {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("Conflict.txt")
        try Data("Original model baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let connector = FileAccessConnector(fileManager: .default)
        addTeardownBlock {
            await connector.pausePresenters()
        }
        return ConflictModelFixture(
            fileURL: fileURL,
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryURL,
                fileManager: .default
            ),
            connector: connector
        )
    }

    private func makeBoundSaveCleanupRaceFixture() async throws
        -> BoundSaveCleanupRaceFixture {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("CleanupRace.txt")
        try Data("Cleanup race baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let cleanupFailureControl = ConflictBoundSaveCleanupFailureControl()
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeConflictTestBookmark,
            bookmarkResolver: resolveConflictTestBookmark,
            identityReader: { _ in nil },
            replacer: { originalURL, stagingURL, fileManager in
                try cleanupFailureControl.replaceAndCorruptRecovery(
                    originalURL: originalURL,
                    stagingURL: stagingURL,
                    fileManager: fileManager
                )
            }
        )
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let recoveryStore = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: .default
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: recoveryStore,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        guard await model.openTestDocument(selectedURL: fileURL) else {
            throw ConflictAppModelFixtureError.fileOpenFailed
        }
        let documentID = model.state.activeTab.document.id
        cleanupFailureControl.configure(
            recoveryURL: recoveryURL.appendingPathComponent(
                documentID.rawValue.uuidString.lowercased()
                    + ".recovery.json",
                isDirectory: false
            )
        )
        let savedText = "Verified PhonePad save\n"
        model.editActiveDocument(text: savedText)
        guard try await waitUntilRecoveryIsProtected(model: model) else {
            throw ConflictAppModelFixtureError.checkpointProtectionFailed
        }
        return BoundSaveCleanupRaceFixture(
            fileURL: fileURL,
            model: model,
            documentID: documentID,
            savedText: savedText,
            savedBytes: Data(savedText.utf8),
            cleanupFailureControl: cleanupFailureControl
        )
    }

    private func makeNestedCleanupConflictFixture() async throws
        -> NestedCleanupConflictFixture {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("NestedConflict.txt")
        try Data("Nested conflict baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let externalBytes = Data("Nested external edit\n".utf8)
        let failureControl = ConflictNestedCleanupFailureControl(
            externalBytes: externalBytes
        )
        let connector = FileAccessConnector(
            fileManager: ConflictReplacementStagingFileManager(
                failureControl: failureControl
            ),
            bookmarkCreator: makeConflictTestBookmark,
            bookmarkResolver: resolveConflictTestBookmark,
            identityReader: { url in
                try failureControl.readIdentity(at: url)
            },
            replacer: replaceConflictTestItem
        )
        addTeardownBlock {
            await connector.pausePresenters()
            try failureControl.removeCleanupBlocker()
        }
        let recoveryStore = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: .default
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: recoveryStore,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        guard await model.openTestDocument(selectedURL: fileURL) else {
            throw ConflictAppModelFixtureError.fileOpenFailed
        }
        let documentID = model.state.activeTab.document.id
        let editedText = "Protected nested-conflict edit\n"
        model.editActiveDocument(text: editedText)
        guard try await waitUntilRecoveryIsProtected(model: model) else {
            throw ConflictAppModelFixtureError.checkpointProtectionFailed
        }
        return NestedCleanupConflictFixture(
            filesURL: filesURL,
            fileURL: fileURL,
            recoveryStore: recoveryStore,
            model: model,
            documentID: documentID,
            editedText: editedText,
            externalBytes: externalBytes,
            failureControl: failureControl
        )
    }

    private func assertNestedCleanupConflictIsSticky(
        fixture: NestedCleanupConflictFixture
    ) async throws {
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.model.activeFileConflict, .contentChanged)
        XCTAssertTrue(fixture.model.fileConflictResolutionIsPresented)
        XCTAssertNil(fixture.model.fileSaveError)
        XCTAssertEqual(fixture.model.activeText, fixture.editedText)
        XCTAssertTrue(fixture.model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            fixture.externalBytes
        )
        let recovery = try await fixture.recoveryStore.load(
            documentID: fixture.documentID
        )
        XCTAssertEqual(recovery?.text, fixture.editedText)
    }

    private func makeFailedCheckpointFixture(
        recoveryFileManager: sending FileManager
    ) async throws -> FailedCheckpointFixture {
        let rootURL = try makeConflictModelRoot()
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("FailedCheckpoint.txt")
        try Data("Failed-checkpoint baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let checkpointControl = ConflictCheckpointFailureControl()
        let recoveryStore = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: recoveryFileManager,
            postPromotionValidation: { promotedURL in
                try checkpointControl.validate(afterPromoting: promotedURL)
            }
        )
        let connector = FileAccessConnector(fileManager: .default)
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: recoveryStore,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        guard await model.openTestDocument(selectedURL: fileURL) else {
            throw ConflictAppModelFixtureError.fileOpenFailed
        }
        let documentID = model.state.activeTab.document.id
        model.editActiveDocument(text: "Earlier protected edit\n")
        guard try await waitUntilRecoveryIsProtected(model: model) else {
            throw ConflictAppModelFixtureError.checkpointProtectionFailed
        }
        let retainedRecovery = try await recoveryStore.load(
            documentID: documentID
        )
        guard retainedRecovery != nil else {
            throw ConflictAppModelFixtureError.checkpointMissing
        }
        checkpointControl.rejectFutureValidations()
        model.editActiveDocument(text: "Latest failed-checkpoint edit\n")
        guard try await waitUntilRecoveryHasFailed(model: model),
              let failedCheckpointError = model.recoveryError else {
            throw ConflictAppModelFixtureError.checkpointFailureMissing
        }
        return FailedCheckpointFixture(
            fileURL: fileURL,
            recoveryRootURL: recoveryURL,
            recoveryStore: recoveryStore,
            connector: connector,
            model: model,
            documentID: documentID,
            retainedRecovery: retainedRecovery,
            failedCheckpointError: failedCheckpointError,
            checkpointControl: checkpointControl
        )
    }

    private func makeConflictModel(
        fixture: ConflictModelFixture
    ) -> PhonePadAppModel {
        PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: fixture.recoveryStore,
            fileAccessConnector: fixture.connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
    }

    private func makeConflictModelRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        return rootURL
    }
}

private extension PhonePadAppModel {
    func openTestDocument(selectedURL: URL) async -> Bool {
        let document = state.activeTab.document
        return await openDocument(
            selectedURL: selectedURL,
            after: CommittedEditorDocument(
                documentID: document.id,
                text: document.text
            )
        )
    }
}

private struct ConflictModelFixture {
    let fileURL: URL
    let recoveryStore: FileRecoveryStore
    let connector: FileAccessConnector
}

private struct FailedCheckpointFixture {
    let fileURL: URL
    let recoveryRootURL: URL
    let recoveryStore: FileRecoveryStore
    let connector: FileAccessConnector
    let model: PhonePadAppModel
    let documentID: DocumentID
    let retainedRecovery: RecoveryEnvelope?
    let failedCheckpointError: String
    let checkpointControl: ConflictCheckpointFailureControl
}

private struct BoundSaveCleanupRaceFixture {
    let fileURL: URL
    let model: PhonePadAppModel
    let documentID: DocumentID
    let savedText: String
    let savedBytes: Data
    let cleanupFailureControl: ConflictBoundSaveCleanupFailureControl
}

private struct NestedCleanupConflictFixture {
    let filesURL: URL
    let fileURL: URL
    let recoveryStore: FileRecoveryStore
    let model: PhonePadAppModel
    let documentID: DocumentID
    let editedText: String
    let externalBytes: Data
    let failureControl: ConflictNestedCleanupFailureControl
}

private enum ConflictAppModelFixtureError: Error {
    case fileOpenFailed
    case checkpointProtectionFailed
    case checkpointMissing
    case checkpointFailureMissing
    case recoveryURLMissing
    case recoverySnapshotMissing
}

private enum InjectedCheckpointValidationError: Error {
    case rejected
}

private final class ConflictCheckpointFailureControl: @unchecked Sendable {
    private let lock = NSLock()
    private var rejectsValidation: Bool = false

    func rejectFutureValidations() {
        lock.withLock {
            rejectsValidation = true
        }
    }

    func allowFutureValidations() {
        lock.withLock {
            rejectsValidation = false
        }
    }

    func validate(afterPromoting _: URL) throws {
        let shouldReject = lock.withLock { rejectsValidation }
        if shouldReject {
            throw InjectedCheckpointValidationError.rejected
        }
    }
}

private final class ConflictRecoveryRemovalControl: @unchecked Sendable {
    private let lock = NSLock()
    private var rejectedRemovalURL: URL?

    func rejectRemoval(of url: URL) {
        lock.withLock {
            rejectedRemovalURL = url.standardizedFileURL
        }
    }

    func shouldRejectRemoval(of url: URL) -> Bool {
        lock.withLock {
            rejectedRemovalURL == url.standardizedFileURL
        }
    }
}

private final class ConflictRecoveryFileManager: FileManager, @unchecked Sendable {
    private let removalControl: ConflictRecoveryRemovalControl

    init(removalControl: ConflictRecoveryRemovalControl) {
        self.removalControl = removalControl
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if removalControl.shouldRejectRemoval(of: url) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

private final class ConflictBoundSaveCleanupFailureControl: @unchecked Sendable {
    private let lock = NSLock()
    private var recoveryURL: URL?
    private var recoverySnapshot: Data?

    func configure(recoveryURL: URL) {
        lock.withLock {
            self.recoveryURL = recoveryURL
        }
    }

    func replaceAndCorruptRecovery(
        originalURL: URL,
        stagingURL: URL,
        fileManager: FileManager
    ) throws -> URL? {
        let replacementURL = try replaceConflictTestItem(
            originalURL: originalURL,
            stagingURL: stagingURL,
            fileManager: fileManager
        )
        guard let recoveryURL = lock.withLock({ recoveryURL }) else {
            throw ConflictAppModelFixtureError.recoveryURLMissing
        }
        let snapshot = try Data(contentsOf: recoveryURL)
        lock.withLock {
            recoverySnapshot = snapshot
        }
        try replaceConflictTestFile(
            at: recoveryURL,
            with: Data("corrupt recovery".utf8)
        )
        return replacementURL
    }

    func restoreRecovery() throws {
        let restoration: (URL, Data)? = lock.withLock {
            guard let recoveryURL, let recoverySnapshot else {
                return nil
            }
            return (recoveryURL, recoverySnapshot)
        }
        guard let (recoveryURL, recoverySnapshot) = restoration else {
            throw ConflictAppModelFixtureError.recoverySnapshotMissing
        }
        try replaceConflictTestFile(
            at: recoveryURL,
            with: recoverySnapshot
        )
    }
}

private final class ConflictNestedCleanupFailureControl: @unchecked Sendable {
    private let externalBytes: Data
    private let lock = NSLock()
    private var isArmed: Bool = false
    private var cleanupDirectoryURL: URL?
    private var cleanupBlockerURL: URL?

    init(externalBytes: Data) {
        self.externalBytes = externalBytes
    }

    func arm() {
        lock.withLock {
            isArmed = true
        }
    }

    func readIdentity(at url: URL) throws -> FileIdentity? {
        let shouldInjectConflict = lock.withLock { isArmed }
        guard shouldInjectConflict else {
            return nil
        }
        try replaceConflictTestFile(at: url, with: externalBytes)
        throw FileAccessConnectorError.fileConflict(.contentChanged)
    }

    func blockCleanup(in directoryURL: URL) throws {
        let blockerURL = directoryURL.appendingPathComponent(
            "cleanup-blocker",
            isDirectory: false
        )
        try Data("retain".utf8).write(
            to: blockerURL,
            options: .withoutOverwriting
        )
        lock.withLock {
            cleanupDirectoryURL = directoryURL
            cleanupBlockerURL = blockerURL
        }
    }

    func removeCleanupBlocker() throws {
        let locations: (URL?, URL?) = lock.withLock {
            (cleanupDirectoryURL, cleanupBlockerURL)
        }
        if let blockerURL = locations.1,
           FileManager.default.fileExists(atPath: blockerURL.path) {
            try FileManager.default.removeItem(at: blockerURL)
        }
        if let directoryURL = locations.0,
           FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }
}

private final class ConflictReplacementStagingFileManager: FileManager,
    @unchecked Sendable {
    private let failureControl: ConflictNestedCleanupFailureControl

    init(failureControl: ConflictNestedCleanupFailureControl) {
        self.failureControl = failureControl
        super.init()
    }

    override func url(
        for directory: SearchPathDirectory,
        in domain: SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        let directoryURL = try super.url(
            for: directory,
            in: domain,
            appropriateFor: url,
            create: shouldCreate
        )
        if directory == .itemReplacementDirectory {
            try failureControl.blockCleanup(in: directoryURL)
        }
        return directoryURL
    }
}

private final class ConflictIdentityControl: @unchecked Sendable {
    private let originalIdentity: FileIdentity
    private let conflictingIdentity: FileIdentity
    private let lock = NSLock()
    private var usesConflictingIdentity: Bool = false

    init(
        originalIdentity: FileIdentity,
        conflictingIdentity: FileIdentity
    ) {
        self.originalIdentity = originalIdentity
        self.conflictingIdentity = conflictingIdentity
    }

    func useConflictingIdentity() {
        lock.withLock {
            usesConflictingIdentity = true
        }
    }

    func currentIdentity() -> FileIdentity {
        lock.withLock {
            usesConflictingIdentity ? conflictingIdentity : originalIdentity
        }
    }
}

private final class ConflictCheckpointGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didEnter: Bool = false
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func validate(afterPromoting _: URL) {
        let continuation = lock.withLock {
            didEnter = true
            let continuation = entryContinuation
            entryContinuation = nil
            return continuation
        }
        continuation?.resume()
        release.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if didEnter {
                    return true
                }
                precondition(entryContinuation == nil)
                entryContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        release.signal()
    }
}

private final class ConflictBookmarkGate: @unchecked Sendable {
    private let blockingURL: URL
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didEnter: Bool = false
    private var entryContinuation: CheckedContinuation<Void, Never>?

    init(blockingURL: URL) {
        self.blockingURL = blockingURL.standardizedFileURL
    }

    func createBookmark(for url: URL) throws -> Data {
        guard url.standardizedFileURL == blockingURL else {
            return try makeConflictTestBookmark(url: url)
        }
        let continuation = lock.withLock {
            didEnter = true
            let continuation = entryContinuation
            entryContinuation = nil
            return continuation
        }
        continuation?.resume()
        release.wait()
        return try makeConflictTestBookmark(url: url)
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if didEnter {
                    return true
                }
                precondition(entryContinuation == nil)
                entryContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        release.signal()
    }
}

@MainActor
private func waitUntilRecoveryIsProtected(
    model: PhonePadAppModel
) async throws -> Bool {
    for _ in 0 ..< 100 {
        if model.state.activeTab.document.recoveryState == .protectedUnsaved {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
private func waitUntilRecoveryHasFailed(
    model: PhonePadAppModel
) async throws -> Bool {
    for _ in 0 ..< 100 {
        if model.recoveryError != nil,
           model.editorMutationDisabled {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func waitUntilPresenterIsRegistered(
    documentID: DocumentID
) async throws -> Bool {
    for _ in 0 ..< 100 {
        if NSFileCoordinator.filePresenters.contains(where: { presenter in
            guard let presentedFile = presenter as? PresentedFile else {
                return false
            }
            return presentedFile.documentID == documentID
        }) {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func waitUntilPresenterUsesLocator(
    documentID: DocumentID,
    locatorURL: URL
) async throws -> Bool {
    for _ in 0 ..< 100 {
        if registeredConflictPresentedFile(documentID: documentID)?
            .currentPresentedItemURL()
            .standardizedFileURL == locatorURL.standardizedFileURL {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
private func waitUntilActiveConflict(
    model: PhonePadAppModel,
    expectedConflict: FileConflict
) async throws -> Bool {
    for _ in 0 ..< 100 {
        if model.activeFileConflict == expectedConflict {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func registeredConflictPresentedFile(
    documentID: DocumentID
) -> PresentedFile? {
    NSFileCoordinator.filePresenters.compactMap { presenter in
        presenter as? PresentedFile
    }
    .first(where: { presenter in
        presenter.documentID == documentID
    })
}

private func replaceConflictTestFile(at url: URL, with data: Data) throws {
    try data.write(to: url, options: [])
}

private func makeConflictTestBookmark(url: URL) throws -> Data {
    try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}

private func resolveConflictTestBookmark(
    bookmark: FileBookmark
) throws -> ResolvedFileBookmark {
    var isStale = false
    let url = try URL(
        resolvingBookmarkData: bookmark.data,
        options: [.withoutUI, .withoutImplicitStartAccessing],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
    )
    return ResolvedFileBookmark(url: url, isStale: isStale)
}

private func replaceConflictTestItem(
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
