import Darwin
import Foundation
import PhonePadCore

public enum ImportedCopyCleanupJournalError: Error, Equatable, Sendable {
    case couldNotCreateDirectory(code: Int)
    case couldNotApplyProtection(code: Int)
    case couldNotApplyBackupExclusion(code: Int)
    case couldNotReadMetadata(code: Int)
    case unexpectedItemType
    case backupExclusionVerificationFailed
    case fileProtectionVerificationFailed
    case couldNotReadJournal(code: Int)
    case journalExceedsMaximumSize(actualByteCount: UInt64, maximumByteCount: UInt64)
    case couldNotDecodeJournal
    case unsupportedVersion(expected: UInt, actual: UInt)
    case couldNotEncodeJournal
    case couldNotWriteJournal(code: Int)
    case journalContentMismatch
    case couldNotRemoveJournal(code: Int)
    case invalidEntry
}

extension ImportedCopyCleanupJournalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .couldNotCreateDirectory(code):
            return "Imported File cleanup storage could not be created (system code \(code)). The supplied File was not accepted."
        case let .couldNotApplyProtection(code):
            return "Complete protection could not be applied to imported File cleanup data (system code \(code))."
        case let .couldNotApplyBackupExclusion(code):
            return "Imported File cleanup data could not be excluded from backup (system code \(code))."
        case let .couldNotReadMetadata(code):
            return "Imported File cleanup metadata could not be verified (system code \(code)). No supplied File was removed."
        case .unexpectedItemType:
            return "Imported File cleanup storage has an unexpected item type. No supplied File was removed."
        case .backupExclusionVerificationFailed:
            return "Imported File cleanup backup exclusion could not be verified. No supplied File was removed."
        case .fileProtectionVerificationFailed:
            return "Complete protection for imported File cleanup data could not be verified. No supplied File was removed."
        case let .couldNotReadJournal(code):
            return "Imported File cleanup data could not be read (system code \(code)). No supplied File was removed."
        case let .journalExceedsMaximumSize(actualByteCount, maximumByteCount):
            return "Imported File cleanup data contains \(actualByteCount) bytes; maximum is \(maximumByteCount). No supplied File was removed."
        case .couldNotDecodeJournal:
            return "Imported File cleanup data is corrupt or unsupported. No supplied File was removed."
        case let .unsupportedVersion(expected, actual):
            return "Imported File cleanup data uses version \(actual), expected \(expected). No supplied File was removed."
        case .couldNotEncodeJournal:
            return "Imported File cleanup data could not be encoded. The supplied File was not accepted."
        case let .couldNotWriteJournal(code):
            return "Imported File cleanup data could not be written (system code \(code)). The supplied File was not accepted."
        case .journalContentMismatch:
            return "Imported File cleanup data did not pass verification. No supplied File was removed."
        case let .couldNotRemoveJournal(code):
            return "Completed imported File cleanup data could not be removed (system code \(code)). Retry cleanup."
        case .invalidEntry:
            return "Imported File cleanup data contains an invalid entry. No supplied File was removed."
        }
    }
}

public struct ImportedCopyCleanupJournalItem: Equatable, Sendable {
    public let token: ImportedCopyCleanupToken
    public let documentID: DocumentID

    public init(token: ImportedCopyCleanupToken, documentID: DocumentID) {
        self.token = token
        self.documentID = documentID
    }
}

public struct ImportedCopyCleanupResidual: Equatable, Sendable {
    public let item: ImportedCopyCleanupJournalItem
    public let failure: ImportedCopyCleanupFailure

    public init(
        item: ImportedCopyCleanupJournalItem,
        failure: ImportedCopyCleanupFailure
    ) {
        self.item = item
        self.failure = failure
    }
}

public struct ImportedCopyCleanupReconciliationReport: Equatable, Sendable {
    public let removed: [ImportedCopyCleanupJournalItem]
    public let alreadyAbsent: [ImportedCopyCleanupJournalItem]
    public let awaitingProtection: [ImportedCopyCleanupJournalItem]
    public let residuals: [ImportedCopyCleanupResidual]

