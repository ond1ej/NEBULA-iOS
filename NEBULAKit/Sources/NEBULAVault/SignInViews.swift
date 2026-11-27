import NEBULAAuth
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import SwiftUI

/// A compact card for lists / the chat: "Jarvis needs to sign in to teams.microsoft.com".
public struct SignInCard: View {
    let session: SignInSession
    public init(session: SignInSession) { self.session = session }

    public var body: some View {
        HStack(spacing: NSpace.m) {
            Image(systemName: "person.badge.key.fill").font(.title3).foregroundStyle(NColor.accent)
                .frame(width: 40, height: 40).background(Circle().fill(NColor.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.agentName) needs to sign in").font(.callout.weight(.semibold))
                Text(NFormat.host(session.request?.pageOrigin ?? session.verifiedOrigin ?? session.requestedOrigin))
                    .font(.footnote).foregroundStyle(NColor.textSecondary)
            }
            Spacer()
            TrustBadge(level: session.request?.trust?.level ?? session.trust?.level)
        }
        .padding(NSpace.m)
        .background(RoundedRectangle(cornerRadius: NRadius.l, style: .continuous).fill(NColor.surface))
        .overlay(RoundedRectangle(cornerRadius: NRadius.l, style: .continuous).strokeBorder(NColor.accent.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }
}

struct TrustBadge: View {
    let level: String?
    var body: some View {
        switch level {
        case "GREEN": NBadge(String(localized: "Verified"), tint: NColor.success)
        case "YELLOW": NBadge(String(localized: "Check"), tint: NColor.warning)
        case "RED": NBadge(String(localized: "Unsafe"), tint: NColor.danger)
        default: EmptyView()
        }
    }
}

/// The owner's answer to one Smart sign-in step (credentials, code, authenticator approval, destination review,
/// passkey / manual steps, method choice).
public struct SignInRequestView: View {
    @Bindable var store: SignInStore
    let sessionID: String
    let onOpenDesktop: (String) -> Void

    @State private var values: [String: String] = [:]
    @State private var saveToVault = true
    @State private var allowFuture = false
    @State private var reviewed = false
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    public init(store: SignInStore, sessionID: String, onOpenDesktop: @escaping (String) -> Void) {
        self.store = store
        self.sessionID = sessionID
        self.onOpenDesktop = onOpenDesktop
    }

    private var session: SignInSession? { store.session(sessionID) }

    public var body: some View {
        Form {
            if let s = session {
                header(s)
                if let r = s.request, !s.isFinal {
                    trust(r)
                    step(s, r)
                } else {
                    finalState(s)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let e = store.error { Section { NBanner(e, style: .warning) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Agent sign-in")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { clear(); dismiss() } }
            if let s = session, !s.isFinal {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Cancel sign-in", role: .destructive) { Task { await store.cancel(s) } }
                }
            }
        }
        .task { await store.refresh(sessionID) }
        .onChange(of: session?.request?.id) { _, _ in clear() }
        .onChange(of: scenePhase) { _, p in if p == .background { clear() } }
        .onDisappear { clear() }
    }

    private func clear() {
        for k in values.keys { values[k] = "" }
        values.removeAll()
    }

    @ViewBuilder private func header(_ s: SignInSession) -> some View {
        Section {
            VStack(alignment: .leading, spacing: NSpace.s) {
                Text("\(s.agentName) is signing in").font(.headline)
                Text(NFormat.host(s.request?.pageOrigin ?? s.verifiedOrigin ?? s.requestedOrigin))
                    .font(.title3.weight(.semibold)).foregroundStyle(NColor.accent)
                Text("NEBULA fills in the details in the isolated browser. The agent never sees the password.")
                    .font(.footnote).foregroundStyle(NColor.textSecondary)
            }
        }
    }

    @ViewBuilder private func trust(_ r: SignInRequest) -> some View {
        if let t = r.trust {
            Section {
                HStack(alignment: .top, spacing: NSpace.s) {
                    Image(systemName: t.level == "GREEN" ? "checkmark.shield.fill" : t.level == "RED"
                          ? "xmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(t.level == "GREEN" ? NColor.success : t.level == "RED" ? NColor.danger : NColor.warning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.provider.map { String(localized: "Verified provider: \($0)") } ??
                             (t.level == "GREEN" ? String(localized: "Verified address") : String(localized: "Check the address")))
                            .font(.callout.weight(.semibold))
                        ForEach(t.reasons, id: \.code) { Text($0.text).font(.caption).foregroundStyle(NColor.textSecondary) }
                    }
                }
                if r.reviewRequired {
                    Toggle("I checked the address and it is correct", isOn: $reviewed)
                }
            }
        }
        if let note = noteText(r) { Section { NBanner(note, style: .info, symbol: "sparkles") } }
        if let e = r.error { Section { NBanner(errorText(e), style: .warning) } }
    }

    @ViewBuilder private func step(_ s: SignInSession, _ r: SignInRequest) -> some View {
        switch r.type {
        case "credentials": credentials(s, r)
        case "otp", "recovery_code": code(s, r)
        case "device_approval": approval(s, r)
        case "confirm_destination": destination(s, r)
        case "method_choice": methodChoice(s, r)
        case "manual", "loop": manual(s, r)
        default: Section { Text("Answer this step in the Dashboard for now.").foregroundStyle(NColor.textSecondary) }
        }
    }

    @ViewBuilder private func credentials(_ s: SignInSession, _ r: SignInRequest) -> some View {
        if let accounts = r.accounts, !accounts.isEmpty {
            Section("Saved accounts") {
                ForEach(accounts) { a in
                    Button {
                        Task { await submitSaved(s, r, a) }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(NColor.accent)
                            VStack(alignment: .leading) {
                                Text(a.name)
                                if let u = a.username { Text(u).font(.caption).foregroundStyle(NColor.textSecondary) }
                            }
                            Spacer()
                            Image(systemName: OwnerPresence.symbol).foregroundStyle(NColor.textTertiary)
                        }
                    }
                    .disabled(store.submitting || (r.reviewRequired && !reviewed))
                }
            }
        }
        Section(r.accounts?.isEmpty == false ? "Or enter the details" : "Details") {
            ForEach(r.fields) { f in field(f) }
        }
        if r.vault.canSave || r.vault.state != "not_created" {
            Section {
                Toggle("Save to the vault", isOn: $saveToVault)
                if saveToVault {
                    TextField("Account name (optional)", text: $name)
                    if r.allowFutureAvailable == true {
                        Toggle("Next time \(s.agentName) can use the account after I approve", isOn: $allowFuture)
                    }
                }
            } footer: {
                Text("You confirm with a single \(OwnerPresence.label). No extra password or PIN.")
            }
        }
        Section {
            Button {
                Task { await submitCredentials(s, r) }
            } label: {
                HStack {
                    Spacer()
                    if store.submitting { ProgressView() } else { Label("Sign in", systemImage: OwnerPresence.symbol) }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent).tint(NColor.accent)
            .disabled(!filled(r) || store.submitting || (r.reviewRequired && !reviewed))
        }
    }

    @ViewBuilder private func field(_ f: SignInField) -> some View {
        let binding = Binding(get: { values[f.id] ?? "" }, set: { values[f.id] = $0 })
        let label = fieldLabel(f)
        if f.role == "password" {
            SecureField(label, text: binding).textContentType(.password)
        } else {
            TextField(label, text: binding)
                .textContentType(f.role == "email" ? .emailAddress : f.role == "phone" ? .telephoneNumber : .username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(f.role == "email" ? .emailAddress : f.role == "phone" ? .phonePad : .default)
                #endif
        }
    }

    private func fieldLabel(_ f: SignInField) -> String {
        switch f.role {
        case "email": return String(localized: "Email")
        case "phone": return String(localized: "Phone")
        case "username": return String(localized: "Username")
        case "username_or_email": return String(localized: "Username or email")
        case "password": return String(localized: "Password")
        case "otp": return String(localized: "Code")
        case "recovery_code": return String(localized: "Backup code")
        default: return f.role
        }
    }

    private func filled(_ r: SignInRequest) -> Bool {
        r.fields.allSatisfy { !(values[$0.id] ?? "").isEmpty }
    }

    @ViewBuilder private func code(_ s: SignInSession, _ r: SignInRequest) -> some View {
        Section {
            if let f = r.fields.first {
                TextField(fieldLabel(f), text: Binding(get: { values[f.id] ?? "" }, set: { values[f.id] = $0 }))
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    #if os(iOS)
                    .keyboardType(f.charset == "numeric" ? .numberPad : .asciiCapable)
                    #endif
            }
        } header: {
            Text(otpHeader(r))
        } footer: {
            Text("The code is not stored anywhere.")
        }
        Section {
            Button("Submit code") {
                Task {
                    let v = values
                    _ = await store.submit(s) { b in b.action = "code"; b.values = v; b.reviewConfirmed = reviewed ? true : nil }
                    clear()
                }
            }
            .disabled(!filled(r) || store.submitting)
            alternatives(s, r)
        }
    }

    private func otpHeader(_ r: SignInRequest) -> String {
        switch r.otp?.channel {
        case "sms": return String(localized: "Code from SMS")
        case "email": return String(localized: "Code from email")
        case "totp": return String(localized: "Code from an authenticator app")
        default: return String(localized: "One-time code")
        }
    }

    @ViewBuilder private func approval(_ s: SignInSession, _ r: SignInRequest) -> some View {
        Section {
            VStack(spacing: NSpace.m) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(NColor.accent)
                Text("Approve the sign-in in your authenticator app").font(.headline).multilineTextAlignment(.center)
                if let n = r.approvalNumber {
                    Text(n).font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                        .accessibilityLabel(Text("Number \(n)"))
                    Text("Enter this number in the app.").font(.footnote).foregroundStyle(NColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, NSpace.m)
            Button("I approved it") {
                Task { _ = await store.submit(s) { b in b.action = "check" } }
            }
            alternatives(s, r)
        }
    }

    @ViewBuilder private func destination(_ s: SignInSession, _ r: SignInRequest) -> some View {
        if let d = r.destination {
            Section("The site wants to send your details elsewhere") {
                LabeledContent("Destination", value: NFormat.host(d.origin))
                LabeledContent("Original site", value: NFormat.host(d.requestedOrigin))
                Toggle("I checked the destination", isOn: $reviewed)
                Button("Allow") {
                    Task { _ = await store.submit(s) { b in b.action = "allow_destination"; b.reviewConfirmed = true } }
                }
                .disabled(!reviewed)
            }
        }
    }

    @ViewBuilder private func methodChoice(_ s: SignInSession, _ r: SignInRequest) -> some View {
        Section("How do you want to sign in?") { alternatives(s, r) }
    }

    @ViewBuilder private func alternatives(_ s: SignInSession, _ r: SignInRequest) -> some View {
        ForEach(r.alternatives ?? [], id: \.self) { alt in
            Button(altText(alt)) {
                Task { _ = await store.submit(s) { b in b.action = "choose"; b.alternative = alt } }
            }
        }
    }

    private func altText(_ a: String) -> String {
        switch a {
        case "password": return String(localized: "Use password")
        case "code": return String(localized: "Send code")
        case "app": return String(localized: "Approve in the app")
        default: return String(localized: "Other options")
        }
    }

    @ViewBuilder private func manual(_ s: SignInSession, _ r: SignInRequest) -> some View {
        Section {
            VStack(alignment: .leading, spacing: NSpace.s) {
                Text(manualTitle(r)).font(.headline)
                Text(manualText(r)).font(.callout).foregroundStyle(NColor.textSecondary)
            }
            Button { onOpenDesktop(s.agentId) } label: { Label("Open the agent's Live Desktop", systemImage: "display") }
            if r.manual?.canCompleteHere != false {
                Button("Done, continue") { Task { _ = await store.submit(s) { b in b.action = "manual_done" } } }
            }
            Button("Try again") { Task { _ = await store.submit(s) { b in b.action = "retry" } } }
            alternatives(s, r)
        }
    }

    private func manualTitle(_ r: SignInRequest) -> String {
        switch r.manual?.kind {
        case "passkey": return String(localized: "The site wants a passkey")
        case "security_key": return String(localized: "The site wants a security key")
        case "captcha": return String(localized: "The site wants a CAPTCHA check")
        default: return r.type == "loop" ? String(localized: "Sign-in stopped") : String(localized: "Do this step by hand")
        }
    }

    private func manualText(_ r: SignInRequest) -> String {
        if r.manual?.canCompleteHere == false {
            return String(localized: "The isolated NEBULA browser has no passkey or security key. Choose another way to sign in, or finish this on the Live Desktop.")
        }
        return String(localized: "Finish the step on the agent's Live Desktop, then tap Done.")
    }

    @ViewBuilder private func finalState(_ s: SignInSession) -> some View {
        Section {
            switch s.state {
            case "AUTHENTICATED":
                Label("Signed in. The agent continues the task", systemImage: "checkmark.seal.fill").foregroundStyle(NColor.success)
            case "CANCELLED": Label("Cancelled", systemImage: "xmark.circle")
            case "EXPIRED": Label("Expired", systemImage: "clock.badge.xmark")
            case "FAILED": Label("Sign-in failed", systemImage: "exclamationmark.triangle").foregroundStyle(NColor.danger)
            default: HStack { ProgressView(); Text("NEBULA is checking the sign-in…") }
            }
        }
        .onAppear { if s.state == "AUTHENTICATED" { Haptics.success() } }
    }

    private func noteText(_ r: SignInRequest) -> String? {
        guard let notes = r.notes, !notes.isEmpty else { return nil }
        var parts: [String] = []
        if notes.contains("passkey_cancelled") || notes.contains("security_key_cancelled") {
            parts.append(String(localized: "NEBULA cancelled the passkey prompt"))
        }
        if notes.contains("chose_password") { parts.append(String(localized: "chose to sign in with a password")) }
        if notes.contains("declined_kmsi") { parts.append(String(localized: "declined “Stay signed in?”")) }
        if notes.contains("restarted_from_service") { parts.append(String(localized: "started over from the service")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ") + "."
    }

    private func errorText(_ e: String) -> String {
        switch e {
        case "credentials_rejected": return String(localized: "The site rejected the details. Check them.")
        case "code_rejected": return String(localized: "The code was not accepted.")
        case "page_changed": return String(localized: "The page has changed. This is a new step.")
        case "no_progress": return String(localized: "The site did not respond.")
        default: return e
        }
    }

    private func submitCredentials(_ s: SignInSession, _ r: SignInRequest) async {
        let v = values
        let save = (r.vault.canSave || r.vault.state != "not_created") && saveToVault ? "vault" : "once"
        let ok = await store.submit(s) { b in
            b.action = "credentials"
            b.values = v
            b.save = save
            if save == "vault" { b.name = name.isEmpty ? nil : name; b.allowFuture = allowFuture ? true : nil }
            b.reviewConfirmed = reviewed ? true : nil
        }
        clear()
        if ok { Haptics.success() }
    }

    private func submitSaved(_ s: SignInSession, _ r: SignInRequest, _ a: SignInAccount) async {
        let ok = await store.submit(s) { b in
            b.action = "saved"
            b.entryId = a.entryId
            b.reviewConfirmed = reviewed ? true : nil
        }
        if ok { Haptics.success() }
    }
}
