import Combine
import PhonePadCore
import UIKit

struct PhonePadExternalOpenRequest: Equatable, Sendable {
    let url: URL
    let accessIntent: FileOpenAccessIntent
}

struct PhonePadExternalOpenBatch: Equatable, Sendable {
    let requests: [PhonePadExternalOpenRequest]
}

struct PhonePadExternalOpenProcessingTrigger: Equatable {
    let commitRequestID: UUID?
    let initialRecoveryRefreshFinished: Bool
    let saveAsIsPresented: Bool
    let folderPickerIsPresented: Bool
    let filePickerIsPresented: Bool

    var readyCommitRequestID: UUID? {
        guard initialRecoveryRefreshFinished,
              !saveAsIsPresented,
              !folderPickerIsPresented,
              !filePickerIsPresented else {
            return nil
        }
        return commitRequestID
    }
}

func makePhonePadExternalOpenBatch(
    requests: [PhonePadExternalOpenRequest]
) -> PhonePadExternalOpenBatch {
    PhonePadExternalOpenBatch(
        requests: requests.sorted(by: externalOpenRequestComesBefore)
    )
}

@MainActor
func intakePhonePadExternalOpenBatches(
    from sceneDelegate: PhonePadExternalOpenSceneDelegate,
    into model: PhonePadAppModel
) async {
    guard !sceneDelegate.pendingExternalOpenBatches.isEmpty else {
        return
    }
    let batches = sceneDelegate.takePendingExternalOpenBatches()
    await model.enqueueExternalOpenRequests(
        batches.flatMap(\.requests)
    )
}

@MainActor
final class PhonePadExternalOpenSceneDelegate: UIResponder,
    UIWindowSceneDelegate,
    ObservableObject {
    @Published private(set) var pendingExternalOpenBatches: [PhonePadExternalOpenBatch]

    override init() {
        pendingExternalOpenBatches = []
        super.init()
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        bufferExternalOpenURLContexts(connectionOptions.urlContexts)
    }

    func scene(
        _ scene: UIScene,
        openURLContexts urlContexts: Set<UIOpenURLContext>
    ) {
        bufferExternalOpenURLContexts(urlContexts)
    }

    func bufferExternalOpenRequests(
        _ requests: [PhonePadExternalOpenRequest]
    ) {
        guard !requests.isEmpty else {
            return
        }
        pendingExternalOpenBatches.append(
            makePhonePadExternalOpenBatch(requests: requests)
        )
    }

    func takePendingExternalOpenBatches() -> [PhonePadExternalOpenBatch] {
        let batches = pendingExternalOpenBatches
        pendingExternalOpenBatches = []
        return batches
    }

    private func bufferExternalOpenURLContexts(
        _ urlContexts: Set<UIOpenURLContext>
    ) {
        let requests = urlContexts.map { context in
            let accessIntent: FileOpenAccessIntent
            if context.options.openInPlace {
                accessIntent = .inPlace
            } else {
                accessIntent = .copyRequired
            }
            return PhonePadExternalOpenRequest(
                url: context.url,
                accessIntent: accessIntent
            )
        }
        bufferExternalOpenRequests(requests)
    }
}

@MainActor
final class PhonePadApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        makePhonePadSceneConfiguration(
            sessionRole: connectingSceneSession.role
        )
    }
}

@MainActor
func makePhonePadSceneConfiguration(
    sessionRole: UISceneSession.Role
) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
        name: nil,
        sessionRole: sessionRole
    )
    if sessionRole == .windowApplication {
        configuration.delegateClass = PhonePadExternalOpenSceneDelegate.self
    }
    return configuration
}

private func externalOpenRequestComesBefore(
    _ lhs: PhonePadExternalOpenRequest,
    _ rhs: PhonePadExternalOpenRequest
) -> Bool {
    let lhsURL = lhs.url.absoluteString
    let rhsURL = rhs.url.absoluteString
    guard lhsURL == rhsURL else {
        return lhsURL < rhsURL
    }
    return fileOpenAccessIntentOrder(lhs.accessIntent)
        < fileOpenAccessIntentOrder(rhs.accessIntent)
}

private func fileOpenAccessIntentOrder(
    _ accessIntent: FileOpenAccessIntent
) -> Int {
    switch accessIntent {
    case .inPlace:
        return 0
    case .copyRequired:
        return 1
    }
}