    public init(
        removed: [ImportedCopyCleanupJournalItem],
        alreadyAbsent: [ImportedCopyCleanupJournalItem],
        awaitingProtection: [ImportedCopyCleanupJournalItem],
        residuals: [ImportedCopyCleanupResidual]
    ) {
        self.removed = removed
        self.alreadyAbsent = alreadyAbsent
        self.awaitingProtection = awaitingProtection
        self.residuals = residuals
    }
}

enum ImportedCopyCleanupJournalItemKind: Equatable, Sendable {
    case directory
    case journalFile
}

typealias ImportedCopyCleanupMetadataVerifier = @Sendable (
    URL,
    ImportedCopyCleanupJournalItemKind,
    FileManager
) throws -> Void

enum ImportedCopyCleanupAuthorizationPhase: String, Codable, Sendable {
    case awaitingProtection
    case cleanupAuthorized
}

struct ImportedCopyCleanupFingerprint: Codable, Equatable, Sendable {
    let deviceID: Int64
    let inode: UInt64
    let generation: UInt32
    let byteCount: Int64
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64
    let statusChangeTimeSeconds: Int64
    let statusChangeTimeNanoseconds: Int64
}

struct ImportedCopyCleanupRecord: Sendable {
    let documentID: DocumentID
    let childName: ValidatedFileName
    let url: URL
    let inboxURL: URL
    let fingerprint: ImportedCopyCleanupFingerprint
    let phase: ImportedCopyCleanupAuthorizationPhase
}

private struct ImportedCopyCleanupJournalEnvelope: Codable, Equatable, Sendable {
    let formatVersion: UInt
    let entries: [ImportedCopyCleanupJournalEntry]
}

private struct ImportedCopyCleanupJournalEntry: Codable, Equatable, Sendable {
    let token: UUID
    let documentID: DocumentID
    let childName: ValidatedFileName
    let fingerprint: ImportedCopyCleanupFingerprint
    let phase: ImportedCopyCleanupAuthorizationPhase

    private enum CodingKeys: String, CodingKey {
        case token
        case documentID
        case childName
        case deviceID
        case inode
        case generation
        case byteCount
        case modificationTimeSeconds
        case modificationTimeNanoseconds
        case statusChangeTimeSeconds
        case statusChangeTimeNanoseconds
        case phase
    }

