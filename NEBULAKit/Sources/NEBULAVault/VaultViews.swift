import NEBULAAuth
import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import SwiftUI

/// The vault: status + unlock with one Face ID, accounts (search), detail with reveal/copy, add/edit/delete,
/// agent permissions and history.
public struct VaultView: View {
    @Bindable var store: VaultStore
    @State private var editing: EditTarget?
    @State private var opened: VaultEntry?
    @State private var section: Pane = .accounts

    enum Pane: String, CaseIterable, Identifiable {
        case accounts, permissions, history
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .accounts: "Accounts"
            case .permissions: "Permissions"
            case .history: "History"
            }
        }
    }

    struct EditTarget: Identifiable { let id = UUID(); let entry: VaultEntry? }

    public init(store: VaultStore) { self.store = store }

    public var body: some View {
        List {
            Section { statusCard }
                .listRowInsets(EdgeInsets(top: NSpace.s, leading: NSpace.l, bottom: NSpace.s, trailing: NSpace.l))
                .listRowBackground(Color.clear)
            Picker("View", selection: $section) {
                ForEach(Pane.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            switch section {
            case .accounts: accounts
            case .permissions: permissions
            case .history: history
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .searchable(text: $store.query, prompt: Text("Search accounts"))
        .refreshable { await store.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EditTarget(entry: nil) } label: { Label("Add account", systemImage: "plus") }
                    .disabled(store.status?.exists != true)
            }
        }
        .sheet(item: $editing) { t in
            NavigationStack { VaultEntryEditor(store: store, entry: t.entry) }
        }
        .sheet(item: $opened) { e in
            NavigationStack { VaultEntryDetailView(store: store, entry: e, onEdit: { opened = nil; editing = EditTarget(entry: e) }) }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
        .task { await store.load() }
        .onChange(of: section) { _, s in
            Task {
                if s == .permissions { await store.loadGrants() }
                if s == .history { await store.loadAudit() }
            }
        }
    }

    @ViewBuilder private var statusCard: some View {
        let s = store.status
        NCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NSpace.m) {
                    statusIcon(s)
                    statusTexts(s)
                    Spacer(minLength: NSpace.s)
                    statusAction(s).fixedSize()
                }
                VStack(alignment: .leading, spacing: NSpace.m) {
                    HStack(spacing: NSpace.m) {
                        statusIcon(s)
                        statusTexts(s)
                        Spacer(minLength: 0)
                    }
                    statusAction(s).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        if let e = store.error { NBanner(e, style: .warning) }
    }

    private func statusIcon(_ s: VaultStatus?) -> some View {
        Image(systemName: s?.locked == false ? "lock.open.fill" : "lock.fill")
            .font(.title2).foregroundStyle(s?.locked == false ? NColor.success : NColor.accent)
            .frame(width: 44, height: 44)
            .background(Circle().fill((s?.locked == false ? NColor.success : NColor.accent).opacity(0.12)))
            .contentTransition(.symbolEffect(.replace))
    }

    private func statusTexts(_ s: VaultStatus?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(s)).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(subtitle(s)).font(.footnote).foregroundStyle(NColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func statusAction(_ s: VaultStatus?) -> some View {
        if s?.exists == true {
            if s?.locked == true {
                Button {
                    Haptics.tap()
                    Task { await store.unlock() }
                } label: { Label("Unlock", systemImage: OwnerPresence.symbol).lineLimit(1) }
                    .buttonStyle(.borderedProminent).tint(NColor.accent)
            } else {
                Button("Lock") { Task { await store.lock(); Haptics.success() } }
                    .buttonStyle(.bordered).lineLimit(1)
            }
        }
    }

    private func title(_ s: VaultStatus?) -> String {
        guard let s else { return String(localized: "Vault") }
        if !s.exists { return String(localized: "The vault has not been created yet") }
        return s.locked ? String(localized: "The vault is locked") : String(localized: "The vault is unlocked")
    }

    private func subtitle(_ s: VaultStatus?) -> String {
        guard let s else { return "" }
        if !s.exists { return String(localized: "Create it in the NEBULA Dashboard on your Mac.") }
        if s.locked { return String(localized: "\(s.entryCount) accounts · unlock with a single \(OwnerPresence.label)") }
        if let at = s.lockAt { return String(localized: "Locks \(NFormat.relativeTime(at))") }
        return String(localized: "\(s.entryCount) accounts")
    }

    @ViewBuilder private var accounts: some View {
        if store.loading && store.entries.isEmpty {
            ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
        } else if store.entries.isEmpty {
            Text(store.query.isEmpty ? "No saved accounts yet." : "Nothing found.").foregroundStyle(NColor.textSecondary)
        } else {
            ForEach(store.entries) { e in
                Button { opened = e } label: { VaultRow(entry: e) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { Task { try? await store.delete(e.id) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        if store.grants.isEmpty {
            Text("No agent has permission to use saved accounts.").foregroundStyle(NColor.textSecondary)
        }
        ForEach(store.grants) { g in
            VStack(alignment: .leading, spacing: 4) {
                Text(g.entryName).font(.body.weight(.medium))
                Text(g.allowedOrigins.map { NFormat.host($0) }.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(NColor.textSecondary)
                HStack {
                    NBadge(policyText(g.approvalPolicy))
                    if !g.enabled { NBadge(String(localized: "off"), tint: NColor.textTertiary) }
                    Spacer()
                    Button("Remove", role: .destructive) { Task { await store.revoke(grant: g.id) } }
                        .font(.footnote).buttonStyle(.borderless)
                }
            }
        }
    }

    private func policyText(_ p: String) -> String {
        switch p {
        case "always_ask": return String(localized: "always ask")
        case "once_per_task": return String(localized: "once per task")
        case "auto": return String(localized: "automatic")
        default: return p
        }
    }

    @ViewBuilder private var history: some View {
        ForEach(store.audit) { r in
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: r.outcome == "ok" ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(r.outcome == "ok" ? NColor.success : NColor.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operationText(r)).font(.callout)
                    Text([r.agentName, r.entryName, r.destinationOrigin.map { NFormat.host($0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(NColor.textSecondary)
                }
                Spacer()
                Text(NFormat.relativeTime(r.ts)).font(.caption2).foregroundStyle(NColor.textTertiary)
            }
        }
    }

    private func operationText(_ r: VaultAuditRow) -> String {
        switch r.operation {
        case "unlock": return String(localized: "Unlocked")
        case "lock": return String(localized: "Locked")
        case "reveal.password", "reveal.username": return String(localized: "Showing a password")
        case "use.smart_sign_in", "use.sign_in": return String(localized: "Used to sign in")
        case "entry.create", "create_entry": return String(localized: "New account")
        case "device_key.enrolled": return String(localized: "Face ID / Touch ID for the vault is on")
        default: return r.operation
        }
    }
}

struct VaultRow: View {
    let entry: VaultEntry
    var body: some View {
        HStack(spacing: NSpace.m) {
            Image(systemName: entry.credentialType == "api_token" ? "key.horizontal.fill"
                  : entry.credentialType == "application" ? "app.badge" : "globe")
                .foregroundStyle(NColor.accent).frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NColor.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.body.weight(.medium))
                Text(entry.origin.map { NFormat.host($0) } ?? entry.appName ?? "")
                    .font(.footnote).foregroundStyle(NColor.textSecondary)
            }
            Spacer()
            if let n = entry.grantCount, n > 0 { NBadge(String(localized: "\(n) agents"), tint: NColor.info) }
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(NColor.textTertiary)
        }
        .contentShape(Rectangle())
    }
}

/// One account: username, a revealed password only on request (one Face ID), copy with expiry.
struct VaultEntryDetailView: View {
    let store: VaultStore
    let entry: VaultEntry
    let onEdit: () -> Void
    @State private var detail: VaultEntryDetail?
    @State private var revealed: String?
    @State private var error: String?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: entry.displayName)
                if let o = entry.origin { LabeledContent("Web", value: NFormat.host(o)) }
                if let u = detail?.username, !u.isEmpty {
                    LabeledContent("User") { Text(u).textSelection(.enabled) }
                }
            }
            Section("Password") {
                HStack {
                    if let r = revealed {
                        Text(r).font(NFont.mono).lineLimit(3)
                            .privacySensitive()
                    } else {
                        Text(verbatim: "••••••••••").foregroundStyle(NColor.textTertiary)
                    }
                    Spacer()
                    Button {
                        if revealed != nil { revealed = nil } else { Task { await reveal() } }
                    } label: {
                        Image(systemName: revealed == nil ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(revealed == nil ? "Show password" : "Hide password"))
                }
                Button {
                    Task {
                        if revealed == nil { await reveal() }
                        if let r = revealed {
                            SecretClipboard.copy(r)
                            Haptics.success()
                            copied = true
                        }
                    }
                } label: { Label(copied ? "Copied for 60 s" : "Copy password", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Text("A copied password stays on this device and disappears from the clipboard after 60 seconds.")
                    .font(.caption).foregroundStyle(NColor.textSecondary)
            }
            if let e = error { Section { NBanner(e, style: .warning) } }
            Section {
                Button("Edit", action: onEdit)
                Button("Delete account", role: .destructive) {
                    Task {
                        do { try await store.delete(entry.id); dismiss() } catch is CancellationError {
                        } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entry.displayName)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task { detail = try? await store.detail(entry.id) }
        .onChange(of: scenePhase) { _, p in if p != .active { revealed = nil } }
        .onDisappear { revealed = nil }
    }

    private func reveal() async {
        do {
            revealed = try await store.reveal(entry.id)
            error = nil
        } catch is CancellationError {
        } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
    }
}

struct VaultEntryEditor: View {
    let store: VaultStore
    let entry: VaultEntry?
    @State private var name = ""
    @State private var origin = ""
    @State private var username = ""
    @State private var password = ""
    @State private var notes = ""
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Website address (https://…)", text: $origin)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
            Section {
                TextField("Username or email", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField(entry == nil ? "Password" : "New password (leave empty to keep it)", text: $password)
                    .textContentType(.password)
                Button("Generate a strong password") { password = Self.generate() }
            }
            Section("Note") { TextField("Note", text: $notes, axis: .vertical).lineLimit(2...5) }
            if let e = error { Section { NBanner(e, style: .warning) } }
        }
        .formStyle(.grouped)
        .navigationTitle(entry == nil ? "New account" : "Edit account")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { password = ""; dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .onAppear {
            if let e = entry { name = e.displayName; origin = e.origin ?? "" }
        }
        .onDisappear { password = "" }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var input = VaultEntryInput()
        input.displayName = name.trimmingCharacters(in: .whitespaces)
        input.origin = origin.isEmpty ? nil : origin.trimmingCharacters(in: .whitespaces)
        input.credentialType = "website"
        if !username.isEmpty || entry == nil { input.username = username }
        if !password.isEmpty { input.password = password }
        if !notes.isEmpty { input.notes = notes }
        do {
            try await store.save(input, id: entry?.id)
            password = ""
            Haptics.success()
            dismiss()
        } catch is CancellationError {
        } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
    }

    static func generate() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_.!@#")
        return String((0..<20).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

/// The single passphrase step of the unified confirmation (first activation on a device, or no biometrics).
public struct PassphraseSheet: View {
    let request: OwnerConfirmController.PassphraseRequest
    let onAnswer: (String?, Bool) -> Void
    @State private var passphrase = ""
    @State private var remember = true
    @FocusState private var focused: Bool

    public init(request: OwnerConfirmController.PassphraseRequest, onAnswer: @escaping (String?, Bool) -> Void) {
        self.request = request
        self.onAnswer = onAnswer
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: NSpace.s) {
                        Image(systemName: "lock.shield.fill").font(.largeTitle).foregroundStyle(NColor.accent)
                        Text(request.reason).font(.headline)
                        Text(request.firstActivation
                             ? "Enter the vault password once. After that you unlock the vault on this device with \(request.biometricLabel) only."
                             : "Biometric authentication is not available on this device. Enter the vault password.")
                            .font(.callout).foregroundStyle(NColor.textSecondary)
                    }
                    .padding(.vertical, NSpace.s)
                }
                Section {
                    SecureField("Vault password", text: $passphrase)
                        .textContentType(.password)
                        .focused($focused)
                        .onSubmit(submit)
                    if request.firstActivation {
                        Toggle("Next time only \(request.biometricLabel)", isOn: $remember)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Confirmation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { passphrase = ""; onAnswer(nil, false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: submit).disabled(passphrase.count < 1)
                }
            }
            .onAppear { focused = true }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        .interactiveDismissDisabled()
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        let p = passphrase
        passphrase = ""
        onAnswer(p, remember)
    }
}
