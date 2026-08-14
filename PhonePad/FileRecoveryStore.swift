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
    case checkpointExceedsMaximumSize(
        DocumentID,
        actualByteCount: UInt64,
        maximumByteCount: UInt64,
        URL
    )
    case checkpointContentExceedsMaximumSize(
        DocumentID,
        actualByteCount: UInt64,
        maximumByteCount: UInt64,
        URL
    )
    case checkpointMetadataExceedsMaximumSize(
        DocumentID,
        actualByteCount: UInt64,
        maximumByteCount: UInt64,
        URL
    )
    case couldNotEnumerateRecovery(String)
    case couldNotEncodeCleanupMarker(DocumentID, String)
    case couldNotWriteCleanupMarker(DocumentID, URL, String)
    case cleanupMarkerContentMismatch(DocumentID, URL)
    case terminalCleanupBlocksCheckpoint(DocumentID)

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
        case let .checkpointExceedsMaximumSize(documentID, _, _, _):
            "Recovery data for document \(documentID.rawValue) exceeds the bounded recovery format size. Keep it until you choose Discard Recovery."
        case let .checkpointContentExceedsMaximumSize(documentID, _, _, _):
            "Recovery content for document \(documentID.rawValue) exceeds the 75 MiB limit. Keep it until you choose Discard Recovery."
        case let .checkpointMetadataExceedsMaximumSize(documentID, _, _, _):
            "Recovery metadata for document \(documentID.rawValue) exceeds the 64 KiB limit. Keep it until you choose Discard Recovery."
        case .couldNotEnumerateRecovery:
            "Could not inspect preserved work. Check available device storage and retry Document Recovery."
        case let .couldNotEncodeCleanupMarker(documentID, _):
            "Could not prepare recovery cleanup for document \(documentID.rawValue). Preserved work remains available; retry."
        case let .couldNotWriteCleanupMarker(documentID, _, _):
            "Could not record recovery cleanup for document \(documentID.rawValue). Preserved work remains available; retry."
        case let .cleanupMarkerContentMismatch(documentID, _):
            "Recovery cleanup for document \(documentID.rawValue) could not be verified. Preserved work remains available; retry."
        case let .terminalCleanupBlocksCheckpoint(documentID):
            "Protected recovery cleanup for document \(documentID.rawValue) remains pending. No new checkpoint was created; retry recovery cleanup before editing."
        }
    }
}