    init(
        token: UUID,
        documentID: DocumentID,
        childName: ValidatedFileName,
        fingerprint: ImportedCopyCleanupFingerprint,
        phase: ImportedCopyCleanupAuthorizationPhase
    ) {
        self.token = token
        self.documentID = documentID
        self.childName = childName
        self.fingerprint = fingerprint
        self.phase = phase
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(UUID.self, forKey: .token)
        documentID = try values.decode(DocumentID.self, forKey: .documentID)
        childName = try values.decode(
            ValidatedFileName.self,
            forKey: .childName
        )
        fingerprint = ImportedCopyCleanupFingerprint(
            deviceID: try values.decode(Int64.self, forKey: .deviceID),
            inode: try values.decode(UInt64.self, forKey: .inode),
            generation: try values.decode(UInt32.self, forKey: .generation),
            byteCount: try values.decode(Int64.self, forKey: .byteCount),
            modificationTimeSeconds: try values.decode(
                Int64.self,
                forKey: .modificationTimeSeconds
            ),
            modificationTimeNanoseconds: try values.decode(
                Int64.self,
                forKey: .modificationTimeNanoseconds
            ),
            statusChangeTimeSeconds: try values.decode(
                Int64.self,
                forKey: .statusChangeTimeSeconds
            ),
            statusChangeTimeNanoseconds: try values.decode(
                Int64.self,
                forKey: .statusChangeTimeNanoseconds
            )
        )
        phase = try values.decode(
            ImportedCopyCleanupAuthorizationPhase.self,
            forKey: .phase
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(token, forKey: .token)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(childName, forKey: .childName)
        try values.encode(fingerprint.deviceID, forKey: .deviceID)
        try values.encode(fingerprint.inode, forKey: .inode)
        try values.encode(fingerprint.generation, forKey: .generation)
        try values.encode(fingerprint.byteCount, forKey: .byteCount)
        try values.encode(
            fingerprint.modificationTimeSeconds,
            forKey: .modificationTimeSeconds
        )
        try values.encode(
            fingerprint.modificationTimeNanoseconds,
            forKey: .modificationTimeNanoseconds
        )
        try values.encode(
            fingerprint.statusChangeTimeSeconds,
            forKey: .statusChangeTimeSeconds
        )
        try values.encode(
            fingerprint.statusChangeTimeNanoseconds,
            forKey: .statusChangeTimeNanoseconds
        )
        try values.encode(phase, forKey: .phase)
    }
}

private let importedCopyCleanupJournalFormatVersion: UInt = 1
private let maximumImportedCopyCleanupJournalByteCount: UInt64 = 1_048_576
private let importedCopyCleanupJournalFileName = "imported-copy-cleanup.json"

func defaultImportedCopyCleanupJournalRootURL() -> URL {
    URL.applicationSupportDirectory
        .appendingPathComponent("PhonePad", isDirectory: true)
        .appendingPathComponent("ImportedCopyCleanup", isDirectory: true)
}

func injectedImportedCopyCleanupJournalRootURL(
    applicationInboxURL: URL?,
    fileManager: FileManager
) -> URL {
    guard let applicationInboxURL else {
        return fileManager.temporaryDirectory.appendingPathComponent(
            ".PhonePad-ImportedCopyCleanup-\(UUID().uuidString)",
            isDirectory: true
        )
    }
    return applicationInboxURL
        .deletingLastPathComponent()
        .appendingPathComponent(
            ".PhonePad-ImportedCopyCleanup",
            isDirectory: true
        )
}

func importedCopyCleanupJournalURL(rootURL: URL) -> URL {
    rootURL.appendingPathComponent(
        importedCopyCleanupJournalFileName,
        isDirectory: false
    )
}

func applyImportedCopyCleanupJournalMetadata(
    url: URL,
    fileManager: FileManager
) throws {
    do {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotApplyProtection(
            code: (error as NSError).code
        )
    }
    do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var metadataURL = url
        try metadataURL.setResourceValues(values)
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotApplyBackupExclusion(
            code: (error as NSError).code
        )
    }
}

func verifyImportedCopyCleanupJournalMetadata(
    url: URL,
    itemKind: ImportedCopyCleanupJournalItemKind,
    fileManager: FileManager
) throws {
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
        throw ImportedCopyCleanupJournalError.couldNotReadMetadata(
            code: (error as NSError).code
        )
    }
    let hasExpectedType: Bool
    switch itemKind {
    case .directory:
        hasExpectedType = values.isDirectory == true
    case .journalFile:
        hasExpectedType = values.isRegularFile == true
    }
    guard hasExpectedType else {
        throw ImportedCopyCleanupJournalError.unexpectedItemType
    }
    guard values.isExcludedFromBackup == true else {
        throw ImportedCopyCleanupJournalError
            .backupExclusionVerificationFailed
    }
    #if !targetEnvironment(simulator)
    guard values.fileProtection == .complete else {
        throw ImportedCopyCleanupJournalError
            .fileProtectionVerificationFailed
    }
    #endif
}

