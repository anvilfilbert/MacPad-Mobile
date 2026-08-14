import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadSaveAsWorkflowTests: XCTestCase {
    func testPrepareSaveAsUsesSelectedEncodingAndBoundLineEnding() throws {
        let sourceBinding = try makeSaveAsSourceBinding()
        let openedState = openBoundDocument(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "Original\n",
            fileBinding: sourceBinding
        )
        let editedState = try beginActiveDocumentEdit(
            state: openedState,
            newText: "A\r\n\u{20ac}",
            editedAt: Date(timeIntervalSince1970: 1_786_800_000)
        ).state

        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Converted.txt",
            encoding: .utf16BigEndianWithBOM,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_800_100)
        )

        XCTAssertEqual(preparation.documentID, editedState.activeTab.document.id)
        XCTAssertEqual(preparation.sourceTitle, sourceBinding.displayName.value)
        XCTAssertEqual(preparation.sourceText, "A\n\u{20ac}")
        XCTAssertEqual(preparation.sourceBinding, sourceBinding)
        XCTAssertTrue(preparation.sourceWasUnsaved)
        XCTAssertEqual(preparation.fileName.value, "Converted.txt")
        XCTAssertEqual(preparation.selectedEncoding, .utf16BigEndianWithBOM)
        XCTAssertEqual(preparation.encodedFile.lineEnding, .crlf)
        XCTAssertEqual(
            preparation.encodedFile.data,
            Data([
                0xfe, 0xff,
                0x00, 0x41,
                0x00, 0x0d, 0x00, 0x0a,
                0x20, 0xac,
            ])
        )
        XCTAssertEqual(
            preparation.recoveryEditedAt,
            Date(timeIntervalSince1970: 1_786_800_100)
        )
    }

    func testPreflightExistingTargetRequiresReplacementWithoutWriting() async throws {
        let fixture = try makeSaveAsFixture()
        let originalTargetBytes = Data("Existing owner\n".utf8)
        let targetURL = fixture.filesURL.appendingPathComponent(
            "Existing.txt",
            isDirectory: false
        )
        try originalTargetBytes.write(to: targetURL, options: .withoutOverwriting)
        let editedState = try beginActiveDocumentEdit(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            newText: "Replacement text\n",
            editedAt: Date(timeIntervalSince1970: 1_786_800_200)
        ).state
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Existing.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_800_300)
        )

        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            recoveryStore: fixture.recoveryStore
        )

        guard case let .replacementRequired(plan) = preflight.target else {
            return XCTFail("Existing regular target must require explicit replacement.")
        }
        XCTAssertEqual(plan.fileName.value, "Existing.txt")
        guard case .existing = plan.expectation else {
            return XCTFail("Replacement plan must retain the exact existing snapshot.")
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), originalTargetBytes)
        XCTAssertEqual(preflight.preparedSave, preparation)
    }

    func testReadySaveAsCreatesVerifiedFileAndTerminatesRecovery() async throws {
        let fixture = try makeSaveAsFixture()
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            newText: "Ready output\n",
            editedAt: Date(timeIntervalSince1970: 1_786_800_400),
            recoveryStore: fixture.recoveryStore
        )
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Ready.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_800_500)
        )
        let connector = FileAccessConnector(fileManager: .default)
        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .ready = preflight.target else {
            return XCTFail("Absent target must be ready without replacement consent.")
        }

        let result = try await saveReadyPreparedSaveAs(
            state: editedState,
            preflight: preflight,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertEqual(result.disposition, .bound)
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(result.state.activeTab.document.recoveryState, .clean)
        XCTAssertEqual(
            try Data(
                contentsOf: fixture.filesURL.appendingPathComponent(
                    "Ready.txt",
                    isDirectory: false
                )
            ),
            Data("Ready output\n".utf8)
        )
        let remainingRecovery = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        XCTAssertNil(remainingRecovery)
    }

    func testReadySaveRejectsReplacementBeforeMutatingRecoveryOrTarget() async throws {
        let fixture = try makeSaveAsFixture()
        let connector = FileAccessConnector(fileManager: .default)
        let targetURL = fixture.filesURL.appendingPathComponent(
            "Existing.txt",
            isDirectory: false
        )
        let originalTargetBytes = Data("Existing owner\n".utf8)
        try originalTargetBytes.write(
            to: targetURL,
            options: .withoutOverwriting
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            newText: "Unsaved replacement\n",
            editedAt: Date(timeIntervalSince1970: 1_786_800_550),
            recoveryStore: fixture.recoveryStore
        )
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Existing.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_800_560)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .replacementRequired = preflight.target else {
            return XCTFail("Existing target must require replacement consent.")
        }
        let stateBeforeAttempt = editedState
        let loadedRecoveryBeforeAttempt = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        let recoveryBeforeAttempt = try XCTUnwrap(loadedRecoveryBeforeAttempt)

        do {
            _ = try await saveReadyPreparedSaveAs(
                state: editedState,
                preflight: preflight,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
            XCTFail("Ready Save must reject a replacement target.")
        } catch let error as SaveAsWorkflowError {
            XCTAssertEqual(error, .targetRequiresReplacement)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let loadedRecoveryAfterAttempt = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        let recoveryAfterAttempt = try XCTUnwrap(loadedRecoveryAfterAttempt)
        XCTAssertEqual(editedState, stateBeforeAttempt)
        XCTAssertEqual(recoveryAfterAttempt, recoveryBeforeAttempt)
        XCTAssertEqual(try Data(contentsOf: targetURL), originalTargetBytes)
    }

    func testReadySaveRejectsCurrentFileBeforeMutatingRecoveryOrTarget() async throws {
        let fixture = try makeSaveAsFixture()
        let connector = FileAccessConnector(fileManager: .default)
        let targetURL = fixture.filesURL.appendingPathComponent(
            "Current.txt",
            isDirectory: false
        )
        let originalTargetBytes = Data("Original\r\n".utf8)
        try originalTargetBytes.write(
            to: targetURL,
            options: .withoutOverwriting
        )
        let openedTarget = try await connector.openTextFile(at: targetURL)
        let openedState = openBoundDocument(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: openedTarget.text,
            fileBinding: openedTarget.binding
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Unsaved current\n",
            editedAt: Date(timeIntervalSince1970: 1_786_800_570),
            recoveryStore: fixture.recoveryStore
        )
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Current.txt",
            encoding: .utf16BigEndianWithBOM,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_800_580)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .currentFile = preflight.target else {
            return XCTFail("Selecting the bound source must route normal Save.")
        }
        let stateBeforeAttempt = editedState
        let loadedRecoveryBeforeAttempt = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        let recoveryBeforeAttempt = try XCTUnwrap(loadedRecoveryBeforeAttempt)

        do {
            _ = try await saveReadyPreparedSaveAs(
                state: editedState,
                preflight: preflight,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
            XCTFail("Ready Save must reject the current File target.")
        } catch let error as SaveAsWorkflowError {
            XCTAssertEqual(error, .targetIsCurrentFile)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let loadedRecoveryAfterAttempt = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        let recoveryAfterAttempt = try XCTUnwrap(loadedRecoveryAfterAttempt)
        XCTAssertEqual(editedState, stateBeforeAttempt)
        XCTAssertEqual(recoveryAfterAttempt, recoveryBeforeAttempt)
        XCTAssertEqual(try Data(contentsOf: targetURL), originalTargetBytes)
    }

    func testCancelReplacementLeavesDocumentTargetAndRecoveryUnchanged() async throws {
        let fixture = try makeSaveAsFixture()
        let targetURL = fixture.filesURL.appendingPathComponent(
            "Existing.txt",
            isDirectory: false
        )
        let originalTargetBytes = Data("Existing owner\n".utf8)
        try originalTargetBytes.write(to: targetURL, options: .withoutOverwriting)
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            newText: "Unsaved replacement\n",
            editedAt: Date(timeIntervalSince1970: 1_786_800_600),
            recoveryStore: fixture.recoveryStore
        )
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Existing.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_800_700)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            recoveryStore: fixture.recoveryStore
        )
        guard case .replacementRequired = preflight.target else {
            return XCTFail("Existing target must require replacement consent.")
        }
        let recoveryBeforeCancel = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )

        let cancelledState = try cancelPreparedSaveAs(
            state: editedState,
            preflight: preflight
        )

        let recoveryAfterCancel = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        XCTAssertEqual(cancelledState, editedState)
        XCTAssertEqual(try Data(contentsOf: targetURL), originalTargetBytes)
        XCTAssertEqual(recoveryAfterCancel, recoveryBeforeCancel)
    }

    func testConfirmedReplacementWritesTargetAndLeavesBoundSourceUnchanged() async throws {
        let fixture = try makeSaveAsFixture()
        let connector = FileAccessConnector(fileManager: .default)
        let sourceURL = fixture.filesURL.appendingPathComponent(
            "Source.txt",
            isDirectory: false
        )
        let sourceBytes = Data("Source\r\n".utf8)
        try sourceBytes.write(to: sourceURL, options: .withoutOverwriting)
        let openedSource = try await connector.openTextFile(at: sourceURL)
        let openedState = openBoundDocument(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: openedSource.text,
            fileBinding: openedSource.binding
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Replacement\ntext\n",
            editedAt: Date(timeIntervalSince1970: 1_786_800_800),
            recoveryStore: fixture.recoveryStore
        )
        let targetURL = fixture.filesURL.appendingPathComponent(
            "Target.txt",
            isDirectory: false
        )
        try Data("Target owner\n".utf8).write(
            to: targetURL,
            options: .withoutOverwriting
        )
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Target.txt",
            encoding: .utf16LittleEndianWithBOM,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_800_900)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .replacementRequired = preflight.target else {
            return XCTFail("Existing target must require replacement consent.")
        }

        let result = try await saveConfirmedReplacementPreparedSaveAs(
            state: editedState,
            preflight: preflight,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertEqual(result.disposition, .bound)
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(result.state.activeTab.document.title, "Target.txt")
        XCTAssertEqual(
            result.state.activeTab.document.fileBinding?.encoding,
            .utf16LittleEndianWithBOM
        )
        XCTAssertEqual(
            result.state.activeTab.document.fileBinding?.lineEnding,
            .crlf
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertEqual(
            try Data(contentsOf: targetURL),
            Data([
                0xff, 0xfe,
                0x52, 0x00, 0x65, 0x00, 0x70, 0x00, 0x6c, 0x00,
                0x61, 0x00, 0x63, 0x00, 0x65, 0x00, 0x6d, 0x00,
                0x65, 0x00, 0x6e, 0x00, 0x74, 0x00,
                0x0d, 0x00, 0x0a, 0x00,
                0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00,
                0x0d, 0x00, 0x0a, 0x00,
            ])
        )
        let remainingRecovery = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        XCTAssertNil(remainingRecovery)
    }

    func testCurrentFileSaveAsUsesSelectedEncodingWithoutReplacement() async throws {
        let fixture = try makeSaveAsFixture()
        let connector = FileAccessConnector(fileManager: .default)
        let sourceURL = fixture.filesURL.appendingPathComponent(
            "Current.txt",
            isDirectory: false
        )
        try Data("Original\r\n".utf8).write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        let documentID = DocumentID(rawValue: UUID())
        let openedSnapshot = try await connector.openTextFile(
            at: sourceURL,
            documentID: documentID
        )
        let openedState = openObservedBoundDocument(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            documentID: documentID,
            tabID: TabID(rawValue: UUID()),
            text: openedSnapshot.openedFile.text,
            observation: ObservedBoundFile(
                binding: openedSnapshot.openedFile.binding,
                providerConflictVersions: openedSnapshot.providerConflictVersions
            )
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Current\nedit\n",
            editedAt: Date(timeIntervalSince1970: 1_786_801_000),
            recoveryStore: fixture.recoveryStore
        )
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Current.txt",
            encoding: .utf16BigEndianWithBOM,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_801_100)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .currentFile = preflight.target else {
            return XCTFail("Selecting the bound source must route normal Save.")
        }

        let result = try await saveCurrentFilePreparedSaveAs(
            state: editedState,
            preflight: preflight,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertEqual(result.disposition, .bound)
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            result.state.activeTab.document.fileBinding?.encoding,
            .utf16BigEndianWithBOM
        )
        XCTAssertEqual(
            result.state.activeTab.document.fileBinding?.lineEnding,
            .crlf
        )
        XCTAssertEqual(
            try Data(contentsOf: sourceURL),
            Data([
                0xfe, 0xff,
                0x00, 0x43, 0x00, 0x75, 0x00, 0x72, 0x00, 0x72,
                0x00, 0x65, 0x00, 0x6e, 0x00, 0x74,
                0x00, 0x0d, 0x00, 0x0a,
                0x00, 0x65, 0x00, 0x64, 0x00, 0x69, 0x00, 0x74,
                0x00, 0x0d, 0x00, 0x0a,
            ])
        )
        let remainingRecovery = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        XCTAssertNil(remainingRecovery)
    }

    func testStableIdentityConflictCannotReplaceSameBoundLocatorThroughSaveAs() async throws {
        let fixture = try makeSaveAsFixture()
        let targetURL = fixture.filesURL.appendingPathComponent(
            "Current.txt",
            isDirectory: false
        )
        let externalBytes = Data("External replacement\n".utf8)
        try externalBytes.write(to: targetURL, options: .withoutOverwriting)
        let volumeUUID = UUID(
            uuidString: "70000000-0000-0000-0000-000000000010"
        )!
        let baselineIdentity = FileIdentity(
            volumeUUID: volumeUUID,
            documentIdentifier: 70
        )
        let externalIdentity = FileIdentity(
            volumeUUID: volumeUUID,
            documentIdentifier: 71
        )
        let connector = makeStableIdentityConflictConnector(
            boundURL: targetURL,
            externalIdentity: externalIdentity
        )
        let baselineFile = try encodeNewTextFile(text: "Opened baseline\n")
        let documentID = DocumentID(rawValue: UUID())
        let binding = FileBinding(
            locatorURL: targetURL,
            bookmark: try FileBookmark(
                data: targetURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            ),
            identity: baselineIdentity,
            displayName: try ValidatedFileName(validating: "Current.txt"),
            digest: baselineFile.digest,
            encoding: baselineFile.encoding,
            lineEnding: baselineFile.lineEnding
        )
        let openedState = openBoundDocument(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            documentID: documentID,
            tabID: TabID(rawValue: UUID()),
            text: baselineFile.text,
            fileBinding: binding
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Local edit\n",
            editedAt: Date(timeIntervalSince1970: 1_786_801_200),
            recoveryStore: fixture.recoveryStore
        )
        let conflictedState = try markDocumentFileConflict(
            state: editedState,
            documentID: documentID,
            conflict: .stableIdentityChanged
        )
        let preparation = try prepareSaveAs(
            state: conflictedState,
            fileName: "Current.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_801_300)
        )
        let stateBeforeAttempt = conflictedState
        var stateAfterAttempt = conflictedState
        let loadedRecoveryBeforeAttempt = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        let recoveryBeforeAttempt = try XCTUnwrap(loadedRecoveryBeforeAttempt)
        let preflight = try await preflightPreparedSaveAs(
            state: conflictedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )

        guard case .currentFile = preflight.target else {
            if case .replacementRequired = preflight.target {
                do {
                    let result = try await saveConfirmedReplacementPreparedSaveAs(
                        state: conflictedState,
                        preflight: preflight,
                        fileAccessConnector: connector,
                        recoveryStore: fixture.recoveryStore
                    )
                    stateAfterAttempt = result.state
                    XCTFail("Conflicted current locator entered confirmed replacement write.")
                } catch {
                    XCTFail("Conflicted current locator entered replacement flow: \(error)")
                }
            }
            let recoveryAfterAttempt = try await fixture.recoveryStore.load(
                documentID: documentID
            )
            XCTAssertEqual(stateAfterAttempt, stateBeforeAttempt)
            XCTAssertEqual(recoveryAfterAttempt, recoveryBeforeAttempt)
            XCTAssertEqual(try Data(contentsOf: targetURL), externalBytes)
            return XCTFail("Conflicted current locator must route through current-File safety.")
        }

        do {
            _ = try await saveCurrentFilePreparedSaveAs(
                state: conflictedState,
                preflight: preflight,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
            XCTFail("Stable-identity conflict must block current-File Save As.")
        } catch let error as SaveAsWorkflowError {
            XCTAssertEqual(
                error,
                .currentFileHasConflict(
                    documentID: documentID,
                    conflict: .stableIdentityChanged
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recoveryAfterAttempt = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        XCTAssertEqual(stateAfterAttempt, stateBeforeAttempt)
        XCTAssertEqual(recoveryAfterAttempt, recoveryBeforeAttempt)
        XCTAssertEqual(try Data(contentsOf: targetURL), externalBytes)
    }

    func testStableIdentityConflictCannotReplaceExistingTargetAtUnknownMovedLocator() async throws {
        let fixture = try makeSaveAsFixture()
        let retainedBoundURL = fixture.filesURL.appendingPathComponent(
            "Original.txt",
            isDirectory: false
        )
        let movedTargetURL = fixture.filesURL.appendingPathComponent(
            "Moved.txt",
            isDirectory: false
        )
        let externalBytes = Data("Moved external replacement\n".utf8)
        try externalBytes.write(
            to: movedTargetURL,
            options: .withoutOverwriting
        )
        let volumeUUID = UUID(
            uuidString: "70000000-0000-0000-0000-000000000011"
        )!
        let baselineIdentity = FileIdentity(
            volumeUUID: volumeUUID,
            documentIdentifier: 80
        )
        let externalIdentity = FileIdentity(
            volumeUUID: volumeUUID,
            documentIdentifier: 81
        )
        let connector = makeStableIdentityConflictConnector(
            boundURL: retainedBoundURL,
            externalIdentity: externalIdentity
        )
        let baselineFile = try encodeNewTextFile(text: "Opened before move\n")
        let documentID = DocumentID(rawValue: UUID())
        let binding = FileBinding(
            locatorURL: retainedBoundURL,
            bookmark: try FileBookmark(data: Data([0x01])),
            identity: baselineIdentity,
            displayName: try ValidatedFileName(validating: "Original.txt"),
            digest: baselineFile.digest,
            encoding: baselineFile.encoding,
            lineEnding: baselineFile.lineEnding
        )
        let openedState = openBoundDocument(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            documentID: documentID,
            tabID: TabID(rawValue: UUID()),
            text: baselineFile.text,
            fileBinding: binding
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Local edit after move\n",
            editedAt: Date(timeIntervalSince1970: 1_786_801_400),
            recoveryStore: fixture.recoveryStore
        )
        let conflictedState = try markDocumentFileConflict(
            state: editedState,
            documentID: documentID,
            conflict: .stableIdentityChanged
        )
        let preparation = try prepareSaveAs(
            state: conflictedState,
            fileName: "Moved.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_801_500)
        )
        let stateBeforeAttempt = conflictedState
        var stateAfterAttempt = conflictedState
        let loadedRecoveryBeforeAttempt = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        let recoveryBeforeAttempt = try XCTUnwrap(loadedRecoveryBeforeAttempt)

        do {
            let preflight = try await preflightPreparedSaveAs(
                state: conflictedState,
                preparedSave: preparation,
                selectedDirectoryURL: fixture.filesURL,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
            guard case .replacementRequired = preflight.target else {
                return XCTFail("Existing moved target unexpectedly bypassed replacement preflight.")
            }
            let result = try await saveConfirmedReplacementPreparedSaveAs(
                state: conflictedState,
                preflight: preflight,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
            stateAfterAttempt = result.state
            XCTFail("Stable-identity conflict entered confirmed replacement write.")
        } catch let error as SaveAsWorkflowError {
            XCTAssertEqual(
                error,
                .currentFileHasConflict(
                    documentID: documentID,
                    conflict: .stableIdentityChanged
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recoveryAfterAttempt = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        XCTAssertEqual(stateAfterAttempt, stateBeforeAttempt)
        XCTAssertEqual(recoveryAfterAttempt, recoveryBeforeAttempt)
        XCTAssertEqual(try Data(contentsOf: movedTargetURL), externalBytes)
    }

    func testStableIdentityConflictBlocksStoredReplacementPreflightBeforeWrite() async throws {
        let fixture = try makeSaveAsFixture()
        let sourceURL = fixture.filesURL.appendingPathComponent(
            "Source.txt",
            isDirectory: false
        )
        try Data("Opened source\n".utf8).write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        let targetURL = fixture.filesURL.appendingPathComponent(
            "Existing.txt",
            isDirectory: false
        )
        let externalBytes = Data("Existing external target\n".utf8)
        try externalBytes.write(to: targetURL, options: .withoutOverwriting)
        let connector = FileAccessConnector(fileManager: .default)
        let documentID = DocumentID(rawValue: UUID())
        let openedSnapshot = try await connector.openTextFile(
            at: sourceURL,
            documentID: documentID
        )
        addTeardownBlock {
            await connector.stopPresenting(documentID: documentID)
        }
        let openedState = openObservedBoundDocument(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            documentID: documentID,
            tabID: TabID(rawValue: UUID()),
            text: openedSnapshot.openedFile.text,
            observation: ObservedBoundFile(
                binding: openedSnapshot.openedFile.binding,
                providerConflictVersions: openedSnapshot.providerConflictVersions
            )
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Local edit before conflict\n",
            editedAt: Date(timeIntervalSince1970: 1_786_801_600),
            recoveryStore: fixture.recoveryStore
        )
        let preparation = try prepareSaveAs(
            state: editedState,
            fileName: "Existing.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_801_700)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: editedState,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .replacementRequired = preflight.target else {
            return XCTFail("Clean existing target must require replacement confirmation.")
        }
        let conflictedState = try markDocumentFileConflict(
            state: editedState,
            documentID: documentID,
            conflict: .stableIdentityChanged
        )
        let stateBeforeAttempt = conflictedState
        var stateAfterAttempt = conflictedState
        let loadedRecoveryBeforeAttempt = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        let recoveryBeforeAttempt = try XCTUnwrap(loadedRecoveryBeforeAttempt)

        do {
            let result = try await saveConfirmedReplacementPreparedSaveAs(
                state: conflictedState,
                preflight: preflight,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
            stateAfterAttempt = result.state
            XCTFail("Stored replacement preflight wrote after stable-identity conflict.")
        } catch let error as SaveAsWorkflowError {
            XCTAssertEqual(
                error,
                .currentFileHasConflict(
                    documentID: documentID,
                    conflict: .stableIdentityChanged
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recoveryAfterAttempt = try await fixture.recoveryStore.load(
            documentID: documentID
        )
        XCTAssertEqual(stateAfterAttempt, stateBeforeAttempt)
        XCTAssertEqual(recoveryAfterAttempt, recoveryBeforeAttempt)
        XCTAssertEqual(try Data(contentsOf: targetURL), externalBytes)
    }

    private func makeSaveAsFixture() throws -> SaveAsWorkflowFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        return SaveAsWorkflowFixture(
            filesURL: filesURL,
            recoveryStore: FileRecoveryStore(
                rootURL: rootURL.appendingPathComponent("Recovery", isDirectory: true),
                fileManager: .default
            )
        )
    }
}

private struct SaveAsWorkflowFixture {
    let filesURL: URL
    let recoveryStore: FileRecoveryStore
}

private func makeStableIdentityConflictConnector(
    boundURL: URL,
    externalIdentity: FileIdentity
) -> FileAccessConnector {
    FileAccessConnector(
        fileManager: .default,
        bookmarkCreator: { url in
            try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        bookmarkResolver: { bookmark in
            if bookmark.data == Data([0x01]) {
                return ResolvedFileBookmark(url: boundURL, isStale: false)
            }
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark.data,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedFileBookmark(url: url, isStale: isStale)
        },
        identityReader: { _ in externalIdentity },
        replacer: { originalURL, replacementURL, fileManager in
            try fileManager.replaceItemAt(
                originalURL,
                withItemAt: replacementURL,
                backupItemName: nil,
                options: []
            )
        }
    )
}

private func makeSaveAsSourceBinding() throws -> FileBinding {
    FileBinding(
        locatorURL: URL(fileURLWithPath: "/private/tmp/PhonePad-Source.txt"),
        bookmark: try FileBookmark(data: Data([0x01])),
        identity: FileIdentity(
            volumeUUID: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 7
        ),
        displayName: try ValidatedFileName(validating: "Source.txt"),
        digest: try FileDigest(bytes: Data(repeating: 0x11, count: 32)),
        encoding: .utf8,
        lineEnding: .crlf
    )
}
