# Security policy

The NEBULA apps hold device keys that approve actions on your NEBULA server, reveal vault passwords and take control
of an agent's desktop. We take reports about their security seriously and appreciate the time you spend on them.

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |
| Older development builds | No |

Security fixes are released as new patch versions. There are no prebuilt binaries: update your checkout and build
again (see [docs/building.md](docs/building.md)).

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately through GitHub Security Advisories of this repository:

1. Open the **Security** tab of [ond1ej/NEBULA-iOS](https://github.com/ond1ej/NEBULA-iOS).
2. Choose **Report a vulnerability**
   ([direct link](https://github.com/ond1ej/NEBULA-iOS/security/advisories/new)).
3. Describe the problem, the affected version or commit, how to reproduce it, and the impact you expect.

If private reporting is unavailable for some reason, open a public issue that says only that you have a security
report and asks for a private channel, without any details.

What to expect:

- an acknowledgement within 5 working days;
- an initial assessment (confirmed, needs more information, or not a vulnerability) within 14 days;
- a fix or a mitigation plan for confirmed issues, coordinated with you before public disclosure;
- credit in the release notes if you want it.

This is a small open-source project without a bug bounty. Please give us a reasonable time to fix a confirmed issue
before you publish details. Test only against your own NEBULA installation or the isolated test server of the server
repository (`scripts/test_instance.py` in [NEBULA_v1](https://github.com/ond1ej/NEBULA_v1)), never against other
people's installations.

## Scope

In scope for this repository:

- the iPhone/iPad app (`iOS/`) and the Mac app (`macOS/`);
- the shared Swift package `NEBULAKit/`: pairing and server-key pinning, device keys and the Keychain, sessions, owner
  confirmation, the API client and event stream, the vault and Smart sign-in screens, the Live Desktop (RFB) client;
- the build configuration, scripts and workflows of this repository.

Out of scope here, please report to the server repository instead
([NEBULA_v1 security policy](https://github.com/ond1ej/NEBULA_v1/security/policy)): the host API, the remote gateway,
the Dashboard, the VM, agents, and how the server stores secrets. If you are unsure where a problem belongs, report it
here; we will move it.

Known limits that are documented as such are not vulnerabilities by themselves:

- The iOS Simulator and a Mac build signed "to run locally" cannot keep the confirmation key in the Secure Enclave.
  The app shows which protection is in use.
- Debug builds accept plain `http://` to a loopback address so they can talk to a local test server. Release builds
  accept `https://` only.
- A password you reveal and copy is removed from the clipboard after 60 seconds and is marked local-only, but other
  apps on the device can read the clipboard during that time.
- Whoever has your unlocked device and can pass its Face ID, Touch ID or passcode prompt can act as you.

## Security model in brief

- **Pairing.** A single-use, short-lived offer from your Dashboard carries the gateway address and the fingerprint of
  the server's key. The app refuses a server that cannot prove it holds that key, and the owner approves every new
  device on the Mac after comparing a six-digit code.
- **Device keys.** P-256 keys in the Secure Enclave where available: an identity key for signing in and a confirmation
  key that requires user presence. Keychain items are "this device only" and never synced.
- **Sessions.** The app signs a single-use, server-signed challenge to get a short-lived Bearer session. Revoking the
  device in the Dashboard ends its sessions immediately.
- **No built-in hosts.** The only server the app talks to is the one in your pairing link. No analytics, no third-party
  services.