public actor FileRecoveryStore: RecoveryStoring {
    typealias PostPromotionValidation = @Sendable (URL) throws -> Void
    typealias TerminalArtifactRemoval = @Sendable (FileManager, URL) throws -> Void

    private let rootURL: URL
    private let fileManager: FileManager
    private let postPromotionValidation: PostPromotionValidation
    private let terminalArtifactRemoval: TerminalArtifactRemoval

    public init(rootURL: URL, fileManager: FileManager) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        postPromotionValidation = { _ in }
        terminalArtifactRemoval = removeTerminalArtifact
    }

    init(
        rootURL: URL,
        fileManager: FileManager,
        postPromotionValidation: @escaping PostPromotionValidation
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.postPromotionValidation = postPromotionValidation
        terminalArtifactRemoval = removeTerminalArtifact
    }

    init(
        rootURL: URL,
        fileManager: FileManager,
        postPromotionValidation: @escaping PostPromotionValidation,
        terminalArtifactRemoval: @escaping TerminalArtifactRemoval
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.postPromotionValidation = postPromotionValidation
        self.terminalArtifactRemoval = terminalArtifactRemoval
    }

    public func save(envelope: RecoveryEnvelope) async throws {
        try prepareRecoveryDirectory()

        let paths = transactionPaths(documentID: envelope.documentID)
        let terminalOutcome = try reconcile(
            documentID: envelope.documentID,
            paths: paths
        )
        guard terminalOutcome != .residualCleanupPending else {
            throw FileRecoveryStoreError.terminalCleanupBlocksCheckpoint(
                envelope.documentID
            )
        }

        let protectedEnvelope = try recoveryEnvelopeForUse(envelope)
        try validateEnvelopeBounds(envelope: protectedEnvelope, url: paths.staging)
        let encodedEnvelope = try encode(envelope: protectedEnvelope)
        do {
            try writeProtectedEnvelope(
                data: encodedEnvelope,
                envelope: protectedEnvelope,
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
                envelope: protectedEnvelope,
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
                expectedEnvelope: protectedEnvelope,
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
        if try reconcile(documentID: documentID, paths: paths) != nil {
            return nil
        }
        guard try recoveryArtifactExists(documentID: documentID, url: paths.canonical) else {
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
        if try reconcile(documentID: documentID, paths: paths) != nil {
            throw FileRecoveryStoreError.checkpointNotFound(documentID, paths.canonical)
        }
        guard try recoveryArtifactExists(documentID: documentID, url: paths.canonical) else {
            throw FileRecoveryStoreError.checkpointNotFound(documentID, paths.canonical)
        }
        return try readVerification(url: paths.canonical, documentID: documentID)
    }

    public func recoveryItems() async throws -> [RecoveryItemSummary] {
        try prepareRecoveryDirectory()
        let documentIDs = try recoveryDocumentIDs()
        var items: [RecoveryItemSummary] = []
        for documentID in documentIDs {
            let paths = transactionPaths(documentID: documentID)
            do {
                if try reconcile(documentID: documentID, paths: paths) != nil {
                    continue
                }
                guard try recoveryArtifactExists(
                    documentID: documentID,
                    url: paths.canonical
                ) else {
                    continue
                }
                let storedEnvelope = try readVerifiedEnvelope(
                    documentID: documentID,
                    url: paths.canonical
                )
                items.append(
                    RecoveryItemSummary(
                        documentID: documentID,
                        title: recoveryDisplayTitle(storedEnvelope.envelope.title),
                        lastEdited: .available(storedEnvelope.envelope.editedAt),
                        status: .recoverable
                    )
                )
            } catch let error as FileRecoveryStoreError {
                guard let summary = recoveryFailureSummary(
                    error: error,
                    documentID: documentID
                ) else {
                    throw error
                }
                guard try recoveryArtifactExists(
                    documentID: documentID,
                    url: paths.canonical
                ) else {
                    continue
                }
                items.append(summary)
            }
        }

        return items.sorted(by: recoverySummaryComesBefore)
    }

    public func recoveryFileCollisionClaims(
        excludingDocumentID: DocumentID
    ) async throws -> [FileCollisionClaim] {
        try prepareRecoveryDirectory()
        let documentIDs = try recoveryDocumentIDs().filter {
            $0 != excludingDocumentID
        }.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        var claims: [FileCollisionClaim] = []
        for documentID in documentIDs {
            let paths = transactionPaths(documentID: documentID)
            if try reconcile(documentID: documentID, paths: paths) != nil {
                continue
            }
            guard try recoveryArtifactExists(
                documentID: documentID,
                url: paths.canonical
            ) else {
                continue
            }
            let envelope = try readVerifiedEnvelope(
                documentID: documentID,
                url: paths.canonical
            ).envelope
            if let fileReference = envelope.fileReference {
                claims.append(
                    .recoveryItem(
                        documentID: documentID,
                        reference: FileCollisionReference(
                            bookmark: fileReference.bookmark,
                            identity: fileReference.identity
                        )
                    )
                )
            }
            if case let .saveAs(destination)? = envelope.pendingSave?.destination {
                claims.append(
                    .pendingSaveAs(
                        documentID: documentID,
                        destination: destination
                    )
                )
            }
        }
        return claims
    }

    @discardableResult
    public func discardRecovery(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        try prepareRecoveryDirectory()
        let paths = transactionPaths(documentID: documentID)

        do {
            if let terminalOutcome = try reconcile(
                documentID: documentID,
                paths: paths
            ) {
                return terminalOutcome
            }
        } catch let error as FileRecoveryStoreError {
            guard recoveryFailureSummary(error: error, documentID: documentID) != nil else {
                throw error
            }
        }

        let hasRecoveryArtifact = try [
            paths.canonical,
            paths.staging,
            paths.transaction,
            paths.previous,
        ].contains {
            try recoveryArtifactExists(documentID: documentID, url: $0)
        }
        guard hasRecoveryArtifact else {
            return .complete
        }

        let marker = RecoveryCleanupMarker(
            documentID: documentID,
            action: .discard
        )
        let markerData = try encodeCleanupMarker(marker)
        try writeProtectedCleanupMarker(
            marker: marker,
            data: markerData,
            url: paths.transaction
        )
        return try finishTerminalRecovery(
            marker: marker,
            markerData: markerData,
            paths: paths
        )
    }

    @discardableResult
    public func completeRecoveryAfterSave(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        try prepareRecoveryDirectory()
        let paths = transactionPaths(documentID: documentID)
        if let terminalOutcome = try finishVerifiedCleanupMarkerIfPresent(
            documentID: documentID,
            paths: paths
        ) {
            return terminalOutcome
        }
        try verifyRecoveryArtifactsForSavedCompletion(
            documentID: documentID,
            paths: paths
        )
        if let terminalOutcome = try reconcile(
            documentID: documentID,
            paths: paths
        ) {
            return terminalOutcome
        }
        guard try recoveryArtifactExists(
            documentID: documentID,
            url: paths.canonical
        ) else {
            return .complete
        }

        _ = try readVerifiedEnvelope(documentID: documentID, url: paths.canonical)
        let marker = RecoveryCleanupMarker(
            documentID: documentID,
            action: .saved
        )
        let markerData = try encodeCleanupMarker(marker)
        try writeProtectedCleanupMarker(
            marker: marker,
            data: markerData,
            url: paths.transaction
        )
        return try finishTerminalRecovery(
            marker: marker,
            markerData: markerData,
            paths: paths
        )
    }

    private func finishVerifiedCleanupMarkerIfPresent(
        documentID: DocumentID,
        paths: RecoveryTransactionPaths
    ) throws -> RecoveryTerminalOutcome? {
        for url in [paths.canonical, paths.transaction] {
            guard let marker = try readCleanupMarkerIfPresent(
                documentID: documentID,
                url: url
            ) else {
                continue
            }
            let markerData = try encodeCleanupMarker(marker)
            return try finishTerminalRecovery(
                marker: marker,
                markerData: markerData,
                paths: paths
            )
        }
        return nil
    }

    private func verifyRecoveryArtifactsForSavedCompletion(
        documentID: DocumentID,
        paths: RecoveryTransactionPaths
    ) throws {
        for url in [
            paths.canonical,
            paths.staging,
            paths.transaction,
            paths.previous,
        ] {
            guard try recoveryArtifactExists(documentID: documentID, url: url) else {
                continue
            }
            _ = try readVerifiedEnvelope(documentID: documentID, url: url)
        }
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

    private func encodeCleanupMarker(_ marker: RecoveryCleanupMarker) throws -> Data {
        do {
            return try JSONEncoder().encode(marker)
        } catch {
            throw FileRecoveryStoreError.couldNotEncodeCleanupMarker(
                marker.documentID,
                String(describing: error)
            )
        }
    }

    private func writeProtectedCleanupMarker(
        marker: RecoveryCleanupMarker,
        data: Data,
        url: URL
    ) throws {
        do {
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            throw FileRecoveryStoreError.couldNotWriteCleanupMarker(
                marker.documentID,
                url,
                String(describing: error)
            )
        }
        try applyProtectedMetadata(url: url, documentID: marker.documentID)
        try verifyCleanupMarker(marker: marker, url: url)
    }

    private func finishTerminalRecovery(
        marker: RecoveryCleanupMarker,
        markerData: Data,
        paths: RecoveryTransactionPaths
    ) throws -> RecoveryTerminalOutcome {
        let canonicalMarker = try readableCleanupMarkerIfPresent(
            documentID: marker.documentID,
            url: paths.canonical
        )
        if canonicalMarker != marker {
            try writeProtectedCleanupMarker(
                marker: marker,
                data: markerData,
                url: paths.staging
            )
            let hasCanonical = try recoveryArtifactExists(
                documentID: marker.documentID,
                url: paths.canonical
            )
            if hasCanonical {
                try removeArtifactIfPresent(
                    documentID: marker.documentID,
                    url: paths.canonical
                )
            }
            try promote(
                documentID: marker.documentID,
                stagingURL: paths.staging,
                canonicalURL: paths.canonical,
                hasPreviousGeneration: false
            )
            try applyProtectedMetadata(
                url: paths.canonical,
                documentID: marker.documentID
            )
        }

        try verifyCleanupMarker(
            marker: marker,
            url: paths.canonical
        )
        let sidecarsRemoved = [
            paths.staging,
            paths.previous,
            paths.transaction,
        ].map { url in
            removeTerminalArtifactIfPresent(
                documentID: marker.documentID,
                url: url
            )
        }
        guard sidecarsRemoved.allSatisfy({ $0 }) else {
            return .residualCleanupPending
        }
        guard removeTerminalArtifactIfPresent(
            documentID: marker.documentID,
            url: paths.canonical
        ) else {
            return .residualCleanupPending
        }
        return .complete
    }

    private func removeTerminalArtifactIfPresent(
        documentID: DocumentID,
        url: URL
    ) -> Bool {
        do {
            guard try recoveryArtifactExists(documentID: documentID, url: url) else {
                return true
            }
            try terminalArtifactRemoval(fileManager, url)
            return true
        } catch {
            return false
        }
    }

    private func readCleanupMarkerIfPresent(
        documentID: DocumentID,
        url: URL
    ) throws -> RecoveryCleanupMarker? {
        guard try recoveryArtifactExists(documentID: documentID, url: url) else {
            return nil
        }
        let byteCount = try recoveryFileByteCount(documentID: documentID, url: url)
        guard byteCount <= maximumRecoveryCleanupMarkerByteCount else {
            return nil
        }

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

        guard let marker = try? JSONDecoder().decode(
            RecoveryCleanupMarker.self,
            from: data
        ) else {
            return nil
        }
        guard marker.documentID == documentID,
              marker.isCurrent else {
            return nil
        }
        try verifyCleanupMarker(marker: marker, url: url)
        return marker
    }

    private func readableCleanupMarkerIfPresent(
        documentID: DocumentID,
        url: URL
    ) throws -> RecoveryCleanupMarker? {
        do {
            return try readCleanupMarkerIfPresent(documentID: documentID, url: url)
        } catch let error as FileRecoveryStoreError {
            guard recoveryFailureSummary(error: error, documentID: documentID) != nil else {
                throw error
            }
            return nil
        }
    }

    private func verifyCleanupMarker(
        marker: RecoveryCleanupMarker,
        url: URL
    ) throws {
        let actualData: Data
        do {
            actualData = try Data(contentsOf: url)
        } catch {
            throw FileRecoveryStoreError.couldNotReadCheckpoint(
                marker.documentID,
                url,
                String(describing: error)
            )
        }
        guard let actualMarker = try? JSONDecoder().decode(
                  RecoveryCleanupMarker.self,
                  from: actualData
              ),
              actualMarker == marker else {
            throw FileRecoveryStoreError.cleanupMarkerContentMismatch(
                marker.documentID,
                url
            )
        }

        let verification = try readVerification(
            url: url,
            documentID: marker.documentID
        )
        guard verification.isExcludedFromBackup else {
            throw FileRecoveryStoreError.backupExclusionVerificationFailed(
                marker.documentID,
                url
            )
        }
        #if !targetEnvironment(simulator)
        guard verification.hasCompleteFileProtection else {
            throw FileRecoveryStoreError.fileProtectionVerificationFailed(
                marker.documentID,
                url
            )
        }
        #endif
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
        guard try recoveryArtifactExists(documentID: documentID, url: canonicalURL) else {
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
    ) throws -> RecoveryTerminalOutcome? {
        let hasTransaction = try recoveryArtifactExists(
            documentID: documentID,
            url: paths.transaction
        )
        let hasPrevious = try recoveryArtifactExists(
            documentID: documentID,
            url: paths.previous
        )
        let hasCanonical = try recoveryArtifactExists(
            documentID: documentID,
            url: paths.canonical
        )

        if hasCanonical,
           let marker = try readCleanupMarkerIfPresent(
               documentID: documentID,
               url: paths.canonical
            ) {
            let markerData = try encodeCleanupMarker(marker)
            return try finishTerminalRecovery(
                marker: marker,
                markerData: markerData,
                paths: paths
            )
        }

        if hasTransaction,
           let marker = try readCleanupMarkerIfPresent(
               documentID: documentID,
               url: paths.transaction
            ) {
            let markerData = try encodeCleanupMarker(marker)
            return try finishTerminalRecovery(
                marker: marker,
                markerData: markerData,
                paths: paths
            )
        }

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
                let transactionGeneration = try readVerifiedEnvelope(
                    documentID: documentID,
                    url: paths.transaction
                )
                if hasCanonical {
                    let canonicalGeneration = try readVerifiedEnvelope(
                        documentID: documentID,
                        url: paths.canonical
                    )
                    guard canonicalGeneration == transactionGeneration else {
                        throw FileRecoveryStoreError.checkpointContentMismatch(
                            documentID,
                            paths.canonical
                        )
                    }
                    try removeArtifactIfPresent(
                        documentID: documentID,
                        url: paths.staging
                    )
                    try removeArtifactIfPresent(
                        documentID: documentID,
                        url: paths.transaction
                    )
                } else {
                    try writeProtectedEnvelope(
                        data: transactionGeneration.data,
                        envelope: transactionGeneration.envelope,
                        url: paths.canonical
                    )
                    try removeArtifactIfPresent(
                        documentID: documentID,
                        url: paths.staging
                    )
                    try removeArtifactIfPresent(
                        documentID: documentID,
                        url: paths.transaction
                    )
                }
            }
            return nil
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
            return nil
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
            return nil
        }

        try removeArtifactIfPresent(documentID: documentID, url: paths.staging)
        return nil
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
        guard try recoveryArtifactExists(documentID: documentID, url: url) else {
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

    private func recoveryArtifactExists(
        documentID: DocumentID,
        url: URL
    ) throws -> Bool {
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && (
                    error.code == CocoaError.Code.fileNoSuchFile.rawValue
                        || error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
                ) {
            return false
        } catch {
            throw FileRecoveryStoreError.couldNotReadRecoveryMetadata(
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
        let serializedByteCount = try recoveryFileByteCount(
            documentID: documentID,
            url: url
        )
        guard serializedByteCount <= maximumRecoverySerializedByteCount else {
            throw FileRecoveryStoreError.checkpointExceedsMaximumSize(
                documentID,
                actualByteCount: serializedByteCount,
                maximumByteCount: maximumRecoverySerializedByteCount,
                url
            )
        }

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

        let formatHeader: RecoveryFormatHeader
        do {
            formatHeader = try JSONDecoder().decode(RecoveryFormatHeader.self, from: data)
        } catch {
            throw FileRecoveryStoreError.couldNotDecodeCheckpoint(
                documentID,
                url,
                String(describing: error)
            )
        }
        guard formatHeader.formatVersion == RecoveryEnvelope.currentFormatVersion else {
            throw FileRecoveryStoreError.unsupportedCheckpointVersion(
                documentID,
                expected: RecoveryEnvelope.currentFormatVersion,
                actual: formatHeader.formatVersion,
                url
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
        guard envelope.documentID == documentID else {
            throw FileRecoveryStoreError.checkpointDocumentMismatch(
                expected: documentID,
                actual: envelope.documentID,
                url
            )
        }
        try validateEnvelopeBounds(envelope: envelope, url: url)
        return (data, try recoveryEnvelopeForUse(envelope))
    }

    private func recoveryFileByteCount(
        documentID: DocumentID,
        url: URL
    ) throws -> UInt64 {
        do {
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw FileRecoveryStoreError.recoveryItemHasUnexpectedType(
                    documentID,
                    url
                )
            }
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw FileRecoveryStoreError.couldNotReadRecoveryMetadata(
                    documentID,
                    url,
                    "Recovery file size is unavailable."
                )
            }
            return UInt64(fileSize)
        } catch let error as FileRecoveryStoreError {
            throw error
        } catch {
            throw FileRecoveryStoreError.couldNotReadRecoveryMetadata(
                documentID,
                url,
                String(describing: error)
            )
        }
    }

    private func recoveryDocumentIDs() throws -> Set<DocumentID> {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw FileRecoveryStoreError.couldNotEnumerateRecovery(
                String(describing: error)
            )
        }
        return Set(
            urls.compactMap {
                recoveryArtifactDocumentID(filename: $0.lastPathComponent)
            }
        )
    }

    private func validateEnvelopeBounds(
        envelope: RecoveryEnvelope,
        url: URL
    ) throws {
        let contentByteCount = UInt64(envelope.text.utf8.count)
        guard contentByteCount <= maximumRecoveryContentByteCount else {
            throw FileRecoveryStoreError.checkpointContentExceedsMaximumSize(
                envelope.documentID,
                actualByteCount: contentByteCount,
                maximumByteCount: maximumRecoveryContentByteCount,
                url
            )
        }

        let metadataEnvelope: RecoveryEnvelope
        do {
            metadataEnvelope = try RecoveryEnvelope(
                formatVersion: envelope.formatVersion,
                documentID: envelope.documentID,
                title: envelope.title,
                text: "",
                editedAt: envelope.editedAt,
                fileReference: envelope.fileReference,
                pendingSave: envelope.pendingSave
            )
        } catch {
            throw FileRecoveryStoreError.couldNotDecodeCheckpoint(
                envelope.documentID,
                url,
                String(describing: error)
            )
        }
        let metadataByteCount: UInt64
        do {
            metadataByteCount = UInt64(try JSONEncoder().encode(metadataEnvelope).count)
        } catch {
            throw FileRecoveryStoreError.couldNotDecodeCheckpoint(
                envelope.documentID,
                url,
                String(describing: error)
            )
        }
        guard metadataByteCount <= maximumRecoveryMetadataByteCount else {
            throw FileRecoveryStoreError.checkpointMetadataExceedsMaximumSize(
                envelope.documentID,
                actualByteCount: metadataByteCount,
                maximumByteCount: maximumRecoveryMetadataByteCount,
                url
            )
        }
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

private struct RecoveryCleanupMarker: Codable, Equatable {
    static let currentFormatVersion: UInt = 1
    static let expectedKind = "phonepad.recovery.cleanup"

    let formatVersion: UInt
    let kind: String
    let documentID: DocumentID
    let action: RecoveryCleanupAction

    var isCurrent: Bool {
        formatVersion == Self.currentFormatVersion
            && kind == Self.expectedKind
    }

    init(documentID: DocumentID, action: RecoveryCleanupAction) {
        formatVersion = Self.currentFormatVersion
        kind = Self.expectedKind
        self.documentID = documentID
        self.action = action
    }
}

private enum RecoveryCleanupAction: String, Codable {
    case discard
    case saved
}

private struct RecoveryFormatHeader: Decodable {
    let formatVersion: UInt
}

private enum FileRecoveryInterruption: Error {
    case interruptedTransaction
    case interruptedFirstGeneration
    case missingCanonical
}

private let maximumRecoveryContentByteCount: UInt64 = 75 * 1_024 * 1_024
private let maximumRecoveryMetadataByteCount: UInt64 = 64 * 1_024
private let maximumJSONEscapedBytesPerContentByte: UInt64 = 6
private let maximumRecoverySerializedByteCount = maximumRecoveryContentByteCount
    * maximumJSONEscapedBytesPerContentByte
    + maximumRecoveryMetadataByteCount
private let maximumRecoveryCleanupMarkerByteCount = maximumRecoveryMetadataByteCount

private func recoveryMessage(documentID: DocumentID?, message: String) -> String {
    guard let documentID else {
        return message
    }
    return "Document \(documentID.rawValue): \(message)"
}

private func canonicalDocumentID(filename: String) -> DocumentID? {
    let suffix = ".recovery.json"
    guard filename.hasSuffix(suffix) else {
        return nil
    }
    let identifier = String(filename.dropLast(suffix.count))
    return recoveryDocumentID(identifier: identifier)
}

private func recoveryArtifactDocumentID(filename: String) -> DocumentID? {
    if let canonicalDocumentID = canonicalDocumentID(filename: filename) {
        return canonicalDocumentID
    }

    let sidecarSuffixes = [
        ".recovery.staging",
        ".recovery.transaction",
        ".recovery.previous",
    ]
    guard filename.first == "." else {
        return nil
    }
    for suffix in sidecarSuffixes where filename.hasSuffix(suffix) {
        let identifier = String(filename.dropFirst().dropLast(suffix.count))
        return recoveryDocumentID(identifier: identifier)
    }
    return nil
}

private func recoveryDocumentID(identifier: String) -> DocumentID? {
    guard identifier.count == 36,
          identifier == identifier.lowercased(),
          let uuid = UUID(uuidString: identifier),
          uuid.uuidString.lowercased() == identifier else {
        return nil
    }
    return DocumentID(rawValue: uuid)
}

private func recoveryDisplayTitle(_ title: String) -> String {
    let leaf = (title as NSString).lastPathComponent
    let singleLine = leaf
        .components(separatedBy: .newlines)
        .joined(separator: " ")
    let withoutControls = String(
        singleLine.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
    )
    let trimmed = withoutControls.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        return "Recovered Document"
    }
    return String(trimmed.prefix(255))
}

private func recoveryEnvelopeForUse(_ envelope: RecoveryEnvelope) throws -> RecoveryEnvelope {
    try RecoveryEnvelope(
        formatVersion: envelope.formatVersion,
        documentID: envelope.documentID,
        title: recoveryDisplayTitle(envelope.title),
        text: envelope.text,
        editedAt: envelope.editedAt,
        fileReference: envelope.fileReference,
        pendingSave: envelope.pendingSave
    )
}

private func recoveryFailureSummary(
    error: FileRecoveryStoreError,
    documentID: DocumentID
) -> RecoveryItemSummary? {
    switch error {
    case let .unsupportedCheckpointVersion(_, _, actual, _):
        return RecoveryItemSummary(
            documentID: documentID,
            title: "Recovered Document",
            lastEdited: .unavailable,
            status: .unsupportedVersion(actual)
        )
    case .couldNotReadCheckpoint,
         .couldNotReadRecoveryMetadata,
         .backupExclusionVerificationFailed,
         .fileProtectionVerificationFailed:
        return RecoveryItemSummary(
            documentID: documentID,
            title: "Recovered Document",
            lastEdited: .unavailable,
            status: .unavailable
        )
    case .couldNotDecodeCheckpoint,
         .checkpointExceedsMaximumSize,
         .checkpointContentExceedsMaximumSize,
         .checkpointMetadataExceedsMaximumSize,
         .checkpointIsNotRegularFile,
         .recoveryItemHasUnexpectedType,
         .checkpointContentMismatch,
         .checkpointDocumentMismatch:
        return RecoveryItemSummary(
            documentID: documentID,
            title: "Recovered Document",
            lastEdited: .unavailable,
            status: .corrupt
        )
    default:
        return nil
    }
}

private func recoverySummaryComesBefore(
    _ left: RecoveryItemSummary,
    _ right: RecoveryItemSummary
) -> Bool {
    switch (left.lastEdited, right.lastEdited) {
    case let (.available(leftDate), .available(rightDate)):
        if leftDate != rightDate {
            return leftDate > rightDate
        }
    case (.available, .unavailable):
        return true
    case (.unavailable, .available):
        return false
    case (.unavailable, .unavailable):
        break
    }
    return left.documentID.rawValue.uuidString
        < right.documentID.rawValue.uuidString
}

private func removeTerminalArtifact(
    fileManager: FileManager,
    url: URL
) throws {
    try fileManager.removeItem(at: url)
}
