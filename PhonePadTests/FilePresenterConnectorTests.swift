import CryptoKit
import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class FilePresenterConnectorTests: XCTestCase {
    func testPresentedOpenRegistersBeforeBaselineAndExplicitStopRemovesPresenter() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Presented.txt", isDirectory: false)
        let bytes = Data("Presented baseline\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        let registration = FilePresenterRegistrationObservation(documentID: documentID)
        let connector = makePresenterConnector(
            bookmarkResolver: resolvePresenterBookmark,
            identityReader: { _ in
                registration.recordCurrentRegistration()
                return nil
            },
            unresolvedVersionCountReader: { _ in 2 }
        )

        let snapshot = try await connector.openTextFile(
            at: fileURL,
            documentID: documentID
        )

        XCTAssertTrue(registration.wasRegisteredDuringBaselineRead())
        XCTAssertTrue(registration.baselineReadUsedPresenterQueue())
        XCTAssertEqual(snapshot.openedFile.text, "Presented baseline\n")
        XCTAssertEqual(snapshot.providerConflictVersions, .unresolved(count: 2))
        XCTAssertTrue(isFilePresenterRegistered(documentID: documentID))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        await connector.stopPresenting(documentID: documentID)

        XCTAssertFalse(isFilePresenterRegistered(documentID: documentID))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        try FileManager.default.removeItem(at: folderURL)
    }

    func testPresentedOpenFailureRemovesProvisionalPresenterWithoutChangingFile() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Binary.txt", isDirectory: false)
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)

        do {
            _ = try await connector.openTextFile(
                at: fileURL,
                documentID: documentID
            )
            XCTFail("Expected unsupported binary content to reject presented Open.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .textDecodingFailed(.unsupportedContent(.rasterImage))
            )
        }

        XCTAssertFalse(isFilePresenterRegistered(documentID: documentID))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        try FileManager.default.removeItem(at: folderURL)
    }

    func testPresenterCallbacksEmitOnlyImmutableDocumentHintsOnSerialQueue() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Callbacks.txt", isDirectory: false)
        let movedURL = folderURL.appendingPathComponent("Moved.txt", isDirectory: false)
        let bytes = Data("Callback baseline\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)
        let snapshot = try await connector.openTextFile(
            at: fileURL,
            documentID: documentID
        )
        guard let presenter = registeredPresentedFile(documentID: documentID) else {
            return XCTFail("Expected registered File presenter.")
        }
        var hints = connector.presentationChangeHints.makeAsyncIterator()

        presenter.presentedItemOperationQueue.addOperation {
            presenter.presentedItemDidChange()
        }
        let contentHint = await hints.next()
        _ = try await connector.reconcilePresentedFile(
            documentID: documentID,
            binding: snapshot.openedFile.binding
        )
        presenter.presentedItemOperationQueue.addOperation {
            presenter.presentedItemDidMove(to: movedURL)
        }
        let moveHint = await hints.next()

        XCTAssertEqual(presenter.presentedItemOperationQueue.maxConcurrentOperationCount, 1)
        XCTAssertEqual(contentHint, documentID)
        XCTAssertEqual(moveHint, documentID)
        XCTAssertEqual(
            presenter.presentedItemURL?.standardizedFileURL,
            movedURL.standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedURL.path))

        await connector.stopPresenting(documentID: documentID)
        try FileManager.default.removeItem(at: folderURL)
    }

    func testReconcileRetainsCallbackEmittedAfterHintConsumptionBoundary() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent(
            "Repeated callback.txt",
            isDirectory: false
        )
        let sentinelFileURL = folderURL.appendingPathComponent(
            "Sentinel callback.txt",
            isDirectory: false
        )
        let bytes = Data("Repeated callback baseline\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        try bytes.write(to: sentinelFileURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        let sentinelDocumentID = DocumentID(rawValue: UUID())
        let callbackControl = PresenterReconcileCallbackControl()
        let connector = makePresenterConnector(
            bookmarkResolver: resolvePresenterBookmark,
            identityReader: { _ in
                callbackControl.emitCallbackIfArmed()
                return nil
            },
            unresolvedVersionCountReader: { _ in 0 }
        )
        let snapshot = try await connector.openTextFile(
            at: fileURL,
            documentID: documentID
        )
        _ = try await connector.openTextFile(
            at: sentinelFileURL,
            documentID: sentinelDocumentID
        )
        guard let presenter = registeredPresentedFile(documentID: documentID) else {
            return XCTFail("Expected registered File presenter.")
        }
        guard let sentinelPresenter = registeredPresentedFile(
            documentID: sentinelDocumentID
        ) else {
            return XCTFail("Expected registered sentinel File presenter.")
        }
        callbackControl.attach(presenter: presenter)
        var hints = connector.presentationChangeHints.makeAsyncIterator()
        presenter.presentedItemOperationQueue.addOperation {
            presenter.presentedItemDidChange()
        }
        let firstHint = await hints.next()
        XCTAssertEqual(firstHint, documentID)
        callbackControl.arm()

        _ = try await connector.reconcilePresentedFile(
            documentID: documentID,
            binding: snapshot.openedFile.binding
        )
        try sentinelPresenter.performSynchronousAccess {
            sentinelPresenter.presentedItemDidChange()
        }

        let secondHint = await hints.next()
        XCTAssertTrue(callbackControl.emittedOnPresenterQueue())
        XCTAssertEqual(
            secondHint,
            documentID,
            "Callback emitted after the authoritative read boundary must retain a later reconciliation hint."
        )
        guard secondHint == documentID else {
            await connector.pausePresenters()
            try FileManager.default.removeItem(at: folderURL)
            return
        }
        let sentinelHint = await hints.next()
        XCTAssertEqual(sentinelHint, sentinelDocumentID)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testResumeReconcilesStableIdentityMoveAsLocatorContinuityWithoutWriting() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let originalURL = folderURL.appendingPathComponent("Original.txt", isDirectory: false)
        let movedURL = folderURL.appendingPathComponent("Moved.txt", isDirectory: false)
        let bytes = Data("Same baseline\n".utf8)
        try bytes.write(to: movedURL, options: .withoutOverwriting)
        let identity = FileIdentity(
            volumeUUID: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 81
        )
        let baseline = try makePresenterBinding(
            locatorURL: originalURL,
            bookmarkData: Data([0x81]),
            identity: identity,
            data: bytes
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: { _ in
                ResolvedFileBookmark(url: movedURL, isStale: true)
            },
            identityReader: { _ in identity },
            unresolvedVersionCountReader: { _ in 0 }
        )

        let outcomes = await connector.resumePresenters(
            bindings: [
                PresentedFileRegistration(
                    documentID: documentID,
                    binding: baseline
                )
            ]
        )

        guard case let .observed(observation)? = outcomes[documentID] else {
            return XCTFail("Expected exact foreground observation, received \(outcomes).")
        }
        XCTAssertEqual(observation.providerConflictVersions, .none)
        XCTAssertEqual(observation.binding.identity, identity)
        XCTAssertEqual(observation.binding.digest, baseline.digest)
        XCTAssertEqual(
            observation.binding.locatorURL.standardizedFileURL,
            movedURL.standardizedFileURL
        )
        XCTAssertEqual(
            reconcileFileBinding(baseline: baseline, observation: observation),
            .continuous(
                updatedBinding: FileBinding(
                    locatorURL: movedURL,
                    bookmark: observation.binding.bookmark,
                    identity: identity,
                    displayName: baseline.displayName,
                    digest: baseline.digest,
                    encoding: baseline.encoding,
                    lineEnding: baseline.lineEnding
                )
            )
        )
        XCTAssertTrue(isFilePresenterRegistered(documentID: documentID))
        XCTAssertEqual(try Data(contentsOf: movedURL), bytes)

        await connector.pausePresenters()

        XCTAssertFalse(isFilePresenterRegistered(documentID: documentID))
        XCTAssertEqual(try Data(contentsOf: movedURL), bytes)
        try FileManager.default.removeItem(at: folderURL)
    }

    func testReconcileReturnsExactIdentityDigestAndProviderVersionsWithoutWriting() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Observed.txt", isDirectory: false)
        let originalBytes = Data("Original baseline\n".utf8)
        let changedBytes = Data("External content\n".utf8)
        try changedBytes.write(to: fileURL, options: .withoutOverwriting)
        let baselineIdentity = FileIdentity(
            volumeUUID: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 82
        )
        let changedIdentity = FileIdentity(
            volumeUUID: baselineIdentity.volumeUUID,
            documentIdentifier: 83
        )
        let baseline = try makePresenterBinding(
            locatorURL: fileURL,
            bookmarkData: try makePresenterBookmarkData(url: fileURL),
            identity: baselineIdentity,
            data: originalBytes
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: resolvePresenterBookmark,
            identityReader: { _ in changedIdentity },
            unresolvedVersionCountReader: { _ in 3 }
        )
        _ = await connector.resumePresenters(
            bindings: [PresentedFileRegistration(documentID: documentID, binding: baseline)]
        )

        let observation = try await connector.reconcilePresentedFile(
            documentID: documentID,
            binding: baseline
        )

        XCTAssertEqual(observation.binding.identity, changedIdentity)
        XCTAssertEqual(observation.binding.digest, try presenterDigest(data: changedBytes))
        XCTAssertEqual(observation.providerConflictVersions, .unresolved(count: 3))
        XCTAssertEqual(
            reconcileFileBinding(baseline: baseline, observation: observation),
            .conflicted(
                retainedBinding: baseline,
                conflict: .stableIdentityChanged
            )
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), changedBytes)

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testReconcileClassifiesContentChangeFromExactRealFileDigestWithoutWriting() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Content.txt", isDirectory: false)
        let originalBytes = Data("Original baseline\n".utf8)
        let changedBytes = Data("External content\n".utf8)
        try changedBytes.write(to: fileURL, options: .withoutOverwriting)
        let identity = FileIdentity(
            volumeUUID: UUID(uuidString: "83000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 83
        )
        let baseline = try makePresenterBinding(
            locatorURL: fileURL,
            bookmarkData: try makePresenterBookmarkData(url: fileURL),
            identity: identity,
            data: originalBytes
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: resolvePresenterBookmark,
            identityReader: { _ in identity },
            unresolvedVersionCountReader: { _ in 0 }
        )
        _ = await connector.resumePresenters(
            bindings: [PresentedFileRegistration(documentID: documentID, binding: baseline)]
        )

        let observation = try await connector.reconcilePresentedFile(
            documentID: documentID,
            binding: baseline
        )
        guard case let .conflicted(_, conflict) = reconcileFileBinding(
            baseline: baseline,
            observation: observation
        ) else {
            return XCTFail("Expected external content conflict.")
        }

        XCTAssertEqual(conflict, .contentChanged)
        XCTAssertEqual(observation.binding.digest, try presenterDigest(data: changedBytes))
        XCTAssertEqual(try Data(contentsOf: fileURL), changedBytes)

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testReconcileClassifiesMovedNilIdentityLocatorAsAmbiguousWithoutWriting() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let originalURL = folderURL.appendingPathComponent("Prior.txt", isDirectory: false)
        let movedURL = folderURL.appendingPathComponent("Moved nil identity.txt", isDirectory: false)
        let bytes = Data("Same bytes\n".utf8)
        try bytes.write(to: movedURL, options: .withoutOverwriting)
        let baseline = try makePresenterBinding(
            locatorURL: originalURL,
            bookmarkData: Data([0x84]),
            identity: nil,
            data: bytes
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: { _ in
                ResolvedFileBookmark(url: movedURL, isStale: true)
            },
            identityReader: { _ in nil },
            unresolvedVersionCountReader: { _ in 0 }
        )

        let outcomes = await connector.resumePresenters(
            bindings: [PresentedFileRegistration(documentID: documentID, binding: baseline)]
        )
        guard case let .observed(observation)? = outcomes[documentID],
              case let .conflicted(retainedBinding, conflict) = reconcileFileBinding(
                baseline: baseline,
                observation: observation
              ) else {
            return XCTFail("Expected ambiguous locator conflict.")
        }

        XCTAssertEqual(conflict, .ambiguousLocatorChange)
        XCTAssertEqual(retainedBinding, baseline)
        XCTAssertEqual(try Data(contentsOf: movedURL), bytes)

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testResumeReturnsIndependentTypedOutcomesWhenOneBookmarkIsUnavailable() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let availableURL = folderURL.appendingPathComponent("Available.txt", isDirectory: false)
        let unavailableURL = folderURL.appendingPathComponent("Unavailable.txt", isDirectory: false)
        let availableBytes = Data("Available\n".utf8)
        let unavailableBytes = Data("Unavailable\n".utf8)
        try availableBytes.write(to: availableURL, options: .withoutOverwriting)
        try unavailableBytes.write(to: unavailableURL, options: .withoutOverwriting)
        let availableDocumentID = DocumentID(rawValue: UUID())
        let unavailableDocumentID = DocumentID(rawValue: UUID())
        let availableBookmarkData = Data([0xa1])
        let unavailableBookmarkData = Data([0xb1])
        let availableBinding = try makePresenterBinding(
            locatorURL: availableURL,
            bookmarkData: availableBookmarkData,
            identity: nil,
            data: availableBytes
        )
        let unavailableBinding = try makePresenterBinding(
            locatorURL: unavailableURL,
            bookmarkData: unavailableBookmarkData,
            identity: nil,
            data: unavailableBytes
        )
        let connector = makePresenterConnector(
            bookmarkResolver: { bookmark in
                guard bookmark.data == availableBookmarkData else {
                    throw ForcedPresenterBookmarkError(code: 91)
                }
                return ResolvedFileBookmark(url: availableURL, isStale: false)
            },
            identityReader: { _ in nil },
            unresolvedVersionCountReader: { _ in 0 }
        )

        let outcomes = await connector.resumePresenters(
            bindings: [
                PresentedFileRegistration(
                    documentID: unavailableDocumentID,
                    binding: unavailableBinding
                ),
                PresentedFileRegistration(
                    documentID: availableDocumentID,
                    binding: availableBinding
                ),
            ]
        )

        guard case .observed? = outcomes[availableDocumentID] else {
            return XCTFail("Expected available File to reconcile independently.")
        }
        XCTAssertEqual(
            outcomes[unavailableDocumentID],
            .failed(.bookmarkResolutionFailed(code: 91))
        )
        XCTAssertTrue(isFilePresenterRegistered(documentID: availableDocumentID))
        XCTAssertFalse(isFilePresenterRegistered(documentID: unavailableDocumentID))
        XCTAssertEqual(try Data(contentsOf: availableURL), availableBytes)
        XCTAssertEqual(try Data(contentsOf: unavailableURL), unavailableBytes)

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testResumeKeepsResolvedPresenterRegisteredWhenObservationNeedsRetry() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let missingURL = folderURL.appendingPathComponent("Offline.txt", isDirectory: false)
        let baseline = try makePresenterBinding(
            locatorURL: missingURL,
            bookmarkData: Data([0xc1]),
            identity: nil,
            data: Data("Prior baseline\n".utf8)
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: { _ in
                ResolvedFileBookmark(url: missingURL, isStale: false)
            },
            identityReader: { _ in nil },
            unresolvedVersionCountReader: { _ in 0 }
        )

        let outcomes = await connector.resumePresenters(
            bindings: [PresentedFileRegistration(documentID: documentID, binding: baseline)]
        )

        XCTAssertEqual(outcomes[documentID], .failed(.boundFileMissing))
        XCTAssertTrue(isFilePresenterRegistered(documentID: documentID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testReadCurrentReturnsUnresolvedVersionObservationWithoutResolvingOrWriting() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Reload.txt", isDirectory: false)
        let bytes = Data("Provider current\n".utf8)
        try bytes.write(to: fileURL, options: .withoutOverwriting)
        let binding = try makePresenterBinding(
            locatorURL: fileURL,
            bookmarkData: try makePresenterBookmarkData(url: fileURL),
            identity: nil,
            data: bytes
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: resolvePresenterBookmark,
            identityReader: { _ in nil },
            unresolvedVersionCountReader: { _ in 2 }
        )
        _ = await connector.resumePresenters(
            bindings: [PresentedFileRegistration(documentID: documentID, binding: binding)]
        )

        let snapshot = try await connector.readCurrentPresentedTextFile(
            documentID: documentID,
            binding: binding
        )

        XCTAssertEqual(snapshot.openedFile.text, "Provider current\n")
        XCTAssertEqual(snapshot.openedFile.binding.digest, binding.digest)
        XCTAssertEqual(snapshot.providerConflictVersions, .unresolved(count: 2))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testPresenterAwareSaveUsesRegisteredPresenterAndKeepsVerifiedBindingPresented() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Save.txt", isDirectory: false)
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        let connector = FileAccessConnector(fileManager: .default)
        let opened = try await connector.openTextFile(
            at: fileURL,
            documentID: documentID
        )
        let encodedFile = try encodeNewTextFile(text: "Saved\n")

        let outcome = try await connector.saveTextFile(
            documentID: documentID,
            binding: opened.openedFile.binding,
            encodedFile: encodedFile
        )

        guard case let .bound(savedBinding) = outcome else {
            return XCTFail("Expected verified bound Save, received \(outcome).")
        }
        XCTAssertEqual(savedBinding.digest, encodedFile.digest)
        XCTAssertTrue(isFilePresenterRegistered(documentID: documentID))
        XCTAssertEqual(
            registeredPresentedFile(documentID: documentID)?
                .presentedItemURL?.standardizedFileURL,
            savedBinding.locatorURL.standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), encodedFile.data)

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testPresenterAwareSaveBlocksUnresolvedVersionsAtFinalAccessorWithoutWriting() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Conflict.txt", isDirectory: false)
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: fileURL, options: .withoutOverwriting)
        let binding = try makePresenterBinding(
            locatorURL: fileURL,
            bookmarkData: try makePresenterBookmarkData(url: fileURL),
            identity: nil,
            data: originalBytes
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: resolvePresenterBookmark,
            identityReader: { _ in nil },
            unresolvedVersionCountReader: { _ in 4 }
        )
        try await connector.startPresenting(documentID: documentID, binding: binding)

        do {
            _ = try await connector.saveTextFile(
                documentID: documentID,
                binding: binding,
                encodedFile: try encodeNewTextFile(text: "PhonePad edit\n")
            )
            XCTFail("Expected unresolved provider versions to block Save.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .fileConflict(.unresolvedProviderVersions(count: 4))
            )
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertTrue(isFilePresenterRegistered(documentID: documentID))

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testMoveCallbackReconcileAndSaveUseCurrentPresenterURL() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let originalURL = folderURL.appendingPathComponent("Original.txt", isDirectory: false)
        let movedURL = folderURL.appendingPathComponent("Moved.txt", isDirectory: false)
        let originalBytes = Data("Original baseline\n".utf8)
        try originalBytes.write(to: originalURL, options: .withoutOverwriting)
        let identity = FileIdentity(
            volumeUUID: UUID(uuidString: "81000000-0000-0000-0000-000000000091")!,
            documentIdentifier: 91
        )
        let documentID = DocumentID(rawValue: UUID())
        let connector = makePresenterConnector(
            bookmarkResolver: { _ in
                ResolvedFileBookmark(url: originalURL, isStale: false)
            },
            identityReader: { _ in identity },
            unresolvedVersionCountReader: { _ in 0 }
        )
        let opened = try await connector.openTextFile(
            at: originalURL,
            documentID: documentID
        )
        guard let presenter = registeredPresentedFile(documentID: documentID) else {
            return XCTFail("Expected registered File presenter.")
        }
        var hints = connector.presentationChangeHints.makeAsyncIterator()
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        presenter.presentedItemOperationQueue.addOperation {
            presenter.presentedItemDidMove(to: movedURL)
        }

        let moveHint = await hints.next()
        XCTAssertEqual(moveHint, documentID)

        let reloaded = try await connector.readCurrentPresentedTextFile(
            documentID: documentID,
            binding: opened.openedFile.binding
        )
        XCTAssertEqual(reloaded.openedFile.text, "Original baseline\n")
        XCTAssertEqual(
            reloaded.openedFile.binding.locatorURL.standardizedFileURL,
            movedURL.standardizedFileURL
        )
        presenter.presentedItemOperationQueue.addOperation {
            presenter.presentedItemDidChange()
        }
        let contentHint = await hints.next()
        XCTAssertEqual(contentHint, documentID)

        let observation = try await connector.reconcilePresentedFile(
            documentID: documentID,
            binding: opened.openedFile.binding
        )
        XCTAssertEqual(observation.binding.identity, identity)
        XCTAssertEqual(observation.binding.digest, opened.openedFile.binding.digest)
        XCTAssertEqual(
            observation.binding.locatorURL.standardizedFileURL,
            movedURL.standardizedFileURL
        )

        let encodedFile = try encodeNewTextFile(text: "Saved after move\n")
        let outcome = try await connector.saveTextFile(
            documentID: documentID,
            binding: opened.openedFile.binding,
            encodedFile: encodedFile
        )

        guard case let .bound(savedBinding) = outcome else {
            return XCTFail("Expected verified bound Save after provider move.")
        }
        XCTAssertEqual(
            savedBinding.locatorURL.standardizedFileURL,
            movedURL.standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: movedURL), encodedFile.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))

        await connector.pausePresenters()
        try FileManager.default.removeItem(at: folderURL)
    }

    func testHintRelayRejectsDeactivatedPresenterGenerationAfterReplacement() throws {
        let pair = AsyncStream<DocumentID>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let relay = PresentationHintRelay(continuation: pair.continuation)
        let documentID = DocumentID(rawValue: UUID())
        let oldPresenter = PresentedFile(
            documentID: documentID,
            itemURL: URL(fileURLWithPath: "/old.txt"),
            changeHandler: { changedDocumentID, generation in
                relay.offer(documentID: changedDocumentID, generation: generation)
            }
        )
        relay.activate(documentID: documentID, generation: oldPresenter.generation)
        oldPresenter.deactivate()
        relay.deactivate(documentID: documentID, generation: oldPresenter.generation)
        let newPresenter = PresentedFile(
            documentID: documentID,
            itemURL: URL(fileURLWithPath: "/new.txt"),
            changeHandler: { changedDocumentID, generation in
                relay.offer(documentID: changedDocumentID, generation: generation)
            }
        )
        relay.activate(documentID: documentID, generation: newPresenter.generation)

        try oldPresenter.performSynchronousAccess {
            oldPresenter.presentedItemDidChange()
        }
        relay.offer(documentID: documentID, generation: oldPresenter.generation)

        XCTAssertEqual(relay.pendingHintCount(), 0)

        try newPresenter.performSynchronousAccess {
            newPresenter.presentedItemDidChange()
        }

        XCTAssertEqual(relay.pendingHintCount(), 1)
        relay.finish()
    }

    func testHintRelayCoalescesPerDocumentAndBoundsCallbackStorm() async {
        let maximumBufferedHintCount = 4
        let pair = AsyncStream<DocumentID>.makeStream(
            bufferingPolicy: .bufferingNewest(maximumBufferedHintCount)
        )
        let relay = PresentationHintRelay(continuation: pair.continuation)
        let repeatedDocumentID = DocumentID(rawValue: UUID())
        let repeatedGeneration = UUID()
        relay.activate(
            documentID: repeatedDocumentID,
            generation: repeatedGeneration
        )

        for _ in 0..<1_000 {
            relay.offer(
                documentID: repeatedDocumentID,
                generation: repeatedGeneration
            )
        }

        XCTAssertEqual(relay.pendingHintCount(), 1)
        var hints = pair.stream.makeAsyncIterator()
        let repeatedHint = await hints.next()
        XCTAssertEqual(repeatedHint, repeatedDocumentID)
        relay.acknowledge(documentID: repeatedDocumentID)

        for _ in 0..<20 {
            let documentID = DocumentID(rawValue: UUID())
            let generation = UUID()
            relay.activate(documentID: documentID, generation: generation)
            relay.offer(documentID: documentID, generation: generation)
        }

        XCTAssertEqual(relay.pendingHintCount(), maximumBufferedHintCount)
        relay.finish()
    }

    func testConnectorDeinitRemovesRegisteredPresenter() async throws {
        let folderURL = try makePresenterTemporaryFolder()
        let fileURL = folderURL.appendingPathComponent("Lifetime.txt", isDirectory: false)
        try Data("Lifetime\n".utf8).write(to: fileURL, options: .withoutOverwriting)
        let documentID = DocumentID(rawValue: UUID())
        weak var releasedConnector: FileAccessConnector?

        do {
            let connector = FileAccessConnector(fileManager: .default)
            releasedConnector = connector
            _ = try await connector.openTextFile(
                at: fileURL,
                documentID: documentID
            )
            XCTAssertTrue(isFilePresenterRegistered(documentID: documentID))
        }

        XCTAssertNil(releasedConnector)
        XCTAssertFalse(isFilePresenterRegistered(documentID: documentID))
        try FileManager.default.removeItem(at: folderURL)
    }
}

