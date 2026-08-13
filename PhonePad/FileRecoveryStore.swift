import Foundation
import PhonePadCore

public enum FileRecoveryStoreError: Error, LocalizedError, Sendable {
    case couldNotCreateRecoveryDirectory(URL, String)
    case couldNotApplyProtection(DocumentID?, URL, String)
    case couldNotApplyBackupExclusion(DocumentID?, URL, String)
    case couldNotEncodeCheckpoint(DocumentID, String)
    case couldNotWriteCheckpoint(DocumentID, URL, String)
    case couldNotReadCheckpoint(DocumentID, URL, String)
    case couldNotReadRecoveryMetadata(DocumentID?, URL, String)
    case couldNotDecodeCheckpoint(DocumentID, URL, String)
    case checkpointIsNotRegularFile(DocumentID, URL)
    case recoveryItemHasUnexpectedType(DocumentID?, URL)
    case checkpointNotFound(DocumentID, URL)
    case checkpointContentMismatch(DocumentID, URL)
    case checkpointDocumentMismatch(expected: DocumentID, actual: DocumentID, URL)
    case unsupportedCheckpointVersion(DocumentID, expected: UInt, actual: UInt, URL)
    case backupExclusionVerificationFailed(DocumentID?, URL)
    case fileProtectionVerificationFailed(DocumentID?, URL)
    case couldNotCreatePreviousGenerationBackup(DocumentID, URL, String)
    case couldNotPromoteCheckpoint(DocumentID, URL, String)
    case postPromotionValidationFailed(DocumentID, String)
    case rollbackFailed(DocumentID, String)
    case couldNotRemovePreviousGenerationBackup(DocumentID, URL, String)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateRecoveryDirectory:
            "Could not create protected recovery storage. Check available device storage and retry."
        case let .couldNotApplyProtection(documentID, _, _):
            recoveryMessage(
                documentID: documentID,
                message: "Could not apply complete file protection. Retry Recovery before editing."
            )
        case let .couldNotApplyBackupExclusion(documentID, _, _):
            recoveryMessage(
                documentID: documentID,
                message: "Could not exclude recovery data from backup. Retry Recovery before editing."
            )
        case let .couldNotEncodeCheckpoint(documentID, _):
            "Could not encode recovery data for document \(documentID.rawValue). Retry Recovery before editing."
        case let .couldNotWriteCheckpoint(documentID, _, _):
            "Could not write recovery data for document \(documentID.rawValue). Check available device storage and retry."
        case let .couldNotReadCheckpoint(documentID, _, _):
            "Could not read recovery data for document \(documentID.rawValue). Keep the data and retry."
        case let .couldNotReadRecoveryMetadata(documentID, _, _):
            recoveryMessage(
                documentID: documentID,
                message: "Could not verify recovery metadata. Keep the data and retry."
            )
        case let .couldNotDecodeCheckpoint(documentID, _, _):
            "Recovery data for document \(documentID.rawValue) is corrupt or unsupported. Keep it until you choose Discard Recovery."
        case let .checkpointIsNotRegularFile(documentID, _):
            "Recovery data for document \(documentID.rawValue) is not a regular file. Keep it and retry."
        case let .recoveryItemHasUnexpectedType(documentID, _):
            recoveryMessage(
                documentID: documentID,
                message: "Recovery storage has an unexpected item type. Keep it and retry."
            )
        case let .checkpointNotFound(documentID, _):
            "Recovery data for document \(documentID.rawValue) is missing. Retry Recovery before editing."
        case let .checkpointContentMismatch(documentID, _):
            "Recovery data for document \(documentID.rawValue) did not pass content verification. The previous verified generation was preserved."
        case let .checkpointDocumentMismatch(expected, actual, _):
            "Recovery data contains document \(actual.rawValue), expected \(expected.rawValue). Keep it until you choose Discard Recovery."
        case let .unsupportedCheckpointVersion(documentID, expected, actual, _):
            "Recovery data for document \(documentID.rawValue) uses version \(actual), expected \(expected). Keep it until PhonePad can read it or you choose Discard Recovery."
        case let .backupExclusionVerificationFailed(documentID, _):
            recoveryMessage(
                documentID: documentID,
                message: "Recovery backup exclusion could not be verified. The previous verified generation was preserved."
            )
        case let .fileProtectionVerificationFailed(documentID, _):
            recoveryMessage(
                documentID: documentID,
                message: "Complete recovery protection could not be verified. The previous verified generation was preserved."
            )
        case let .couldNotCreatePreviousGenerationBackup(documentID, _, _):
            "Could not preserve the previous recovery generation for document \(documentID.rawValue). It remains canonical; retry Recovery."
        case let .couldNotPromoteCheckpoint(documentID, _, _):
            "Could not promote new recovery data for document \(documentID.rawValue). The previous verified generation was preserved."
        case let .postPromotionValidationFailed(documentID, _):
            "New recovery data for document \(documentID.rawValue) failed final verification. The previous verified generation was restored."
        case let .rollbackFailed(documentID, _):
            "Recovery rollback for document \(documentID.rawValue) needs attention. Do not discard recovery data; retry Recovery."
        case let .couldNotRemovePreviousGenerationBackup(documentID, _, _):
            "New recovery data for document \(documentID.rawValue) is verified, but protected cleanup remains. Retry Recovery."
        }
    }
}