func readImportedCopyCleanupRecords(
    rootURL: URL,
    inboxURL: URL?,
    fileManager: FileManager,
    metadataVerifier: ImportedCopyCleanupMetadataVerifier
) throws -> [ImportedCopyCleanupToken: ImportedCopyCleanupRecord] {
    try prepareImportedCopyCleanupJournalDirectory(
        rootURL: rootURL,
        fileManager: fileManager,
        metadataVerifier: metadataVerifier
    )
    let journalURL = importedCopyCleanupJournalURL(rootURL: rootURL)
    var status = stat()
    let statusResult = lstat(
        fileManager.fileSystemRepresentation(withPath: journalURL.path),
        &status
    )
    guard statusResult == 0 else {
        if errno == ENOENT {
            return [:]
        }
        throw ImportedCopyCleanupJournalError.couldNotReadMetadata(
            code: Int(errno)
        )
    }
    guard journalItemKind(mode: status.st_mode) == .regularFile else {
        throw ImportedCopyCleanupJournalError.unexpectedItemType
    }
    try metadataVerifier(journalURL, .journalFile, fileManager)
    let byteCount = UInt64(status.st_size)
    guard byteCount <= maximumImportedCopyCleanupJournalByteCount else {
        throw ImportedCopyCleanupJournalError.journalExceedsMaximumSize(
            actualByteCount: byteCount,
            maximumByteCount: maximumImportedCopyCleanupJournalByteCount
        )
    }
    let data: Data
    do {
        data = try Data(contentsOf: journalURL)
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotReadJournal(
            code: (error as NSError).code
        )
    }
    let envelope: ImportedCopyCleanupJournalEnvelope
    do {
        envelope = try JSONDecoder().decode(
            ImportedCopyCleanupJournalEnvelope.self,
            from: data
        )
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotDecodeJournal
    }
    guard envelope.formatVersion == importedCopyCleanupJournalFormatVersion else {
        throw ImportedCopyCleanupJournalError.unsupportedVersion(
            expected: importedCopyCleanupJournalFormatVersion,
            actual: envelope.formatVersion
        )
    }
    guard let inboxURL else {
        if envelope.entries.isEmpty {
            return [:]
        }
        throw ImportedCopyCleanupJournalError.invalidEntry
    }
    return try importedCopyCleanupRecords(
        entries: envelope.entries,
        inboxURL: inboxURL
    )
}

func persistImportedCopyCleanupRecords(
    _ records: [ImportedCopyCleanupToken: ImportedCopyCleanupRecord],
    rootURL: URL,
    fileManager: FileManager,
    metadataVerifier: ImportedCopyCleanupMetadataVerifier
) throws {
    try prepareImportedCopyCleanupJournalDirectory(
        rootURL: rootURL,
        fileManager: fileManager,
        metadataVerifier: metadataVerifier
    )
    let journalURL = importedCopyCleanupJournalURL(rootURL: rootURL)
    guard !records.isEmpty else {
        try removeImportedCopyCleanupJournalIfPresent(
            journalURL: journalURL,
            fileManager: fileManager,
            metadataVerifier: metadataVerifier
        )
        return
    }
    let entries = try sortedImportedCopyCleanupTokens(records.keys).map {
        token -> ImportedCopyCleanupJournalEntry in
        guard let record = records[token] else {
            throw ImportedCopyCleanupJournalError.invalidEntry
        }
        return ImportedCopyCleanupJournalEntry(
            token: token.rawValue,
            documentID: record.documentID,
            childName: record.childName,
            fingerprint: record.fingerprint,
            phase: record.phase
        )
    }
    let envelope = ImportedCopyCleanupJournalEnvelope(
        formatVersion: importedCopyCleanupJournalFormatVersion,
        entries: entries
    )
    let data: Data
    do {
        data = try JSONEncoder().encode(envelope)
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotEncodeJournal
    }
    guard UInt64(data.count) <= maximumImportedCopyCleanupJournalByteCount else {
        throw ImportedCopyCleanupJournalError.journalExceedsMaximumSize(
            actualByteCount: UInt64(data.count),
            maximumByteCount: maximumImportedCopyCleanupJournalByteCount
        )
    }
    do {
        try data.write(
            to: journalURL,
            options: [.atomic, .completeFileProtection]
        )
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotWriteJournal(
            code: (error as NSError).code
        )
    }
    try applyImportedCopyCleanupJournalMetadata(
        url: journalURL,
        fileManager: fileManager
    )
    try metadataVerifier(journalURL, .journalFile, fileManager)
    let verifiedData: Data
    do {
        verifiedData = try Data(contentsOf: journalURL)
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotReadJournal(
            code: (error as NSError).code
        )
    }
    guard verifiedData == data else {
        throw ImportedCopyCleanupJournalError.journalContentMismatch
    }
}

