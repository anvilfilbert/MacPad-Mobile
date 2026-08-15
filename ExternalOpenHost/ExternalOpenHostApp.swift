import Darwin
import Foundation
import SwiftUI

@main
struct ExternalOpenHostApp: App {
    private let fixtureState: ExternalOpenHostFixtureState

    init() {
        fixtureState = makeExternalOpenHostFixtureState(
            fileManager: .default
        )
    }

    var body: some Scene {
        WindowGroup {
            ExternalOpenHostRootView(fixtureState: fixtureState)
        }
    }
}

private struct ExternalOpenHostRootView: View {
    let fixtureState: ExternalOpenHostFixtureState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("External Open Host")
                    .font(.headline)
                    .accessibilityIdentifier("externalopenhost.root")
                switch fixtureState {
                case let .ready(fixtures):
                    Text("Ready")
                        .accessibilityIdentifier("externalopenhost.ready")
                    ExternalOpenHostFixtureView(
                        title: "Durable text",
                        fixture: fixtures.durable,
                        urlIdentifier: "externalopenhost.fixture.durable.url",
                        contentIdentifier: "externalopenhost.fixture.durable.content"
                    )
                    ExternalOpenHostFixtureView(
                        title: "Read-only text",
                        fixture: fixtures.readOnly,
                        urlIdentifier: "externalopenhost.fixture.readonly.url",
                        contentIdentifier: "externalopenhost.fixture.readonly.content"
                    )
                    ExternalOpenHostFixtureView(
                        title: "Generic data",
                        fixture: fixtures.generic,
                        urlIdentifier: "externalopenhost.fixture.generic.url",
                        contentIdentifier: "externalopenhost.fixture.generic.content"
                    )
                case let .failed(error):
                    Text(verbatim: error.message)
                        .accessibilityIdentifier("externalopenhost.error")
                        .accessibilityValue(Text(verbatim: error.message))
                }
            }
            .padding()
        }
    }
}

private struct ExternalOpenHostFixtureView: View {
    let title: String
    let fixture: ExternalOpenHostFileFixture
    let urlIdentifier: String
    let contentIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.subheadline)
            Text(verbatim: fixture.url.absoluteString)
                .accessibilityIdentifier(urlIdentifier)
                .accessibilityValue(
                    Text(verbatim: fixture.url.absoluteString)
                )
            Text(verbatim: fixture.content)
                .accessibilityIdentifier(contentIdentifier)
                .accessibilityValue(Text(verbatim: fixture.content))
        }
    }
}

private enum ExternalOpenHostFixtureState {
    case ready(ExternalOpenHostFixtures)
    case failed(ExternalOpenHostFixtureError)
}

private struct ExternalOpenHostFixtures {
    let durable: ExternalOpenHostFileFixture
    let readOnly: ExternalOpenHostFileFixture
    let generic: ExternalOpenHostFileFixture
}

private struct ExternalOpenHostFileFixture {
    let url: URL
    let content: String
}

private enum ExternalOpenHostFixtureError: Error {
    case documentsDirectoryUnavailable
    case directoryCreationFailed(
        url: URL,
        underlying: ExternalOpenHostUnderlyingError
    )
    case fileWriteFailed(
        url: URL,
        underlying: ExternalOpenHostUnderlyingError
    )
    case fileReadFailed(
        url: URL,
        underlying: ExternalOpenHostUnderlyingError
    )
    case fileContentMismatch(url: URL)
    case readOnlyPermissionChangeFailed(url: URL, errorNumber: Int32)
    case readOnlyPermissionInspectionFailed(url: URL, errorNumber: Int32)
    case readOnlyPermissionsNotApplied(url: URL, mode: mode_t)

    var message: String {
        switch self {
        case .documentsDirectoryUnavailable:
            return "documents_directory_unavailable: Host Documents directory was not available."
        case let .directoryCreationFailed(url, underlying):
            return "directory_creation_failed: \(url.path); \(underlying.message)"
        case let .fileWriteFailed(url, underlying):
            return "file_write_failed: \(url.path); \(underlying.message)"
        case let .fileReadFailed(url, underlying):
            return "file_read_failed: \(url.path); \(underlying.message)"
        case let .fileContentMismatch(url):
            return "file_content_mismatch: Fixture bytes differed after writing \(url.path)."
        case let .readOnlyPermissionChangeFailed(url, errorNumber):
            return "readonly_chmod_failed: \(url.path); errno=\(errorNumber)."
        case let .readOnlyPermissionInspectionFailed(url, errorNumber):
            return "readonly_lstat_failed: \(url.path); errno=\(errorNumber)."
        case let .readOnlyPermissionsNotApplied(url, mode):
            return "readonly_mode_invalid: \(url.path); mode=\(mode)."
        }
    }
}