private struct ForcedPresenterBookmarkError: CustomNSError, Sendable {
    static let errorDomain = "PhonePadTests.ForcedPresenterBookmark"

    let code: Int

    var errorCode: Int {
        code
    }
}

private final class FilePresenterRegistrationObservation: @unchecked Sendable {
    private let documentID: DocumentID
    private let lock = NSLock()
    private var registeredDuringBaselineRead = false
    private var usedPresenterQueue = false

    init(documentID: DocumentID) {
        self.documentID = documentID
    }

    func recordCurrentRegistration() {
        let presenter = registeredPresentedFile(documentID: documentID)
        lock.lock()
        registeredDuringBaselineRead = presenter != nil
        usedPresenterQueue = OperationQueue.current === presenter?.presentedItemOperationQueue
        lock.unlock()
    }

    func wasRegisteredDuringBaselineRead() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registeredDuringBaselineRead
    }

    func baselineReadUsedPresenterQueue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usedPresenterQueue
    }
}

private func isFilePresenterRegistered(documentID: DocumentID) -> Bool {
    registeredPresentedFile(documentID: documentID) != nil
}

private func registeredPresentedFile(documentID: DocumentID) -> PresentedFile? {
    NSFileCoordinator.filePresenters.compactMap { presenter in
        presenter as? PresentedFile
    }
    .first { presentedFile in
        presentedFile.documentID == documentID
    }
}

