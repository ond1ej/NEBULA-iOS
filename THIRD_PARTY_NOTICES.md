# Third-party notices

The NEBULA apps for iPhone and Mac are licensed under the MIT License (see [LICENSE](LICENSE)).

## Dependencies

The apps have **no third-party dependencies**. `NEBULAKit/Package.swift` declares no package dependencies, and
`NEBULA.xcodeproj` references only the local package `NEBULAKit` (no remote Swift packages, no CocoaPods, no
Carthage, no vendored libraries).

The code uses Apple's system frameworks (SwiftUI, Foundation, CryptoKit, Security, LocalAuthentication, AVFoundation,
UserNotifications and others) from the iOS and macOS SDKs. `NEBULAKit` links the system zlib library (`libz`, zlib
license) from those SDKs for the Live Desktop's compressed streams; it is part of the operating system and is not
redistributed.

The app icons are rendered by `scripts/make_icons.py` from code, without external artwork.

## Development tools

These are used only while developing and are not part of the apps:

- Xcode and the Swift toolchain (Apple).
- Python 3 for the scripts in `scripts/`; `scripts/make_icons.py` also uses Pillow (MIT-CMU license).
- gitleaks (MIT) for secret scanning in CI.

## Services

The apps talk only to your own NEBULA server. Tailscale, Cloudflare and Apple Push Notification service are
third-party services that you may choose to use, under their own terms.

## Trademarks

Apple, iPhone, iPad, Mac, Mac mini, macOS, iOS, Face ID, Touch ID, Xcode and Swift are trademarks of Apple Inc.
Tailscale is a trademark of Tailscale Inc. Cloudflare is a trademark of Cloudflare, Inc. Other names are trademarks of
their respective owners. NEBULA is not affiliated with or endorsed by any of them.
