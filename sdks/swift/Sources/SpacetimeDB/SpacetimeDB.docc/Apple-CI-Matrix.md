# Apple CI Matrix

## Goals

- Run the complete unit suite and Thread Sanitizer on macOS.
- Verify every declared Apple platform can compile the `SpacetimeDB` product.
- Keep deployment targets synchronized with `Package.swift` and the use of Swift 6 `Synchronization` primitives.

## Supported Platforms

| Platform | Minimum | CI validation                                         |
| -------- | ------: | ----------------------------------------------------- |
| macOS    |      15 | Unit tests, Thread Sanitizer, release build, and DocC |
| iOS      |      18 | Generic simulator release build                       |
| visionOS |       2 | Generic simulator release build                       |
| watchOS  |      11 | Generic simulator release build                       |

## Local Validation

```bash
swift test
swift test --sanitize=thread
swift build -c release

xcodebuild -scheme SpacetimeDB \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -scheme SpacetimeDB \
  -destination 'generic/platform=visionOS Simulator' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild -scheme SpacetimeDB \
  -destination 'generic/platform=watchOS Simulator' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The same matrix runs in `.github/workflows/swift-sdk.yml` in the monorepo and `.github/workflows/ci.yml` in the standalone mirror, both on GitHub's `macos-26` image. Local cross-builds require the corresponding optional Xcode platform components to be installed.
