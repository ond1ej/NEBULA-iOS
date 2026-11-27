import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import SwiftUI

/// One conversation: history (lazy, anchored at the bottom, older pages on demand), live agent activity with
/// streamed text, and the composer.
public struct ConversationView: View {
    @Bindable var store: ConversationStore
    let agentAvatar: AvatarSpec?
    let onOpenDesktop: ((String) -> Void)?
    let onOpenSignIn: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var nearBottom = true
    @State private var draft = ""

    public init(store: ConversationStore, agentAvatar: AvatarSpec? = nil, onOpenDesktop: ((String) -> Void)? = nil,
                onOpenSignIn: ((String) -> Void)? = nil) {
        self.store = store
        self.agentAvatar = agentAvatar
        self.onOpenDesktop = onOpenDesktop
        self.onOpenSignIn = onOpenSignIn
    }

    private var agentName: String { store.conversation?.agentName ?? "" }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: NSpace.s) {
                if store.loadingInitial {
                    ForEach(0..<6, id: \.self) { i in MessageSkeleton(isUser: i % 3 == 1) }
                } else {
                    if store.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity).padding(.vertical, NSpace.m)
                            .onAppear { Task { await store.loadOlder() } }
                    } else if store.messages.isEmpty && store.pending.isEmpty {
                        ConversationIntro(name: agentName, avatar: agentAvatar, seed: store.agentID).padding(.top, NSpace.xxl)
                    }
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { index, m in
                        MessageRow(message: m, agentName: agentName, avatar: agentAvatar, seed: store.agentID,
                                   showsAvatar: showsAvatar(at: index),
                                   showsDate: showsDate(at: index))
                            .equatable()
                            .id(m.id)
                    }
                    ForEach(store.pending) { p in
                        PendingRow(pending: p, onRetry: { store.retry(p.clientID) },
                                   onDiscard: { store.discard(p.clientID) })
                            .id(p.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if let a = store.activity {
                        ActivityRow(activity: a, agentName: agentName, avatar: agentAvatar, seed: store.agentID,
                                    onStop: { Task { await store.stop() } },
                                    onPause: { Task { await store.pause() } },
                                    onResume: { Task { await store.resume() } },
                                    onOpenDesktop: onOpenDesktop.map { open in { if let id = store.agentID { open(id) } } })
                            .id("activity")
                            .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, NSpace.l)
            .padding(.vertical, NSpace.m)
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentSize.height - (g.contentOffset.y + g.containerSize.height) < 160
        } action: { _, near in nearBottom = near }
        .onChange(of: store.bottomRevision) { _, _ in
            guard nearBottom else { return }
            withAnimation(NMotion.animation(NMotion.smooth, reduceMotion: reduceMotion)) { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: store.activity?.streamedLength ?? 0) { _, _ in
            if nearBottom { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !nearBottom {
                Button {
                    Haptics.tap()
                    withAnimation(NMotion.smooth) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down").font(.callout.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .nGlass(cornerRadius: 20)
                }
                .buttonStyle(.plain)
                .padding(NSpace.l)
                .accessibilityLabel(Text("Scroll to the end of the conversation"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: NSpace.s) {
                if let e = store.error {
                    NBanner(e, style: .warning).padding(.horizontal, NSpace.l)
                        .onTapGesture { store.error = nil }
                }
                ComposerView(text: $draft, isRunning: store.activity != nil, agentName: agentName,
                             onSend: { text, attachments in
                                 Haptics.soft()
                                 store.send(text, attachments: attachments)
                             },
                             onStop: { Task { await store.stop() } },
                             upload: { name, mime, data in try await store.upload(fileName: name, mime: mime, data: data) })
            }
        }
        .background(NColor.background)
        .nAnimation(NMotion.smooth, value: store.pending)
        .nAnimation(NMotion.smooth, value: store.activity?.taskID)
        .task { await store.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.fetchLatest() } }
        }
        .onDisappear { store.close() }
    }

    private func showsAvatar(at i: Int) -> Bool {
        let m = store.messages[i]
        guard !m.isUser else { return false }
        guard i + 1 < store.messages.count else { return true }
        return store.messages[i + 1].isUser
    }

    private func showsDate(at i: Int) -> Bool {
        guard i > 0 else { return true }
        return store.messages[i].createdAt - store.messages[i - 1].createdAt > 3600
    }
}

// MARK: - Rows

struct MessageRow: View, Equatable {
    let message: Message
    let agentName: String
    let avatar: AvatarSpec?
    let seed: String?
    let showsAvatar: Bool
    let showsDate: Bool

    nonisolated static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && a.showsAvatar == b.showsAvatar && a.showsDate == b.showsDate &&
            a.agentName == b.agentName
    }

    var body: some View {
        VStack(spacing: NSpace.xs) {
            if showsDate {
                Text(message.createdAt.date.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                    .font(.caption2.weight(.medium)).foregroundStyle(NColor.textTertiary)
                    .padding(.vertical, NSpace.s)
            }
            if message.role == "system" {
                Text(message.content).font(.footnote).foregroundStyle(NColor.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, NSpace.xl)
            } else if message.isUser {
                HStack {
                    Spacer(minLength: 48)
                    UserBubble(text: message.content, attachments: message.attachments)
                }
            } else {
                HStack(alignment: .bottom, spacing: NSpace.s) {
                    Group {
                        if showsAvatar { NAvatar(name: agentName, spec: avatar, seed: seed, size: 28) } else { Color.clear }
                    }.frame(width: 28, height: 28)
                    AssistantBubble(message: message)
                    Spacer(minLength: 24)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct UserBubble: View {
    let text: String
    let attachments: [MessageAttachment]
    var body: some View {
        VStack(alignment: .trailing, spacing: NSpace.xs) {
            ForEach(attachments) { a in AttachmentChip(attachment: a, onAccent: true) }
            if !text.isEmpty && text != "📎" {
                Text(text)
                    .font(.body)
                    .foregroundStyle(NColor.onAccent)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(NColor.accentGradient, in: BubbleShape(isUser: true))
        .contextMenu { CopyButton(text: text) }
        .accessibilityLabel(Text("You: \(text)"))
    }
}

struct AssistantBubble: View {
    let message: Message
    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.s) {
            MarkdownView(text: message.content, isStreaming: false, id: message.id)
            ForEach(message.attachments) { a in AttachmentChip(attachment: a, onAccent: false) }
            if let t = message.task, t.state == "FAILED", let reason = t.failureReason, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(NColor.danger)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(NColor.bubbleAssistant, in: BubbleShape(isUser: false))
        .overlay(BubbleShape(isUser: false).stroke(NColor.separator.opacity(0.5), lineWidth: 0.5))
        .contextMenu { CopyButton(text: message.content) }
    }
}

struct CopyButton: View {
    let text: String
    var body: some View {
        Button {
            Pasteboard.copy(text)
            Haptics.success()
        } label: { Label("Copy", systemImage: "doc.on.doc") }
    }
}

/// Continuous-corner bubble with a slightly tighter corner towards the sender.
struct BubbleShape: Shape {
    let isUser: Bool
    func path(in r: CGRect) -> Path {
        let big = NRadius.bubble, small: CGFloat = 6
        return Path(roundedRect: r, cornerRadii: RectangleCornerRadii(
            topLeading: big, bottomLeading: isUser ? big : small, bottomTrailing: isUser ? small : big,
            topTrailing: big), style: .continuous)
    }
}

struct PendingRow: View {
    let pending: PendingMessage
    let onRetry: () -> Void
    let onDiscard: () -> Void
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: NSpace.xs) {
                UserBubble(text: pending.content, attachments: [])
                    .opacity(pending.failed == nil ? 0.75 : 1)
                if let f = pending.failed {
                    HStack(spacing: NSpace.s) {
                        Text(f).font(.caption).foregroundStyle(NColor.danger).lineLimit(2)
                        Button("Try again", action: onRetry).font(.caption.weight(.semibold))
                        Button(role: .destructive, action: onDiscard) { Image(systemName: "xmark") }
                            .font(.caption).accessibilityLabel(Text("Discard"))
                    }
                } else {
                    Label("Sending", systemImage: "clock").font(.caption2).foregroundStyle(NColor.textTertiary)
                        .labelStyle(.iconOnly).accessibilityLabel(Text("Sending"))
                }
            }
        }
    }
}

/// The agent at work: live stage + elapsed time + streamed text, and task controls.
struct ActivityRow: View {
    let activity: LiveActivity
    let agentName: String
    let avatar: AvatarSpec?
    let seed: String?
    let onStop: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onOpenDesktop: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: NSpace.s) {
            NAvatar(name: agentName, spec: avatar, seed: seed, size: 28)
            VStack(alignment: .leading, spacing: NSpace.s) {
                if !activity.streamedText.isEmpty {
                    MarkdownView(text: activity.streamedText, isStreaming: true, id: "live-\(activity.taskID)")
                } else {
                    TypingIndicator()
                }
                HStack(spacing: NSpace.s) {
                    StatusDot(color: activity.isPaused ? NColor.warning : NColor.accent, pulsing: !activity.isPaused)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(statusLine(now: ctx.date)).font(.caption).foregroundStyle(NColor.textSecondary)
                            .monospacedDigit().contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                    controls
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(NColor.bubbleAssistant, in: BubbleShape(isUser: false))
            .overlay(BubbleShape(isUser: false).stroke(NColor.accent.opacity(0.25), lineWidth: 0.75))
            Spacer(minLength: 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(agentName) is working"))
    }

    private func statusLine(now: Date) -> String {
        let label = activity.isPaused ? NText.taskState(activity.state)
            : activity.isWaiting ? NText.taskState(activity.state)
            : activity.stage.map(NText.stage) ?? NText.taskState(activity.state)
        guard let ms = activity.elapsedMs else { return label }
        let total = ms + (activity.isPaused ? 0 : now.timeIntervalSince(activity.stageAt) * 1000)
        return "\(label) · \(NFormat.duration(ms: total))"
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 2) {
            if let onOpenDesktop {
                iconButton("display", "Live Desktop", onOpenDesktop)
            }
            if activity.isPaused {
                iconButton("play.fill", "Resume", onResume)
            } else {
                iconButton("pause.fill", "Pause", onPause)
            }
            iconButton("stop.fill", "Stop", onStop, tint: NColor.danger)
        }
    }

    private func iconButton(_ symbol: String, _ label: LocalizedStringKey, _ action: @escaping () -> Void,
                            tint: Color = NColor.textSecondary) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol).font(.caption.weight(.bold)).frame(width: 30, height: 30)
                .background(Circle().fill(NColor.surfaceSunken))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .accessibilityLabel(Text(label))
        #if os(macOS)
        .help(Text(label))
        #endif
    }
}

struct MessageSkeleton: View {
    let isUser: Bool
    var body: some View {
        HStack {
            if isUser { Spacer() }
            VStack(alignment: .leading, spacing: 6) {
                Skeleton().frame(width: isUser ? 140 : 220, height: 12)
                Skeleton().frame(width: isUser ? 90 : 260, height: 12)
                if !isUser { Skeleton().frame(width: 180, height: 12) }
            }
            .padding(12)
            .background(BubbleShape(isUser: isUser).fill(NColor.surface))
            if !isUser { Spacer() }
        }
    }
}

struct ConversationIntro: View {
    let name: String
    let avatar: AvatarSpec?
    var seed: String? = nil
    var body: some View {
        VStack(spacing: NSpace.m) {
            NAvatar(name: name, spec: avatar, seed: seed, size: 72)
            Text(name).font(NFont.title)
            Text("Write a task. The agent carries it out in its own isolated environment, and you follow the progress here.")
                .font(.callout).foregroundStyle(NColor.textSecondary).multilineTextAlignment(.center)
                .padding(.horizontal, NSpace.xl)
        }
        .frame(maxWidth: .infinity)
        .nAppear()
    }
}

struct AttachmentChip: View {
    let attachment: MessageAttachment
    let onAccent: Bool
    var body: some View {
        let (icon, title): (String, String) = {
            switch attachment {
            case .artifact(let ref):
                return ("photo", (ref as NSString).lastPathComponent)
            case .file(let a):
                if a.isAudio { return ("waveform", a.transcript ?? String(localized: "Voice message")) }
                if a.isImage { return ("photo", a.name ?? String(localized: "Image")) }
                return ("doc", a.name ?? String(localized: "File"))
            }
        }()
        Label(title, systemImage: icon)
            .font(.footnote).lineLimit(2)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(onAccent ? Color.white.opacity(0.18) : NColor.surfaceSunken))
            .foregroundStyle(onAccent ? NColor.onAccent : NColor.textPrimary)
    }
}

/// Cross-platform pasteboard. Copied passwords never go through here (the vault uses an expiring copy).
public enum Pasteboard {
    @MainActor
    public static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}
