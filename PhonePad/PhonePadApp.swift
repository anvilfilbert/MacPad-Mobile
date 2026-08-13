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
                recoveryRootURL: applicationSupportURL
                    .appendingPathComponent("Recovery", isDirectory: true)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            PhonePadRootView(model: model)
        }
    }
}
