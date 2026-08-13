import SwiftUI

@main
struct ExternalOpenHostApp: App {
    var body: some Scene {
        WindowGroup {
            ExternalOpenHostRootView()
        }
    }
}

private struct ExternalOpenHostRootView: View {
    var body: some View {
        Text("External Open Host")
            .accessibilityIdentifier("externalOpenHost.root")
    }
}