func sortedImportedCopyCleanupTokens<S: Sequence>(
    _ tokens: S
) -> [ImportedCopyCleanupToken]
where S.Element == ImportedCopyCleanupToken {
    tokens.sorted {
        $0.rawValue.uuidString < $1.rawValue.uuidString
    }
}

private enum ImportedCopyCleanupJournalNodeKind: Equatable {
    case regularFile
    case other
}

private func journalItemKind(mode: mode_t) -> ImportedCopyCleanupJournalNodeKind {
    mode & S_IFMT == S_IFREG ? .regularFile : .other
}

private func prepareImportedCopyCleanupJournalDirectory(
    rootURL: URL,
    fileManager: FileManager,
    metadataVerifier: ImportedCopyCleanupMetadataVerifier
) throws {
    do {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    } catch {
        throw ImportedCopyCleanupJournalError.couldNotCreateDirectory(
            code: (error as NSError).code
        )
    }
    try applyImportedCopyCleanupJournalMetadata(
        url: rootURL,
        fileManager: fileManager
    )
    try metadataVerifier(rootURL, .directory, fileManager)
}

private func importedCopyCleanupRecords(
    entries: [ImportedCopyCleanupJournalEntry],
    inboxURL: URL
) throws -> [ImportedCopyCleanupToken: ImportedCopyCleanupRecord] {
    let canonicalInboxURL = inboxURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
    var records: [ImportedCopyCleanupToken: ImportedCopyCleanupRecord] = [:]
    for entry in entries {
        let token = ImportedCopyCleanupToken(rawValue: entry.token)
        guard records[token] == nil,
              dev_t(exactly: entry.fingerprint.deviceID) != nil,
              ino_t(exactly: entry.fingerprint.inode) != nil else {
            throw ImportedCopyCleanupJournalError.invalidEntry
        }
        let url = canonicalInboxURL.appendingPathComponent(
            entry.childName.value,
            isDirectory: false
        )
        guard url.deletingLastPathComponent().standardizedFileURL
                == canonicalInboxURL,
              url.lastPathComponent == entry.childName.value else {
            throw ImportedCopyCleanupJournalError.invalidEntry
        }
        records[token] = ImportedCopyCleanupRecord(
            documentID: entry.documentID,
            childName: entry.childName,
            url: url,
            inboxURL: canonicalInboxURL,
            fingerprint: entry.fingerprint,
            phase: entry.phase
        )
    }
    return records
}

private func removeImportedCopyCleanupJournalIfPresent(
    journalURL: URL,
    fileManager: FileManager,
    metadataVerifier: ImportedCopyCleanupMetadataVerifier
) throws {
    var status = stat()
    let statusResult = lstat(
        fileManager.fileSystemRepresentation(withPath: journalURL.path),
        &status
    )
    guard statusResult == 0 else {
        if errno == ENOENT {
            return
        }
        throw ImportedCopyCleanupJournalError.couldNotReadMetadata(
            code: Int(errno)
        )
    }
    guard journalItemKind(mode: status.st_mode) == .regularFile else {
        throw ImportedCopyCleanupJournalError.unexpectedItemType
    }
    try metadataVerifier(journalURL, .journalFile, fileManager)
    let removalResult = unlink(
        fileManager.fileSystemRepresentation(withPath: journalURL.path)
    )
    guard removalResult == 0 || errno == ENOENT else {
        throw ImportedCopyCleanupJournalError.couldNotRemoveJournal(
            code: Int(errno)
        )
    }
}
