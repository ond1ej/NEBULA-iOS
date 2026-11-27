# Contributing to NEBULA for iPhone and Mac

Thank you for considering a contribution. Bug reports, documentation fixes, tests and code are all welcome. By
participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- **Security problems** go through private reporting, not issues or pull requests. See [SECURITY.md](SECURITY.md).
- **Server problems** (agents, the VM, the Dashboard, the gateway) belong in the server repository,
  [ond1ej/NEBULA_v1](https://github.com/ond1ej/NEBULA_v1).
- **Bugs in the apps:** open an issue with the bug template. Say which app (iPhone, iPad or Mac), the app and server
  versions, the device and OS version, and how you reach the server (Tailscale Serve, Funnel, a tunnel).
- **Larger changes or new features:** open an issue first, so we can agree on the approach before you invest time.

## Development setup

You need a Mac with Xcode 26 or later. See [docs/building.md](docs/building.md) for the full build instructions.

```bash
git clone https://github.com/<you>/NEBULA-iOS.git && cd NEBULA-iOS
open NEBULA.xcodeproj
```

Put your own Team ID and bundle-identifier prefix only in `Config/Local.xcconfig`, which git ignores. Never commit it,
and never put a Team ID into `Config/Signing.xcconfig` or the project.

For anything that talks to a server, use the isolated test server of the server repository
(`scripts/test_instance.py` in NEBULA_v1), never the installation you use every day.

## Checks

Every pull request must pass:

```bash
cd NEBULAKit && swift build && swift test && cd ..
xcodebuild -project NEBULA.xcodeproj -scheme "NEBULA iOS" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
xcodebuild -project NEBULA.xcodeproj -scheme "NEBULA Mac" -destination 'platform=macOS' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
python3 scripts/check_localizations.py build/dd --lang cs
```

CI runs the same checks, plus a secret scan with `gitleaks`. Run `gitleaks dir . --redact` and
`gitleaks git . --redact` before you push if you have it installed. If a test fixture has to look like a secret, use
an obviously fake value; if the scanner still flags it, add a narrow `.gitleaks.toml` allowlist entry for that file and
that exact value, with a comment that says why. Never allowlist a whole directory or rule.

If you change the project structure (targets, build settings), edit `scripts/gen_xcodeproj.py` and regenerate the
project with `python3 scripts/gen_xcodeproj.py`; do not edit `NEBULA.xcodeproj` by hand. New source files in `iOS/`,
`macOS/` or `UITests-*/` need no regeneration.

## Pull requests

- Keep a pull request focused on one change. Separate refactoring from behaviour changes.
- Add or update tests. A bug fix needs a test that fails without the fix.
- Every user-facing string goes into `Localization/Localizable.xcstrings` with an English base value. Add a Czech
  translation if you can; otherwise say so in the pull request.
- Update the documentation when behaviour changes, and add an entry under "Unreleased" in [CHANGELOG.md](CHANGELOG.md).
- Never commit secrets, tokens, Team IDs, provisioning profiles, signing certificates, device identifiers, real
  host names, or screenshots that contain personal data. Use obviously fake values in tests and documentation
  (`ABCDE12345`, `com.yourname`, `your-mac.your-tailnet.ts.net`).
- Do not add hard-coded server addresses, analytics or third-party services. The app talks only to the server in the
  pairing link.
- New dependencies must have a license compatible with MIT (MIT, BSD, Apache-2.0, ISC, zlib and similar). Copyleft
  licenses such as GPL or AGPL are not accepted. The project has no third-party dependencies today; please discuss
  adding one in an issue first.
- Describe security properties honestly in docs and UI text, including what the simulator and unsigned builds cannot
  protect.

## Commit sign-off

Please sign off your commits (`git commit -s`) to certify the
[Developer Certificate of Origin](https://developercertificate.org/): that you wrote the change or have the right to
submit it under the project's license.

## License

The apps are licensed under the [MIT License](LICENSE). By contributing, you agree that your contributions are licensed
under the same license (inbound equals outbound).
