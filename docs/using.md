# Using the apps

The NEBULA apps for iPhone, iPad and Mac are clients of your own NEBULA server. The server, from the
[NEBULA_v1](https://github.com/ond1ej/NEBULA_v1) repository, runs on a Mac (typically a Mac mini) and holds your
agents, tasks, vault and data. The apps have no server and no account of their own. To build and install them, see
[building.md](building.md).

## Before you start

- NEBULA is installed and running on your Mac, and you can open its Dashboard.
- The server's remote gateway is reachable over HTTPS from the device you want to pair (see
  [Reaching your server](#reaching-your-server)).
- The app is installed on your iPhone, iPad or Mac.

## Reaching your server

The apps talk only to the server's remote gateway, and only over `https://`. You choose how the gateway is reached;
the address ends up in the pairing link, so the app never needs a built-in host.

**Recommended: Tailscale Serve.** The gateway is published only inside your tailnet, for example at
`https://your-mac.your-tailnet.ts.net`, and nothing is exposed to the public internet.

1. Install [Tailscale](https://tailscale.com) on the Mac and on the phone and sign both in to the same tailnet. Turn
   on MagicDNS and HTTPS certificates for the tailnet.
2. On the Mac, open the Dashboard and go to the **Remote Access** page (a top-level page in the sidebar). Enable the
   gateway and start Tailscale Serve there.
3. On the phone, check that the Tailscale app is connected.

Other options, all configured on the same **Remote Access** page of the Dashboard:

- **Tailscale Funnel** publishes the gateway on the public internet. It is opt-in, the Dashboard asks you to confirm
  it, and you only need it if the device cannot run Tailscale.
- **Cloudflare Tunnel** or your own TLS reverse proxy also work, as long as the address the app uses is HTTPS. A
  tunnel that terminates TLS at a third party can see the traffic; the server's documentation explains the trade-offs.

The details are in the server repository's documentation.

## Pair a device

1. **Start pairing on the Mac.** In the Dashboard, open the **Devices** page (a top-level page in the sidebar) and
   click **Pair an iPhone or Mac**. It shows a QR code and a pairing link. The offer is valid for a few minutes and
   can be used once. It contains the gateway address, a pairing id, a one-time code and the fingerprint of the
   server's public key, but no long-term secret.
2. **Scan or paste it in the app.** On first launch the app shows "Connect to NEBULA". Tap **Scan QR code**, or paste
   the `nebula://pair?...` link into the text field and tap **Pair**. The app contacts the gateway and stops if the
   server cannot prove it holds the key whose fingerprint is in the link, or if it speaks a gateway protocol the app
   does not support.
3. **Confirm with Face ID or Touch ID.** The app creates its device keys: an identity key for signing in and a
   confirmation key that only Face ID, Touch ID or the device passcode can unlock (in the Secure Enclave where the
   device has one), plus a random device secret for the vault.
4. **Approve on the Mac.** The app and the Dashboard show the same six-digit code. If they match, click **Approve** in
   the Dashboard. Until then the device has no access. Never approve a code you did not start.

After pairing, the app signs in by signing a single-use challenge from the server with its identity key. Sessions are
renewed silently while you use the app.

## What you can do

| iPhone tab / Mac sidebar | What you can do |
| --- | --- |
| Chats | Conversations with your agents: streamed answers, Markdown and code, photos, files and voice notes |
| Agents | List, create, edit and delete agents; pause, resume, sleep and wake them; follow tasks and pause, resume, stop or retry them |
| Activity | Approvals waiting for you, recent notifications, Smart sign-in requests |
| Vault | The Password Vault and sign-in requests; revealing a password needs Face ID or Touch ID |
| System (Mac sidebar; on iPhone under Settings) | Mac and VM status, start or stop the VM, restart services, back up the database, diagnostics, paired devices |
| Settings | This device (name, server, key protection, how the vault unlocks), an optional Face ID / Touch ID lock when the app opens, paired devices, disconnect this device, app and server version |

**Live Desktop** opens from an agent: watch its desktop, take control with touch (iPhone) or mouse and keyboard (Mac),
and release control when you are done. On the Mac it opens in its own window.

**One confirmation for sensitive actions.** Revealing a vault password, approving an agent action, deleting an agent,
stopping the VM and similar actions are confirmed with one Face ID or Touch ID prompt. The first time you use the vault
on a device you enter the vault passphrase once; after that the device's secret unlocks it.

**Notifications.** While the app runs it shows local notifications for approvals and sign-in requests. Notifications
while the app is closed need remote push, see [building.md](building.md#push-notifications).

## Removing a device

In the Dashboard, open **Devices** and revoke the device. Its sessions end immediately and the server deletes its vault
key wrap and push token. Do this if you lose the device. Deleting the app removes its keys from the device; revoke it
in the Dashboard as well.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Server not reachable | Is Tailscale connected on the device, in the same tailnet as the Mac? Is the gateway enabled on the **Remote Access** page? Open the gateway address in Safari on the device. |
| The fingerprint does not match | The link is not from the server the app reached. Create a new pairing on the right Mac. |
| Pairing link expired or already used | Offers are short-lived and single use. Click **Pair an iPhone or Mac** again. |
| The app is refused as incompatible | The app and the server speak different gateway protocol versions. Update the server or rebuild the app from a matching release. |
| The app stopped launching after a week | Free Apple ID builds expire after 7 days. Build and install again from Xcode. |
| No notifications while the app is closed | Expected without remote push; see [building.md](building.md#push-notifications). |

Server-side problems (agents, the VM, the gateway) are covered by the
[NEBULA_v1 documentation](https://github.com/ond1ej/NEBULA_v1).
