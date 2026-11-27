import NEBULACore
import NEBULADesignSystem
import SwiftUI

/// One task: prompt, state, the steps timeline (tool, status, time), the result summary or failure reason, and the
/// owner's controls (pause / resume / stop while it runs, retry when it failed or was cancelled). Steps follow
/// `task.step` events while the view is on screen.
public struct TaskDetailView: View {
    let store: AgentsStore
    let taskID: String

    @State private var shownID: String
    @State private var banner: BannerContent?
    @State private var confirmStop = false

    public init(store: AgentsStore, taskID: String) {
        self.store = store
        self.taskID = taskID
        self._shownID = State(initialValue: taskID)
    }

    public var body: some View {
        Group {
            if let task = store.taskDetails[shownID] {
                content(task)
            } else if case .failed(let msg) = store.taskPhase[shownID] ?? .idle {
                ContentUnavailableView {
                    Label("Could not load the task", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Try again") { Task { await store.loadTask(shownID) } }
                }
            } else {
                TaskSkeleton()
            }
        }
        .navigationTitle(Text("Task"))
        .inlineTitle()
        .transientBanner($banner)
        .task(id: shownID) { await store.loadTask(shownID) }
        .onAppear { store.watchTask(shownID) }
        .onDisappear { store.unwatchTask(shownID) }
        .onChange(of: shownID) { old, new in
            store.unwatchTask(old)
            store.watchTask(new)
        }
        .onChange(of: taskID) { _, new in shownID = new }
    }

    private func content(_ task: AgentTask) -> some View {
        let running = !task.isTerminal
        let paused = TaskStates.paused.contains(task.state)
        let busy = store.isTaskBusy(task.id)
        let stage = store.stage(for: task.agentId).flatMap { $0.taskID == task.id ? $0 : nil }
        return Form {
            Section {
                VStack(alignment: .leading, spacing: NSpace.m) {
                    HStack(spacing: NSpace.s) {
                        Image(systemName: AText.taskSymbol(task.state)).font(.title3)
                            .foregroundStyle(AText.taskColor(task.state))
                        VStack(alignment: .leading, spacing: 2) {
                            if running, !paused, let stage {
                                StageText(stage: stage).font(NFont.headline).foregroundStyle(NColor.accent)
                            } else {
                                Text(NText.taskState(task.state)).font(NFont.headline)
                            }
                            Text(meta(task)).font(.caption).foregroundStyle(NColor.textSecondary)
                        }
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .accessibilityElement(children: .combine)
                    Text(task.prompt.nonEmptyText ?? String(localized: "(no prompt)"))
                        .font(.body).foregroundStyle(NColor.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, NSpace.xs)
                .nAnimation(NMotion.smooth, value: task.state)
            } header: {
                Text("Prompt")
            }

            if running || task.state == "FAILED" || task.state == "CANCELLED" {
                Section {
                    if running {
                        HStack(spacing: NSpace.s) {
                            Button {
                                Haptics.tap()
                                Task { banner = .from(await store.perform(paused ? .resume : .pause, taskID: task.id)) }
                            } label: {
                                Label(paused ? "Resume" : "Pause",
                                      systemImage: paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity)
                            }
                            .tint(paused ? NColor.success : NColor.warning)
                            Button(role: .destructive) {
                                confirmStop = true
                            } label: {
                                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                            }
                            .tint(NColor.danger)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                    } else {
                        Button {
                            Haptics.tap()
                            Task { await retry(task) }
                        } label: {
                            Label("Run again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(NColor.accent)
                        .disabled(busy)
                    }
                }
            }

            if let reason = task.failureReason.nonEmpty, task.state != "COMPLETED" {
                Section {
                    NBanner(AText.sanitize(reason, max: 600), style: task.state == "FAILED" ? .danger : .warning)
                        .listRowInsets(EdgeInsets(top: NSpace.s, leading: NSpace.s, bottom: NSpace.s, trailing: NSpace.s))
                } header: {
                    Text(task.state == "FAILED" ? "Why it failed" : "Reason")
                }
            }

            if let summary = task.summary.nonEmpty {
                Section {
                    Text(summary).font(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Result")
                }
            }

            stepsSection(task)
        }
        .agentsFormStyle()
        .refreshable { await store.loadTask(task.id) }
        .confirmationDialog(Text("Stop the task?"), isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop task", role: .destructive) {
                Task { banner = .from(await store.perform(.stop, taskID: task.id), success: String(localized: "Task stopped")) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent will stop working and the task will be cancelled. Completed steps stay in the history.")
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await store.loadTask(task.id) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif
    }

    @ViewBuilder
    private func stepsSection(_ task: AgentTask) -> some View {
        let steps = (task.steps ?? []).sorted { $0.seq < $1.seq }
        Section {
            if steps.isEmpty {
                Text(task.isTerminal ? "The task took no steps." : "The agent has not taken any steps yet.")
                    .font(.callout).foregroundStyle(NColor.textSecondary)
            } else {
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                    StepRow(step: step, first: i == 0, last: i == steps.count - 1 && task.isTerminal)
                        .listRowSeparator(.hidden)
                }
                if !task.isTerminal && !TaskStates.paused.contains(task.state) {
                    HStack(spacing: NSpace.m) {
                        ProgressView().controlSize(.small).frame(width: 28)
                        Text("Working on the next step…").font(.callout).foregroundStyle(NColor.textSecondary)
                    }
                    .listRowSeparator(.hidden)
                }
            }
        } header: {
            HStack {
                Text("Steps")
                Spacer()
                if !steps.isEmpty {
                    Text("\(steps.count)").monospacedDigit()
                }
            }
        }
    }

    private func meta(_ t: AgentTask) -> String {
        var parts: [String] = []
        if let name = t.agentName.nonEmpty ?? store.agent(t.agentId)?.name { parts.append(name) }
        parts.append(t.createdAt.date.formatted(date: .abbreviated, time: .shortened))
        if let s = t.startedAt, let f = t.finishedAt, f >= s { parts.append(NFormat.duration(ms: (f - s) * 1000)) }
        return parts.joined(separator: " · ")
    }

    private func retry(_ task: AgentTask) async {
        let r = await store.perform(.retry, taskID: task.id)
        switch r {
        case .done(let newID?):
            banner = .success(String(localized: "The task was submitted again"))
            shownID = newID
        default:
            banner = .from(r)
        }
    }
}

/// One step of the timeline: tool category icon on a vertical line, tool name, status, summary and time.
private struct StepRow: View {
    let step: TaskStep
    let first: Bool
    let last: Bool

    var body: some View {
        let tool = AText.tool(step.toolType)
        let status = AText.stepStatus(step.resultStatus)
        HStack(alignment: .top, spacing: NSpace.m) {
            VStack(spacing: 0) {
                Rectangle().fill(first ? Color.clear : NColor.separator).frame(width: 2, height: 8)
                ZStack {
                    Circle().fill(status.color.opacity(0.15))
                    Image(systemName: tool.symbol).font(.caption.weight(.semibold)).foregroundStyle(status.color)
                }
                .frame(width: 28, height: 28)
                Rectangle().fill(last ? Color.clear : NColor.separator).frame(width: 2).frame(maxHeight: .infinity)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: NSpace.s) {
                    Text(tool.label).font(.subheadline.weight(.semibold)).foregroundStyle(NColor.textPrimary)
                    Text(step.toolType).font(NFont.monoSmall).foregroundStyle(NColor.textTertiary).lineLimit(1)
                    Spacer(minLength: NSpace.xs)
                    if let ms = step.elapsedMs {
                        Text(AText.elapsed(ms: ms)).font(.caption).monospacedDigit().foregroundStyle(NColor.textTertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text("\(step.seq).").monospacedDigit()
                    Text(status.label).foregroundStyle(status.color)
                }
                .font(.caption.weight(.medium))
                if let s = step.resultSummary.nonEmpty {
                    Text(AText.sanitize(s, max: 400)).font(.footnote).foregroundStyle(NColor.textSecondary)
                        .lineLimit(4).textSelection(.enabled)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, NSpace.m)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: NSpace.l, bottom: 0, trailing: NSpace.l))
        .accessibilityElement(children: .combine)
    }
}

private struct TaskSkeleton: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: NSpace.m) {
                    Skeleton().frame(width: 140, height: 16)
                    Skeleton().frame(height: 12)
                    Skeleton().frame(width: 220, height: 12)
                }
                .padding(.vertical, NSpace.xs)
            }
            Section {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: NSpace.m) {
                        Skeleton(cornerRadius: 14).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Skeleton().frame(width: 120, height: 12)
                            Skeleton().frame(height: 10)
                        }
                    }
                }
            }
        }
        .agentsFormStyle()
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }
}

/// TaskDetailView presented in its own sheet (with its own navigation bar and a Done button).
struct TaskDetailSheet: View {
    let store: AgentsStore
    let taskID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TaskDetailView(store: store, taskID: taskID)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 720)
        #else
        .presentationDragIndicator(.visible)
        #endif
    }
}

// MARK: - Previews

#Preview("Task is running") {
    NavigationStack { TaskDetailView(store: PreviewData.store(), taskID: "t1") }
}

#Preview("Task failed") {
    NavigationStack { TaskDetailView(store: PreviewData.store(), taskID: "t3") }
}
