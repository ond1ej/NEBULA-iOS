import NEBULACore
import NEBULADesignSystem
import SwiftUI

/// All agents: working first, then by recent activity; live state and stage from events. Selection-driven (the app
/// shell decides what selecting an agent does: show its detail, or pick it for a new conversation).
public struct AgentsListView: View {
    let store: AgentsStore
    @Binding var selection: String?

    @State private var query = ""
    @State private var banner: BannerContent?
    @State private var creating = false
    @State private var editingID: String?
    @State private var createdID: String?

    public init(store: AgentsStore, selection: Binding<String?>) {
        self.store = store
        self._selection = selection
    }

    public var body: some View {
        let items = store.filtered(query)
        List(selection: $selection) {
            if store.showsSkeleton {
                ForEach(0..<6, id: \.self) { _ in SkeletonRow().listRowSeparator(.hidden) }
            } else {
                if let err = store.refreshError {
                    NBanner(err, style: .warning, symbol: "wifi.exclamationmark")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
                ForEach(items) { agent in
                    AgentRow(agent: agent, stage: store.stage(for: agent.id), busy: store.isBusy(agent.id))
                        .tag(agent.id)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe(agent) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingSwipe(agent) }
                        .contextMenu { menu(agent) }
                }
            }
        }
        .modifier(AgentsListStyle())
        .nAnimation(NMotion.smooth, value: items.map(\.id))
        .overlay { overlay(items) }
        .searchable(text: $query, prompt: Text("Search agents"))
        .refreshable { await store.refresh() }
        .navigationTitle(Text("Agents"))
        .toolbar { toolbar }
        .transientBanner($banner)
        .task { await store.load() }
        .onChange(of: store.agents.map(\.id)) { _, ids in
            if let s = selection, store.phase == .loaded, !ids.contains(s) { selection = nil }
            if let c = createdID, ids.contains(c) {
                selection = c
                createdID = nil
            }
        }
        .sheet(isPresented: $creating) {
            AgentEditorSheet(store: store, agentID: nil) { id in createdID = id; selection = id }
        }
        .sheet(item: Binding(get: { editingID.map(EditorItem.init) }, set: { editingID = $0?.id })) { item in
            AgentEditorSheet(store: store, agentID: item.id)
        }
    }

    // MARK: pieces

    @ViewBuilder
    private func overlay(_ items: [Agent]) -> some View {
        if case .failed(let msg) = store.phase, store.agents.isEmpty {
            ContentUnavailableView {
                Label("Could not load agents", systemImage: "exclamationmark.triangle")
            } description: {
                Text(msg)
            } actions: {
                Button("Try again") { Task { await store.refresh() } }.buttonStyle(.borderedProminent)
            }
        } else if store.phase == .loaded && store.agents.isEmpty {
            ContentUnavailableView {
                Label("No agents yet", systemImage: "person.2.badge.plus")
            } description: {
                Text("Create your first agent. It gets its own desktop and browser in the Ubuntu VM.")
            } actions: {
                Button("New agent") { creating = true }.buttonStyle(.borderedProminent)
            }
        } else if !query.isEmpty && items.isEmpty && !store.agents.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                creating = true
            } label: {
                Label("New agent", systemImage: "plus")
            }
            .help(Text("Create a new agent"))
        }
        #if os(macOS)
        ToolbarItem(placement: .automatic) {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Refresh agent list (⌘R)"))
        }
        #endif
    }

    @ViewBuilder
    private func leadingSwipe(_ agent: Agent) -> some View {
        if agent.state == "PAUSED" {
            Button { run(.resume, agent) } label: { Label("Resume", systemImage: "play.fill") }
                .tint(NColor.success)
        } else if agent.activity != .sleeping && agent.activity != .busy {
            Button { run(.pause, agent) } label: { Label("Pause", systemImage: "pause.fill") }
                .tint(NColor.warning)
        }
    }

    @ViewBuilder
    private func trailingSwipe(_ agent: Agent) -> some View {
        if agent.activity == .sleeping {
            Button { run(.wake, agent) } label: { Label("Wake", systemImage: "sun.max.fill") }
                .tint(NColor.accent)
        } else if agent.activity != .working && agent.activity != .busy {
            Button { run(.sleep, agent) } label: { Label("Put to sleep", systemImage: "moon.fill") }
                .tint(Color.indigo)
        }
        Button { editingID = agent.id } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            .tint(Color.gray)
    }

    @ViewBuilder
    private func menu(_ agent: Agent) -> some View {
        if agent.state == "PAUSED" {
            Button { run(.resume, agent) } label: { Label("Resume", systemImage: "play.fill") }
        } else if agent.activity != .sleeping {
            Button { run(.pause, agent) } label: { Label("Pause", systemImage: "pause.fill") }
                .disabled(agent.activity == .busy)
        }
        if agent.activity == .sleeping {
            Button { run(.wake, agent) } label: { Label("Wake", systemImage: "sun.max.fill") }
        } else {
            Button { run(.sleep, agent) } label: { Label("Put to sleep", systemImage: "moon.fill") }
                .disabled(agent.activity == .working || agent.activity == .busy)
        }
        if let t = agent.currentTask, !TaskStates.paused.contains(t.state) {
            Button(role: .destructive) {
                Task { banner = .from(await store.perform(.stop, taskID: t.id), success: String(localized: "Task stopped")) }
            } label: {
                Label("Stop task", systemImage: "stop.fill")
            }
        }
        Divider()
        Button { editingID = agent.id } label: { Label("Edit…", systemImage: "slider.horizontal.3") }
    }

    private func run(_ cmd: AgentsStore.AgentCommand, _ agent: Agent) {
        Haptics.tap()
        Task { banner = .from(await store.perform(cmd, agentID: agent.id)) }
    }
}

private struct EditorItem: Identifiable { let id: String }

private struct AgentsListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listStyle(.insetGrouped)
        #else
        content.listStyle(.inset)
        #endif
    }
}

/// One agent row: avatar, name, status dot + state (live stage while working), last activity.
struct AgentRow: View {
    let agent: Agent
    let stage: AgentStage?
    let busy: Bool
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 44

    var body: some View {
        HStack(spacing: NSpace.m) {
            AgentAvatarView(agent: agent, size: avatarSize)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: NSpace.s) {
                    Text(agent.name).font(NFont.headline).foregroundStyle(NColor.textPrimary).lineLimit(1)
                    Spacer(minLength: NSpace.xs)
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if let t = agent.lastActiveAt, agent.activity != .working {
                        Text(NFormat.listTime(t)).font(.caption).foregroundStyle(NColor.textTertiary)
                    }
                }
                AgentStatusLine(agent: agent, stage: stage)
                if let sub = subtitle {
                    Text(sub.text).font(.footnote).foregroundStyle(sub.danger ? NColor.danger : NColor.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, NSpace.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(busy ? String(localized: "Action in progress") : ""))
    }

    private var subtitle: (text: String, danger: Bool)? {
        if agent.activity == .error, let e = agent.lastError.nonEmpty { return (AText.sanitize(e, max: 120), true) }
        if agent.activity == .working { return nil }
        if let d = agent.description.nonEmpty { return (d, false) }
        return nil
    }
}

// MARK: - Previews

#Preview("Agents") {
    NavigationStack {
        AgentsListView(store: PreviewData.store(), selection: .constant("a1"))
    }
}

#Preview("Loading") {
    NavigationStack {
        AgentsListView(store: PreviewData.emptyStore(), selection: .constant(nil))
    }
}
