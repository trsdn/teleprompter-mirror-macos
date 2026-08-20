# Contributing

Thank you for your interest in Teleprompter Mirror. This project is
intentionally kept small — please read the [Project scope](#project-scope)
section before making larger changes.

## Requirements

- macOS 13 or newer (developed and tested on current versions)
- Xcode Command Line Tools with Swift 6.1 or newer
  (`swift-tools-version: 6.1`, see `Package.swift`)
- For signed builds: a "Developer ID Application" or "Apple Development"
  certificate in the keychain

There are no third-party dependencies. `swift build` is enough.

## Development workflow

```bash
swift build          # build
swift test           # run unit tests
./build-app.sh       # create signed .app bundle in dist/
```

The app icon is generated from code and is present in the repository as
`Resources/AppIcon.icns`. Regenerate it after changes to
`Scripts/make-icon.swift`:

```bash
swift Scripts/make-icon.swift
```

There is a self-test for a smoke test without a real target display:

```bash
open "dist/Teleprompter Mirror.app" --args --self-test
```

It reports `SELF_TEST_PASS` when capture setup and output work.

## Before the pull request

- `swift build` completes without warnings.
- `swift test` is green.
- The change was checked manually with at least one source.
- Behavior changes are described in `README.md`.

## Conventions

- **Language:** All user-facing text, code comments, and commit messages are in
  **English**. Symbol names are in **English**.
- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/),
  subject line in English, for example `fix: keep output above the menu bar`.
- **Formatting:** Four spaces for indentation, line length of 80 characters as
  a guideline.
- **Dependencies:** None. If a task can be solved without an external package,
  it is solved without one.
- **Private APIs:** Access to `CGVirtualDisplay` and related APIs happens
  exclusively through `NSClassFromString` in `Sources/VirtualDisplayBridge`.
  Private symbols are not linked.

## Project scope

The app does exactly one thing: capture a source, mirror or rotate the image,
and output it full-screen on a target display — with the lowest possible
resource usage.

Text editor, script management, scrolling text, remote control, and recording
are explicitly **not** part of the project. Specialized teleprompter
applications exist for such functions.

## Reporting bugs

Please use the [issue templates](https://github.com/trsdn/teleprompter-mirror-macos/issues/new/choose).
Please do **not** create an issue for security-relevant findings; report them as
described in [SECURITY.md](SECURITY.md).

## Working together

The [Code of Conduct](CODE_OF_CONDUCT.md) applies to all project areas.
