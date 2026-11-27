import NEBULACore
import NEBULADesignSystem
import SwiftUI

/// One agent: header with state and quick actions (Chat, Live Desktop, Pause/Resume, Sleep/Wake), the current task
/// with stop / pause / resume, model and permissions, recent tasks. Navigation-agnostic: the app shell's stack hosts it.
public struct AgentDetailView: View {
    let store: AgentsStore
    let agentID: String
    let onOpenChat: (String) -> Void
    let onOpenDesktop: (String) -> Void
    let onOpenTask: ((String) -> Void)?

    @State private var editing = false
    @State private var sheetTask: TaskItem?
    @State private var confirmStop: TaskItem?
    @State private var banner: BannerContent?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameter onOpenTask: push `TaskDetailView(store:taskID:)` in the shell's own stack; when nil the task opens
    ///   in a sheet.
    public init(store: AgentsStore, agentID: String, onOpenChat: @escaping (String) -> Void,
                onOpenDesktop: @escaping (String) -> Void, onOpenTask: ((String) -> Void)? = nil) {
        self.store = store
        self.agentID = agentID
        self.onOpenChat = onOpenChat
        self.onOpenDesktop = onOpenDesktop
        self.onOpenTask = onOpenTask
    }

    public var body: some View {
        Group {
            if let agent = store.agent(agentID) {
                content(agent)
            } else if store.showsSkeleton || store.phase == .loading {
                DetailSkeleton()
            } else {
                ContentUnavailableView {
                    Label("Agent not found", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("It may have been deleted in the meantime.")
                }
            }
        }
        .task(id: agentID) { await store.loadDetail(agentID) }
    }

    // MARK: content

    private func content(_ agent: Agent) -> some View {
        Form {
            header(agent)
            if agent.activity == .error, let err = agent.lastError.nonEmpty {
                Section {
                    NBanner(AText.sanitize(err, max: 400), style: .danger)
                        .listRowInsets(EdgeInsets(top: NSpace.s, leading: NSpace.s, bottom: NSpace.s, trailing: NSpace.s))
                }
            }
            if let ref = agent.currentTask {
                currentTaskSection(agent, ref: ref)
            }
            infoSection(agent)
            recentTasksSection(agent)
        }
        .agentsFormStyle()
        .navigationTitle(Text(agent.name))
        .inlineTitle()
        .refreshable { await store.loadDetail(agentID) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .keyboardShortcut("e", modifiers: .command)
                .help(Text("Edit agent (⌘E)"))
                .disabled(agent.activity == .busy)
            }
            #if os(macOS)
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await store.loadDetail(agentID) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(Text("Refresh (⌘R)"))
            }
            #endif
        }
        .transientBanner($banner)
        .sheet(isPresented: $editing) {
            AgentEditorSheet(store: store, agentID: agentID)
        }
        .sheet(item: $sheetTask) { item in
            TaskDetailSheet(store: store, taskID: item.id)
        }
        .confirmationDialog(Text("Stop the task?"), isPresented: Binding(get: { confirmStop != nil },
                                                                        set: { if !$0 { confirmStop = nil } }),
                            titleVisibility: .visible, presenting: confirmStop) { item in
            Button("Stop task", role: .destructive) {
                Task {
                    banner = .from(await store.perform(.stop, taskID: item.id),
                                   success: String(localized: "Task stopped"))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The agent will stop working and the task will be cancelled. Completed steps stay in the history.")
        }
    }

    // MARK: header

    private func header(_ agent: Agent) -> some View {
        Section {
            VStack(spacing: NSpace.m) {
                AgentAvatarView(agent: agent, size: 76)
                    .nAppear()
                VStack(spacing: NSpace.xs) {
                    Text(agent.name).font(NFont.title).foregroundStyle(NColor.textPrimary)
                        .multilineTextAlignment(.center)
                    AgentStatusLine(agent: agent, stage: store.stage(for: agent.id))
                    if let d = agent.description.nonEmpty {
                        Text(d).font(.callout).foregroundStyle(NColor.textSecondary)
                            .multilineTextAlignment(.center).lineLimit(4)
                            .padding(.top, NSpace.xxs)
                    }
                }
                .accessibilityElement(children: .combine)
                quickActions(agent)
                    .padding(.top, NSpace.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NSpace.s)
            .nAnimation(NMotion.smooth, value: agent.state)
        }
        .modifier(ClearRowBackground())
    }

    private func quickActions(_ agent: Agent) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: NSpace.s),
                            count: typeSize.isAccessibilitySize ? 2 : 4)
        let paused = agent.state == "PAUSED"
        let sleeping = agent.activity == .sleeping
        let busy = store.isBusy(agent.id)
        let blocked = agent.activity == .busy
        return LazyVGrid(columns: columns, spacing: NSpace.s) {
            QuickActionTile(title: String(localized: "Chat"), symbol: "bubble.left.and.bubble.right.fill",
                            enabled: !blocked) { onOpenChat(agent.id) }
            QuickActionTile(title: String(localized: "Live Desktop"), symbol: "display",
                            enabled: !blocked) { onOpenDesktop(agent.id) }
            QuickActionTile(title: paused ? String(localized: "Resume") : String(localized: "Pause"),
                            symbol: paused ? "play.fill" : "pause.fill",
                            tint: paused ? NColor.success : NColor.warning,
                            busy: busy, enabled: !blocked && !sleeping) {
                run(paused ? .resume : .pause, agent)
            }
            QuickActionTile(title: sleeping ? String(localized: "Wake") : String(localized: "Put to sleep"),
                            symbol: sleeping ? "sun.max.fill" : "moon.fill", tint: Color.indigo,
                            busy: busy, enabled: !blocked && (sleeping || agent.activity != .working)) {
                run(sleeping ? .wake : .sleep, agent)
            }
        }
    }

    // MARK: current task

    private func currentTaskSection(_ agent: Agent, ref: TaskRef) -> some View {
        let task = store.currentTask(of: agent.id)
        let stage = store.stage(for: agent.id).flatMap { $0.taskID == ref.id ? $0 : nil }
        let paused = TaskStates.paused.contains(ref.state)
        let busy = store.isTaskBusy(ref.id)
        return Section {
            VStack(alignment: .leading, spacing: NSpace.s) {
                HStack(spacing: NSpace.s) {
                    Image(systemName: AText.taskSymbol(ref.state)).foregroundStyle(AText.taskColor(ref.state))
                    if let stage, !paused {
                        StageText(stage: stage).font(.subheadline.weight(.semibold)).foregroundStyle(NColor.accent)
                    } else {
                        Text(NText.taskState(ref.state)).font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                if let prompt = task?.prompt.nonEmptyText {
                    Text(prompt).font(.body).foregroundStyle(NColor.textPrimary).lineLimit(4)
                } else {
                    Skeleton().frame(height: 12).frame(maxWidth: 220)
                }
                if let detail = stage?.detail.nonEmpty {
                    Text(AText.sanitize(detail, max: 200)).font(.footnote).foregroundStyle(NColor.textSecondary)
                }
                if let step = task?.currentStep, step > 0 {
                    if let max = task?.maxSteps, max > 0 {
                        ProgressView(value: Double(min(step, max)), total: Double(max)) {
                            Text("Step \(step) of \(max)").font(.caption).foregroundStyle(NColor.textSecondary)
                        }
                        .tint(NColor.accent)
                    } else {
                        Text("Step \(step)").font(.caption).foregroundStyle(NColor.textSecondary)
                    }
                }
            }
            .padding(.vertical, NSpace.xs)
            .accessibilityElement(children: .combine)
            .id(ref.id)
            .onAppear { store.watchTask(ref.id) }
            .onDisappear { store.unwatchTask(ref.id) }
            .task(id: ref.id) { if store.taskDetails[ref.id] == nil { await store.loadTask(ref.id) } }

            HStack(spacing: NSpace.s) {
                Button {
                    Haptics.tap()
                    Task {
                        banner = .from(await store.perform(paused ? .resume : .pause, taskID: ref.id))
                    }
                } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(paused ? NColor.success : NColor.warning)
                Button(role: .destructive) {
                    confirmStop = TaskItem(id: ref.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(NColor.danger)
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            .labelStyle(.titleAndIcon)

            Button {
                open(ref.id)
            } label: {
                HStack {
                    Text("Details and steps")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        .foregroundStyle(NColor.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(NColor.accent)
        } header: {
            Text("Working now")
        }
    }

    // MARK: info

    private func infoSection(_ agent: Agent) -> some View {
        Section {
            InfoRow(title: String(localized: "Provider"), value: AText.provider(agent.providerId, options: store.options),
                    symbol: "cloud")
            InfoRow(title: String(localized: "Model"), value: agent.modelId.nonEmpty ?? String(localized: "Not selected"),
                    symbol: "cpu", mono: agent.modelId.nonEmpty != nil)
            InfoRow(title: String(localized: "Permissions"), value: AText.level(agent.permissionLevel), symbol: "lock.shield")
            if let signIn = agent.config?.signInAssistance {
                InfoRow(title: String(localized: "Smart sign-in"),
                        value: signIn ? String(localized: "Ask") : String(localized: "Off"), symbol: "key")
            }
            if let mem = agent.config?.memoryAutoSave {
                InfoRow(title: String(localized: "Memory"),
                        value: mem ? String(localized: "On") : String(localized: "Off"), symbol: "brain")
            }
            if let res = agent.desktopResolution.nonEmpty {
                InfoRow(title: String(localized: "Desktop"), value: res.replacingOccurrences(of: "x", with: " × "),
                        symbol: "display")
            }
            if let created = agent.createdAt {
                InfoRow(title: String(localized: "Created"),
                        value: created.date.formatted(date: .abbreviated, time: .omitted), symbol: "calendar")
            }
        } header: {
            Text("Settings")
        }
    }

    // MARK: recent tasks

    private func recentTasksSection(_ agent: Agent) -> some View {
        let tasks = (store.recentTasks[agent.id] ?? []).filter { $0.id != agent.currentTask?.id }.prefix(12)
        let phase = store.tasksPhase[agent.id] ?? .idle
        return Section {
            if tasks.isEmpty {
                switch phase {
                case .idle, .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: NSpace.s) {
                            Skeleton().frame(height: 12)
                            Skeleton().frame(width: 120, height: 10)
                        }
                        .padding(.vertical, NSpace.xs)
                    }
                case .failed(let msg):
                    HStack {
                        Text(msg).font(.callout).foregroundStyle(NColor.textSecondary)
                        Spacer()
                        Button("Try again") { Task { await store.loadTasks(for: agent.id) } }
                            .buttonStyle(.borderless)
                    }
                case .loaded:
                    Text("No completed tasks yet.").font(.callout).foregroundStyle(NColor.textSecondary)
                }
            } else {
                ForEach(Array(tasks)) { t in
                    Button { open(t.id) } label: { TaskRow(task: t) }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: NRadius.s)
                }
            }
        } header: {
            Text("Latest tasks")
        }
    }

    // MARK: actions

    private func open(_ taskID: String) {
        Haptics.selection()
        if let onOpenTask { onOpenTask(taskID) } else { sheetTask = TaskItem(id: taskID) }
    }

    private func run(_ cmd: AgentsStore.AgentCommand, _ agent: Agent) {
        Task { banner = .from(await store.perform(cmd, agentID: agent.id)) }
    }
}

struct TaskItem: Identifiable, Hashable { let id: String }

/// A task in a list: state icon, the prompt, when and how it ended.
struct TaskRow: View {
    let task: AgentTask

    var body: some View {
        HStack(alignment: .top, spacing: NSpace.m) {
            Image(systemName: AText.taskSymbol(task.state))
                .font(.body)
                .foregroundStyle(AText.taskColor(task.state))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.prompt.nonEmptyText ?? String(localized: "(no prompt)"))
                    .font(.callout).foregroundStyle(NColor.textPrimary).lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(NText.taskState(task.state))
                    Text("·")
                    Text(NFormat.relativeTime(task.finishedAt ?? task.createdAt))
                    if let d = duration { Text("·"); Text(d) }
                }
                .font(.caption).foregroundStyle(NColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(NColor.textTertiary)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NSpace.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var duration: String? {
        guard let s = task.startedAt, let f = task.finishedAt, f >= s else { return nil }
        return NFormat.duration(ms: (f - s) * 1000)
    }
}

/// Header rows float on the grouped background on iOS (like Contacts); on the Mac they stay in their group box.
struct ClearRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        #else
        content
        #endif
    }
}

private struct DetailSkeleton: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: NSpace.m) {
                    Skeleton(cornerRadius: 38).frame(width: 76, height: 76)
                    Skeleton().frame(width: 160, height: 18)
                    Skeleton().frame(width: 100, height: 12)
                    HStack(spacing: NSpace.s) {
                        ForEach(0..<4, id: \.self) { _ in Skeleton(cornerRadius: NRadius.m).frame(height: 58) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, NSpace.s)
            }
            .modifier(ClearRowBackground())
            Section {
                ForEach(0..<4, id: \.self) { _ in Skeleton().frame(height: 14) }
            }
        }
        .agentsFormStyle()
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }
}

extension String {
    var nonEmptyText: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// MARK: - Previews

#Preview("Agent is working") {
    NavigationStack {
        AgentDetailView(store: PreviewData.store(), agentID: "a1", onOpenChat: { _ in }, onOpenDesktop: { _ in })
    }
}

#Preview("Agent is asleep") {
    NavigationStack {
        AgentDetailView(store: PreviewData.store(), agentID: "a3", onOpenChat: { _ in }, onOpenDesktop: { _ in })
    }
}