public actor FileRecoveryStore: RecoveryStoring {
    typealias PostPromotionValidation = @Sendable (URL) throws -> Void

    private let rootURL: URL
    private let fileManager: FileManager
    private let postPromotionValidation: PostPromotionValidation

    public init(rootURL: URL, fileManager: FileManager) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        postPromotionValidation = { _ in }
    }

    init(
        rootURL: URL,
        fileManager: FileManager,
        postPromotionValidation: @escaping PostPromotionValidation
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.postPromotionValidation = postPromotionValidation
    }

    public func save(envelope: RecoveryEnvelope) async throws {
        try prepareRecoveryDirectory()

        let encodedEnvelope = try encode(envelope: envelope)
        let canonicalURL = checkpointURL(documentID: envelope.documentID)
        let stagingURL = temporaryURL(kind: "staging", documentID: envelope.documentID)
        let backupURL = temporaryURL(kind: "previous", documentID: envelope.documentID)
        let failedURL = temporaryURL(kind: "failed", documentID: envelope.documentID)

        try writeStagedEnvelope(
            data: encodedEnvelope,
            envelope: envelope,
            stagingURL: stagingURL
        )

        let previousGeneration = try preservePreviousGeneration(
            documentID: envelope.documentID,
            canonicalURL: canonicalURL,
            backupURL: backupURL
        )

        do {
            try promote(
                documentID: envelope.documentID,
                stagingURL: stagingURL,
                canonicalURL: canonicalURL,
                hasPreviousGeneration: previousGeneration != nil
            )
        } catch {
            try restorePreviousGeneration(
                documentID: envelope.documentID,
                canonicalURL: canonicalURL,
                backupURL: previousGeneration == nil ? nil : backupURL,
                failedURL: failedURL,
                previousGeneration: previousGeneration,
                originalFailure: error
            )
            throw error
        }

        do {
            try applyProtectedMetadata(
                url: canonicalURL,
                documentID: envelope.documentID
            )
            try verifyStoredEnvelope(
                url: canonicalURL,
                expectedEnvelope: envelope,
                expectedData: encodedEnvelope
            )
            try postPromotionValidation(canonicalURL)
        } catch {
            try restorePreviousGeneration(
                documentID: envelope.documentID,
                canonicalURL: canonicalURL,
                backupURL: previousGeneration == nil ? nil : backupURL,
                failedURL: failedURL,
                previousGeneration: previousGeneration,
                originalFailure: error
            )
            if error is FileRecoveryStoreError {
                throw error
            }
            throw FileRecoveryStoreError.postPromotionValidationFailed(
                envelope.documentID,
                String(describing: error)
            )
        }

        guard previousGeneration != nil else {
            return
        }
        do {
            try fileManager.removeItem(at: backupURL)
        } catch {
            throw FileRecoveryStoreError.couldNotRemovePreviousGenerationBackup(
                envelope.documentID,
                backupURL,
                String(describing: error)
            )
        }
    }

    public func load(documentID: DocumentID) async throws -> RecoveryEnvelope? {
        let canonicalURL = checkpointURL(documentID: documentID)
        guard fileManager.fileExists(atPath: canonicalURL.path) else {
            return nil
        }

        let (data, envelope) = try readEnvelope(
            documentID: documentID,
            url: canonicalURL
        )
        try verifyStoredEnvelope(
            url: canonicalURL,
            expectedEnvelope: envelope,
            expectedData: data
        )
        return envelope
    }

    public func verifyCheckpoint(
        documentID: DocumentID
    ) async throws -> RecoveryCheckpointVerification {
        let canonicalURL = checkpointURL(documentID: documentID)
        guard fileManager.fileExists(atPath: canonicalURL.path) else {
            throw FileRecoveryStoreError.checkpointNotFound(documentID, canonicalURL)
        }
        return try readVerification(url: canonicalURL, documentID: documentID)
    }

    private func prepareRecoveryDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        } catch {
            throw FileRecoveryStoreError.couldNotCreateRecoveryDirectory(
                rootURL,
                String(describing: error)
            )
        }
        try applyProtectedMetadata(url: rootURL, documentID: nil)
        let verification = try readVerification(url: rootURL, documentID: nil)
        guard verification.isExcludedFromBackup else {
            throw FileRecoveryStoreError.backupExclusionVerificationFailed(nil, rootURL)
        }
        #if !targetEnvironment(simulator)
        guard verification.hasCompleteFileProtection else {
            throw FileRecoveryStoreError.fileProtectionVerificationFailed(nil, rootURL)
        }
        #endif
    }

    private func encode(envelope: RecoveryEnvelope) throws -> Data {
        do {
            return try JSONEncoder().encode(envelope)
        } catch {
            throw FileRecoveryStoreError.couldNotEncodeCheckpoint(
                envelope.documentID,
                String(describing: error)
            )
        }
    }

    private func writeStagedEnvelope(
        data: Data,
        envelope: RecoveryEnvelope,
        stagingURL: URL
    ) throws {
        do {
            try data.write(
                to: stagingURL,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            throw FileRecoveryStoreError.couldNotWriteCheckpoint(
                envelope.documentID,
                stagingURL,
                String(describing: error)
            )
        }
        try applyProtectedMetadata(url: stagingURL, documentID: envelope.documentID)
        try verifyStoredEnvelope(
            url: stagingURL,
            expectedEnvelope: envelope,
            expectedData: data
        )
    }

    private func preservePreviousGeneration(
        documentID: DocumentID,
        canonicalURL: URL,
        backupURL: URL
    ) throws -> (data: Data, envelope: RecoveryEnvelope)? {
        guard fileManager.fileExists(atPath: canonicalURL.path) else {
            return nil
        }
        let previousGeneration = try readEnvelope(
            documentID: documentID,
            url: canonicalURL
        )
        try verifyStoredEnvelope(
            url: canonicalURL,
            expectedEnvelope: previousGeneration.envelope,
            expectedData: previousGeneration.data
        )
        do {
            try fileManager.copyItem(at: canonicalURL, to: backupURL)
        } catch {
            throw FileRecoveryStoreError.couldNotCreatePreviousGenerationBackup(
                documentID,
                backupURL,
                String(describing: error)
            )
        }
        try applyProtectedMetadata(url: backupURL, documentID: documentID)
        try verifyStoredEnvelope(
            url: backupURL,
            expectedEnvelope: previousGeneration.envelope,
            expectedData: previousGeneration.data
        )
        return previousGeneration
    }

    private func promote(
        documentID: DocumentID,
        stagingURL: URL,
        canonicalURL: URL,
        hasPreviousGeneration: Bool
    ) throws {
        do {
            if hasPreviousGeneration {
                _ = try fileManager.replaceItemAt(
                    canonicalURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: canonicalURL)
            }
        } catch {
            throw FileRecoveryStoreError.couldNotPromoteCheckpoint(
                documentID,
                canonicalURL,
                String(describing: error)
            )
        }
    }

    private func restorePreviousGeneration(
        documentID: DocumentID,
        canonicalURL: URL,
        backupURL: URL?,
        failedURL: URL,
        previousGeneration: (data: Data, envelope: RecoveryEnvelope)?,
        originalFailure: Error
    ) throws {
        do {
            if fileManager.fileExists(atPath: canonicalURL.path) {
                try fileManager.moveItem(at: canonicalURL, to: failedURL)
            }
            if let backupURL, let previousGeneration {
                try fileManager.moveItem(at: backupURL, to: canonicalURL)
                try applyProtectedMetadata(url: canonicalURL, documentID: documentID)
                try verifyStoredEnvelope(
                    url: canonicalURL,
                    expectedEnvelope: previousGeneration.envelope,
                    expectedData: previousGeneration.data
                )
            }
        } catch {
            throw FileRecoveryStoreError.rollbackFailed(
                documentID,
                "Original failure: \(String(describing: originalFailure)); rollback failure: \(String(describing: error))"
            )
        }
    }

    private func applyProtectedMetadata(
        url: URL,
        documentID: DocumentID?
    ) throws {
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            throw FileRecoveryStoreError.couldNotApplyProtection(
                documentID,
                url,
                String(describing: error)
            )
        }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var metadataURL = url
            try metadataURL.setResourceValues(values)
        } catch {
            throw FileRecoveryStoreError.couldNotApplyBackupExclusion(
                documentID,
                url,
                String(describing: error)
            )
        }
    }

    private func readEnvelope(
        documentID: DocumentID,
        url: URL
    ) throws -> (data: Data, envelope: RecoveryEnvelope) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileRecoveryStoreError.couldNotReadCheckpoint(
                documentID,
                url,
                String(describing: error)
            )
        }

        let envelope: RecoveryEnvelope
        do {
            envelope = try JSONDecoder().decode(RecoveryEnvelope.self, from: data)
        } catch {
            throw FileRecoveryStoreError.couldNotDecodeCheckpoint(
                documentID,
                url,
                String(describing: error)
            )
        }
        guard envelope.formatVersion == RecoveryEnvelope.currentFormatVersion else {
            throw FileRecoveryStoreError.unsupportedCheckpointVersion(
                documentID,
                expected: RecoveryEnvelope.currentFormatVersion,
                actual: envelope.formatVersion,
                url
            )
        }
        guard envelope.documentID == documentID else {
            throw FileRecoveryStoreError.checkpointDocumentMismatch(
                expected: documentID,
                actual: envelope.documentID,
                url
            )
        }
        return (data, envelope)
    }

    private func verifyStoredEnvelope(
        url: URL,
        expectedEnvelope: RecoveryEnvelope,
        expectedData: Data
    ) throws {
        let actual = try readEnvelope(
            documentID: expectedEnvelope.documentID,
            url: url
        )
        guard actual.data == expectedData, actual.envelope == expectedEnvelope else {
            throw FileRecoveryStoreError.checkpointContentMismatch(
                expectedEnvelope.documentID,
                url
            )
        }
        let verification = try readVerification(
            url: url,
            documentID: expectedEnvelope.documentID
        )
        guard verification.isExcludedFromBackup else {
            throw FileRecoveryStoreError.backupExclusionVerificationFailed(
                expectedEnvelope.documentID,
                url
            )
        }
        #if !targetEnvironment(simulator)
        guard verification.hasCompleteFileProtection else {
            throw FileRecoveryStoreError.fileProtectionVerificationFailed(
                expectedEnvelope.documentID,
                url
            )
        }
        #endif
    }

    private func readVerification(
        url: URL,
        documentID: DocumentID?
    ) throws -> RecoveryCheckpointVerification {
        var uncachedURL = url
        uncachedURL.removeAllCachedResourceValues()
        let values: URLResourceValues
        do {
            values = try uncachedURL.resourceValues(
                forKeys: [
                    .fileProtectionKey,
                    .isExcludedFromBackupKey,
                    .isRegularFileKey,
                    .isDirectoryKey,
                ]
            )
        } catch {
            throw FileRecoveryStoreError.couldNotReadRecoveryMetadata(
                documentID,
                url,
                String(describing: error)
            )
        }
        let hasExpectedType = documentID == nil
            ? values.isDirectory == true
            : values.isRegularFile == true
        guard hasExpectedType else {
            throw FileRecoveryStoreError.recoveryItemHasUnexpectedType(
                documentID,
                url
            )
        }
        return RecoveryCheckpointVerification(
            hasCompleteFileProtection: values.fileProtection == .complete,
            isExcludedFromBackup: values.isExcludedFromBackup == true
        )
    }

    private func checkpointURL(documentID: DocumentID) -> URL {
        let filename = documentID.rawValue.uuidString.lowercased() + ".recovery.json"
        return rootURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func temporaryURL(kind: String, documentID: DocumentID) -> URL {
        let filename = ".\(documentID.rawValue.uuidString.lowercased()).\(kind).\(UUID().uuidString.lowercased())"
        return rootURL.appendingPathComponent(filename, isDirectory: false)
    }
}

private func recoveryMessage(documentID: DocumentID?, message: String) -> String {
    guard let documentID else {
        return message
    }
    return "Document \(documentID.rawValue): \(message)"
}
