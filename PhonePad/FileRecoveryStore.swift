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
    case couldNotCommitCheckpoint(DocumentID, URL, String)
    case couldNotRemoveRecoveryArtifact(DocumentID, URL, String)
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
        case let .couldNotCommitCheckpoint(documentID, _, _):
            "New recovery data for document \(documentID.rawValue) is verified, but its transaction could not be committed. The previous verified generation remains available."
        case let .couldNotRemoveRecoveryArtifact(documentID, _, _):
            "Could not remove rejected recovery data for document \(documentID.rawValue). Do not discard recovery data; retry Recovery."
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

        let paths = transactionPaths(documentID: envelope.documentID)
        try reconcile(documentID: envelope.documentID, paths: paths)

        let encodedEnvelope = try encode(envelope: envelope)
        do {
            try writeProtectedEnvelope(
                data: encodedEnvelope,
                envelope: envelope,
                url: paths.staging
            )
        } catch {
            try removeRejectedArtifact(
                documentID: envelope.documentID,
                url: paths.staging,
                originalFailure: error
            )
            throw error
        }

        let previousGeneration = try preservePreviousGeneration(
            documentID: envelope.documentID,
            canonicalURL: paths.canonical,
            backupURL: paths.previous
        )

        do {
            try writeProtectedEnvelope(
                data: encodedEnvelope,
                envelope: envelope,
                url: paths.transaction
            )
            try promote(
                documentID: envelope.documentID,
                stagingURL: paths.staging,
                canonicalURL: paths.canonical,
                hasPreviousGeneration: previousGeneration != nil
            )
            try applyProtectedMetadata(
                url: paths.canonical,
                documentID: envelope.documentID
            )
            try verifyStoredEnvelope(
                url: paths.canonical,
                expectedEnvelope: envelope,
                expectedData: encodedEnvelope
            )
            try postPromotionValidation(paths.canonical)
        } catch {
            try restorePreviousGeneration(
                documentID: envelope.documentID,
                paths: paths,
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

        do {
            try removeArtifactIfPresent(
                documentID: envelope.documentID,
                url: paths.transaction
            )
        } catch {
            throw FileRecoveryStoreError.couldNotCommitCheckpoint(
                envelope.documentID,
                paths.transaction,
                String(describing: error)
            )
        }

        guard previousGeneration != nil else {
            return
        }
        do {
            try removeArtifactIfPresent(
                documentID: envelope.documentID,
                url: paths.previous
            )
        } catch {
            throw FileRecoveryStoreError.couldNotRemovePreviousGenerationBackup(
                envelope.documentID,
                paths.previous,
                String(describing: error)
            )
        }
    }

    public func load(documentID: DocumentID) async throws -> RecoveryEnvelope? {
        try prepareRecoveryDirectory()
        let paths = transactionPaths(documentID: documentID)
        try reconcile(documentID: documentID, paths: paths)
        guard fileManager.fileExists(atPath: paths.canonical.path) else {
            return nil
        }

        let (data, envelope) = try readEnvelope(
            documentID: documentID,
            url: paths.canonical
        )
        try verifyStoredEnvelope(
            url: paths.canonical,
            expectedEnvelope: envelope,
            expectedData: data
        )
        return envelope
    }

    public func verifyCheckpoint(
        documentID: DocumentID
    ) async throws -> RecoveryCheckpointVerification {
        try prepareRecoveryDirectory()
        let paths = transactionPaths(documentID: documentID)
        try reconcile(documentID: documentID, paths: paths)
        guard fileManager.fileExists(atPath: paths.canonical.path) else {
            throw FileRecoveryStoreError.checkpointNotFound(documentID, paths.canonical)
        }
        return try readVerification(url: paths.canonical, documentID: documentID)
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

    private func writeProtectedEnvelope(
        data: Data,
        envelope: RecoveryEnvelope,
        url: URL
    ) throws {
        do {
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            throw FileRecoveryStoreError.couldNotWriteCheckpoint(
                envelope.documentID,
                url,
                String(describing: error)
            )
        }
        try applyProtectedMetadata(url: url, documentID: envelope.documentID)
        try verifyStoredEnvelope(
            url: url,
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
            try removeRejectedArtifact(
                documentID: documentID,
                url: backupURL,
                originalFailure: error
            )
            throw FileRecoveryStoreError.couldNotCreatePreviousGenerationBackup(
                documentID,
                backupURL,
                String(describing: error)
            )
        }
        do {
            try applyProtectedMetadata(url: backupURL, documentID: documentID)
            try verifyStoredEnvelope(
                url: backupURL,
                expectedEnvelope: previousGeneration.envelope,
                expectedData: previousGeneration.data
            )
        } catch {
            try removeRejectedArtifact(
                documentID: documentID,
                url: backupURL,
                originalFailure: error
            )
            throw error
        }
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
        paths: RecoveryTransactionPaths,
        previousGeneration: (data: Data, envelope: RecoveryEnvelope)?,
        originalFailure: Error
    ) throws {
        do {
            if let previousGeneration {
                try verifyStoredEnvelope(
                    url: paths.previous,
                    expectedEnvelope: previousGeneration.envelope,
                    expectedData: previousGeneration.data
                )
                try removeArtifactIfPresent(
                    documentID: documentID,
                    url: paths.canonical
                )
                try fileManager.copyItem(at: paths.previous, to: paths.canonical)
                try applyProtectedMetadata(url: paths.canonical, documentID: documentID)
                try verifyStoredEnvelope(
                    url: paths.canonical,
                    expectedEnvelope: previousGeneration.envelope,
                    expectedData: previousGeneration.data
                )
            } else {
                try removeArtifactIfPresent(
                    documentID: documentID,
                    url: paths.canonical
                )
            }
            try removeArtifactIfPresent(documentID: documentID, url: paths.staging)
            try removeArtifactIfPresent(documentID: documentID, url: paths.transaction)
            try removeArtifactIfPresent(documentID: documentID, url: paths.previous)
        } catch {
            throw FileRecoveryStoreError.rollbackFailed(
                documentID,
                "Original failure: \(String(describing: originalFailure)); rollback failure: \(String(describing: error))"
            )
        }
    }

    private func reconcile(
        documentID: DocumentID,
        paths: RecoveryTransactionPaths
    ) throws {
        let hasTransaction = fileManager.fileExists(atPath: paths.transaction.path)
        let hasPrevious = fileManager.fileExists(atPath: paths.previous.path)
        let hasCanonical = fileManager.fileExists(atPath: paths.canonical.path)

        if hasTransaction {
            if hasPrevious {
                let previousGeneration = try readVerifiedEnvelope(
                    documentID: documentID,
                    url: paths.previous
                )
                try restorePreviousGeneration(
                    documentID: documentID,
                    paths: paths,
                    previousGeneration: previousGeneration,
                    originalFailure: FileRecoveryInterruption.interruptedTransaction
                )
            } else {
                try restorePreviousGeneration(
                    documentID: documentID,
                    paths: paths,
                    previousGeneration: nil,
                    originalFailure: FileRecoveryInterruption.interruptedFirstGeneration
                )
            }
            return
        }

        if hasCanonical {
            do {
                _ = try readVerifiedEnvelope(
                    documentID: documentID,
                    url: paths.canonical
                )
            } catch {
                throw error
            }
            try removeArtifactIfPresent(documentID: documentID, url: paths.staging)
            try removeArtifactIfPresent(documentID: documentID, url: paths.previous)
            return
        }

        if hasPrevious {
            let previousGeneration = try readVerifiedEnvelope(
                documentID: documentID,
                url: paths.previous
            )
            try restorePreviousGeneration(
                documentID: documentID,
                paths: paths,
                previousGeneration: previousGeneration,
                originalFailure: FileRecoveryInterruption.missingCanonical
            )
            return
        }

        try removeArtifactIfPresent(documentID: documentID, url: paths.staging)
    }

    private func readVerifiedEnvelope(
        documentID: DocumentID,
        url: URL
    ) throws -> (data: Data, envelope: RecoveryEnvelope) {
        let storedEnvelope = try readEnvelope(documentID: documentID, url: url)
        try verifyStoredEnvelope(
            url: url,
            expectedEnvelope: storedEnvelope.envelope,
            expectedData: storedEnvelope.data
        )
        return storedEnvelope
    }

    private func removeRejectedArtifact(
        documentID: DocumentID,
        url: URL,
        originalFailure: Error
    ) throws {
        do {
            try removeArtifactIfPresent(documentID: documentID, url: url)
        } catch {
            throw FileRecoveryStoreError.rollbackFailed(
                documentID,
                "Original failure: \(String(describing: originalFailure)); cleanup failure: \(String(describing: error))"
            )
        }
    }

    private func removeArtifactIfPresent(
        documentID: DocumentID,
        url: URL
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw FileRecoveryStoreError.couldNotRemoveRecoveryArtifact(
                documentID,
                url,
                String(describing: error)
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

    private func transactionPaths(documentID: DocumentID) -> RecoveryTransactionPaths {
        let identifier = documentID.rawValue.uuidString.lowercased()
        return RecoveryTransactionPaths(
            canonical: checkpointURL(documentID: documentID),
            staging: rootURL.appendingPathComponent(
                ".\(identifier).recovery.staging",
                isDirectory: false
            ),
            transaction: rootURL.appendingPathComponent(
                ".\(identifier).recovery.transaction",
                isDirectory: false
            ),
            previous: rootURL.appendingPathComponent(
                ".\(identifier).recovery.previous",
                isDirectory: false
            )
        )
    }
}

private struct RecoveryTransactionPaths {
    let canonical: URL
    let staging: URL
    let transaction: URL
    let previous: URL
}

private enum FileRecoveryInterruption: Error {
    case interruptedTransaction
    case interruptedFirstGeneration
    case missingCanonical
}

private func recoveryMessage(documentID: DocumentID?, message: String) -> String {
    guard let documentID else {
        return message
    }
    return "Document \(documentID.rawValue): \(message)"
}
