import NEBULACore
import NEBULADesignSystem
import SwiftUI

/// About NEBULA: the app and server versions and what the app does (and does not) do with data.
public struct AboutView: View {
    let appVersion: String
    let serverVersion: String?

    public init(appVersion: String, serverVersion: String?) {
        self.appVersion = appVersion
        self.serverVersion = serverVersion
    }

    public var body: some View {
        Form {
            Section {
                VStack(spacing: NSpace.m) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(NColor.accentGradient)
                        Image(systemName: "sparkles").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 88, height: 88)
                    .shadow(color: NColor.accent.opacity(0.3), radius: 14, y: 6)
                    .accessibilityHidden(true)
                    .nAppear()
                    Text("NEBULA").font(NFont.largeTitle)
                    Text("Your AI agents on your Mac mini, wherever you go.")
                        .font(.callout).foregroundStyle(NColor.textSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, NSpace.m)
            }
            .modifier(SClearRow())

            Section {
                ValueRow(title: String(localized: "App"), value: appVersion, symbol: "app.badge")
                ValueRow(title: String(localized: "NEBULA server"), value: serverVersion ?? "–", symbol: "server.rack")
            } header: {
                Text("Version")
            }

            Section {
                Label("Agents, tasks and the Password Vault run on your Mac mini; this app is only a secure client.",
                      systemImage: "desktopcomputer")
                Label("Device keys never leave this device (Secure Enclave where available), and you confirm sensitive actions with Face ID or Touch ID.",
                      systemImage: "lock.shield")
                Label("The app talks only through your secure NEBULA gateway; server responses are not cached on disk.",
                      systemImage: "hand.raised")
            } header: {
                Text("Privacy")
            }
            .font(.callout)
        }
        .systemFormStyle()
        .navigationTitle(Text("About"))
        .systemInlineTitle()
    }
}

#Preview("About") {
    NavigationStack { AboutView(appVersion: "1.0.0 (1)", serverVersion: "1.0.0") }
}
