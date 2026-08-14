import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class FileRecoveryStoreRecoveryItemsTests: XCTestCase {
    func testRecoveryItemsRestoresVerifiedPreviousGenerationWhenCanonicalIsMissing() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "05000000-0000-0000-0000-000000000001")!
        )
        let editedAt = Date(timeIntervalSince1970: 1_786_649_900)
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Interrupted Draft",
            text: "Verified content preserved before an interrupted rollback.",
            editedAt: editedAt
        )
        let previousURL = rootURL.appendingPathComponent(
            ".05000000-0000-0000-0000-000000000001.recovery.previous",
            isDirectory: false
        )
        try JSONEncoder().encode(envelope).write(
            to: previousURL,
            options: [.atomic, .completeFileProtection]
        )
        try applyProtectedMetadata(to: previousURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()
        let restoredEnvelope = try await store.load(documentID: documentID)

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Interrupted Draft",
                    lastEdited: .available(editedAt),
                    status: .recoverable
                )
            ]
        )
        XCTAssertEqual(restoredEnvelope, envelope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: canonicalURL(rootURL: rootURL, documentID: documentID).path
            )
        )
    }

    func testRecoveryItemsReturnsSanitizedMetadataNewestFirstWithoutDocumentText() async throws {
        let rootURL = try makeRecoveryRoot()
        let olderDocumentID = DocumentID(
            rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let newerDocumentID = DocumentID(
            rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        let olderDate = Date(timeIntervalSince1970: 1_786_650_000)
        let newerDate = Date(timeIntervalSince1970: 1_786_650_100)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: olderDocumentID,
                title: "Draft",
                text: "Older private recovery text.",
                editedAt: olderDate
            )
        )
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: newerDocumentID,
                title: "/private/example/New\nDraft",
                text: "Newer private recovery text.",
                editedAt: newerDate
            )
        )

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: newerDocumentID,
                    title: "New Draft",
                    lastEdited: .available(newerDate),
                    status: .recoverable
                ),
                RecoveryItemSummary(
                    documentID: olderDocumentID,
                    title: "Draft",
                    lastEdited: .available(olderDate),
                    status: .recoverable
                )
            ]
        )
    }

    func testLoadSanitizesPersistedTitleWithoutMutatingDocumentText() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "15000000-0000-0000-0000-000000000001")!
        )
        let privateText = "Private document text must remain byte-for-byte equivalent."
        let storedEnvelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "/private/customer/Unsafe\nTitle\u{0007}",
            text: privateText,
            editedAt: Date(timeIntervalSince1970: 1_786_650_050)
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let storedData = try JSONEncoder().encode(storedEnvelope)
        try storedData.write(to: canonicalURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: canonicalURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let loadedEnvelope = try await store.load(documentID: documentID)

        XCTAssertEqual(loadedEnvelope?.title, "Unsafe Title")
        XCTAssertEqual(loadedEnvelope?.text, privateText)
        XCTAssertNil(loadedEnvelope?.fileReference)
        XCTAssertNil(loadedEnvelope?.pendingSave)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), storedData)
    }

    func testSaveAndLoadPreserveDurableFileRecoveryMetadataWithoutRawLocator() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "15500000-0000-0000-0000-000000000001")!
        )
        let fileReference = RecoveryFileReference(
            bookmark: try FileBookmark(data: Data("provider-bookmark".utf8)),
            identity: FileIdentity(
                volumeUUID: UUID(uuidString: "15500000-0000-0000-0000-000000000002")!,
                documentIdentifier: 42
            ),
            displayName: try ValidatedFileName(validating: "Original.txt"),
            cleanDigest: try FileDigest(bytes: Data(repeating: 0x11, count: 32)),
            encoding: .utf8,
            lineEnding: .lf
        )
        let pendingSave = RecoveryPendingSave(
            intendedOutputDigest: try FileDigest(
                bytes: Data(repeating: 0x22, count: 32)
            )
        )
        let storedEnvelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "/private/customer/Unsafe\nTitle",
            text: "Unsaved edits",
            editedAt: Date(timeIntervalSince1970: 1_786_650_055),
            fileReference: fileReference,
            pendingSave: pendingSave
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        try await store.save(envelope: storedEnvelope)
        let loadedEnvelope = try await store.load(documentID: documentID)
        let serializedData = try Data(
            contentsOf: canonicalURL(rootURL: rootURL, documentID: documentID)
        )
        let serializedText = try XCTUnwrap(String(data: serializedData, encoding: .utf8))

        XCTAssertEqual(loadedEnvelope?.title, "Unsafe Title")
        XCTAssertEqual(loadedEnvelope?.text, storedEnvelope.text)
        XCTAssertEqual(loadedEnvelope?.fileReference, fileReference)
        XCTAssertEqual(loadedEnvelope?.pendingSave, pendingSave)
        XCTAssertFalse(serializedText.contains("/private/customer"))
        XCTAssertFalse(serializedText.contains("file://"))
    }

    func testRecoveryFileCollisionClaimsExposeBoundAndPendingSaveAsTargets() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "15700000-0000-0000-0000-000000000001")!
        )
        let excludedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "15700000-0000-0000-0000-000000000002")!
        )
        let fileReference = RecoveryFileReference(
            bookmark: try FileBookmark(data: Data("bound-file-bookmark".utf8)),
            identity: nil,
            displayName: try ValidatedFileName(validating: "Bound.txt"),
            cleanDigest: try FileDigest(bytes: Data(repeating: 0x31, count: 32)),
            encoding: .utf8,
            lineEnding: .lf
        )
        let collisionReference = FileCollisionReference(
            bookmark: fileReference.bookmark,
            identity: fileReference.identity
        )
        let saveAsDestination = RecoverySaveAsDestination(
            directoryBookmark: try FileBookmark(
                data: Data("destination-directory-bookmark".utf8)
            ),
            fileName: try ValidatedFileName(validating: "Replacement.txt")
        )
        let pendingSave = RecoveryPendingSave(
            intendedOutputDigest: try FileDigest(
                bytes: Data(repeating: 0x32, count: 32)
            ),
            destination: .saveAs(saveAsDestination)
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        for storedDocumentID in [documentID, excludedDocumentID] {
            try await store.save(
                envelope: try RecoveryEnvelope(
                    formatVersion: RecoveryEnvelope.currentFormatVersion,
                    documentID: storedDocumentID,
                    title: "Private recovery title",
                    text: "Private recovery text",
                    editedAt: Date(timeIntervalSince1970: 1_786_650_057),
                    fileReference: fileReference,
                    pendingSave: pendingSave
                )
            )
        }

        let claims = try await store.recoveryFileCollisionClaims(
            excludingDocumentID: excludedDocumentID
        )

        XCTAssertEqual(claims.count, 2)
        XCTAssertTrue(
            claims.contains(
                .recoveryItem(
                    documentID: documentID,
                    reference: collisionReference
                )
            )
        )
        XCTAssertTrue(
            claims.contains(
                .pendingSaveAs(
                    documentID: documentID,
                    destination: saveAsDestination
                )
            )
        )
    }

    func testRecoveryFileCollisionClaimsFailClosedWhenAnyRecoveryIsCorrupt() async throws {
        let rootURL = try makeRecoveryRoot()
        let validDocumentID = DocumentID(
            rawValue: UUID(uuidString: "15800000-0000-0000-0000-000000000001")!
        )
        let corruptDocumentID = DocumentID(
            rawValue: UUID(uuidString: "15800000-0000-0000-0000-000000000002")!
        )
        let fileReference = RecoveryFileReference(
            bookmark: try FileBookmark(data: Data("valid-bookmark".utf8)),
            identity: FileIdentity(
                volumeUUID: UUID(uuidString: "15800000-0000-0000-0000-000000000003")!,
                documentIdentifier: 158
            ),
            displayName: try ValidatedFileName(validating: "Valid.txt"),
            cleanDigest: try FileDigest(bytes: Data(repeating: 0x41, count: 32)),
            encoding: .utf8,
            lineEnding: .lf
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: try RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: validDocumentID,
                title: "Valid",
                text: "Valid recovery text",
                editedAt: Date(timeIntervalSince1970: 1_786_650_058),
                fileReference: fileReference,
                pendingSave: nil
            )
        )
        let corruptURL = canonicalURL(
            rootURL: rootURL,
            documentID: corruptDocumentID
        )
        try Data("not-json".utf8).write(
            to: corruptURL,
            options: [.atomic, .completeFileProtection]
        )
        try applyProtectedMetadata(to: corruptURL)

        do {
            _ = try await store.recoveryFileCollisionClaims(
                excludingDocumentID: DocumentID(rawValue: UUID())
            )
            XCTFail("Expected corrupt recovery metadata to block collision inventory.")
        } catch let error as FileRecoveryStoreError {
            guard case .couldNotDecodeCheckpoint = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let retainedValidEnvelope = try await store.load(
            documentID: validDocumentID
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertNotNil(retainedValidEnvelope)
    }

    func testRecoveryItemsClassifiesAndRetainsEnvelopeWithOversizedMetadata() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "16000000-0000-0000-0000-000000000001")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: String(repeating: "M", count: 64 * 1_024),
            text: "Small content",
            editedAt: Date(timeIntervalSince1970: 1_786_650_060)
        )
        let storedData = try JSONEncoder().encode(envelope)
        try storedData.write(to: canonicalURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: canonicalURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        do {
            _ = try await store.load(documentID: documentID)
            XCTFail("Expected oversized metadata to be rejected.")
        } catch let error as FileRecoveryStoreError {
            XCTAssertTrue(error.localizedDescription.contains("64 KiB"))
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: canonicalURL), storedData)
    }

    func testSaveRejectsOversizedBookmarkMetadataBeforeWritingArtifact() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "16500000-0000-0000-0000-000000000001")!
        )
        let fileReference = RecoveryFileReference(
            bookmark: try FileBookmark(data: Data(repeating: 0x41, count: 49 * 1_024)),
            identity: nil,
            displayName: try ValidatedFileName(validating: "Oversized.txt"),
            cleanDigest: try FileDigest(bytes: Data(repeating: 0x33, count: 32)),
            encoding: .utf8,
            lineEnding: .lf
        )
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Oversized Bookmark",
            text: "Small content",
            editedAt: Date(timeIntervalSince1970: 1_786_650_065),
            fileReference: fileReference,
            pendingSave: nil
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        do {
            try await store.save(envelope: envelope)
            XCTFail("Expected oversized recovery metadata to be rejected.")
        } catch let error as FileRecoveryStoreError {
            guard case let .checkpointMetadataExceedsMaximumSize(
                actualDocumentID,
                actualByteCount,
                maximumByteCount,
                _
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actualDocumentID, documentID)
            XCTAssertGreaterThan(actualByteCount, UInt64(64 * 1_024))
            XCTAssertEqual(maximumByteCount, UInt64(64 * 1_024))
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: canonicalURL(rootURL: rootURL, documentID: documentID).path
            )
        )
    }

    func testLoadRejectsAndRetainsOversizedBookmarkMetadata() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "16600000-0000-0000-0000-000000000001")!
        )
        let fileReference = RecoveryFileReference(
            bookmark: try FileBookmark(data: Data(repeating: 0x42, count: 49 * 1_024)),
            identity: nil,
            displayName: try ValidatedFileName(validating: "Retained.txt"),
            cleanDigest: try FileDigest(bytes: Data(repeating: 0x44, count: 32)),
            encoding: .utf8,
            lineEnding: .lf
        )
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Retained Oversized Bookmark",
            text: "Small content",
            editedAt: Date(timeIntervalSince1970: 1_786_650_066),
            fileReference: fileReference,
            pendingSave: nil
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let storedData = try JSONEncoder().encode(envelope)
        try storedData.write(to: canonicalURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: canonicalURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        do {
            _ = try await store.load(documentID: documentID)
            XCTFail("Expected oversized recovery metadata to be rejected.")
        } catch let error as FileRecoveryStoreError {
            guard case .checkpointMetadataExceedsMaximumSize = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: canonicalURL), storedData)
    }

    func testSaveRejectsContentExceedingSeventyFiveMiBWithoutWritingArtifact() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "17000000-0000-0000-0000-000000000001")!
        )
        let contentByteCount = 75 * 1_024 * 1_024 + 1
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Oversized Content",
            text: String(repeating: "C", count: contentByteCount),
            editedAt: Date(timeIntervalSince1970: 1_786_650_070)
        )

        do {
            try await store.save(envelope: envelope)
            XCTFail("Expected oversized recovery content to be rejected.")
        } catch let error as FileRecoveryStoreError {
            guard case let .checkpointContentExceedsMaximumSize(
                actualDocumentID,
                actualByteCount,
                maximumByteCount,
                _
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actualDocumentID, documentID)
            XCTAssertEqual(actualByteCount, UInt64(contentByteCount))
            XCTAssertEqual(maximumByteCount, UInt64(75 * 1_024 * 1_024))
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: canonicalURL(rootURL: rootURL, documentID: documentID).path
            )
        )
    }

    func testRecoveryItemsRetainsAndReportsCorruptAndUnsupportedCanonicalFiles() async throws {
        let rootURL = try makeRecoveryRoot()
        let corruptDocumentID = DocumentID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
        let unsupportedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )
        let corruptURL = canonicalURL(rootURL: rootURL, documentID: corruptDocumentID)
        let unsupportedURL = canonicalURL(
            rootURL: rootURL,
            documentID: unsupportedDocumentID
        )
        let corruptData = Data("not-json".utf8)
        let unsupportedData = Data(
            """
            {"documentID":{"rawValue":"20000000-0000-0000-0000-000000000002"},"editedAt":0,"formatVersion":42,"text":"retained","title":"Future"}
            """.utf8
        )
        try corruptData.write(to: corruptURL, options: .completeFileProtection)
        try unsupportedData.write(to: unsupportedURL, options: .completeFileProtection)
        let hiddenSidecar = rootURL.appendingPathComponent(
            ".20000000-0000-0000-0000-000000000003.recovery.internal",
            isDirectory: false
        )
        try Data("internal".utf8).write(to: hiddenSidecar)
        let unrelated = rootURL.appendingPathComponent("notes.txt", isDirectory: false)
        try Data("unrelated".utf8).write(to: unrelated)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: corruptDocumentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                ),
                RecoveryItemSummary(
                    documentID: unsupportedDocumentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .unsupportedVersion(42)
                ),
            ]
        )
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptData)
        XCTAssertEqual(try Data(contentsOf: unsupportedURL), unsupportedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenSidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRecoveryItemsRetainsAndReportsInvalidFileReferenceAndPendingSave() async throws {
        let rootURL = try makeRecoveryRoot()
        let invalidReferenceID = DocumentID(
            rawValue: UUID(uuidString: "20500000-0000-0000-0000-000000000001")!
        )
        let invalidPendingSaveID = DocumentID(
            rawValue: UUID(uuidString: "20500000-0000-0000-0000-000000000002")!
        )
        let invalidReferenceURL = canonicalURL(
            rootURL: rootURL,
            documentID: invalidReferenceID
        )
        let invalidPendingSaveURL = canonicalURL(
            rootURL: rootURL,
            documentID: invalidPendingSaveID
        )
        let digest = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let invalidReferenceData = Data(
            """
            {"documentID":{"rawValue":"20500000-0000-0000-0000-000000000001"},"editedAt":0,"fileReference":{"bookmark":"","cleanDigest":"\(digest)","displayName":"Invalid.txt","encoding":"utf8","lineEnding":"lf"},"formatVersion":1,"text":"retained reference","title":"Invalid Reference"}
            """.utf8
        )
        let invalidPendingSaveData = Data(
            """
            {"documentID":{"rawValue":"20500000-0000-0000-0000-000000000002"},"editedAt":0,"formatVersion":1,"pendingSave":{"intendedOutputDigest":"\(digest)"},"text":"retained pending save","title":"Invalid Pending Save"}
            """.utf8
        )
        try invalidReferenceData.write(
            to: invalidReferenceURL,
            options: .completeFileProtection
        )
        try invalidPendingSaveData.write(
            to: invalidPendingSaveURL,
            options: .completeFileProtection
        )
        try applyProtectedMetadata(to: invalidReferenceURL)
        try applyProtectedMetadata(to: invalidPendingSaveURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: invalidReferenceID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                ),
                RecoveryItemSummary(
                    documentID: invalidPendingSaveID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                ),
            ]
        )
        for documentID in [invalidReferenceID, invalidPendingSaveID] {
            do {
                _ = try await store.load(documentID: documentID)
                XCTFail("Expected invalid recovery metadata to be rejected.")
            } catch let error as FileRecoveryStoreError {
                guard case .couldNotDecodeCheckpoint = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: invalidReferenceURL), invalidReferenceData)
        XCTAssertEqual(try Data(contentsOf: invalidPendingSaveURL), invalidPendingSaveData)
    }

    func testRecoveryItemsKeepsOtherRowsWhenOneCanonicalMetadataIsUnavailable() async throws {
        let rootURL = try makeRecoveryRoot()
        let validDocumentID = DocumentID(
            rawValue: UUID(uuidString: "28000000-0000-0000-0000-000000000001")!
        )
        let unavailableDocumentID = DocumentID(
            rawValue: UUID(uuidString: "28000000-0000-0000-0000-000000000002")!
        )
        let validDate = Date(timeIntervalSince1970: 1_786_650_080)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: validDocumentID,
                title: "Available Draft",
                text: "Available content",
                editedAt: validDate
            )
        )
        let unavailableURL = canonicalURL(
            rootURL: rootURL,
            documentID: unavailableDocumentID
        )
        let unavailableData = try JSONEncoder().encode(
            RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: unavailableDocumentID,
                title: "Unavailable Draft",
                text: "Retained content",
                editedAt: Date(timeIntervalSince1970: 1_786_650_070)
            )
        )
        try unavailableData.write(
            to: unavailableURL,
            options: .completeFileProtection
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: unavailableURL.path
        )
        var unavailableValues = URLResourceValues()
        unavailableValues.isExcludedFromBackup = false
        var mutableUnavailableURL = unavailableURL
        try mutableUnavailableURL.setResourceValues(unavailableValues)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: validDocumentID,
                    title: "Available Draft",
                    lastEdited: .available(validDate),
                    status: .recoverable
                ),
                RecoveryItemSummary(
                    documentID: unavailableDocumentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .unavailable
                ),
            ]
        )
        XCTAssertEqual(try Data(contentsOf: unavailableURL), unavailableData)
    }

    func testRecoveryItemsRejectsCanonicalSymbolicLinkWithoutFollowingTarget() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "29000000-0000-0000-0000-000000000001")!
        )
        let targetURL = rootURL.appendingPathComponent("symbolic-link-target", isDirectory: false)
        let targetData = try JSONEncoder().encode(
            RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Target Must Not Be Loaded",
                text: "Target content",
                editedAt: Date(timeIntervalSince1970: 1_786_650_090)
            )
        )
        try targetData.write(to: targetURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: targetURL)
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        try FileManager.default.createSymbolicLink(
            at: canonicalURL,
            withDestinationURL: targetURL
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: canonicalURL.path),
            targetURL.path
        )
    }

    func testRecoveryItemsClassifiesAndRetainsOversizedCanonicalBeforeDecoding() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "25000000-0000-0000-0000-000000000001")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let maximumLength = 75 * 1_024 * 1_024 * 6 + 64 * 1_024
        let oversizedLength = maximumLength + 1
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: canonicalURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        )
        let handle = try FileHandle(forWritingTo: canonicalURL)
        try handle.truncate(atOffset: UInt64(oversizedLength))
        try handle.close()
        try applyProtectedMetadata(to: canonicalURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        do {
            _ = try await store.load(documentID: documentID)
            XCTFail("Expected oversized recovery to be rejected.")
        } catch let error as FileRecoveryStoreError {
            guard case let .checkpointExceedsMaximumSize(
                actualDocumentID,
                actualByteCount,
                maximumByteCount,
                _
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actualDocumentID, documentID)
            XCTAssertEqual(actualByteCount, UInt64(oversizedLength))
            XCTAssertEqual(maximumByteCount, UInt64(maximumLength))
            XCTAssertTrue(error.localizedDescription.contains("bounded recovery format"))
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(
            try canonicalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            oversizedLength
        )
    }

    func testRecoveryItemsReportsFutureVersionBeforeDecodingCurrentEnvelopeShape() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "26000000-0000-0000-0000-000000000001")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let futureData = Data(
            """
            {"formatVersion":42,"futurePayload":{"blocks":["retained"]}}
            """.utf8
        )
        try futureData.write(to: canonicalURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: canonicalURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .unsupportedVersion(42)
                )
            ]
        )
        XCTAssertEqual(try Data(contentsOf: canonicalURL), futureData)
    }

    func testRecoveryItemsKeepsCorruptCanonicalAuthoritativeOverValidPreviousGeneration() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "27000000-0000-0000-0000-000000000001")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let previousURL = rootURL.appendingPathComponent(
            ".27000000-0000-0000-0000-000000000001.recovery.previous",
            isDirectory: false
        )
        let corruptData = Data("authoritative-corrupt-canonical".utf8)
        let previousEnvelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Older Verified Generation",
            text: "Older content must not replace authoritative canonical.",
            editedAt: Date(timeIntervalSince1970: 1_786_649_000)
        )
        let previousData = try JSONEncoder().encode(previousEnvelope)
        try corruptData.write(to: canonicalURL, options: .completeFileProtection)
        try previousData.write(to: previousURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: canonicalURL)
        try applyProtectedMetadata(to: previousURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        XCTAssertEqual(try Data(contentsOf: canonicalURL), corruptData)
        XCTAssertEqual(try Data(contentsOf: previousURL), previousData)
    }

    func testRecoveryItemsRetainsVerifiedCanonicalWhenTransactionIsCorruptAndPreviousIsMissing() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "27500000-0000-0000-0000-000000000001")!
        )
        let editedAt = Date(timeIntervalSince1970: 1_786_650_095)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Verified Draft",
                text: "Last verified content must remain recoverable.",
                editedAt: editedAt
            )
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let canonicalData = try Data(contentsOf: canonicalURL)
        let transactionURL = rootURL.appendingPathComponent(
            ".27500000-0000-0000-0000-000000000001.recovery.transaction",
            isDirectory: false
        )
        let corruptTransactionData = Data("corrupt-transaction".utf8)
        try corruptTransactionData.write(
            to: transactionURL,
            options: [.atomic, .completeFileProtection]
        )
        try applyProtectedMetadata(to: transactionURL)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        XCTAssertEqual(try Data(contentsOf: transactionURL), corruptTransactionData)
    }

    func testRecoveryItemsRetainsVerifiedCanonicalWhenTransactionIsDanglingSymbolicLink() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "27500000-0000-0000-0000-000000000002")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Verified Draft",
                text: "Verified content must survive an unreadable transaction.",
                editedAt: Date(timeIntervalSince1970: 1_786_650_096)
            )
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let canonicalData = try Data(contentsOf: canonicalURL)
        let transactionURL = rootURL.appendingPathComponent(
            ".27500000-0000-0000-0000-000000000002.recovery.transaction",
            isDirectory: false
        )
        let missingTargetURL = rootURL.appendingPathComponent(
            "missing-transaction-target",
            isDirectory: false
        )
        try FileManager.default.createSymbolicLink(
            at: transactionURL,
            withDestinationURL: missingTargetURL
        )

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: transactionURL.path
            ),
            missingTargetURL.path
        )
    }

    func testRecoveryItemsKeepsIdenticalVerifiedCanonicalAfterInterruptedFirstGenerationCommit() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "27600000-0000-0000-0000-000000000001")!
        )
        let editedAt = Date(timeIntervalSince1970: 1_786_650_097)
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "First Generation",
            text: "Verified first-generation content.",
            editedAt: editedAt
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(envelope: envelope)
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let transactionURL = rootURL.appendingPathComponent(
            ".27600000-0000-0000-0000-000000000001.recovery.transaction",
            isDirectory: false
        )
        try FileManager.default.copyItem(at: canonicalURL, to: transactionURL)
        try applyProtectedMetadata(to: transactionURL)

        let items = try await store.recoveryItems()
        let loadedEnvelope = try await store.load(documentID: documentID)

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "First Generation",
                    lastEdited: .available(editedAt),
                    status: .recoverable
                )
            ]
        )
        XCTAssertEqual(loadedEnvelope, envelope)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            [canonicalURL.lastPathComponent]
        )
    }

    func testRecoveryItemsRestoresVerifiedTransactionWhenFirstGenerationCanonicalIsMissing() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "27600000-0000-0000-0000-000000000002")!
        )
        let editedAt = Date(timeIntervalSince1970: 1_786_650_098)
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Interrupted First Generation",
            text: "Verified transaction content must become recoverable.",
            editedAt: editedAt
        )
        let data = try JSONEncoder().encode(envelope)
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let transactionURL = rootURL.appendingPathComponent(
            ".27600000-0000-0000-0000-000000000002.recovery.transaction",
            isDirectory: false
        )
        let stagingURL = rootURL.appendingPathComponent(
            ".27600000-0000-0000-0000-000000000002.recovery.staging",
            isDirectory: false
        )
        try data.write(to: transactionURL, options: [.atomic, .completeFileProtection])
        try data.write(to: stagingURL, options: [.atomic, .completeFileProtection])
        try applyProtectedMetadata(to: transactionURL)
        try applyProtectedMetadata(to: stagingURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()
        let loadedEnvelope = try await store.load(documentID: documentID)

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Interrupted First Generation",
                    lastEdited: .available(editedAt),
                    status: .recoverable
                )
            ]
        )
        XCTAssertEqual(loadedEnvelope, envelope)
        XCTAssertEqual(try Data(contentsOf: canonicalURL), data)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            [canonicalURL.lastPathComponent]
        )
    }

    func testDiscardRecoveryTerminatesValidCorruptAndUnsupportedItems() async throws {
        let rootURL = try makeRecoveryRoot()
        let validDocumentID = DocumentID(
            rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        )
        let corruptDocumentID = DocumentID(
            rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        )
        let unsupportedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: validDocumentID,
                title: "Valid",
                text: "Valid private content",
                editedAt: Date(timeIntervalSince1970: 1_786_650_000)
            )
        )
        try Data("not-json".utf8).write(
            to: canonicalURL(rootURL: rootURL, documentID: corruptDocumentID),
            options: .completeFileProtection
        )
        try Data(
            """
            {"documentID":{"rawValue":"30000000-0000-0000-0000-000000000003"},"editedAt":0,"formatVersion":99,"text":"retained","title":"Future"}
            """.utf8
        ).write(
            to: canonicalURL(rootURL: rootURL, documentID: unsupportedDocumentID),
            options: .completeFileProtection
        )

        try await store.discardRecovery(documentID: validDocumentID)
        try await store.discardRecovery(documentID: corruptDocumentID)
        try await store.discardRecovery(documentID: unsupportedDocumentID)

        let remainingItems = try await store.recoveryItems()
        let validEnvelope = try await store.load(documentID: validDocumentID)
        let corruptEnvelope = try await store.load(documentID: corruptDocumentID)
        let unsupportedEnvelope = try await store.load(documentID: unsupportedDocumentID)
        XCTAssertTrue(remainingItems.isEmpty)
        XCTAssertNil(validEnvelope)
        XCTAssertNil(corruptEnvelope)
        XCTAssertNil(unsupportedEnvelope)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty
        )
    }

    func testCompleteRecoveryAfterSaveTerminatesValidRecovery() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000001")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Saved Document",
                text: "Verified content already saved to the chosen File.",
                editedAt: Date(timeIntervalSince1970: 1_786_650_000)
            )
        )

        try await store.completeRecoveryAfterSave(documentID: documentID)

        let recoveryItems = try await store.recoveryItems()
        let loadedEnvelope = try await store.load(documentID: documentID)
        XCTAssertTrue(recoveryItems.isEmpty)
        XCTAssertNil(loadedEnvelope)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty
        )
    }

    func testCompleteRecoveryAfterSaveWithoutRecoveryArtifactIsNoOp() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000002")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        try await store.completeRecoveryAfterSave(documentID: documentID)

        let recoveryItems = try await store.recoveryItems()
        XCTAssertTrue(recoveryItems.isEmpty)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty
        )
    }

    func testCompleteRecoveryAfterSaveRetainsCorruptRecoveryAndThrowsTypedFailure() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000003")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let corruptData = Data("corrupt-preserved-work".utf8)
        try corruptData.write(to: canonicalURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: canonicalURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        do {
            try await store.completeRecoveryAfterSave(documentID: documentID)
            XCTFail("Expected corrupt recovery to block saved cleanup.")
        } catch let error as FileRecoveryStoreError {
            guard case .couldNotDecodeCheckpoint = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: canonicalURL), corruptData)
        let recoveryItems = try await store.recoveryItems()
        XCTAssertEqual(
            recoveryItems,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
    }

    func testCompleteRecoveryAfterSaveRetainsUnsupportedRecoveryAndThrowsTypedFailure() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000004")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let unsupportedData = Data(
            """
            {"documentID":{"rawValue":"30500000-0000-0000-0000-000000000004"},"editedAt":0,"formatVersion":42,"text":"retained","title":"Future"}
            """.utf8
        )
        try unsupportedData.write(to: canonicalURL, options: .completeFileProtection)
        try applyProtectedMetadata(to: canonicalURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        do {
            try await store.completeRecoveryAfterSave(documentID: documentID)
            XCTFail("Expected unsupported recovery to block saved cleanup.")
        } catch let error as FileRecoveryStoreError {
            guard case let .unsupportedCheckpointVersion(
                actualDocumentID,
                expectedVersion,
                actualVersion,
                _
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actualDocumentID, documentID)
            XCTAssertEqual(expectedVersion, RecoveryEnvelope.currentFormatVersion)
            XCTAssertEqual(actualVersion, 42)
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: canonicalURL), unsupportedData)
    }

    func testCompleteRecoveryAfterSaveRetainsUnavailableRecoveryAndThrowsTypedFailure() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000005")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Unavailable Recovery",
            text: "Protected content must remain available for retry.",
            editedAt: Date(timeIntervalSince1970: 1_786_650_000)
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        try envelopeData.write(to: canonicalURL, options: .completeFileProtection)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: canonicalURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var mutableCanonicalURL = canonicalURL
        try mutableCanonicalURL.setResourceValues(values)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        do {
            try await store.completeRecoveryAfterSave(documentID: documentID)
            XCTFail("Expected unavailable recovery to block saved cleanup.")
        } catch let error as FileRecoveryStoreError {
            guard case .backupExclusionVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: canonicalURL), envelopeData)
    }

    func testCompleteRecoveryAfterSaveRetainsSymbolicLinkAndTarget() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000006")!
        )
        let targetURL = rootURL.appendingPathComponent(
            "saved-cleanup-symbolic-link-target",
            isDirectory: false
        )
        let targetData = Data("Target content must remain untouched.".utf8)
        try targetData.write(to: targetURL, options: .completeFileProtection)
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        try FileManager.default.createSymbolicLink(
            at: canonicalURL,
            withDestinationURL: targetURL
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        do {
            try await store.completeRecoveryAfterSave(documentID: documentID)
            XCTFail("Expected symbolic-link recovery to block saved cleanup.")
        } catch let error as FileRecoveryStoreError {
            guard case .recoveryItemHasUnexpectedType = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: canonicalURL.path
            ),
            targetURL.path
        )
    }

    func testCompleteRecoveryAfterSaveRetainsUnexpectedDirectoryArtifact() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000008")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        try FileManager.default.createDirectory(
            at: canonicalURL,
            withIntermediateDirectories: false
        )
        let nestedURL = canonicalURL.appendingPathComponent(
            "retained-private-artifact",
            isDirectory: false
        )
        let nestedData = Data("Unexpected recovery artifact remains untouched.".utf8)
        try nestedData.write(to: nestedURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        do {
            try await store.completeRecoveryAfterSave(documentID: documentID)
            XCTFail("Expected unexpected recovery type to block saved cleanup.")
        } catch let error as FileRecoveryStoreError {
            guard case .recoveryItemHasUnexpectedType = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: nestedURL), nestedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
    }

    func testCompleteRecoveryAfterSaveRetainsCorruptStagingSidecar() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "30500000-0000-0000-0000-000000000007")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Verified Canonical",
                text: "Canonical content must remain retained.",
                editedAt: Date(timeIntervalSince1970: 1_786_650_000)
            )
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let canonicalData = try Data(contentsOf: canonicalURL)
        let stagingURL = rootURL.appendingPathComponent(
            ".30500000-0000-0000-0000-000000000007.recovery.staging",
            isDirectory: false
        )
        let corruptStagingData = Data("corrupt-sidecar".utf8)
        try corruptStagingData.write(
            to: stagingURL,
            options: [.atomic, .completeFileProtection]
        )
        try applyProtectedMetadata(to: stagingURL)

        do {
            try await store.completeRecoveryAfterSave(documentID: documentID)
            XCTFail("Expected corrupt staging data to block saved cleanup.")
        } catch let error as FileRecoveryStoreError {
            guard case .couldNotDecodeCheckpoint = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        XCTAssertEqual(try Data(contentsOf: stagingURL), corruptStagingData)
    }

    func testDiscardRecoveryRemovesCanonicalSymbolicLinkWithoutFollowingTarget() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
        )
        let targetURL = rootURL.appendingPathComponent(
            "discard-symbolic-link-target",
            isDirectory: false
        )
        let targetData = Data("Target must remain untouched.".utf8)
        try targetData.write(to: targetURL, options: .completeFileProtection)
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        try FileManager.default.createSymbolicLink(
            at: canonicalURL,
            withDestinationURL: targetURL
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: canonicalURL.path
            ),
            targetURL.path
        )

        try await store.discardRecovery(documentID: documentID)

        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path),
            [targetURL.lastPathComponent]
        )
    }

    func testDiscardRecoveryRemovesDanglingCanonicalSymbolicLink() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "31000000-0000-0000-0000-000000000002")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let missingTargetURL = rootURL.appendingPathComponent(
            "missing-symbolic-link-target",
            isDirectory: false
        )
        try FileManager.default.createSymbolicLink(
            at: canonicalURL,
            withDestinationURL: missingTargetURL
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        let items = try await store.recoveryItems()

        XCTAssertEqual(
            items,
            [
                RecoveryItemSummary(
                    documentID: documentID,
                    title: "Recovered Document",
                    lastEdited: .unavailable,
                    status: .corrupt
                )
            ]
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: canonicalURL.path
            ),
            missingTargetURL.path
        )

        try await store.discardRecovery(documentID: documentID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingTargetURL.path)
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty
        )
    }

    func testDiscardRecoveryRemovesCanonicalDirectory() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "31000000-0000-0000-0000-000000000003")!
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        try FileManager.default.createDirectory(
            at: canonicalURL,
            withIntermediateDirectories: false
        )
        let nestedURL = canonicalURL.appendingPathComponent(
            "untrusted-artifact",
            isDirectory: false
        )
        try Data("untrusted".utf8).write(to: nestedURL)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)

        try await store.discardRecovery(documentID: documentID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty
        )
    }

    func testRecoveryItemsCompletesDurableDiscardIntentAfterInterruption() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Discarded",
                text: "Content whose discard was authorized",
                editedAt: Date(timeIntervalSince1970: 1_786_650_000)
            )
        )
        let transactionURL = rootURL.appendingPathComponent(
            ".40000000-0000-0000-0000-000000000001.recovery.transaction",
            isDirectory: false
        )
        let markerData = Data(
            """
            {"action":"discard","documentID":{"rawValue":"40000000-0000-0000-0000-000000000001"},"formatVersion":1,"kind":"phonepad.recovery.cleanup"}
            """.utf8
        )
        try markerData.write(
            to: transactionURL,
            options: [.atomic, .completeFileProtection]
        )
        try applyProtectedMetadata(to: transactionURL)

        let items = try await store.recoveryItems()
        let recoveredEnvelope = try await store.load(documentID: documentID)

        XCTAssertTrue(items.isEmpty)
        XCTAssertNil(recoveredEnvelope)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty
        )
    }

    func testRecoveryItemsCompletesDurableSavedIntentAfterInterruption() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "40500000-0000-0000-0000-000000000001")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Saved",
                text: "Content already committed to the chosen File",
                editedAt: Date(timeIntervalSince1970: 1_786_650_000)
            )
        )
        let transactionURL = rootURL.appendingPathComponent(
            ".40500000-0000-0000-0000-000000000001.recovery.transaction",
            isDirectory: false
        )
        let markerData = Data(
            """
            {"action":"saved","documentID":{"rawValue":"40500000-0000-0000-0000-000000000001"},"formatVersion":1,"kind":"phonepad.recovery.cleanup"}
            """.utf8
        )
        try markerData.write(
            to: transactionURL,
            options: [.atomic, .completeFileProtection]
        )
        try applyProtectedMetadata(to: transactionURL)

        let items = try await store.recoveryItems()
        let recoveredEnvelope = try await store.load(documentID: documentID)

        XCTAssertTrue(items.isEmpty)
        XCTAssertNil(recoveredEnvelope)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty
        )
    }

    func testUnverifiedSavedIntentDoesNotTerminateRecovery() async throws {
        let rootURL = try makeRecoveryRoot()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "40500000-0000-0000-0000-000000000002")!
        )
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Retained",
                text: "Recovery remains until cleanup intent is verified.",
                editedAt: Date(timeIntervalSince1970: 1_786_650_000)
            )
        )
        let canonicalURL = canonicalURL(rootURL: rootURL, documentID: documentID)
        let canonicalData = try Data(contentsOf: canonicalURL)
        let transactionURL = rootURL.appendingPathComponent(
            ".40500000-0000-0000-0000-000000000002.recovery.transaction",
            isDirectory: false
        )
        let markerData = Data(
            """
            {"action":"saved","documentID":{"rawValue":"40500000-0000-0000-0000-000000000002"},"formatVersion":1,"kind":"phonepad.recovery.cleanup"}
            """.utf8
        )
        try markerData.write(
            to: transactionURL,
            options: [.atomic, .completeFileProtection]
        )

        do {
            try await store.completeRecoveryAfterSave(documentID: documentID)
            XCTFail("Expected unverified saved intent to block cleanup.")
        } catch let error as FileRecoveryStoreError {
            guard case .backupExclusionVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(rootURL.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: canonicalURL), canonicalData)
        XCTAssertEqual(try Data(contentsOf: transactionURL), markerData)
    }

    private func makeRecoveryRoot() throws -> URL {
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

    private func canonicalURL(rootURL: URL, documentID: DocumentID) -> URL {
        rootURL.appendingPathComponent(
            documentID.rawValue.uuidString.lowercased() + ".recovery.json",
            isDirectory: false
        )
    }

    private func applyProtectedMetadata(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var metadataURL = url
        try metadataURL.setResourceValues(values)
    }

}
