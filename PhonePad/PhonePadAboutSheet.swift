import Foundation
import SwiftUI

struct PhonePadAboutInformation: Equatable, Sendable {
    let applicationName: String
    let version: String
    let build: String
    let creatorName: String
    let creatorURL: URL
    let repositoryName: String
    let repositoryURL: URL
}

func makePhonePadAboutInformation(
    bundle: Bundle
) -> PhonePadAboutInformation {
    PhonePadAboutInformation(
        applicationName: requiredPhonePadBundleString(
            bundle: bundle,
            key: "CFBundleDisplayName"
        ),
        version: requiredPhonePadBundleString(
            bundle: bundle,
            key: "CFBundleShortVersionString"
        ),
        build: requiredPhonePadBundleString(
            bundle: bundle,
            key: "CFBundleVersion"
        ),
        creatorName: "anvilfilbert",
        creatorURL: requiredPhonePadAboutURL(
            "https://github.com/anvilfilbert"
        ),
        repositoryName: "anvilfilbert/MacPad-Mobile",
        repositoryURL: requiredPhonePadAboutURL(
            "https://github.com/anvilfilbert/MacPad-Mobile"
        )
    )
}

struct PhonePadAboutSheet: View {
    let information: PhonePadAboutInformation
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image("MacPadMobileLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 25,
                                style: .continuous
                            )
                        )
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text(information.applicationName)
                            .font(.title.bold())
                            .accessibilityIdentifier(
                                "phonepad.about.app-name"
                            )

                        Text(
                            "Version \(information.version) " +
                                "(\(information.build))"
                        )
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("phonepad.about.version")
                    }

                    Divider()

                    VStack(spacing: 14) {
                        Link(
                            "Created by \(information.creatorName)",
                            destination: information.creatorURL
                        )
                        .accessibilityIdentifier("phonepad.about.creator")

                        Link(
                            "Public repo: \(information.repositoryName)",
                            destination: information.repositoryURL
                        )
                        .accessibilityIdentifier("phonepad.about.repository")
                    }
                    .font(.body)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                        .accessibilityIdentifier("phonepad.about.done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phonepad.about.sheet")
    }
}

private func requiredPhonePadBundleString(
    bundle: Bundle,
    key: String
) -> String {
    guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
          !value.isEmpty else {
        preconditionFailure(
            "About MacPad Mobile requires a non-empty \(key) bundle value."
        )
    }
    return value
}

private func requiredPhonePadAboutURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
        preconditionFailure(
            "About MacPad Mobile has an invalid link: \(value)"
        )
    }
    return url
}
