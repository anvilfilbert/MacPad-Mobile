import Foundation
import PhonePadCore

public struct PresentedTextFileSnapshot: Equatable, Sendable {
    public let openedFile: OpenedTextFile
    public let providerConflictVersions: FileProviderConflictVersions

    public init(
        openedFile: OpenedTextFile,
        providerConflictVersions: FileProviderConflictVersions
    ) {
        self.openedFile = openedFile
        self.providerConflictVersions = providerConflictVersions
    }
}

public struct PresentedFileRegistration: Equatable, Sendable {
    public let documentID: DocumentID
    public let binding: FileBinding

    public init(documentID: DocumentID, binding: FileBinding) {
        self.documentID = documentID
        self.binding = binding
    }
}

public enum PresentedFileResumeOutcome: Equatable, Sendable {
    case observed(ObservedBoundFile)
    case failed(FileAccessConnectorError)
}

final class PresentedFile: NSObject, NSFilePresenter, @unchecked Sendable {
    let documentID: DocumentID
    let generation: UUID
    let presentedItemOperationQueue: OperationQueue

    private let lock = NSLock()
    private var itemURL: URL
    private var isActive = true
    private let changeHandler: @Sendable (DocumentID, UUID) -> Void

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return itemURL
    }

    func currentPresentedItemURL() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return itemURL
    }

    init(
        documentID: DocumentID,
        itemURL: URL,
        changeHandler: @escaping @Sendable (DocumentID, UUID) -> Void
    ) {
        self.documentID = documentID
        self.generation = UUID()
        self.itemURL = itemURL
        self.changeHandler = changeHandler
        let operationQueue = OperationQueue()
        operationQueue.name = "PhonePad.FilePresenter.\(documentID.rawValue.uuidString)"
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInitiated
        self.presentedItemOperationQueue = operationQueue
        super.init()
    }

    func updatePresentedItemURL(_ url: URL) {
        lock.lock()
        if isActive {
            itemURL = url
        }
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func performSynchronousAccess<Value: Sendable>(
        _ access: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        if OperationQueue.current === presentedItemOperationQueue {
            return try access()
        }
        let resultBox = PresentedFileAccessResultBox<Value>()
        let completion = DispatchSemaphore(value: 0)
        presentedItemOperationQueue.addOperation {
            resultBox.result = Result(catching: access)
            completion.signal()
        }
        completion.wait()
        guard let result = resultBox.result else {
            throw FileAccessConnectorError.fileCoordinationAccessorNotInvoked
        }
        return try result.get()
    }

    func presentedItemDidChange() {
        emitChangeHint()
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        itemURL = newURL
        lock.unlock()
        changeHandler(documentID, generation)
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        emitChangeHint()
    }

    func presentedItemDidLose(_ version: NSFileVersion) {
        emitChangeHint()
    }

    func presentedItemDidResolveConflict(_ version: NSFileVersion) {
        emitChangeHint()
    }

    private func emitChangeHint() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        lock.unlock()
        changeHandler(documentID, generation)
    }
}

private final class PresentedFileAccessResultBox<Value: Sendable>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

final class PresentationHintRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<DocumentID>.Continuation
    private var activeGenerations: [DocumentID: UUID] = [:]
    private var pendingDocumentIDs: Set<DocumentID> = []

    init(continuation: AsyncStream<DocumentID>.Continuation) {
        self.continuation = continuation
    }

    func activate(documentID: DocumentID, generation: UUID) {
        lock.lock()
        activeGenerations[documentID] = generation
        pendingDocumentIDs.remove(documentID)
        lock.unlock()
    }

    func deactivate(documentID: DocumentID, generation: UUID) {
        lock.lock()
        if activeGenerations[documentID] == generation {
            activeGenerations.removeValue(forKey: documentID)
            pendingDocumentIDs.remove(documentID)
        }
        lock.unlock()
    }

    func offer(documentID: DocumentID, generation: UUID) {
        lock.lock()
        guard activeGenerations[documentID] == generation,
              pendingDocumentIDs.insert(documentID).inserted else {
            lock.unlock()
            return
        }
        let result = continuation.yield(documentID)
        switch result {
        case .enqueued:
            break
        case let .dropped(droppedDocumentID):
            pendingDocumentIDs.remove(droppedDocumentID)
        case .terminated:
            pendingDocumentIDs.remove(documentID)
        @unknown default:
            pendingDocumentIDs.remove(documentID)
        }
        lock.unlock()
    }

    func acknowledge(documentID: DocumentID) {
        lock.lock()
        pendingDocumentIDs.remove(documentID)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        activeGenerations.removeAll(keepingCapacity: false)
        pendingDocumentIDs.removeAll(keepingCapacity: false)
        continuation.finish()
        lock.unlock()
    }

    func pendingHintCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingDocumentIDs.count
    }
}
