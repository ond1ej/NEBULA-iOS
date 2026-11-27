# Building the apps

This repository contains the NEBULA app for iPhone and iPad (`iOS/`) and the NEBULA app for the Mac (`macOS/`). Both
are built on one Swift package, `NEBULAKit/`. They are clients of the remote gateway of your
[NEBULA server](https://github.com/ond1ej/NEBULA_v1); there is no second backend. For pairing and day-to-day use, see
[using.md](using.md).

## Requirements

- A Mac with **Xcode 26 or later**. The package uses Swift 6 and the Xcode 16+ project format with synchronized
  folders, and a few views use iOS 26 / macOS 26 APIs behind availability checks, so the iOS 26 and macOS 26 SDKs are
  needed to compile.
- Deployment targets: **iOS 18** (iPhone and iPad) and **macOS 15**.
- For a real iPhone: an Apple ID signed in to Xcode (free or paid).
- Optional: Python 3 for the helper scripts in `scripts/` (the icon renderer also needs Pillow).

## Schemes

| Scheme | Builds | Run destination |
| --- | --- | --- |
| `NEBULA iOS` | The iPhone/iPad app (target `NEBULA`) and its UI tests | An iOS simulator or your iPhone |
| `NEBULA Mac` | The Mac app (target `NEBULA Mac`) and its UI tests | My Mac |

## Build in Xcode

```bash
open NEBULA.xcodeproj
```

Pick a scheme and a destination and press Run. With the committed defaults, simulator builds are signed ad hoc and
the Mac app is signed "to run locally", so you do not need an Apple account for either.

## Build from the command line

```bash
# Shared package: build and unit tests
cd NEBULAKit && swift build && swift test && cd ..

# iPhone app for the simulator, unsigned
xcodebuild -project NEBULA.xcodeproj -scheme "NEBULA iOS" \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Mac app, unsigned
xcodebuild -project NEBULA.xcodeproj -scheme "NEBULA Mac" \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

These are the same commands CI runs.

## Signing with your own team

The committed project contains no Team ID and uses the placeholder bundle-identifier prefix `com.example`. All
signing values come from two configuration files:

| File | Purpose |
| --- | --- |
| `Config/Signing.xcconfig` | Committed defaults, safe for everybody: no team, prefix `com.example`, Mac signed to run locally |
| `Config/Local.xcconfig` | Your own values. Git-ignored, never commit it. `Signing.xcconfig` includes it when it exists |
| `Config/Local.xcconfig.example` | The template for `Local.xcconfig` |

To run on a real iPhone:

1. Create your local file:

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. Edit it:

   ```
   DEVELOPMENT_TEAM = ABCDE12345          // your Team ID (Xcode > Settings > Accounts)
   NEBULA_BUNDLE_ID_PREFIX = com.yourname // a reverse-DNS prefix unique to you
   ```

   A free Apple ID gets a "Personal Team" in Xcode, which has a Team ID as well. The bundle identifiers become
   `<prefix>.nebula` (iPhone) and `<prefix>.nebula.mac` (Mac). The prefix also names the app's Keychain service, its
   log subsystem and the pairing URL type, so two builds with different prefixes never share secrets. If you change the
   prefix later, the app starts unpaired and you pair it again.

3. Open `NEBULA.xcodeproj`, choose the `NEBULA iOS` scheme and your iPhone, and press Run.
4. On the iPhone, turn on Developer Mode (Settings > Privacy & Security) and, with a free Apple ID, trust your
   developer certificate (Settings > General > VPN & Device Management).

You do not need to regenerate the Xcode project when you edit an `.xcconfig` file.

Optional settings in `Config/Local.xcconfig` (also described in the example file):

- **Mac keychain access group.** `CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development` together with
  `NEBULA_MAC_ENTITLEMENTS = macOS/NEBULA-provisioned.entitlements` signs the Mac app with your development
  certificate and adds a keychain access group, so the vault key can use the data-protection keychain. This needs a
  team. Without it, the Mac app uses the login keychain and enforces Touch ID inside the app. The Welcome and Settings
  screens say which protection is in use.
- **Remote push on iOS.** `NEBULA_IOS_ENTITLEMENTS = iOS/NEBULA-push.entitlements`, see
  [Push notifications](#push-notifications).

To see when your signing certificates and provisioning profiles expire (read-only):

```bash
scripts/check_signing.sh                    # optionally pass the path of a built .app
```

## Push notifications

Without any setup, the app shows local notifications for approvals, sign-in requests and other important events
**while it is running**. Remote push (notifications while the app is closed) needs all of the following:

1. **A paid Apple Developer Program membership.** A free Personal Team cannot use the Push Notifications capability.
2. **The push entitlement in the app.** Add `NEBULA_IOS_ENTITLEMENTS = iOS/NEBULA-push.entitlements` to
   `Config/Local.xcconfig`. It sets `aps-environment` to `development`, which is what builds installed from Xcode
   use. With the entitlement, the app registers its push token with your server after it signs in; the token is
   stored for this device only and deleted when you revoke the device.
3. **APNs configured on the server.** Your own APNs authentication key (`.p8`) with its key id and your team id, and
   the topic, which is your iPhone app's bundle identifier (`<prefix>.nebula`). The NEBULA server stores the key in
   the macOS Keychain and needs the `h2` Python package, because APNs speaks HTTP/2 only. See the server
   repository, [NEBULA_v1](https://github.com/ond1ej/NEBULA_v1), `docs/apple-apps.md`, section "Push notifications".

Push alerts contain the agent's name only, never task content. The Mac app does not use remote push.

## Tests

- **Unit tests:** `cd NEBULAKit && swift test`. They cover Markdown parsing and rendering, syntax highlighting, the
  VNC (RFB) handshake, decoders, input and transport for the Live Desktop, pairing links and server signatures, the
  server-sent event stream, and model decoding.
- **UI tests** (`UITests-iOS/`, `UITests-macOS/`) run end to end against an isolated test NEBULA started by
  `scripts/test_instance.py` **in the server repository** (temporary data, in-memory secrets, a scripted model, no AI
  provider). From a checkout of NEBULA_v1, with this repository next to it:

  ```bash
  .venv/bin/python scripts/test_instance.py --out /tmp/nebula-e2e --auto-approve
  # read pairing_link and vault_passphrase from /tmp/nebula-e2e/state.json, then:
  TEST_RUNNER_NEBULA_LINK='<pairing_link>' TEST_RUNNER_NEBULA_VAULT='<vault_passphrase>' \
  xcodebuild test -project ../NEBULA-iOS/NEBULA.xcodeproj -scheme "NEBULA iOS" \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:NEBULAUITests/NEBULAUITests/testEndToEnd
  ```

  On the simulator, enroll Face ID (Features > Face ID > Enrolled) and answer each prompt with "Matching Face". The
  pairing link is single use; ask the script for a fresh one (`touch /tmp/nebula-e2e/cmd-pair`) before each run.

## Localization

English is the base language and Czech is included. User-facing strings live in
`Localization/Localizable.xcstrings`, and the permission prompts in `Localization/InfoPlist.xcstrings`; both catalogs
are compiled into the app targets. Package code uses `String(localized:)` and SwiftUI string literals, which resolve in
the app bundle. To add a language, add it in Xcode's catalog editor.

After you add or change strings, check the catalog against what the compiler extracts:

```bash
xcodebuild -project NEBULA.xcodeproj -scheme "NEBULA iOS" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/dd-loc CODE_SIGNING_ALLOWED=NO build
python3 scripts/check_localizations.py build/dd-loc --lang cs
```

It exits with code 1 if a string used in the code is missing from the catalog or has no Czech translation. Messages
that come from the server (error texts, Smart sign-in prompts) are shown as the server sends them.

## Helper scripts

| Script | What it does |
| --- | --- |
| `scripts/gen_xcodeproj.py` | Regenerates `NEBULA.xcodeproj` and its shared schemes. Run it only when you change the project structure (targets, build settings). It never writes a Team ID into the project. Files added to `iOS/`, `macOS/` or `UITests-*/` are picked up automatically |
| `scripts/make_icons.py` | Renders the app icons for both asset catalogs (needs Pillow) |
| `scripts/check_localizations.py` | The localization check above |
| `scripts/check_signing.sh` | Shows the expiry of your Apple Development certificates and provisioning profiles |
| `scripts/build_mac_release.sh` | Builds a Release Mac app signed with your settings and packages it as `dist/NEBULA-<version>-mac.dmg`, for your own Macs only. It is not notarized; do not publish it |

## Project layout

| NEBULAKit module | Contents |
| --- | --- |
| NEBULACore | Wire models, formatting, JSON values |
| NEBULANetwork | Typed API client with Bearer sessions, server-sent events with resume, connectivity |
| NEBULAAuth | Keychain (this device only), Secure Enclave keys, pairing, sessions, owner confirmation |
| NEBULADesignSystem | Colours, spacing, motion, haptics and shared components |
| NEBULAChat | Conversations, composer, Markdown renderer with syntax highlighting |
| NEBULAAgents | Agents, agent editor, tasks |
| NEBULAVault | Vault screens, owner confirmation, Smart sign-in requests |
| NEBULADesktop | RFB 3.8 client (Raw, CopyRect, Tight, ZRLE, cursor), touch, mouse and keyboard input |
| NEBULASystem | Mac and VM status and actions, diagnostics, paired devices |
| NEBULAAppUI | App model, iPhone tab shell, Mac split view, activity center, pairing screens |

## Limitations

- No App Store, TestFlight or notarized build is provided; you build and sign the apps yourself.
- A free Apple ID build expires after 7 days on the device; a paid program build after a year.
- Remote push needs the paid Apple Developer Program and an APNs key on your server.
- The simulator and a Mac build signed "to run locally" have no Secure Enclave protection for the confirmation key.