private final class PresenterReconcileCallbackControl: @unchecked Sendable {
    private let lock = NSLock()
    private var presenter: PresentedFile?
    private var isArmed: Bool = false
    private var didEmit: Bool = false
    private var didEmitOnPresenterQueue: Bool = false

    func attach(presenter: PresentedFile) {
        lock.withLock {
            self.presenter = presenter
        }
    }

    func arm() {
        lock.withLock {
            isArmed = true
        }
    }

    func emitCallbackIfArmed() {
        let presenter = lock.withLock { () -> PresentedFile? in
            guard isArmed, !didEmit else {
                return nil
            }
            didEmit = true
            return self.presenter
        }
        guard let presenter else {
            return
        }
        let emittedOnPresenterQueue = OperationQueue.current
            === presenter.presentedItemOperationQueue
        lock.withLock {
            didEmitOnPresenterQueue = emittedOnPresenterQueue
        }
        presenter.presentedItemDidChange()
    }

    func emittedOnPresenterQueue() -> Bool {
        lock.withLock { didEmitOnPresenterQueue }
    }
}

private func makePresenterTemporaryFolder() throws -> URL {
    let folderURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: folderURL,
        withIntermediateDirectories: false,
        attributes: nil
    )
    return folderURL
}

private func makePresenterConnector(
    bookmarkResolver: @escaping FileAccessConnector.BookmarkResolver,
    identityReader: @escaping FileAccessConnector.FileIdentityReader,
    unresolvedVersionCountReader: @escaping FileAccessConnector.UnresolvedVersionCountReader
) -> FileAccessConnector {
    FileAccessConnector(
        fileManager: .default,
        bookmarkCreator: makePresenterBookmarkData,
        bookmarkResolver: bookmarkResolver,
        identityReader: identityReader,
        replacer: replacePresentedFile,
        saveAsRecoveryAccessorSourceProvider: { sourceURL, _ in sourceURL },
        unresolvedVersionCountReader: unresolvedVersionCountReader
    )
}

private func makePresenterBinding(
    locatorURL: URL,
    bookmarkData: Data,
    identity: FileIdentity?,
    data: Data
) throws -> FileBinding {
    FileBinding(
        locatorURL: locatorURL,
        bookmark: try FileBookmark(data: bookmarkData),
        identity: identity,
        displayName: try ValidatedFileName(validating: locatorURL.lastPathComponent),
        digest: try presenterDigest(data: data),
        encoding: .utf8,
        lineEnding: .lf
    )
}

private func presenterDigest(data: Data) throws -> FileDigest {
    try FileDigest(bytes: Data(SHA256.hash(data: data)))
}

private func makePresenterBookmarkData(url: URL) throws -> Data {
    try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}

private func resolvePresenterBookmark(
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

private func replacePresentedFile(
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
