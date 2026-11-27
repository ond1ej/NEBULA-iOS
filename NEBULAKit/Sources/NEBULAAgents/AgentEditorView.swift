import NEBULACore
import NEBULADesignSystem
import SwiftUI

/// Create (agentID == nil) or edit an agent through the composer endpoints: name, description, avatar, provider and
/// model, instructions, permission level, capabilities, Smart sign-in; delete (fresh owner confirmation).
///
/// Navigation-agnostic: present it inside a NavigationStack (e.g. in a sheet) so its Cancel / Save toolbar shows.
public struct AgentEditorView: View {
    let store: AgentsStore
    let agentID: String?
    let onSaved: ((String) -> Void)?
    let onDeleted: ((String) -> Void)?

    @State private var model: AgentEditorModel
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var deleting = false
    @State private var deleteError: String?
    @FocusState private var focus: AgentEditorModel.Field?
    @Environment(\.dismiss) private var dismiss

    public init(store: AgentsStore, agentID: String?, onSaved: ((String) -> Void)? = nil,
                onDeleted: ((String) -> Void)? = nil) {
        self.store = store
        self.agentID = agentID
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        self._model = State(initialValue: AgentEditorModel(agentID: agentID))
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .loading:
                EditorSkeleton()
            case .failed(let msg):
                ContentUnavailableView {
                    Label("Could not load the form", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Try again") { Task { await model.load(store: store) } }.buttonStyle(.borderedProminent)
                }
            case .ready:
                form
            }
        }
        .navigationTitle(Text(agentID == nil ? "New agent" : "Edit agent"))
        .inlineTitle()
        .toolbar { toolbar }
        .task { if model.options == nil { await model.load(store: store) } }
        #if os(iOS)
        .interactiveDismissDisabled(model.isDirty || model.saving || deleting)
        #endif
        .confirmationDialog(Text("Discard changes?"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog(Text("Delete agent “\(model.original?.name ?? "")”?"), isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete agent", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its account in the Ubuntu VM, its desktop, files and memory are deleted, and running tasks are stopped. This cannot be undone.")
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if model.isDirty { confirmDiscard = true } else { dismiss() }
            }
            .disabled(model.saving || deleting)
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.saving {
                ProgressView().controlSize(.small)
            } else {
                Button(agentID == nil ? "Create" : "Save") { Task { await save() } }
                    .disabled(model.phase != .ready || (agentID != nil && !model.isDirty) || deleting)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private func save() async {
        focus = nil
        guard let id = await model.save(store: store) else { return }
        if !id.isEmpty { onSaved?(id) }
        dismiss()
    }

    // MARK: form

    private var form: some View {
        let errors = model.visibleErrors
        return ScrollViewReader { proxy in
            Form {
                if model.saving && model.isCreate {
                    Section {
                        HStack(spacing: NSpace.m) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Setting up the agent…").font(NFont.headline)
                                Text("Its account, desktop and browser are being created in the Ubuntu VM. This usually takes under a minute.")
                                    .font(.footnote).foregroundStyle(NColor.textSecondary)
                            }
                        }
                        .padding(.vertical, NSpace.xs)
                        .accessibilityElement(children: .combine)
                    }
                }
                if let err = model.generalError {
                    Section {
                        NBanner(err, style: .danger)
                            .listRowInsets(EdgeInsets(top: NSpace.s, leading: NSpace.s, bottom: NSpace.s, trailing: NSpace.s))
                    }
                    .id("general")
                }
                avatarSection(errors)
                basicsSection(errors)
                modelSection(errors)
                instructionsSection(errors)
                levelSection(errors)
                capabilitiesSection(errors)
                vaultSection
                startSection
                if agentID != nil { deleteSection }
            }
            .agentsFormStyle()
            .disabled(model.saving || deleting)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: model.attempted ? model.visibleErrors.keys.map(\.rawValue).sorted() : []) { _, keys in
                guard let first = AgentEditorModel.Field.allCases.first(where: { keys.contains($0.rawValue) }) else { return }
                withAnimation(NMotion.smooth) { proxy.scrollTo(first, anchor: .top) }
            }
            .onChange(of: model.generalError) { _, e in
                if e != nil { withAnimation(NMotion.smooth) { proxy.scrollTo("general", anchor: .top) } }
            }
        }
        .onAppear { if agentID == nil { focus = .name } }
    }

    // MARK: avatar

    private func avatarSection(_ errors: [AgentEditorModel.Field: String]) -> some View {
        Section {
            VStack(spacing: NSpace.m) {
                AgentAvatarView(name: model.form.normalizedName.isEmpty ? "?" : model.form.normalizedName,
                                avatar: model.avatarError() == nil ? model.form.avatar : nil,
                                seed: agentID ?? "new-agent", size: 72)
                    .nAnimation(NMotion.snappy, value: model.form.avatar)
                Picker("Avatar", selection: $model.form.avatarMode) {
                    Text("Automatic").tag(AgentEditorModel.AvatarMode.auto)
                    Text("Emoji").tag(AgentEditorModel.AvatarMode.emoji)
                    Text("Initials").tag(AgentEditorModel.AvatarMode.initials)
                    Text("Icon").tag(AgentEditorModel.AvatarMode.icon)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NSpace.xs)
            .id(AgentEditorModel.Field.avatar)

            switch model.form.avatarMode {
            case .auto:
                Text("The agent's initials on a colored circle.").font(.footnote).foregroundStyle(NColor.textSecondary)
            case .emoji:
                SymbolGrid(items: AText.emojiChoices, selected: model.form.emoji) { e in
                    model.form.emoji = e
                } label: { e in
                    Text(e).font(.title2)
                }
                TextField("Custom emoji", text: $model.form.emoji)
                    .onChange(of: model.form.emoji) { _, v in
                        if v.unicodeScalars.count > 8 { model.form.emoji = String(v.prefix(1)) }
                    }
            case .initials:
                TextField("Initials (1–2 characters)", text: $model.form.initials)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .autocorrectionDisabled()
                    .onChange(of: model.form.initials) { _, v in
                        if v.count > 2 { model.form.initials = String(v.prefix(2)) }
                    }
            case .icon:
                SymbolGrid(items: model.icons, selected: model.form.icon) { i in
                    model.form.icon = i
                } label: { i in
                    Image(systemName: AText.iconSymbol(i)).font(.title3.weight(.semibold))
                        .accessibilityLabel(Text(i))
                }
            }
            if let e = errors[.avatar] { ErrorText(e) }
        } header: {
            Text("Appearance")
        }
    }

    // MARK: basics

    private func basicsSection(_ errors: [AgentEditorModel.Field: String]) -> some View {
        Section {
            TextField("Name", text: $model.form.name, prompt: Text("E.g. Researcher"))
                .focused($focus, equals: .name)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { focus = .description }
                .id(AgentEditorModel.Field.name)
            if let e = errors[.name] {
                ErrorText(e)
                if model.showsDuplicateOverride {
                    Button("Use the same name anyway") { model.allowDuplicate() }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }
            TextField("Description", text: $model.form.description, prompt: Text("What the agent is for (optional)"),
                      axis: .vertical)
                .lineLimit(1...4)
                .focused($focus, equals: .description)
                .id(AgentEditorModel.Field.description)
            if let e = errors[.description] { ErrorText(e) }
        } header: {
            Text("Basics")
        }
    }

    // MARK: model

    private func modelSection(_ errors: [AgentEditorModel.Field: String]) -> some View {
        Section {
            if model.connectedProviders.isEmpty {
                Label("No AI provider is connected", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NColor.warning)
            } else {
                Picker("Provider", selection: Binding(get: { model.form.providerID },
                                                          set: { model.selectProvider($0, store: store) })) {
                    if model.form.providerID.isEmpty { Text("Choose").tag("") }
                    ForEach(model.connectedProviders) { p in Text(p.displayName).tag(p.id) }
                    if !model.form.providerID.isEmpty,
                       !model.connectedProviders.contains(where: { $0.id == model.form.providerID }) {
                        Text("\(AText.provider(model.form.providerID, options: model.options)) (not connected)")
                            .tag(model.form.providerID)
                    }
                }
                .id(AgentEditorModel.Field.provider)
            }
            if let e = errors[.provider] { ErrorText(e) }

            if !model.form.providerID.isEmpty {
                switch model.modelsPhase {
                case .idle, .loading:
                    HStack {
                        Text("Model")
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Loading models"))
                case .failed(let msg):
                    VStack(alignment: .leading, spacing: NSpace.xs) {
                        ErrorText(msg)
                        Button("Reload") { model.loadModels(store: store, keepSelection: true, force: true) }
                            .buttonStyle(.borderless)
                    }
                case .loaded:
                    Picker("Model", selection: $model.form.modelID) {
                        if model.form.modelID.isEmpty { Text("Choose a model").tag("") }
                        ForEach(model.usableModels) { m in Text(m.displayName).tag(m.id) }
                        if !model.form.modelID.isEmpty, !model.usableModels.contains(where: { $0.id == model.form.modelID }) {
                            Text("\(model.form.modelID) (unavailable)").tag(model.form.modelID)
                        }
                    }
                    .id(AgentEditorModel.Field.model)
                }
            }
            if let e = errors[.model] { ErrorText(e) }
        } header: {
            Text("AI model")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !model.disconnectedProviders.isEmpty {
                    Text("Not connected: \(model.disconnectedProviders.map(\.displayName).joined(separator: ", ")). Connect the provider on your Mac (NEBULA Dashboard → AI Providers).")
                }
                if model.unusableModelCount > 0 {
                    Text("Hidden: \(model.unusableModelCount) models that cannot use tools.")
                }
            }
        }
    }

    // MARK: instructions

    private func instructionsSection(_ errors: [AgentEditorModel.Field: String]) -> some View {
        let count = model.form.instructions.trimmingCharacters(in: .whitespacesAndNewlines).count
        return Section {
            TextField("Instructions", text: $model.form.instructions,
                      prompt: Text(model.defaultInstructions ?? String(localized: "How the agent should work and reply")),
                      axis: .vertical)
                .lineLimit(4...14)
                .focused($focus, equals: .instructions)
                .id(AgentEditorModel.Field.instructions)
            if let e = errors[.instructions] { ErrorText(e) }
        } header: {
            Text("Agent instructions")
        } footer: {
            HStack(alignment: .top) {
                Text("These are added to the agent's system instructions, below NEBULA's safety rules.")
                Spacer(minLength: NSpace.s)
                Text("\(count) / \(model.instructionsMax)").monospacedDigit()
                    .foregroundStyle(count > model.instructionsMax ? NColor.danger : NColor.textTertiary)
            }
        }
    }

    // MARK: level

    private func levelSection(_ errors: [AgentEditorModel.Field: String]) -> some View {
        Section {
            ForEach(model.levelChoices) { lv in
                OptionRow(title: AText.level(lv.id), detail: AText.levelDescription(lv.id, fallback: lv.description),
                          selected: model.form.level == lv.id,
                          enabled: AText.levelOrder.contains(lv.id)) {
                    Haptics.selection()
                    model.setLevel(lv.id)
                }
            }
            .id(AgentEditorModel.Field.level)
            if let note = model.levelNote {
                Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(NColor.info)
            }
            if let e = errors[.level] { ErrorText(e) }
        } header: {
            Text("Permission level")
        } footer: {
            Text("Sensitive actions (payments, password changes, deleting accounts, messages to other people) always wait for your approval.")
        }
    }

    // MARK: capabilities

    private func capabilitiesSection(_ errors: [AgentEditorModel.Field: String]) -> some View {
        Section {
            ForEach(model.capabilityChoices) { c in
                CapabilityToggle(id: c.id, title: AText.capability(c.id, fallback: c.label),
                                 detail: AText.capabilityDescription(c.id, fallback: c.description),
                                 requires: c.requiresLevel.flatMap { $0 == "STANDARD" || $0 == "READ_ONLY" ? nil : $0 },
                                 isOn: Binding(get: { model.form.capabilities[c.id] ?? false },
                                               set: { model.setCapability(c.id, $0) }))
            }
            .id(AgentEditorModel.Field.capabilities)
            CapabilityToggle(id: "memory", title: AText.capability("memory", fallback: nil),
                             detail: AText.capabilityDescription("memory", fallback: model.options?.memory?.description),
                             requires: nil,
                             isOn: Binding(get: { model.form.capabilities["memory"] ?? true },
                                           set: { model.form.capabilities["memory"] = $0 }))
            ForEach(model.extraSkills) { s in
                CapabilityToggle(id: s.id, title: s.name ?? s.id, detail: s.description ?? "",
                                 requires: s.requiresLevel.flatMap { $0 == "STANDARD" || $0 == "READ_ONLY" ? nil : $0 },
                                 isOn: Binding(get: { model.form.extraSkills.contains(s.id) },
                                               set: { model.setExtraSkill(s.id, $0) }))
            }
            if let e = errors[.capabilities] { ErrorText(e) }
        } header: {
            Text("Capabilities")
        }
    }

    // MARK: vault / Smart sign-in

    private var vaultSection: some View {
        Section {
            ForEach(model.vaultChoices, id: \.self) { id in
                OptionRow(title: AText.vault(id), detail: AText.vaultDescription(id),
                          selected: model.form.vaultAccess == id, enabled: true) {
                    Haptics.selection()
                    model.form.vaultAccess = id
                }
            }
            .id(AgentEditorModel.Field.vault)
        } header: {
            Text("Smart sign-in")
        } footer: {
            Text("An agent can use saved passwords from the Vault only with a permission you create on your Mac (Agents → Security). Permissions cannot be created from the app.")
        }
    }

    // MARK: start / idle

    private var startSection: some View {
        Section {
            if model.isCreate {
                Toggle(isOn: $model.form.startActive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start immediately")
                        Text("Off: the agent goes to sleep after it is created and does not use memory.")
                            .font(.footnote).foregroundStyle(NColor.textSecondary)
                    }
                }
            }
            Picker("Sleep when idle", selection: $model.form.idleSleep) {
                Text("Default").tag(Int?.none)
                ForEach(idleChoices, id: \.self) { m in Text(idleLabel(m)).tag(Int?.some(m)) }
            }
            .id(AgentEditorModel.Field.idle)
        } header: {
            Text("Starting up")
        }
    }

    private var idleChoices: [Int] {
        var c = [15, 30, 60, 120, 240, 480, 1440]
        if let v = model.form.idleSleep, !c.contains(v) { c.append(v); c.sort() }
        return c
    }

    private func idleLabel(_ m: Int) -> String {
        if m == 0 { return String(localized: "Never") }
        if m < 60 { return String(localized: "\(m) min") }
        if m % 60 == 0 { return String(localized: "\(m / 60) h") }
        return String(localized: "\(m) min")
    }

    // MARK: delete

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                HStack {
                    Label("Delete agent…", systemImage: "trash")
                    Spacer()
                    if deleting { ProgressView().controlSize(.small) }
                }
            }
            .foregroundStyle(NColor.danger)
            if let deleteError { ErrorText(deleteError) }
        } footer: {
            Text("Deleting requires confirmation with Face ID or Touch ID.")
        }
    }

    private func delete() async {
        guard let agentID else { return }
        deleting = true
        deleteError = nil
        let r = await store.deleteAgent(agentID)
        deleting = false
        switch r {
        case .done:
            onDeleted?(agentID)
            dismiss()
        case .cancelled: break
        case .failed(let m): deleteError = m
        }
    }
}

