import NEBULACore
import NEBULADesignSystem
import SwiftUI

/// The owner's paired NEBULA apps: this device, the others (revoke with confirmation), pending pairings, and the
/// server's fingerprint. New devices are paired on the Mac (QR code in the NEBULA dashboard).
public struct DevicesView: View {
    let store: SystemStore
    let currentDeviceID: String?
    let onUnpairThisDevice: () -> Void

    @State private var banner: SBanner?
    @State private var confirmRevoke: AppDevice?
    @State private var confirmUnpair = false

    public init(store: SystemStore, currentDeviceID: String?, onUnpairThisDevice: @escaping () -> Void) {
        self.store = store
        self.currentDeviceID = currentDeviceID
        self.onUnpairThisDevice = onUnpairThisDevice
    }

    public var body: some View {
        let this = store.devices.first { $0.id == currentDeviceID }
        let others = store.devices.filter { $0.id != currentDeviceID }
        Form {
            if store.devicesPhase == .loading && store.devices.isEmpty {
                Section {
                    ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                }
            } else if case .failed(let msg) = store.devicesPhase, store.devices.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: NSpace.s) {
                        NBanner(msg, style: .danger)
                        Button("Try again") { Task { await store.loadDevices() } }.buttonStyle(.borderless)
                    }
                    .listRowInsets(EdgeInsets(top: NSpace.s, leading: NSpace.s, bottom: NSpace.s, trailing: NSpace.s))
                }
            }

            Section {
                if let this {
                    DeviceRow(device: this, isCurrent: true, busy: false)
                }
                Button(role: .destructive) {
                    confirmUnpair = true
                } label: {
                    Label("Unpair this device", systemImage: "iphone.slash")
                }
                .foregroundStyle(NColor.danger)
            } header: {
                Text("This device")
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { d in
                        DeviceRow(device: d, isCurrent: false, busy: store.revoking.contains(d.id))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    confirmRevoke = d
                                } label: {
                                    Label(d.status == "pending" ? "Reject" : "Remove", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    confirmRevoke = d
                                } label: {
                                    Label(d.status == "pending" ? "Reject…" : "Remove device…", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("Other devices")
                } footer: {
                    Text("A removed device is signed out immediately and loses access to NEBULA and the Password Vault.")
                }
            }

            Section {
                Label {
                    Text("Pair a new device on your Mac: in the NEBULA Dashboard open Devices → “Pair an iPhone or Mac” and scan the QR code with the NEBULA app. You then approve the new device by comparing a six-digit code.")
                        .font(.callout).foregroundStyle(NColor.textSecondary)
                } icon: {
                    Image(systemName: "qrcode.viewfinder").foregroundStyle(NColor.accent)
                }
                .padding(.vertical, NSpace.xxs)
            } header: {
                Text("Pair a new device")
            }

            if store.serverFingerprint != nil || store.gatewayURL != nil {
                Section {
                    if let g = store.gatewayURL, let host = URL(string: g)?.host() {
                        ValueRow(title: String(localized: "Gateway"), value: host, symbol: "network")
                    }
                    if let f = store.serverFingerprint {
                        VStack(alignment: .leading, spacing: NSpace.xs) {
                            Label("Server fingerprint", systemImage: "touchid")
                            Text(Self.grouped(f)).font(NFont.monoSmall).foregroundStyle(NColor.textSecondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The fingerprint must match the one the NEBULA Dashboard shows on your Mac.")
                }
            }
        }
        .systemFormStyle()
        .navigationTitle(Text("Devices"))
        .refreshable { await store.loadDevices() }
        .onAppear { store.devicesAppeared() }
        .onDisappear { store.devicesDisappeared() }
        .nAnimation(NMotion.smooth, value: store.devices.map(\.id))
        .systemBanner($banner)
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await store.loadDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif
        .confirmationDialog(Text(revokeTitle), isPresented: Binding(get: { confirmRevoke != nil },
                                                                   set: { if !$0 { confirmRevoke = nil } }),
                            titleVisibility: .visible, presenting: confirmRevoke) { d in
            Button(d.status == "pending" ? "Reject device" : "Remove device", role: .destructive) {
                Task { banner = .from(await store.revoke(d)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { d in
            Text(d.status == "pending"
                 ? "The pairing request will be declined."
                 : "The device is signed out and loses access to NEBULA and the Password Vault. It can be paired again only on your Mac.")
        }
        .confirmationDialog(Text("Unpair this device?"), isPresented: $confirmUnpair,
                            titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { onUnpairThisDevice() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The app signs out and deletes its keys. You will need a QR code from your Mac to connect again.")
        }
    }

    private var revokeTitle: String {
        guard let d = confirmRevoke else { return "" }
        return d.status == "pending" ? String(localized: "Reject “\(d.name)”?") : String(localized: "Remove “\(d.name)”?")
    }

    /// "ab12cd34ef56…" → "AB12 CD34 EF56 …" for comparing by eye.
    static func grouped(_ f: String) -> String {
        let clean = f.replacingOccurrences(of: ":", with: "").uppercased()
        var out: [String] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 4, limitedBy: clean.endIndex) ?? clean.endIndex
            out.append(String(clean[i..<j]))
            i = j
        }
        return out.joined(separator: " ")
    }
}

private struct DeviceRow: View {
    let device: AppDevice
    let isCurrent: Bool
    let busy: Bool

    var body: some View {
        HStack(spacing: NSpace.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(device.status == "pending" ? NColor.warning : NColor.accent)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: NSpace.s) {
                    Text(device.name).font(NFont.headline).lineLimit(1)
                    if isCurrent { NBadge(String(localized: "This device")) }
                }
                Text(subtitle).font(.footnote).foregroundStyle(NColor.textSecondary).lineLimit(2)
                if device.status == "pending" {
                    if let code = device.verificationCode {
                        Text("Waiting for approval on the Mac · code \(code)").font(.footnote.weight(.medium))
                            .foregroundStyle(NColor.warning)
                    } else {
                        Text("Waiting for approval on the Mac").font(.footnote.weight(.medium)).foregroundStyle(NColor.warning)
                    }
                } else {
                    HStack(spacing: NSpace.xs) {
                        NBadge(device.keyProtection == "secure_enclave" ? "Secure Enclave" : String(localized: "Keychain"),
                               tint: NColor.info)
                        if device.vaultKey == true { NBadge(String(localized: "Unlocks the Vault"), tint: NColor.success) }
                    }
                }
            }
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, NSpace.xxs)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        let m = (device.model ?? "").lowercased()
        if m.contains("ipad") { return "ipad" }
        if device.platform == "ios" { return "iphone" }
        if m.contains("macbook") { return "laptopcomputer" }
        return "desktopcomputer"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let m = device.model, !m.isEmpty { parts.append(m) }
        if let v = device.appVersion, !v.isEmpty { parts.append(String(localized: "NEBULA \(v)")) }
        if isCurrent {
            parts.append(String(localized: "in use right now"))
        } else if let seen = device.lastSeenAt {
            parts.append(String(localized: "last seen \(NFormat.relativeTime(seen))"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Previews

#Preview("Devices") {
    NavigationStack {
        DevicesView(store: SystemPreviewData.store(), currentDeviceID: "d1", onUnpairThisDevice: {})
    }
}
