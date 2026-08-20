# Security Policy

## Supported versions

Security fixes are released for the latest release.
Older versions are not maintained.

## Reporting a vulnerability

Please do **not** report vulnerabilities through a public issue.

Instead, use GitHub's private reporting feature:
[Report Security Advisory](https://github.com/trsdn/teleprompter-mirror-macos/security/advisories/new).

Helpful information for the analysis includes:

- affected app version and macOS version,
- a description of the impact,
- the briefest possible reproduction.

You will usually receive a response within seven days.

## Security-relevant context

The following architecture is relevant for evaluating reports:

- The app requires **Screen Recording** permission. Captured images are processed
  exclusively locally and displayed on a display. There is no network
  communication, no telemetry, and no storage of image content on disk.
- In **Virtual display** mode, the app starts a second instance of the same
  signed binary as a headless display host. Only its own bundle path is started;
  no external programs are executed.
- Access to the private CoreGraphics classes happens dynamically through
  `NSClassFromString`, without linking private symbols.
- Settings remain unchanged in the app's `UserDefaults`. No credentials or
  personal data are stored.
- The bundles are signed with "Developer ID" and enabled Hardened Runtime.
