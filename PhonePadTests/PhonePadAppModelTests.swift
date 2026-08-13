import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadAppModelTests: XCTestCase {
    func testRapidEditsCheckpointLatestGenerationWithoutSerializingEveryEdit() async throws {
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

        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        let tabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(documentID: documentID, tabID: tabID),
            recoveryStore: store,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )

        for generation in 1 ... 160 {
            model.editActiveDocument(text: "Generation \(generation)")
        }

        try await Task.sleep(for: .milliseconds(250))

        let envelope = try await store.load(documentID: documentID)
        XCTAssertEqual(envelope?.text, "Generation 160")
        XCTAssertEqual(model.activeText, "Generation 160")
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .protectedUnsaved)
    }
}
