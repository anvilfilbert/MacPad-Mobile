import SwiftUI

@main
struct PhonePadApp: App {
    @StateObject private var model: PhonePadAppModel

    init() {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        _model = StateObject(
            wrappedValue: PhonePadAppModel(
                recoveryRootURL: phonePadRecoveryRootURL(
                    applicationSupportURL: applicationSupportURL,
                    environment: ProcessInfo.processInfo.environment
                )
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            PhonePadRootView(model: model)
        }
    }
}

private func phonePadRecoveryRootURL(
    applicationSupportURL: URL,
    environment: [String: String]
) -> URL {
    #if DEBUG
    if let namespace = environment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"],
       let identifier = UUID(uuidString: namespace) {
        return applicationSupportURL
            .appendingPathComponent("UITestRecovery", isDirectory: true)
            .appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: true)
    }
    #endif

    return applicationSupportURL
        .appendingPathComponent("Recovery", isDirectory: true)
}
