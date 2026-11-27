## What and why

<!-- What does this change, and what problem does it solve? Link the issue: "Fixes #123". -->

## How it was tested

<!-- Commands you ran and their result. Say what you could not test (for example: no real iPhone, no push setup). -->

- [ ] `swift build && swift test` in `NEBULAKit`
- [ ] `xcodebuild ... -scheme "NEBULA iOS" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
- [ ] `xcodebuild ... -scheme "NEBULA Mac" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- [ ] `python3 scripts/check_localizations.py <derived data> --lang cs` (string changes)
- [ ] Tried on a device or simulator against a NEBULA test server (UI changes)

## Checklist

- [ ] Tests added or updated; a bug fix has a test that fails without it.
- [ ] Documentation and `CHANGELOG.md` ("Unreleased") updated where behaviour changes.
- [ ] New user-facing strings are in `Localization/Localizable.xcstrings`.
- [ ] No secrets, Team IDs, provisioning profiles, device identifiers, real host names or personal data in the diff or
      in screenshots; `Config/Local.xcconfig` is not committed.
- [ ] No hard-coded server addresses, analytics or third-party services.
- [ ] Commits are signed off (`git commit -s`).

## Security impact

<!-- Does this change pairing, keys, the Keychain, sessions, confirmations, or what the app sends where? -->
