# Publishing DocC and Swift Package Index Releases

The public package is hosted at <https://github.com/avias8/spacetimedb-swift>. Its root manifest can be consumed directly by Swift Package Manager and is listed at <https://swiftpackageindex.com/avias8/spacetimedb-swift>.

## Prepare A Release

- Keep `Package.swift`, `Sources`, `Tests`, `.spi.yml`, and `LICENSE.txt` at repository root.
- Keep third-party benchmark dependencies isolated under `Benchmarks`.
- Update the README dependency version and `CHANGELOG.md` together.
- Run the macOS test/release build and all declared Apple simulator builds.

## Build Documentation

```bash
xcodebuild docbuild \
  -scheme SpacetimeDB \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Swift Package Index reads `.spi.yml` and builds documentation for `SpacetimeDB` from the semantic-version tag.

## Tag And Verify

- Create an annotated `vX.Y.Z` tag on the validated release commit.
- Push the branch and tag without rewriting existing tags.
- Confirm the package page, generated documentation, platform badge, and Swift-version badge update.

See `DISTRIBUTION.md` and `SPI_SUBMISSION_CHECKLIST.md` at repository root for complete commands.
