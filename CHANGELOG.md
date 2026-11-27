# Changelog

All notable changes to the NEBULA apps for iPhone and Mac are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - first public release

The first public, open-source release of the NEBULA apps for iPhone, iPad and Mac under the MIT License, as a
standalone repository. The apps are clients of a NEBULA 1.x server ([NEBULA_v1](https://github.com/ond1ej/NEBULA_v1)).
No binaries are published: you build and sign the apps yourself.

### Added

- iPhone/iPad app (iOS 18 or later) and Mac app (macOS 15 or later), built on the shared Swift package `NEBULAKit`.
- Pairing with a server through a single-use QR code or link from the Dashboard's Devices page, with server-key
  pinning, Secure Enclave device keys and a six-digit code approved on the Mac.
- Sign-in by signing server challenges with the device's identity key; Bearer sessions; immediate revocation.
- Chats with streamed replies, Markdown and syntax-highlighted code, photo, file and voice-note attachments.
- Agents: list, create, edit, delete, pause, resume, sleep and wake; task details with pause, resume, stop and retry.
- Activity: approvals, notifications and Smart sign-in requests; local notifications while the app runs; optional
  remote push with your own APNs key.
- One Face ID or Touch ID confirmation for sensitive actions, signed by a confirmation key the server verifies.
- Password Vault and Smart sign-in; revealed passwords leave the clipboard after 60 seconds.
- Live Desktop: an RFB client (Raw, CopyRect, Tight, ZRLE, cursor) with touch, mouse and keyboard input and taking and
  releasing control.
- System: Mac and VM status, start and stop the VM, restart services, database backup, diagnostics, paired devices.
- Optional app lock with Face ID or Touch ID.
- English base language and a Czech translation.
- Signing through `Config/Signing.xcconfig` and a git-ignored `Config/Local.xcconfig`; the committed project contains
  no Team ID.
- Helper scripts for the project generator, icons, the localization check, signing expiry and a local Mac package.
- CI (NEBULAKit build and tests, iOS and Mac builds, localization check), secret scanning and draft releases.

[Unreleased]: https://github.com/ond1ej/NEBULA-iOS/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ond1ej/NEBULA-iOS/releases/tag/v1.0.0
