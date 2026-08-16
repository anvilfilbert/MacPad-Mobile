# Contributing

MacPad Mobile's internal Xcode project, targets, modules, and accessibility
identifiers retain the `PhonePad` name.

## Prerequisites

- macOS with Xcode 26.5
- An iOS 18 or newer simulator runtime
- Git

The project has no third-party package dependency. Do not add signing team IDs,
certificates, provisioning profiles, credentials, personal paths, or private
test content to the repository.

## Build

```sh
xcodebuild \
  -project PhonePad.xcodeproj \
  -scheme PhonePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build
```

## Test

Run unit and integration tests with an available simulator:

```sh
xcodebuild \
  -project PhonePad.xcodeproj \
  -scheme PhonePad \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  test \
  -only-testing:PhonePadTests
```

The full UI suite is intentionally manual in GitHub Actions. Start it from the
`iOS UI Tests` workflow or run:

```sh
xcodebuild \
  -project PhonePad.xcodeproj \
  -scheme PhonePad \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  test \
  -only-testing:PhonePadUITests
```

## Contribution expectations

- Read [AGENTS.md](AGENTS.md) and the domain language in [CONTEXT.md](CONTEXT.md).
- Keep customer-facing wording aligned with MacPad Mobile while leaving
  internal `PhonePad` identifiers stable.
- Preserve explicit Save, conflict protection, and deliberate recovery behavior.
- Add the minimum useful behavior coverage and run relevant build and test
  commands before opening a pull request.
- Use redacted, invented content in tests, screenshots, and issue reports.
- Keep pull requests focused and describe any customer-visible safety change.

## Licensing

No current repository license has been specified. Contribution and reuse terms
remain blocked on a product owner-approved license or rights statement.