// MARK: - Pieces

private struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(NColor.danger)
            .transition(.opacity)
            .accessibilityLabel(Text("Error: \(text)"))
    }
}

/// A single-choice row with a description and a checkmark.
private struct OptionRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: NSpace.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(enabled ? NColor.textPrimary : NColor.textTertiary)
                    if !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(NColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: NSpace.s)
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(NColor.accent)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CapabilityToggle: View {
    let id: String
    let title: String
    let detail: String
    let requires: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: NSpace.m) {
                Image(systemName: AText.capabilitySymbol(id)).foregroundStyle(NColor.accent).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(NColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let requires {
                        Text("Requires the \(AText.level(requires)) level").font(.caption.weight(.medium))
                            .foregroundStyle(NColor.warning)
                    }
                }
            }
        }
        .tint(NColor.accent)
    }
}

/// A grid of tappable choices (emoji / icons) with a selection ring.
private struct SymbolGrid<Label: View>: View {
    let items: [String]
    let selected: String
    let onSelect: (String) -> Void
    @ViewBuilder let label: (String) -> Label

    init(items: [String], selected: String, onSelect: @escaping (String) -> Void,
         @ViewBuilder label: @escaping (String) -> Label) {
        self.items = items; self.selected = selected; self.onSelect = onSelect; self.label = label
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: NSpace.s)], spacing: NSpace.s) {
            ForEach(items, id: \.self) { item in
                Button {
                    Haptics.selection()
                    onSelect(item)
                } label: {
                    label(item)
                        .foregroundStyle(item == selected ? NColor.onAccent : NColor.accent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(item == selected ? NColor.accent : NColor.accentSoft))
                        .overlay(Circle().strokeBorder(NColor.accent, lineWidth: item == selected ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(NPressableStyle())
                .accessibilityAddTraits(item == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, NSpace.xs)
    }
}

private struct EditorSkeleton: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: NSpace.m) {
                    Skeleton(cornerRadius: 36).frame(width: 72, height: 72)
                    Skeleton().frame(height: 28)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, NSpace.xs)
            }
            Section {
                Skeleton().frame(height: 14)
                Skeleton().frame(height: 14)
            }
            Section {
                Skeleton().frame(height: 14)
                Skeleton().frame(height: 14)
                Skeleton().frame(height: 14)
            }
        }
        .agentsFormStyle()
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }
}

/// The editor in its own sheet (with a navigation bar for Cancel / Save).
struct AgentEditorSheet: View {
    let store: AgentsStore
    let agentID: String?
    var onSaved: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            AgentEditorView(store: store, agentID: agentID, onSaved: onSaved)
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 600, idealHeight: 760)
        #endif
    }
}

// MARK: - Previews

#Preview("New agent") {
    NavigationStack { AgentEditorView(store: PreviewData.store(), agentID: nil) }
}