private struct ExternalOpenHostUnderlyingError {
    let domain: String
    let code: Int
    let description: String

    init(error: any Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        description = nsError.localizedDescription
    }

    var message: String {
        "domain=\(domain); code=\(code); description=\(description)"
    }
}

private func makeExternalOpenHostFixtureState(
    fileManager: FileManager
) -> ExternalOpenHostFixtureState {
    switch createExternalOpenHostFixtures(fileManager: fileManager) {
    case let .success(fixtures):
        return .ready(fixtures)
    case let .failure(error):
        return .failed(error)
    }
}

private func createExternalOpenHostFixtures(
    fileManager: FileManager
) -> Result<ExternalOpenHostFixtures, ExternalOpenHostFixtureError> {
    guard let documentsURL = fileManager.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first else {
        return .failure(.documentsDirectoryUnavailable)
    }
    let rootURL = documentsURL
        .appendingPathComponent("external-open-host", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    } catch {
        return .failure(
            .directoryCreationFailed(
                url: rootURL,
                underlying: ExternalOpenHostUnderlyingError(error: error)
            )
        )
    }

    let durable = ExternalOpenHostFileFixture(
        url: rootURL.appendingPathComponent("durable.txt", isDirectory: false),
        content: "Durable external open\n"
    )
    let readOnly = ExternalOpenHostFileFixture(
        url: rootURL.appendingPathComponent("read-only.txt", isDirectory: false),
        content: "Read-only external open\n"
    )
    let generic = ExternalOpenHostFileFixture(
        url: rootURL.appendingPathComponent("generic.dat", isDirectory: false),
        content: "Generic data external open\n"
    )

    for fixture in [durable, readOnly, generic] {
        switch writeExternalOpenHostFixture(fixture) {
        case .success:
            break
        case let .failure(error):
            return .failure(error)
        }
    }
    switch makeExternalOpenHostFixtureReadOnly(at: readOnly.url) {
    case .success:
        return .success(
            ExternalOpenHostFixtures(
                durable: durable,
                readOnly: readOnly,
                generic: generic
            )
        )
    case let .failure(error):
        return .failure(error)
    }
}

private func writeExternalOpenHostFixture(
    _ fixture: ExternalOpenHostFileFixture
) -> Result<Void, ExternalOpenHostFixtureError> {
    let expectedData = Data(fixture.content.utf8)
    do {
        try expectedData.write(
            to: fixture.url,
            options: .withoutOverwriting
        )
    } catch {
        return .failure(
            .fileWriteFailed(
                url: fixture.url,
                underlying: ExternalOpenHostUnderlyingError(error: error)
            )
        )
    }
    let storedData: Data
    do {
        storedData = try Data(contentsOf: fixture.url)
    } catch {
        return .failure(
            .fileReadFailed(
                url: fixture.url,
                underlying: ExternalOpenHostUnderlyingError(error: error)
            )
        )
    }
    guard storedData == expectedData else {
        return .failure(.fileContentMismatch(url: fixture.url))
    }
    return .success(())
}

private func makeExternalOpenHostFixtureReadOnly(
    at url: URL
) -> Result<Void, ExternalOpenHostFixtureError> {
    let readOnlyMode = mode_t(S_IRUSR | S_IRGRP | S_IROTH)
    let permissionStatus = url.path.withCString { fileSystemPath in
        chmod(fileSystemPath, readOnlyMode)
    }
    guard permissionStatus == 0 else {
        return .failure(
            .readOnlyPermissionChangeFailed(
                url: url,
                errorNumber: errno
            )
        )
    }

    var fileStatus = stat()
    let inspectionStatus = url.path.withCString { fileSystemPath in
        lstat(fileSystemPath, &fileStatus)
    }
    guard inspectionStatus == 0 else {
        return .failure(
            .readOnlyPermissionInspectionFailed(
                url: url,
                errorNumber: errno
            )
        )
    }
    let writeMode = mode_t(S_IWUSR | S_IWGRP | S_IWOTH)
    guard fileStatus.st_mode & writeMode == 0 else {
        return .failure(
            .readOnlyPermissionsNotApplied(
                url: url,
                mode: fileStatus.st_mode
            )
        )
    }
    return .success(())
}
