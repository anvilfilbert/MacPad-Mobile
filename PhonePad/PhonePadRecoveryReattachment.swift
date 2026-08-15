import Foundation
import PhonePadCore

enum RecoveryReattachmentCollision: Equatable, Sendable {
    case none
    case activeDocument(DocumentID)
    case recoveryItem(DocumentID)
    case ambiguous([DocumentID])
}

enum PhonePadRecoveryReattachmentError: Error, Equatable, Sendable {
    case selectedFileIsNotDurablyWritable(FileOpenDetachmentReason)
    case selectedFileBelongsToRecovery(DocumentID)
    case collisionIsAmbiguous([DocumentID])
}

enum RecoveredDocumentReattachmentResult: Equatable, Sendable {
    case reattached(PhonePadState)
    case activatedExisting(PhonePadState)
}

func reattachRecoveredDocument(
    state: PhonePadState,
    documentID: DocumentID,
    selectedURL: URL,
    editedAt: Date,
    recoveryStore: any RecoveryStoring,
    fileAccessConnector: FileAccessConnector
) async throws -> RecoveredDocumentReattachmentResult {
    var presenterWasRegistered = false
    do {
        let outcome = try await fileAccessConnector.openTextFile(
            at: selectedURL,
            documentID: documentID,
            accessIntent: .inPlace
        )
        let snapshot: PresentedTextFileSnapshot
        switch outcome {
        case let .bound(openedSnapshot):
            snapshot = openedSnapshot
            presenterWasRegistered = true
        case let .detached(openedFile):
            throw PhonePadRecoveryReattachmentError
                .selectedFileIsNotDurablyWritable(openedFile.reason)
        case let .rejected(rejection):
            throw rejection.error
        }

        let candidate = FileOpenCandidate(
            locatorURL: snapshot.openedFile.binding.locatorURL,
            identity: snapshot.openedFile.binding.identity,
            digest: snapshot.openedFile.binding.digest,
            providerConflictVersions: snapshot.providerConflictVersions
        )
        let activeClaims = activeTabFileCollisionClaims(state: state)
            .filter { claim in
                claim.documentID != documentID
            }
        let recoveryClaims = try await recoveryStore
            .recoveryFileCollisionClaims(
                excludingDocumentID: documentID
            )
        let matchingClaims = try await fileAccessConnector
            .matchingFileCollisionClaims(
                candidate: candidate,
                claims: activeClaims + recoveryClaims
            )
        switch classifyRecoveryReattachmentCollision(claims: matchingClaims) {
        case .none:
            break
        case let .activeDocument(existingDocumentID):
            await fileAccessConnector.stopPresenting(documentID: documentID)
            presenterWasRegistered = false
            guard let existingTab = state.tabs.first(where: { tab in
                tab.document.id == existingDocumentID
            }) else {
                throw PhonePadStateError.documentMissing(existingDocumentID)
            }
            return .activatedExisting(
                try PhonePadCore.selectTab(
                    state: state,
                    tabID: existingTab.id
                )
            )
        case let .recoveryItem(recoveryDocumentID):
            throw PhonePadRecoveryReattachmentError
                .selectedFileBelongsToRecovery(recoveryDocumentID)
        case let .ambiguous(documentIDs):
            throw PhonePadRecoveryReattachmentError
                .collisionIsAmbiguous(documentIDs)
        }

        let prepared = try prepareRecoveredDocumentReattachment(
            state: state,
            documentID: documentID,
            observation: ObservedBoundFile(
                binding: snapshot.openedFile.binding,
                providerConflictVersions: snapshot.providerConflictVersions
            ),
            editedAt: editedAt
        )
        _ = try commitPreparedRecoveredDocumentReattachment(
            state: state,
            prepared: prepared
        )
        try await protectRecoveryEnvelope(
            envelope: prepared.transition.envelope,
            recoveryStore: recoveryStore
        )
        let committed = try commitPreparedRecoveredDocumentReattachment(
            state: state,
            prepared: prepared
        )
        return .reattached(
            try markDocumentRecoveryProtected(
                state: committed.state,
                documentID: documentID,
                expectedText: committed.envelope.text
            )
        )
    } catch {
        if presenterWasRegistered {
            await fileAccessConnector.stopPresenting(documentID: documentID)
        }
        throw error
    }
}

extension PhonePadRecoveryReattachmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .selectedFileIsNotDurablyWritable(reason):
            return "Selected File cannot provide durable writable access (\(recoveryReattachmentDetachmentDescription(reason))). Recovered text remains protected; choose another original File or use Save As."
        case let .selectedFileBelongsToRecovery(documentID):
            return "Selected File belongs to preserved Document \(documentID.rawValue.uuidString). Recovered text remains detached; recover that item or use Save As."
        case let .collisionIsAmbiguous(documentIDs):
            let identifiers = documentIDs
                .map(\.rawValue.uuidString)
                .joined(separator: ", ")
            return "Selected File matches multiple Documents (\(identifiers)). Recovered text remains detached; resolve those items or use Save As."
        }
    }
}

func classifyRecoveryReattachmentCollision(
    claims: [FileCollisionClaim]
) -> RecoveryReattachmentCollision {
    let documentIDs = Set(claims.map(\.documentID)).sorted {
        $0.rawValue.uuidString < $1.rawValue.uuidString
    }
    guard let documentID = documentIDs.first else {
        return .none
    }
    guard documentIDs.count == 1 else {
        return .ambiguous(documentIDs)
    }
    if claims.contains(where: { claim in
        if case let .activeTab(claimedDocumentID, _) = claim {
            return claimedDocumentID == documentID
        }
        return false
    }) {
        return .activeDocument(documentID)
    }
    return .recoveryItem(documentID)
}

private func recoveryReattachmentDetachmentDescription(
    _ reason: FileOpenDetachmentReason
) -> String {
    switch reason {
    case .copyRequired:
        return "Files supplied a copy instead of the original"
    case .notWritable:
        return "the File is read-only"
    case .writabilityNotReported:
        return "the provider did not report write access"
    case let .writabilityInspectionFailed(code):
        return "write access verification failed with system code \(code)"
    case let .bookmarkCreationFailed(code):
        return "durable access creation failed with system code \(code)"
    case let .bookmarkResolutionFailed(code):
        return "durable access resolution failed with system code \(code)"
    case .bookmarkIsStale:
        return "the new durable access reference is stale"
    case let .bookmarkVerificationFailed(code):
        return "durable access verification failed with system code \(code)"
    case .bookmarkResolvedToDifferentFile:
        return "durable access resolved to a different File"
    }
}
