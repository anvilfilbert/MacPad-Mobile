import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadExternalOpenAppModelTests: XCTestCase {
    func testColdDurableExternalOpenReplacesUntitledWithBoundDocument() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Durable.txt",
            text: "Durable external content\n",
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }

        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .inPlace
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.model.state.tabs.count, 1)
        XCTAssertEqual(fixture.model.state.activeTab.document.title, "Durable.txt")
        XCTAssertEqual(
            fixture.model.state.activeTab.document.text,
            "Durable external content\n"
        )
        XCTAssertNotNil(fixture.model.state.activeTab.document.fileBinding)
        XCTAssertFalse(fixture.model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .clean
        )
        XCTAssertNil(fixture.model.pendingExternalOpenRecoveryPrompt)
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testColdReadOnlyExternalOpenIsProtectedUnsavedAndRequiresSaveAs() async throws {
        let openedText = "Read-only external content\n"
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Read Only.txt",
            text: openedText,
            isWritable: false
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }

        let earliestEditedAt = Date()
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .inPlace
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )
        let latestEditedAt = Date()

        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.model.state.tabs.count, 1)
        XCTAssertEqual(fixture.model.state.activeTab.document.title, "Read Only.txt")
        XCTAssertEqual(
            fixture.model.state.activeTab.document.text,
            openedText
        )
        XCTAssertNil(fixture.model.state.activeTab.document.fileBinding)
        XCTAssertTrue(fixture.model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        let documentID = fixture.model.state.activeTab.document.id
        let envelope = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        let storedEnvelope = try XCTUnwrap(envelope)
        let decodedFile = try decodeSupportedTextFile(data: Data(openedText.utf8))
        let expectedReference = RecoveryFileReference(
            bookmark: try FileBookmark(
                data: makeExternalOpenBookmark(url: fixture.fileURL)
            ),
            identity: nil,
            displayName: try ValidatedFileName(validating: "Read Only.txt"),
            cleanDigest: decodedFile.digest,
            encoding: decodedFile.encoding,
            lineEnding: decodedFile.lineEnding
        )
        let expectedEnvelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Read Only.txt",
            text: openedText,
            editedAt: storedEnvelope.editedAt,
            fileReference: expectedReference,
            pendingSave: nil
        )
        XCTAssertEqual(storedEnvelope, expectedEnvelope)
        XCTAssertGreaterThanOrEqual(storedEnvelope.editedAt, earliestEditedAt)
        XCTAssertLessThanOrEqual(storedEnvelope.editedAt, latestEditedAt)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryFileReference,
            expectedReference
        )
        XCTAssertFalse(fixture.connectorHasPresenter(documentID: documentID))
        XCTAssertNil(fixture.model.state.activeTab.document.fileBinding)
    }

    func testQueuedExternalOpenRejectsRecoveryMutationWithoutChangingState() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Protected.txt",
            text: "External source content\n",
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let recoveryDocumentID = DocumentID(rawValue: UUID())
        let recoveryEnvelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fixture.fileURL,
            documentID: recoveryDocumentID,
            title: "Protected edits.txt",
            text: "Preserved edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: fixture.recoveryStore
        )
        await fixture.model.refreshRecoveryItems()
        XCTAssertTrue(fixture.model.recoveryItems.contains { item in
            item.documentID == recoveryDocumentID
        })

        let initialState = fixture.model.state
        let initialRecoveryItems = fixture.model.recoveryItems
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .inPlace
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        fixture.model.reportExternalOpenCommitFailure(
            commitRequestID: commitRequestID,
            error: ExternalOpenTestError.editorCommitFailed
        )
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertTrue(fixture.model.fileMutationDisabled)

        let recovered = await fixture.model.recoverRecovery(
            documentID: recoveryDocumentID,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertFalse(recovered)
        XCTAssertEqual(fixture.model.state, initialState)
        XCTAssertEqual(fixture.model.recoveryItems, initialRecoveryItems)
        XCTAssertNotNil(fixture.model.externalOpenError)
        XCTAssertNotNil(fixture.model.recoveryCatalogError)
        let retainedEnvelope = try await fixture.recoveryStore.load(
            documentID: recoveryDocumentID
        )
        XCTAssertEqual(retainedEnvelope, recoveryEnvelope)
    }

    func testRecoveryPromptRejectsTabMutationWithoutChangingState() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Prompted.txt",
            text: "Prompted external content\n",
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let recoveryDocumentID = DocumentID(rawValue: UUID())
        let recoveryEnvelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fixture.fileURL,
            documentID: recoveryDocumentID,
            title: "Prompted edits.txt",
            text: "Preserved prompted edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_150)
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: fixture.recoveryStore
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .inPlace
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )

        let prompted = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )
        let prompt = try XCTUnwrap(
            fixture.model.pendingExternalOpenRecoveryPrompt
        )
        let promptedState = fixture.model.state

        XCTAssertTrue(prompted)
        XCTAssertEqual(prompt.recoveryDocumentID, recoveryDocumentID)
        XCTAssertTrue(fixture.model.fileMutationDisabled)
        XCTAssertTrue(fixture.model.editorMutationDisabled)

        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertFalse(createdTab)
        XCTAssertEqual(fixture.model.state, promptedState)
        XCTAssertEqual(
            fixture.model.pendingExternalOpenRecoveryPrompt,
            prompt
        )
        XCTAssertNotNil(fixture.model.tabTransitionError)
        let retainedEnvelope = try await fixture.recoveryStore.load(
            documentID: recoveryDocumentID
        )
        XCTAssertEqual(retainedEnvelope, recoveryEnvelope)
    }

    func testPendingInboxRecoveryPromptCleanupSurvivesTermination() async throws {
        let fixture = try makeInboxExternalOpenModelFixture(
            fileName: "Interrupted Prompt.txt",
            text: "Prompted imported content\n",
            isWritable: true
        )
        let recoveryDocumentID = DocumentID(rawValue: UUID())
        let recoveryEnvelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fixture.fileURL,
            documentID: recoveryDocumentID,
            title: "Interrupted prompted edits.txt",
            text: "Protected prompted edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_175)
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: fixture.recoveryStore
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let prompted = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )
        XCTAssertTrue(prompted)
        XCTAssertEqual(
            fixture.model.pendingExternalOpenRecoveryPrompt?
                .recoveryDocumentID,
            recoveryDocumentID
        )

        let recreatedConnector = makeExternalOpenConnector(
            applicationInboxURL: fixture.fileURL.deletingLastPathComponent(),
            isWritable: true
        )
        let recreatedModel = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: fixture.recoveryStore,
            fileAccessConnector: recreatedConnector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            await recreatedConnector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }

        await recreatedModel.sceneBecameActive()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertFalse(recreatedModel.externalOpenCleanupRequired)
        XCTAssertNil(recreatedModel.externalOpenError)
        XCTAssertNil(recreatedModel.externalOpenNotice)
        let retainedEnvelope = try await fixture.recoveryStore.load(
            documentID: recoveryDocumentID
        )
        XCTAssertEqual(
            retainedEnvelope,
            recoveryEnvelope
        )
    }

    func testQueuedInboxCleanupSurvivesTerminationBeforeEditorCommit() async throws {
        let fixture = try makeInboxExternalOpenModelFixture(
            fileName: "Queued Before Commit.txt",
            text: "Queued imported content\n",
            isWritable: true
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        XCTAssertNotNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )

        let recreatedConnector = makeExternalOpenConnector(
            applicationInboxURL: fixture.fileURL.deletingLastPathComponent(),
            isWritable: true
        )
        let recreatedModel = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: fixture.recoveryStore,
            fileAccessConnector: recreatedConnector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            await recreatedConnector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }

        await recreatedModel.sceneBecameActive()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertFalse(recreatedModel.externalOpenCleanupRequired)
        XCTAssertNil(recreatedModel.externalOpenError)
        XCTAssertNil(recreatedModel.externalOpenNotice)
    }

    func testFailedInboxRecoveryRevalidationRetainsAllCleanupUntilCancel() async throws {
        let originalText = "First imported copy\n"
        let replacementText = "Second imported copy\n"
        let fixture = try makeInboxExternalOpenModelFixture(
            fileName: "Imported.txt",
            text: originalText,
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let recoveryDocumentID = DocumentID(rawValue: UUID())
        let recoveryEnvelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fixture.fileURL,
            documentID: recoveryDocumentID,
            title: "Imported edits.txt",
            text: "Preserved imported edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: fixture.recoveryStore
        )
        let initialState = fixture.model.state
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let prompted = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertTrue(prompted)
        XCTAssertEqual(
            fixture.model.pendingExternalOpenRecoveryPrompt?
                .recoveryDocumentID,
            recoveryDocumentID
        )
        XCTAssertEqual(fixture.model.state, initialState)

        let retainedOriginalURL = fixture.rootURL.appendingPathComponent(
            "Retained Imported.txt",
            isDirectory: false
        )
        try FileManager.default.moveItem(
            at: fixture.fileURL,
            to: retainedOriginalURL
        )
        try Data(replacementText.utf8).write(
            to: fixture.fileURL,
            options: .withoutOverwriting
        )
        let discardOutcome = try await fixture.recoveryStore.discardRecovery(
            documentID: recoveryDocumentID
        )
        XCTAssertEqual(discardOutcome, .complete)

        let recovered = await fixture.model.recoverPendingExternalOpen()

        XCTAssertFalse(recovered)
        XCTAssertEqual(fixture.model.state, initialState)
        XCTAssertNotNil(fixture.model.pendingExternalOpenRecoveryPrompt)
        XCTAssertNotNil(fixture.model.externalOpenError)
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data(replacementText.utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedOriginalURL),
            Data(originalText.utf8)
        )

        await fixture.model.cancelPendingExternalOpen()

        XCTAssertNil(fixture.model.pendingExternalOpenRecoveryPrompt)
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data(replacementText.utf8)
        )
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
        XCTAssertNil(fixture.model.externalOpenNotice)
        XCTAssertTrue(fixture.model.externalOpenErrorRequiresDismissal)
        XCTAssertEqual(
            fixture.model.externalOpenError,
            FileAccessConnectorError
                .importedCopyCleanupCandidateChanged
                .localizedDescription
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedOriginalURL),
            Data(originalText.utf8)
        )

        let cleaned = await fixture.model.retryExternalOpenCleanup()

        XCTAssertFalse(cleaned)
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
    }

    func testFailedDetachedInboxCheckpointDefersCleanupUntilRecoveryRepair() async throws {
        let openedText = "Checkpoint-protected import\n"
        let validationGate = ExternalOpenCheckpointValidationGate()
        let fixture = try makeFailingInboxExternalOpenModelFixture(
            fileName: "Deferred Cleanup.txt",
            text: openedText,
            validationGate: validationGate
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let followingURL = fixture.rootURL.appendingPathComponent(
            "Following Deferred Cleanup.txt",
            isDirectory: false
        )
        try Data("Following queued content\n".utf8).write(
            to: followingURL,
            options: .withoutOverwriting
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
            PhonePadExternalOpenRequest(
                url: followingURL,
                accessIntent: .inPlace
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )

        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertFalse(opened)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .checkpointPending
        )
        XCTAssertNotNil(fixture.model.recoveryError)
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data(openedText.utf8)
        )
        let cleanedBeforeProtection = await fixture.model
            .retryExternalOpenCleanup()
        XCTAssertFalse(cleanedBeforeProtection)
        XCTAssertNotNil(fixture.model.externalOpenError)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data(openedText.utf8)
        )

        validationGate.repair()
        await fixture.model.sceneBecameInactive()

        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertNil(fixture.model.recoveryError)
        XCTAssertNil(fixture.model.externalOpenError)
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertTrue(
            fixture.model.externalOpenNotice?.contains(
                "Opened supplied File copy as a protected unsaved Document. Use Save As to choose a durable location."
            ) == true
        )
        let storedEnvelope = try await fixture.recoveryStore.load(
            documentID: fixture.model.state.activeTab.document.id
        )
        XCTAssertEqual(storedEnvelope?.text, openedText)

        await fixture.model.sceneBecameActive()
        XCTAssertNotNil(fixture.model.externalOpenCommitRequestID)
    }

    func testCancelAfterPreOpenCheckpointFailureCleansCapturedInboxCopy() async throws {
        let validationGate = ExternalOpenCheckpointValidationGate()
        let fixture = try makeFailingInboxExternalOpenModelFixture(
            fileName: "Pre-Open Failure.txt",
            text: "Imported copy pending Open\n",
            validationGate: validationGate
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        fixture.model.editActiveDocument(text: "Unprotected current edits\n")
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .checkpointPending
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )

        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertFalse(opened)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )

        await fixture.model.cancelPendingExternalOpen()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
    }

    func testCancelAfterEditorCommitFailureRefusesReplacedInboxItem() async throws {
        let originalText = "Original queued Inbox copy\n"
        let replacementText = "Replacement Inbox copy\n"
        let fixture = try makeInboxExternalOpenModelFixture(
            fileName: "Commit Failure Replacement.txt",
            text: originalText,
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        fixture.model.reportExternalOpenCommitFailure(
            commitRequestID: commitRequestID,
            error: NSError(domain: "EditorCommit", code: 934)
        )
        let retainedOriginalURL = fixture.rootURL.appendingPathComponent(
            "Retained Commit Failure Replacement.txt",
            isDirectory: false
        )
        try FileManager.default.moveItem(
            at: fixture.fileURL,
            to: retainedOriginalURL
        )
        try Data(replacementText.utf8).write(
            to: fixture.fileURL,
            options: .withoutOverwriting
        )

        await fixture.model.cancelPendingExternalOpen()

        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data(replacementText.utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedOriginalURL),
            Data(originalText.utf8)
        )
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
        XCTAssertEqual(
            fixture.model.externalOpenError,
            FileAccessConnectorError
                .importedCopyCleanupCandidateChanged
                .localizedDescription
        )
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
    }

    func testManualOpenUsesTypedReadOnlyDetachmentPath() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Manual Read Only.txt",
            text: "Manual read-only content\n",
            isWritable: false
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }

        let opened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.model.state.tabs.count, 1)
        XCTAssertNil(fixture.model.state.activeTab.document.fileBinding)
        XCTAssertNotNil(
            fixture.model.state.activeTab.document.recoveryFileReference
        )
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertNotNil(fixture.model.externalOpenNotice)

        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        XCTAssertNil(fixture.model.externalOpenNotice)
    }

    func testManualOpenUsesExternalRecoveryDecisionPath() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Manual Recovery.txt",
            text: "Current File content\n",
            isWritable: false
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let recoveryDocumentID = DocumentID(rawValue: UUID())
        let recoveryEnvelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fixture.fileURL,
            documentID: recoveryDocumentID,
            title: "Manual preserved edits.txt",
            text: "Preserved manual edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_250)
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: fixture.recoveryStore
        )
        let initialState = fixture.model.state

        let prompted = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(prompted)
        XCTAssertEqual(fixture.model.state, initialState)
        XCTAssertEqual(
            fixture.model.pendingExternalOpenRecoveryPrompt?
                .recoveryDocumentID,
            recoveryDocumentID
        )
        XCTAssertTrue(fixture.model.fileMutationDisabled)
        XCTAssertTrue(fixture.model.editorMutationDisabled)

        let recovered = await fixture.model.recoverPendingExternalOpen()

        XCTAssertTrue(recovered)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            recoveryDocumentID
        )
        XCTAssertEqual(
            fixture.model.externalOpenNotice,
            "Opened read-only File as a protected unsaved Document. Use Save As to choose a writable location."
        )
    }

    func testRecoveredExternalOpenPrunesCatalogAndRejectsCatalogActionsForOpenDocument() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Catalog Recovery.txt",
            text: "Current catalog File content\n",
            isWritable: false
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let recoveryDocumentID = DocumentID(rawValue: UUID())
        let recoveryEnvelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fixture.fileURL,
            documentID: recoveryDocumentID,
            title: "Catalog preserved edits.txt",
            text: "Protected catalog edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_275)
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: fixture.recoveryStore
        )
        await fixture.model.refreshRecoveryItems()
        XCTAssertTrue(fixture.model.recoveryItems.contains { item in
            item.documentID == recoveryDocumentID
        })

        let prompted = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(prompted)
        let recovered = await fixture.model.recoverPendingExternalOpen()

        XCTAssertTrue(recovered)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            recoveryDocumentID
        )
        XCTAssertFalse(fixture.model.recoveryItems.contains { item in
            item.documentID == recoveryDocumentID
        })
        let recoveredState = fixture.model.state

        let discardedOpenDocument = await fixture.model.discardRecovery(
            documentID: recoveryDocumentID
        )
        XCTAssertFalse(discardedOpenDocument)
        XCTAssertEqual(fixture.model.state, recoveredState)
        XCTAssertNotNil(fixture.model.recoveryCatalogError)
        let envelopeAfterRejectedDiscard = try await fixture.recoveryStore.load(
            documentID: recoveryDocumentID
        )
        XCTAssertEqual(envelopeAfterRejectedDiscard, recoveryEnvelope)

        let recoveredOpenDocument = await fixture.model.recoverRecovery(
            documentID: recoveryDocumentID,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertFalse(recoveredOpenDocument)
        XCTAssertEqual(fixture.model.state, recoveredState)
        XCTAssertEqual(fixture.model.state.tabs.count, 1)
        let envelopeAfterRejectedRecover = try await fixture.recoveryStore.load(
            documentID: recoveryDocumentID
        )
        XCTAssertEqual(envelopeAfterRejectedRecover, recoveryEnvelope)
    }

    func testOpenPendingSaveAsDestinationOwnedByActiveRecoveryActivatesExistingTabWithoutPrompt() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let sourceURL = filesURL.appendingPathComponent("Source.txt")
        let destinationURL = filesURL.appendingPathComponent("Pending.txt")
        let sourceText = "Original source content\n"
        let destinationText = "Pending Save As output\n"
        try Data(sourceText.utf8).write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        try Data(destinationText.utf8).write(
            to: destinationURL,
            options: .withoutOverwriting
        )
        let sourceFile = try decodeSupportedTextFile(
            data: Data(sourceText.utf8)
        )
        let destinationFile = try decodeSupportedTextFile(
            data: Data(destinationText.utf8)
        )
        let documentID = DocumentID(rawValue: UUID())
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Protected pending Save As.txt",
            text: "Protected unsaved edits\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_274),
            fileReference: RecoveryFileReference(
                bookmark: try FileBookmark(
                    data: makeExternalOpenBookmark(url: sourceURL)
                ),
                identity: nil,
                displayName: try ValidatedFileName(
                    validating: sourceURL.lastPathComponent
                ),
                cleanDigest: sourceFile.digest,
                encoding: sourceFile.encoding,
                lineEnding: sourceFile.lineEnding
            ),
            pendingSave: RecoveryPendingSave(
                intendedOutputDigest: destinationFile.digest,
                destination: .saveAs(
                    RecoverySaveAsDestination(
                        directoryBookmark: try FileBookmark(
                            data: makeExternalOpenBookmark(url: filesURL)
                        ),
                        fileName: try ValidatedFileName(
                            validating: destinationURL.lastPathComponent
                        )
                    )
                )
            )
        )
        let recoveryStore = FileRecoveryStore(
            rootURL: externalOpenRecoveryURL(rootURL: rootURL),
            fileManager: .default
        )
        let connector = makeExternalOpenConnector(
            applicationInboxURL: nil,
            isWritable: true
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
        addTeardownBlock {
            await connector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }
        try await protectRecoveryEnvelope(
            envelope: envelope,
            recoveryStore: recoveryStore
        )
        await model.refreshRecoveryItems()
        let recovered = await model.recoverRecovery(
            documentID: documentID,
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.state.activeTab.document.id, documentID)
        let tabCount = model.state.tabs.count
        let retainedBeforeOpen = try await recoveryStore.load(
            documentID: documentID
        )

        let opened = await model.openDocument(
            selectedURL: destinationURL,
            after: committedActiveDocument(model: model)
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(model.state.tabs.count, tabCount)
        XCTAssertEqual(model.state.activeTab.document.id, documentID)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertNil(model.pendingExternalOpenRecoveryPrompt)
        let retainedAfterOpen = try await recoveryStore.load(
            documentID: documentID
        )
        XCTAssertEqual(retainedAfterOpen, retainedBeforeOpen)
        XCTAssertNil(model.externalOpenError)
    }

    func testDiscardAndOpenExternalRecoveryPrunesCatalog() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Catalog Discard.txt",
            text: "Current discarded catalog File content\n",
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let recoveryDocumentID = DocumentID(rawValue: UUID())
        let recoveryEnvelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fixture.fileURL,
            documentID: recoveryDocumentID,
            title: "Discarded catalog edits.txt",
            text: "Discard this protected catalog work\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_276)
        )
        try await protectRecoveryEnvelope(
            envelope: recoveryEnvelope,
            recoveryStore: fixture.recoveryStore
        )
        await fixture.model.refreshRecoveryItems()
        XCTAssertTrue(fixture.model.recoveryItems.contains { item in
            item.documentID == recoveryDocumentID
        })

        let prompted = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(prompted)
        let opened = await fixture.model
            .discardRecoveryAndOpenPendingExternalOpen()

        XCTAssertTrue(opened)
        XCTAssertFalse(fixture.model.recoveryItems.contains { item in
            item.documentID == recoveryDocumentID
        })
        let discardedEnvelope = try await fixture.recoveryStore.load(
            documentID: recoveryDocumentID
        )
        XCTAssertNil(discardedEnvelope)
    }

    func testBookmarkFailurePublishesSpecificSaveAsNotice() async throws {
        let bookmarkFailureCode = 731
        let fixture = try makeBookmarkFailureExternalOpenModelFixture(
            fileName: "Bookmark Failure.txt",
            text: "Detached after bookmark failure\n",
            bookmarkFailureCode: bookmarkFailureCode
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }

        let opened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(opened)
        XCTAssertNil(fixture.model.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            fixture.model.externalOpenNotice,
            "Opened File as a protected unsaved Document because durable access could not be created (system code 731). Use Save As to choose a durable location."
        )
    }

    func testRepeatedBoundLocatorActivatesExistingTabWithoutReadingMissingFile() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Offline Bound.txt",
            text: "Bound content\n",
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstOpen = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(firstOpen)
        let documentID = fixture.model.state.activeTab.document.id
        try FileManager.default.removeItem(at: fixture.fileURL)

        let reopened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(fixture.model.state.tabs.count, 1)
        XCTAssertEqual(fixture.model.state.activeTab.document.id, documentID)
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testPresentBoundLocatorReadsReplacementAndMarksContentConflict() async throws {
        let originalText = "Original bound content\n"
        let replacementText = "Replacement bound content\n"
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Changed Bound.txt",
            text: originalText,
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstOpen = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(firstOpen)
        let originalDocumentID = fixture.model.state.activeTab.document.id
        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = fixture.model.state.tabs.count
        await fixture.connector.pausePresenters()
        try FileManager.default.removeItem(at: fixture.fileURL)
        try Data(replacementText.utf8).write(
            to: fixture.fileURL,
            options: .withoutOverwriting
        )

        let reopened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(fixture.model.state.tabs.count, tabCount)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            originalDocumentID
        )
        XCTAssertEqual(
            fixture.model.state.activeTab.document.text,
            originalText
        )
        XCTAssertEqual(
            fixture.model.state.activeTab.document.fileConflict,
            .contentChanged
        )
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testPresentBoundLocatorReadsUnresolvedProviderVersionsBeforeActivation() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = filesURL.appendingPathComponent("Provider Versions.txt")
        try Data("Provider content\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let versionControl = ExternalOpenProviderVersionControl(count: 0)
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeExternalOpenBookmark,
            bookmarkResolver: resolveExternalOpenBookmark,
            identityReader: { _ in nil },
            replacer: replaceExternalOpenItem,
            saveAsRecoveryAccessorSourceProvider: { sourceURL, _ in
                sourceURL
            },
            unresolvedVersionCountReader: versionControl.read
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: FileRecoveryStore(
                rootURL: externalOpenRecoveryURL(rootURL: rootURL),
                fileManager: .default
            ),
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        addTeardownBlock {
            await connector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }
        let firstOpen = await model.openDocument(
            selectedURL: fileURL,
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(firstOpen)
        let originalDocumentID = model.state.activeTab.document.id
        let createdTab = await model.createTab(
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = model.state.tabs.count
        await connector.pausePresenters()
        versionControl.update(count: 2)

        let reopened = await model.openDocument(
            selectedURL: fileURL,
            after: committedActiveDocument(model: model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(model.state.tabs.count, tabCount)
        XCTAssertEqual(model.state.activeTab.document.id, originalDocumentID)
        XCTAssertEqual(
            model.state.activeTab.document.fileConflict,
            .unresolvedProviderVersions(count: 2)
        )
        XCTAssertNil(model.externalOpenError)
    }

    func testRepeatedIdentitylessDetachedLocatorActivatesExistingTabWithoutReadingMissingFile() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Offline Detached.txt",
            text: "Detached content\n",
            isWritable: false
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstOpen = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(firstOpen)
        let detachedDocumentID = fixture.model.state.activeTab.document.id
        XCTAssertNil(
            fixture.model.state.activeTab.document
                .recoveryFileReference?.identity
        )
        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = fixture.model.state.tabs.count
        try FileManager.default.removeItem(at: fixture.fileURL)

        let reopened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(fixture.model.state.tabs.count, tabCount)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            detachedDocumentID
        )
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testPresentUnchangedDurableDetachedLocatorActivatesExistingTabAfterRead() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Unchanged Detached.txt",
            text: "Unchanged detached content\n",
            isWritable: false
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstOpen = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(firstOpen)
        let originalDocumentID = fixture.model.state.activeTab.document.id
        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = fixture.model.state.tabs.count

        let reopened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(fixture.model.state.tabs.count, tabCount)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            originalDocumentID
        )
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testPresentDurableDetachedLocatorRejectsChangedSourceAndPreservesWorkspace() async throws {
        let originalText = "Original detached content\n"
        let replacementText = "Replacement detached content\n"
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Changed Detached.txt",
            text: originalText,
            isWritable: false
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstOpen = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(firstOpen)
        let originalDocumentID = fixture.model.state.activeTab.document.id
        let originalRecovery = try await fixture.recoveryStore.load(
            documentID: originalDocumentID
        )
        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        let stateBeforeReopen = fixture.model.state
        try FileManager.default.removeItem(at: fixture.fileURL)
        try Data(replacementText.utf8).write(
            to: fixture.fileURL,
            options: .withoutOverwriting
        )

        let reopened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertFalse(reopened)
        XCTAssertEqual(fixture.model.state, stateBeforeReopen)
        let retainedRecovery = try await fixture.recoveryStore.load(
            documentID: originalDocumentID
        )
        XCTAssertEqual(retainedRecovery, originalRecovery)
        XCTAssertTrue(
            fixture.model.externalOpenError?.contains(
                "changed since this protected Document was opened"
            ) == true
        )
    }

    func testMovedWritableStableIdentityDurableDetachedSourceActivatesExistingTabWithoutRecoveryPrompt() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let originalURL = filesURL.appendingPathComponent("Read Only.txt")
        let movedURL = filesURL.appendingPathComponent("Writable.txt")
        let text = "Moved stable-identity content\n"
        try Data(text.utf8).write(
            to: originalURL,
            options: .withoutOverwriting
        )
        let identity = FileIdentity(
            volumeUUID: UUID(),
            documentIdentifier: 811
        )
        let bookmarkControl = ExternalOpenBookmarkLocationControl(
            url: originalURL
        )
        let writabilityControl = ExternalOpenWritabilityControl(
            isWritable: false
        )
        let recoveryStore = FileRecoveryStore(
            rootURL: externalOpenRecoveryURL(rootURL: rootURL),
            fileManager: .default
        )
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: makeExternalOpenBookmark,
            bookmarkResolver: bookmarkControl.resolve,
            identityReader: { _ in identity },
            replacer: replaceExternalOpenItem,
            fileWritabilityReader: writabilityControl.read,
            applicationInboxURL: nil
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
        let fixture = ExternalOpenModelFixture(
            rootURL: rootURL,
            fileURL: originalURL,
            recoveryStore: recoveryStore,
            connector: connector,
            model: model
        )
        addTeardownBlock {
            await connector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }
        let firstOpen = await model.openDocument(
            selectedURL: originalURL,
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(firstOpen)
        let originalDocumentID = model.state.activeTab.document.id
        let originalRecovery = try await recoveryStore.load(
            documentID: originalDocumentID
        )
        XCTAssertNotNil(originalRecovery)
        XCTAssertNil(model.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryFileReference?.identity,
            identity
        )
        let createdTab = await model.createTab(
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = model.state.tabs.count
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        writabilityControl.update(isWritable: true)

        let reopened = await model.openDocument(
            selectedURL: movedURL,
            after: committedActiveDocument(model: model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(model.state.tabs.count, tabCount)
        XCTAssertEqual(model.state.activeTab.document.id, originalDocumentID)
        XCTAssertNil(model.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertNil(model.pendingExternalOpenRecoveryPrompt)
        XCTAssertFalse(
            fixture.connectorHasPresenter(documentID: originalDocumentID)
        )
        let retainedRecovery = try await recoveryStore.load(
            documentID: originalDocumentID
        )
        XCTAssertEqual(retainedRecovery, originalRecovery)
        XCTAssertNil(model.externalOpenError)
    }

    func testMovedIdentitylessBoundBookmarkActivatesExistingTabAndMarksAmbiguousLocatorConflict() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let originalURL = filesURL.appendingPathComponent("Original.txt")
        let movedURL = filesURL.appendingPathComponent("Moved.txt")
        let text = "Moved identityless content\n"
        try Data(text.utf8).write(
            to: originalURL,
            options: .withoutOverwriting
        )
        let bookmarkControl = ExternalOpenBookmarkLocationControl(
            url: originalURL
        )
        let recoveryStore = FileRecoveryStore(
            rootURL: externalOpenRecoveryURL(rootURL: rootURL),
            fileManager: .default
        )
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { _ in Data([0xB0, 0x0C]) },
            bookmarkResolver: bookmarkControl.resolve,
            identityReader: { _ in nil },
            replacer: replaceExternalOpenItem,
            fileWritabilityReader: { _ in true },
            applicationInboxURL: nil
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
        addTeardownBlock {
            await connector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }
        let firstOpen = await model.openDocument(
            selectedURL: originalURL,
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(firstOpen)
        let originalDocumentID = model.state.activeTab.document.id
        let createdTab = await model.createTab(
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = model.state.tabs.count
        await connector.pausePresenters()
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        bookmarkControl.update(url: movedURL)

        let reopened = await model.openDocument(
            selectedURL: movedURL,
            after: committedActiveDocument(model: model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(model.state.tabs.count, tabCount)
        XCTAssertEqual(model.state.activeTab.document.id, originalDocumentID)
        XCTAssertEqual(
            model.state.activeTab.document.fileConflict,
            .ambiguousLocatorChange
        )
        XCTAssertEqual(model.state.activeTab.document.text, text)
        XCTAssertNil(model.externalOpenError)
    }

    func testRepeatedEphemeralDetachedLocatorActivatesExistingTabWithoutReadingMissingFile() async throws {
        let fixture = try makeBookmarkFailureExternalOpenModelFixture(
            fileName: "Offline Ephemeral.txt",
            text: "Ephemeral detached content\n",
            bookmarkFailureCode: 732
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstOpen = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(firstOpen)
        let detachedDocumentID = fixture.model.state.activeTab.document.id
        XCTAssertNil(
            fixture.model.state.activeTab.document.recoveryFileReference
        )
        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = fixture.model.state.tabs.count
        try FileManager.default.removeItem(at: fixture.fileURL)

        let reopened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(fixture.model.state.tabs.count, tabCount)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            detachedDocumentID
        )
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testExistingEphemeralLocatorRequiresAuthoritativeReadBeforeActivation() async throws {
        let originalText = "Original ephemeral content\n"
        let fixture = try makeBookmarkFailureExternalOpenModelFixture(
            fileName: "Existing Ephemeral.txt",
            text: originalText,
            bookmarkFailureCode: 733
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstOpen = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(firstOpen)
        let originalDocumentID = fixture.model.state.activeTab.document.id
        XCTAssertNil(
            fixture.model.state.activeTab.document.recoveryFileReference
        )
        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        try FileManager.default.removeItem(at: fixture.fileURL)
        let invalidReplacement = Data("Replacement\0content".utf8)
        try invalidReplacement.write(
            to: fixture.fileURL,
            options: .withoutOverwriting
        )
        let stateBeforeReopen = fixture.model.state

        let reopened = await fixture.model.openDocument(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertFalse(reopened)
        XCTAssertEqual(fixture.model.state, stateBeforeReopen)
        XCTAssertEqual(
            fixture.model.state.tabs.first(where: { tab in
                tab.document.id == originalDocumentID
            })?.document.text,
            originalText
        )
        XCTAssertTrue(
            fixture.model.externalOpenError?.contains(
                "contains a null character"
            ) == true
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            invalidReplacement
        )
    }

    func testRepeatedImportedEphemeralLocatorCleansNewInboxCopyBeforeActivation() async throws {
        let openedText = "Repeated imported content\n"
        let fixture = try makeInboxExternalOpenModelFixture(
            fileName: "Repeated Import.txt",
            text: openedText,
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let firstCommitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let firstOpen = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: firstCommitRequestID
        )
        XCTAssertTrue(firstOpen)
        let detachedDocumentID = fixture.model.state.activeTab.document.id
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        let createdTab = await fixture.model.createTab(
            after: committedActiveDocument(model: fixture.model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = fixture.model.state.tabs.count
        try Data(openedText.utf8).write(
            to: fixture.fileURL,
            options: .withoutOverwriting
        )

        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let secondCommitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let reopened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: secondCommitRequestID
        )

        XCTAssertTrue(reopened)
        XCTAssertEqual(fixture.model.state.tabs.count, tabCount)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            detachedDocumentID
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
    }

    func testRecreatedInboxPathWithDifferentBytesOpensNewProtectedDocumentBeforeCleanup() async throws {
        let firstText = "First delivered Inbox content\n"
        let secondText = "Second delivered Inbox content\n"
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent(
            "Inbox",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = inboxURL.appendingPathComponent(
            "Repeated Delivery.txt",
            isDirectory: false
        )
        try Data(firstText.utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let protectionGate = ExternalOpenCopyProtectionOrderGate(
            sourceURL: fileURL
        )
        let recoveryStore = FileRecoveryStore(
            rootURL: externalOpenRecoveryURL(rootURL: rootURL),
            fileManager: .default,
            postPromotionValidation: protectionGate.validate
        )
        let connector = makeExternalOpenConnector(
            applicationInboxURL: inboxURL,
            isWritable: true
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
        addTeardownBlock {
            await connector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }

        await model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let firstCommitRequestID = try XCTUnwrap(
            model.externalOpenCommitRequestID
        )
        let firstOpened = await model.processNextExternalOpen(
            after: committedActiveDocument(model: model),
            commitRequestID: firstCommitRequestID
        )
        XCTAssertTrue(firstOpened)
        let firstDocumentID = model.state.activeTab.document.id
        XCTAssertEqual(model.state.activeTab.document.text, firstText)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let createdTab = await model.createTab(
            after: committedActiveDocument(model: model)
        )
        XCTAssertTrue(createdTab)
        let tabCount = model.state.tabs.count
        try Data(secondText.utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )

        await model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let secondCommitRequestID = try XCTUnwrap(
            model.externalOpenCommitRequestID
        )
        let secondOpened = await model.processNextExternalOpen(
            after: committedActiveDocument(model: model),
            commitRequestID: secondCommitRequestID
        )

        XCTAssertTrue(secondOpened)
        XCTAssertEqual(model.state.tabs.count, tabCount + 1)
        XCTAssertNotEqual(
            model.state.activeTab.document.id,
            firstDocumentID
        )
        XCTAssertEqual(model.state.activeTab.document.text, secondText)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertEqual(
            model.state.tabs.first(where: { tab in
                tab.document.id == firstDocumentID
            })?.document.text,
            firstText
        )
        let secondEnvelope = try await recoveryStore.load(
            documentID: model.state.activeTab.document.id
        )
        XCTAssertEqual(secondEnvelope?.text, secondText)
        XCTAssertEqual(protectionGate.validationCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(model.externalOpenCleanupRequired)
    }

    func testInactiveSceneHoldsQueuedOpenUntilActivation() async throws {
        let fixture = try makeExternalOpenModelFixture(
            fileName: "Inactive Queue.txt",
            text: "Queued while inactive\n",
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let initialState = fixture.model.state
        await fixture.model.sceneBecameInactive()

        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .inPlace
            ),
        ])

        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertEqual(fixture.model.state, initialState)

        await fixture.model.sceneBecameActive()

        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )
        XCTAssertTrue(opened)
    }

    func testActivationPreservesQueuedInboxCopyUntilOpenProtectsIt() async throws {
        let openedText = "Queued Inbox copy while inactive\n"
        let fixture = try makeInboxExternalOpenModelFixture(
            fileName: "Inactive Inbox Queue.txt",
            text: openedText,
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        await fixture.model.sceneBecameInactive()
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )

        await fixture.model.sceneBecameActive()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.model.state.activeTab.document.text, openedText)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testActivationDefersTokenlessQueuedInboxCleanupUntilPreflightRetry() async throws {
        let openedText = "Tokenless queued Inbox copy\n"
        let failureGate = ExternalOpenInitialCleanupPersistenceFailureGate(
            removalFailureCode: 976
        )
        let fixture = try makeInitialCleanupFailureInboxExternalOpenModelFixture(
            fileName: "Tokenless Inactive Inbox Queue.txt",
            text: openedText,
            failureGate: failureGate
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        await fixture.model.sceneBecameInactive()
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertNotNil(fixture.model.externalOpenError)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        failureGate.repair()

        await fixture.model.sceneBecameActive()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        await fixture.model.retryExternalOpenCommit()
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.model.state.activeTab.document.text, openedText)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertNil(fixture.model.externalOpenError)
    }

    func testTokenlessCandidateChangeCancelRetiresOrphanedCleanupAuthority() async throws {
        let originalText = "Tokenless original Inbox copy\n"
        let replacementText = "Tokenless replacement Inbox copy\n"
        let failureGate = ExternalOpenInitialCleanupPersistenceFailureGate(
            removalFailureCode: 977
        )
        let fixture = try makeInitialCleanupFailureInboxExternalOpenModelFixture(
            fileName: "Tokenless Cancel Replacement.txt",
            text: originalText,
            failureGate: failureGate
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        await fixture.model.sceneBecameInactive()
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        failureGate.repair()
        let retainedOriginalURL = fixture.rootURL.appendingPathComponent(
            "Retained Tokenless Cancel Replacement.txt",
            isDirectory: false
        )
        try FileManager.default.moveItem(
            at: fixture.fileURL,
            to: retainedOriginalURL
        )
        try Data(replacementText.utf8).write(
            to: fixture.fileURL,
            options: .withoutOverwriting
        )

        await fixture.model.cancelPendingExternalOpen()

        XCTAssertNil(fixture.model.externalOpenCommitRequestID)
        XCTAssertNil(fixture.model.pendingExternalOpenRecoveryPrompt)
        XCTAssertTrue(fixture.model.externalOpenErrorRequiresDismissal)
        XCTAssertEqual(
            fixture.model.externalOpenError,
            FileAccessConnectorError
                .importedCopyCleanupCandidateChanged
                .localizedDescription
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data(replacementText.utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedOriginalURL),
            Data(originalText.utf8)
        )

        let recreatedConnector = makeImportedCopyExternalOpenConnector(
            applicationInboxURL: fixture.fileURL.deletingLastPathComponent(),
            journalRootURL: fixture.rootURL.appendingPathComponent(
                "Cleanup Journal",
                isDirectory: true
            ),
            importedCopyRemover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let recreatedModel = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: fixture.recoveryStore,
            fileAccessConnector: recreatedConnector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        addTeardownBlock {
            await recreatedConnector.pausePresenters()
        }

        await recreatedModel.sceneBecameActive()

        XCTAssertFalse(recreatedModel.externalOpenCleanupRequired)
        XCTAssertNil(recreatedModel.externalOpenNotice)
        XCTAssertNil(recreatedModel.externalOpenError)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data(replacementText.utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedOriginalURL),
            Data(originalText.utf8)
        )
        let report = try await recreatedConnector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(report.alreadyAbsent, [])
        XCTAssertEqual(report.awaitingProtection, [])
        XCTAssertEqual(report.residuals, [])
    }

    func testBoundOpenFinishingInactiveDoesNotLeavePresenterRegistered() async throws {
        let checkpointGate = ExternalOpenProtectionGate()
        let fixture = try makeBlockingProtectionExternalOpenModelFixture(
            fileName: "Inactive Finish.txt",
            text: "Open finishes while inactive\n",
            checkpointGate: checkpointGate
        )
        addTeardownBlock {
            checkpointGate.resume()
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        let committedText = "Edited before inactive Open\n"
        XCTAssertTrue(
            fixture.model.editDocument(
                documentID: fixture.model.state.activeTab.document.id,
                text: committedText
            )
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .inPlace
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let lifecycle = Task { @MainActor in
            await checkpointGate.waitUntilEntered()
            let commitRequestWasRetained =
                fixture.model.externalOpenCommitRequestID == commitRequestID
            await fixture.model.sceneBecameInactive()
            checkpointGate.resume()
            return commitRequestWasRetained
        }
        let opened = await fixture.model.processNextExternalOpen(
            after: CommittedEditorDocument(
                documentID: fixture.model.state.activeTab.document.id,
                text: committedText
            ),
            commitRequestID: commitRequestID
        )
        let commitRequestWasRetained = await lifecycle.value

        XCTAssertTrue(opened)
        XCTAssertTrue(commitRequestWasRetained)
        XCTAssertFalse(
            fixture.connectorHasPresenter(
                documentID: fixture.model.state.activeTab.document.id
            )
        )
    }

    func testActivationReconcilesAuthorizedInboxCleanupAfterConcurrentColdExternalOpenFinishes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
        let journalRootURL = rootURL.appendingPathComponent(
            "Cleanup Journal",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let deferredCleanupURL = inboxURL.appendingPathComponent(
            "Deferred Cold Cleanup.txt",
            isDirectory: false
        )
        try Data("Deferred cold cleanup\n".utf8).write(
            to: deferredCleanupURL,
            options: .withoutOverwriting
        )
        let queuedURL = inboxURL.appendingPathComponent(
            "Concurrent Cold Open.txt",
            isDirectory: false
        )
        let queuedText = "Concurrent cold External Open\n"
        try Data(queuedText.utf8).write(
            to: queuedURL,
            options: .withoutOverwriting
        )
        let checkpointGate = ExternalOpenProtectionGate()
        let recoveryStore = FileRecoveryStore(
            rootURL: externalOpenRecoveryURL(rootURL: rootURL),
            fileManager: .default,
            postPromotionValidation: checkpointGate.validate
        )
        let connector = makeImportedCopyExternalOpenConnector(
            applicationInboxURL: inboxURL,
            journalRootURL: journalRootURL,
            importedCopyRemover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let cleanupToken = try await connector.captureImportedCopyCleanup(
            at: deferredCleanupURL,
            documentID: DocumentID(rawValue: UUID())
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
        addTeardownBlock {
            checkpointGate.resume()
            await connector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }
        XCTAssertNotNil(cleanupToken)
        let committedText = "Edited before concurrent cold Open\n"
        XCTAssertTrue(
            model.editDocument(
                documentID: model.state.activeTab.document.id,
                text: committedText
            )
        )
        await model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: queuedURL,
                accessIntent: .copyRequired
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            model.externalOpenCommitRequestID
        )
        let openTask = Task { @MainActor in
            await model.processNextExternalOpen(
                after: CommittedEditorDocument(
                    documentID: model.state.activeTab.document.id,
                    text: committedText
                ),
                commitRequestID: commitRequestID
            )
        }
        await checkpointGate.waitUntilEntered()

        await model.sceneBecameInactive()
        await model.sceneBecameActive()

        XCTAssertTrue(model.externalOpenInProgress)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: deferredCleanupURL.path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: queuedURL.path))
        checkpointGate.resume()
        let opened = await openTask.value

        XCTAssertTrue(opened)
        XCTAssertEqual(model.state.activeTab.document.text, queuedText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedURL.path))
        let deferredCleanupFinished = try await waitUntilFileIsMissing(
            at: deferredCleanupURL
        )
        XCTAssertTrue(deferredCleanupFinished)
        let cleanupReport = try await connector
            .reconcileImportedCopyCleanupJournal()
        XCTAssertEqual(cleanupReport.removed, [])
        XCTAssertEqual(cleanupReport.alreadyAbsent, [])
        XCTAssertEqual(cleanupReport.awaitingProtection, [])
        XCTAssertEqual(cleanupReport.residuals, [])
        XCTAssertFalse(model.externalOpenCleanupRequired)
    }

    func testRejectedInboxOpenCleansImportedCopyBeforeSurfacingError() async throws {
        let fixture = try makeInboxExternalOpenModelFixture(
            fileName: "Rejected.txt",
            text: "Temporary placeholder\n",
            isWritable: true
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }
        try Data("Rejected\0binary".utf8).write(
            to: fixture.fileURL,
            options: []
        )
        let followingURL = fixture.rootURL.appendingPathComponent(
            "Following.txt",
            isDirectory: false
        )
        try Data("Following content\n".utf8).write(
            to: followingURL,
            options: .withoutOverwriting
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
            PhonePadExternalOpenRequest(
                url: followingURL,
                accessIntent: .inPlace
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )

        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertFalse(opened)
        XCTAssertEqual(
            fixture.model.externalOpenError,
            FileAccessConnectorError.textDecodingFailed(
                .containsNullScalar
            ).localizedDescription
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertFalse(fixture.model.externalOpenCleanupRequired)
        XCTAssertTrue(fixture.model.externalOpenErrorRequiresDismissal)

        await fixture.model.retryExternalOpenCommit()

        XCTAssertTrue(fixture.model.externalOpenErrorRequiresDismissal)
        XCTAssertNotNil(fixture.model.externalOpenError)
        XCTAssertNil(fixture.model.externalOpenCommitRequestID)

        fixture.model.dismissTerminalExternalOpenError()

        let followingCommitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )
        let followingOpened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: followingCommitRequestID
        )
        XCTAssertTrue(followingOpened)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.title,
            "Following.txt"
        )
    }

    func testRejectedCleanupDualFailureBlocksCancelUntilSettledAndRelaunchesCleanly() async throws {
        let failureGate = ExternalOpenCleanupDualFailureGate(
            removalFailureCode: 972
        )
        let fixture = try makeRejectedCleanupDualFailureFixture(
            failureGate: failureGate
        )
        let journalRootURL = fixture.rootURL.appendingPathComponent(
            "Cleanup Journal",
            isDirectory: true
        )
        await fixture.model.enqueueExternalOpenRequests([
            PhonePadExternalOpenRequest(
                url: fixture.fileURL,
                accessIntent: .copyRequired
            ),
        ])
        let commitRequestID = try XCTUnwrap(
            fixture.model.externalOpenCommitRequestID
        )

        let opened = await fixture.model.processNextExternalOpen(
            after: committedActiveDocument(model: fixture.model),
            commitRequestID: commitRequestID
        )

        XCTAssertFalse(opened)
        XCTAssertTrue(fixture.model.externalOpenCleanupRequired)
        XCTAssertTrue(fixture.model.externalOpenErrorRequiresDismissal)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )

        await fixture.model.cancelPendingExternalOpen()

        XCTAssertTrue(fixture.model.externalOpenCleanupRequired)
        XCTAssertTrue(fixture.model.externalOpenErrorRequiresDismissal)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.fileURL.path)
        )
        XCTAssertTrue(
            fixture.model.externalOpenError?.contains(
                "cleanup must finish before External Open can be dismissed"
            ) == true
        )

        let recreatedConnector = makeImportedCopyExternalOpenConnector(
            applicationInboxURL: fixture.fileURL.deletingLastPathComponent(),
            journalRootURL: journalRootURL,
            importedCopyRemover: removeImportedCopy,
            metadataVerifier: verifyImportedCopyCleanupJournalMetadata
        )
        let recreatedModel = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: fixture.recoveryStore,
            fileAccessConnector: recreatedConnector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        addTeardownBlock {
            await fixture.connector.pausePresenters()
            await recreatedConnector.pausePresenters()
            try FileManager.default.removeItem(at: fixture.rootURL)
        }

        await recreatedModel.sceneBecameActive()

        XCTAssertFalse(recreatedModel.externalOpenCleanupRequired)
        XCTAssertNil(recreatedModel.externalOpenError)
        XCTAssertNil(recreatedModel.externalOpenNotice)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: importedCopyCleanupJournalURL(
                    rootURL: journalRootURL
                ).path
            )
        )
    }

    func testFirstActivationReconcilesProtectedImportedCopyAfterConnectorRecreation() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent(
            "Inbox",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = inboxURL.appendingPathComponent(
            "Interrupted Import.txt",
            isDirectory: false
        )
        try Data("Interrupted imported content\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let recoveryStore = FileRecoveryStore(
            rootURL: externalOpenRecoveryURL(rootURL: rootURL),
            fileManager: .default
        )
        let documentID = DocumentID(rawValue: UUID())
        let envelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fileURL,
            documentID: documentID,
            title: "Interrupted Import.txt",
            text: "Protected interrupted import\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_500)
        )
        try await protectRecoveryEnvelope(
            envelope: envelope,
            recoveryStore: recoveryStore
        )
        let firstConnector = makeExternalOpenConnector(
            applicationInboxURL: inboxURL,
            isWritable: true
        )
        let outcome = try await firstConnector.openTextFile(
            at: fileURL,
            documentID: documentID,
            accessIntent: .copyRequired
        )
        guard case let .detached(openedFile) = outcome else {
            return XCTFail("Expected detached imported copy, received \(outcome).")
        }
        XCTAssertNotNil(openedFile.importedCopyCleanupToken)

        let recreatedConnector = makeExternalOpenConnector(
            applicationInboxURL: inboxURL,
            isWritable: true
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: recoveryStore,
            fileAccessConnector: recreatedConnector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        addTeardownBlock {
            await firstConnector.pausePresenters()
            await recreatedConnector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }

        await model.sceneBecameActive()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(model.externalOpenCleanupRequired)
        XCTAssertNil(model.externalOpenError)
        let retainedEnvelope = try await recoveryStore.load(
            documentID: documentID
        )
        XCTAssertEqual(retainedEnvelope, envelope)
    }

    func testLaterActivationRetriesJournalCleanupAfterRecoveryBecomesProtected() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent(
            "Inbox",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let fileURL = inboxURL.appendingPathComponent(
            "Awaiting Protection.txt",
            isDirectory: false
        )
        try Data("Awaiting recovery protection\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let recoveryStore = FileRecoveryStore(
            rootURL: externalOpenRecoveryURL(rootURL: rootURL),
            fileManager: .default
        )
        let documentID = DocumentID(rawValue: UUID())
        let envelope = try makeSourceFileRecoveryEnvelope(
            fileURL: fileURL,
            documentID: documentID,
            title: "Awaiting Protection.txt",
            text: "Protected after first activation\n",
            editedAt: Date(timeIntervalSince1970: 1_800_000_525)
        )
        let firstConnector = makeExternalOpenConnector(
            applicationInboxURL: inboxURL,
            isWritable: true
        )
        let outcome = try await firstConnector.openTextFile(
            at: fileURL,
            documentID: documentID,
            accessIntent: .copyRequired
        )
        guard case .detached = outcome else {
            return XCTFail("Expected detached imported copy, received \(outcome).")
        }
        let recreatedConnector = makeExternalOpenConnector(
            applicationInboxURL: inboxURL,
            isWritable: true
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: recoveryStore,
            fileAccessConnector: recreatedConnector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        addTeardownBlock {
            await firstConnector.pausePresenters()
            await recreatedConnector.pausePresenters()
            try FileManager.default.removeItem(at: rootURL)
        }

        await model.sceneBecameActive()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(model.externalOpenCleanupRequired)
        XCTAssertNotNil(model.externalOpenNotice)
        XCTAssertNil(model.externalOpenError)

        try await protectRecoveryEnvelope(
            envelope: envelope,
            recoveryStore: recoveryStore
        )
        await model.sceneBecameInactive()
        await model.sceneBecameActive()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(model.externalOpenCleanupRequired)
        XCTAssertNil(model.externalOpenError)
        XCTAssertNil(model.externalOpenNotice)
    }
}

@MainActor
private struct ExternalOpenModelFixture {
    let rootURL: URL
    let fileURL: URL
    let recoveryStore: FileRecoveryStore
    let connector: FileAccessConnector
    let model: PhonePadAppModel

    func connectorHasPresenter(documentID: DocumentID) -> Bool {
        NSFileCoordinator.filePresenters.contains { presenter in
            (presenter as? PresentedFile)?.documentID == documentID
        }
    }
}

@MainActor
private func makeExternalOpenModelFixture(
    fileName: String,
    text: String,
    isWritable: Bool
) throws -> ExternalOpenModelFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
    let recoveryStore = FileRecoveryStore(
        rootURL: externalOpenRecoveryURL(rootURL: rootURL),
        fileManager: .default
    )
    return try makeExternalOpenModelFixture(
        rootURL: rootURL,
        filesURL: filesURL,
        applicationInboxURL: nil,
        recoveryStore: recoveryStore,
        fileName: fileName,
        text: text,
        isWritable: isWritable
    )
}

@MainActor
private func makeInboxExternalOpenModelFixture(
    fileName: String,
    text: String,
    isWritable: Bool
) throws -> ExternalOpenModelFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
    let recoveryStore = FileRecoveryStore(
        rootURL: externalOpenRecoveryURL(rootURL: rootURL),
        fileManager: .default
    )
    return try makeExternalOpenModelFixture(
        rootURL: rootURL,
        filesURL: inboxURL,
        applicationInboxURL: inboxURL,
        recoveryStore: recoveryStore,
        fileName: fileName,
        text: text,
        isWritable: isWritable
    )
}

@MainActor
private func makeFailingInboxExternalOpenModelFixture(
    fileName: String,
    text: String,
    validationGate: ExternalOpenCheckpointValidationGate
) throws -> ExternalOpenModelFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
    let recoveryStore = FileRecoveryStore(
        rootURL: externalOpenRecoveryURL(rootURL: rootURL),
        fileManager: .default,
        postPromotionValidation: validationGate.validate
    )
    return try makeExternalOpenModelFixture(
        rootURL: rootURL,
        filesURL: inboxURL,
        applicationInboxURL: inboxURL,
        recoveryStore: recoveryStore,
        fileName: fileName,
        text: text,
        isWritable: true
    )
}

@MainActor
private func makeRejectedCleanupDualFailureFixture(
    failureGate: ExternalOpenCleanupDualFailureGate
) throws -> ExternalOpenModelFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(
        at: inboxURL,
        withIntermediateDirectories: true,
        attributes: nil
    )
    let fileURL = inboxURL.appendingPathComponent(
        "Rejected Dual Failure.txt",
        isDirectory: false
    )
    try Data("Rejected\0binary".utf8).write(
        to: fileURL,
        options: .withoutOverwriting
    )
    let recoveryStore = FileRecoveryStore(
        rootURL: externalOpenRecoveryURL(rootURL: rootURL),
        fileManager: .default
    )
    let connector = makeImportedCopyExternalOpenConnector(
        applicationInboxURL: inboxURL,
        journalRootURL: rootURL.appendingPathComponent(
            "Cleanup Journal",
            isDirectory: true
        ),
        importedCopyRemover: failureGate.remove,
        metadataVerifier: failureGate.verifyMetadata
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
    return ExternalOpenModelFixture(
        rootURL: rootURL,
        fileURL: fileURL,
        recoveryStore: recoveryStore,
        connector: connector,
        model: model
    )
}

@MainActor
private func makeInitialCleanupFailureInboxExternalOpenModelFixture(
    fileName: String,
    text: String,
    failureGate: ExternalOpenInitialCleanupPersistenceFailureGate
) throws -> ExternalOpenModelFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(
        at: inboxURL,
        withIntermediateDirectories: true,
        attributes: nil
    )
    let fileURL = inboxURL.appendingPathComponent(
        fileName,
        isDirectory: false
    )
    try Data(text.utf8).write(to: fileURL, options: .withoutOverwriting)
    let recoveryStore = FileRecoveryStore(
        rootURL: externalOpenRecoveryURL(rootURL: rootURL),
        fileManager: .default
    )
    let connector = makeImportedCopyExternalOpenConnector(
        applicationInboxURL: inboxURL,
        journalRootURL: rootURL.appendingPathComponent(
            "Cleanup Journal",
            isDirectory: true
        ),
        importedCopyRemover: failureGate.remove,
        metadataVerifier: failureGate.verifyMetadata
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
    return ExternalOpenModelFixture(
        rootURL: rootURL,
        fileURL: fileURL,
        recoveryStore: recoveryStore,
        connector: connector,
        model: model
    )
}

@MainActor
private func makeExternalOpenModelFixture(
    rootURL: URL,
    filesURL: URL,
    applicationInboxURL: URL?,
    recoveryStore: FileRecoveryStore,
    fileName: String,
    text: String,
    isWritable: Bool
) throws -> ExternalOpenModelFixture {
    try makeExternalOpenModelFixture(
        rootURL: rootURL,
        filesURL: filesURL,
        applicationInboxURL: applicationInboxURL,
        recoveryStore: recoveryStore,
        fileName: fileName,
        text: text,
        bookmarkCreator: makeExternalOpenBookmark,
        isWritable: isWritable
    )
}

@MainActor
private func makeExternalOpenModelFixture(
    rootURL: URL,
    filesURL: URL,
    applicationInboxURL: URL?,
    recoveryStore: FileRecoveryStore,
    fileName: String,
    text: String,
    bookmarkCreator: @escaping FileAccessConnector.BookmarkCreator,
    isWritable: Bool
) throws -> ExternalOpenModelFixture {
    try FileManager.default.createDirectory(
        at: filesURL,
        withIntermediateDirectories: true,
        attributes: nil
    )
    let fileURL = filesURL.appendingPathComponent(fileName, isDirectory: false)
    try Data(text.utf8).write(to: fileURL, options: .withoutOverwriting)
    let connector = makeExternalOpenConnector(
        applicationInboxURL: applicationInboxURL,
        bookmarkCreator: bookmarkCreator,
        isWritable: isWritable
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
    return ExternalOpenModelFixture(
        rootURL: rootURL,
        fileURL: fileURL,
        recoveryStore: recoveryStore,
        connector: connector,
        model: model
    )
}

private func makeExternalOpenConnector(
    applicationInboxURL: URL?,
    isWritable: Bool
) -> FileAccessConnector {
    makeExternalOpenConnector(
        applicationInboxURL: applicationInboxURL,
        bookmarkCreator: makeExternalOpenBookmark,
        isWritable: isWritable
    )
}

private func makeImportedCopyExternalOpenConnector(
    applicationInboxURL: URL,
    journalRootURL: URL,
    importedCopyRemover: @escaping FileAccessConnector.ImportedCopyRemover,
    metadataVerifier: @escaping FileAccessConnector
        .ImportedCopyCleanupJournalMetadataVerifier
) -> FileAccessConnector {
    FileAccessConnector(
        fileManager: .default,
        bookmarkCreator: makeExternalOpenBookmark,
        bookmarkResolver: resolveExternalOpenBookmark,
        identityReader: { _ in nil },
        replacer: replaceExternalOpenItem,
        fileWritabilityReader: { _ in true },
        applicationInboxURL: applicationInboxURL,
        importedCopyCleanupJournalRootURL: journalRootURL,
        importedCopyRemover: importedCopyRemover,
        importedCopyCleanupJournalMetadataVerifier: metadataVerifier
    )
}

private func makeExternalOpenConnector(
    applicationInboxURL: URL?,
    bookmarkCreator: @escaping FileAccessConnector.BookmarkCreator,
    isWritable: Bool
) -> FileAccessConnector {
    FileAccessConnector(
        fileManager: .default,
        bookmarkCreator: bookmarkCreator,
        bookmarkResolver: resolveExternalOpenBookmark,
        identityReader: { _ in nil },
        replacer: replaceExternalOpenItem,
        fileWritabilityReader: { _ in isWritable },
        applicationInboxURL: applicationInboxURL
    )
}

@MainActor
private func makeBookmarkFailureExternalOpenModelFixture(
    fileName: String,
    text: String,
    bookmarkFailureCode: Int
) throws -> ExternalOpenModelFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
    let recoveryStore = FileRecoveryStore(
        rootURL: externalOpenRecoveryURL(rootURL: rootURL),
        fileManager: .default
    )
    return try makeExternalOpenModelFixture(
        rootURL: rootURL,
        filesURL: filesURL,
        applicationInboxURL: nil,
        recoveryStore: recoveryStore,
        fileName: fileName,
        text: text,
        bookmarkCreator: { _ in
            throw NSError(
                domain: "PhonePadExternalOpenAppModelTests.Bookmark",
                code: bookmarkFailureCode
            )
        },
        isWritable: true
    )
}

@MainActor
private func makeBlockingProtectionExternalOpenModelFixture(
    fileName: String,
    text: String,
    checkpointGate: ExternalOpenProtectionGate
) throws -> ExternalOpenModelFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
    let recoveryStore = FileRecoveryStore(
        rootURL: externalOpenRecoveryURL(rootURL: rootURL),
        fileManager: .default,
        postPromotionValidation: checkpointGate.validate
    )
    return try makeExternalOpenModelFixture(
        rootURL: rootURL,
        filesURL: filesURL,
        applicationInboxURL: nil,
        recoveryStore: recoveryStore,
        fileName: fileName,
        text: text,
        bookmarkCreator: makeExternalOpenBookmark,
        isWritable: true
    )
}

private func externalOpenRecoveryURL(rootURL: URL) -> URL {
    rootURL.appendingPathComponent("Recovery", isDirectory: true)
}

private func waitUntilFileIsMissing(at url: URL) async throws -> Bool {
    for _ in 0 ..< 100 {
        if !FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func makeSourceFileRecoveryEnvelope(
    fileURL: URL,
    documentID: DocumentID,
    title: String,
    text: String,
    editedAt: Date
) throws -> RecoveryEnvelope {
    let decodedFile = try decodeSupportedTextFile(
        data: Data(contentsOf: fileURL)
    )
    return try RecoveryEnvelope(
        formatVersion: RecoveryEnvelope.currentFormatVersion,
        documentID: documentID,
        title: title,
        text: text,
        editedAt: editedAt,
        fileReference: RecoveryFileReference(
            bookmark: try FileBookmark(
                data: makeExternalOpenBookmark(url: fileURL)
            ),
            identity: nil,
            displayName: try ValidatedFileName(
                validating: fileURL.lastPathComponent
            ),
            cleanDigest: decodedFile.digest,
            encoding: decodedFile.encoding,
            lineEnding: decodedFile.lineEnding
        ),
        pendingSave: nil
    )
}

@MainActor
private func committedActiveDocument(
    model: PhonePadAppModel
) -> CommittedEditorDocument {
    CommittedEditorDocument(
        documentID: model.state.activeTab.document.id,
        text: model.state.activeTab.document.text
    )
}

private func makeExternalOpenBookmark(url: URL) throws -> Data {
    guard let data = url.standardizedFileURL.path.data(using: .utf8) else {
        throw ExternalOpenTestError.bookmarkEncodingFailed
    }
    return data
}

private func resolveExternalOpenBookmark(
    bookmark: FileBookmark
) throws -> ResolvedFileBookmark {
    guard let path = String(data: bookmark.data, encoding: .utf8) else {
        throw ExternalOpenTestError.bookmarkDecodingFailed
    }
    return ResolvedFileBookmark(
        url: URL(fileURLWithPath: path),
        isStale: false
    )
}

private func replaceExternalOpenItem(
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

private enum ExternalOpenTestError: Error {
    case bookmarkEncodingFailed
    case bookmarkDecodingFailed
    case editorCommitFailed
    case checkpointValidationFailed
    case sourceRemovedBeforeProtection
}

private final class ExternalOpenBookmarkLocationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL

    init(url: URL) {
        self.url = url
    }

    func update(url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
    }

    func resolve(bookmark: FileBookmark) -> ResolvedFileBookmark {
        _ = bookmark
        lock.lock()
        let resolvedURL = url
        lock.unlock()
        return ResolvedFileBookmark(url: resolvedURL, isStale: false)
    }
}

private final class ExternalOpenWritabilityControl: @unchecked Sendable {
    private let lock = NSLock()
    private var isWritable: Bool

    init(isWritable: Bool) {
        self.isWritable = isWritable
    }

    func update(isWritable: Bool) {
        lock.lock()
        self.isWritable = isWritable
        lock.unlock()
    }

    func read(url: URL) -> Bool {
        _ = url
        lock.lock()
        let result = isWritable
        lock.unlock()
        return result
    }
}

private final class ExternalOpenProviderVersionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int

    init(count: Int) {
        self.count = count
    }

    func update(count: Int) {
        lock.lock()
        self.count = count
        lock.unlock()
    }

    func read(url: URL) -> Int {
        _ = url
        lock.lock()
        let currentCount = count
        lock.unlock()
        return currentCount
    }
}

private final class ExternalOpenCopyProtectionOrderGate: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceURL: URL
    private var protectedValidationCount: Int = 0

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    var validationCount: Int {
        lock.withLock { protectedValidationCount }
    }

    func validate(_ promotedURL: URL) throws {
        _ = promotedURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ExternalOpenTestError.sourceRemovedBeforeProtection
        }
        lock.withLock {
            protectedValidationCount += 1
        }
    }
}

private final class ExternalOpenCheckpointValidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail: Bool = true

    func validate(_ promotedURL: URL) throws {
        _ = promotedURL
        let mustFail = lock.withLock { shouldFail }
        guard mustFail else {
            return
        }
        throw ExternalOpenTestError.checkpointValidationFailed
    }

    func repair() {
        lock.withLock {
            shouldFail = false
        }
    }
}

private final class ExternalOpenProtectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didEnter: Bool = false
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func validate(_ promotedURL: URL) {
        _ = promotedURL
        let blockedValidation: (
            continuation: CheckedContinuation<Void, Never>?,
            shouldBlock: Bool
        ) = lock.withLock {
            guard !didEnter else {
                return (continuation: nil, shouldBlock: false)
            }
            didEnter = true
            let continuation = entryContinuation
            entryContinuation = nil
            return (continuation: continuation, shouldBlock: true)
        }
        blockedValidation.continuation?.resume()
        if blockedValidation.shouldBlock {
            release.wait()
        }
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

private final class ExternalOpenCleanupDualFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private let removalFailureCode: Int
    private var directoryVerificationCount: Int = 0
    private var shouldFail: Bool = true

    init(removalFailureCode: Int) {
        self.removalFailureCode = removalFailureCode
    }

    func verifyMetadata(
        _ url: URL,
        itemKind: ImportedCopyCleanupJournalItemKind,
        fileManager: FileManager
    ) throws {
        try verifyImportedCopyCleanupJournalMetadata(
            url: url,
            itemKind: itemKind,
            fileManager: fileManager
        )
        let mustFail = lock.withLock {
            guard itemKind == .directory else {
                return false
            }
            directoryVerificationCount += 1
            return shouldFail && directoryVerificationCount >= 3
        }
        guard !mustFail else {
            throw ImportedCopyCleanupJournalError
                .fileProtectionVerificationFailed
        }
    }

    func remove(_ url: URL, fileManager: FileManager) throws {
        let mustFail = lock.withLock { shouldFail }
        guard !mustFail else {
            throw ExternalOpenCleanupRemovalError(code: removalFailureCode)
        }
        try removeImportedCopy(url: url, fileManager: fileManager)
    }

}

private final class ExternalOpenInitialCleanupPersistenceFailureGate:
    @unchecked Sendable {
    private let lock = NSLock()
    private let removalFailureCode: Int
    private var shouldFailJournalVerification: Bool = true
    private var shouldFailRemoval: Bool = true

    init(removalFailureCode: Int) {
        self.removalFailureCode = removalFailureCode
    }

    func verifyMetadata(
        _ url: URL,
        itemKind: ImportedCopyCleanupJournalItemKind,
        fileManager: FileManager
    ) throws {
        try verifyImportedCopyCleanupJournalMetadata(
            url: url,
            itemKind: itemKind,
            fileManager: fileManager
        )
        let mustFail = lock.withLock {
            guard itemKind == .journalFile,
                  shouldFailJournalVerification else {
                return false
            }
            shouldFailJournalVerification = false
            return true
        }
        guard !mustFail else {
            throw ImportedCopyCleanupJournalError
                .fileProtectionVerificationFailed
        }
    }

    func remove(_ url: URL, fileManager: FileManager) throws {
        let mustFail = lock.withLock { shouldFailRemoval }
        guard !mustFail else {
            throw ExternalOpenCleanupRemovalError(
                code: removalFailureCode
            )
        }
        try removeImportedCopy(url: url, fileManager: fileManager)
    }

    func repair() {
        lock.withLock {
            shouldFailJournalVerification = false
            shouldFailRemoval = false
        }
    }
}

private struct ExternalOpenCleanupRemovalError: CustomNSError, Sendable {
    static let errorDomain =
        "PhonePadExternalOpenAppModelTests.CleanupRemoval"
    let code: Int
    var errorCode: Int { code }
}
