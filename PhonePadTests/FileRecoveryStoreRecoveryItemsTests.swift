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
        XCTAssertEqual(try Data(contentsOf: canonicalURL), storedData)
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
