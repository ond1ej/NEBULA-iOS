import NEBULACore
import NEBULADesignSystem
import NEBULANetwork
import SwiftUI

/// All conversations, newest first; search across conversations and messages; archive / rename.
public struct ConversationListView: View {
    @Bindable var store: ChatListStore
    @Binding var selection: String?
    let avatarFor: (String) -> AvatarSpec?
    let onNewChat: () -> Void

    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var showArchived = false

    public init(store: ChatListStore, selection: Binding<String?>, avatarFor: @escaping (String) -> AvatarSpec?,
                onNewChat: @escaping () -> Void) {
        self.store = store
        self._selection = selection
        self.avatarFor = avatarFor
        self.onNewChat = onNewChat
    }

    public var body: some View {
        List(selection: $selection) {
            if let r = store.searchResult, !query.isEmpty {
                searchSections(r)
            } else if !store.loaded && store.loading {
                ForEach(0..<7, id: \.self) { _ in SkeletonRow().listRowSeparator(.hidden) }
            } else {
                ForEach(store.conversations) { c in
                    ConversationRow(conversation: c, avatar: avatarFor(c.agentId))
                        .tag(c.id)
                        .swipeActions(edge: .trailing) {
                            Button { Task { await store.setArchived(c.id, true) } } label: {
                                Label("Archive", systemImage: "archivebox")
                            }.tint(NColor.textSecondary)
                        }
                        .swipeActions(edge: .leading) {
                            Button { renaming = c; newTitle = c.title } label: {
                                Label("Rename", systemImage: "pencil")
                            }.tint(NColor.accent)
                        }
                        .contextMenu {
                            Button { renaming = c; newTitle = c.title } label: { Label("Rename", systemImage: "pencil") }
                            Button { Task { await store.setArchived(c.id, true) } } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        }
                }
                if store.loaded {
                    Section {
                        DisclosureGroup(isExpanded: $showArchived) {
                            ForEach(store.archived) { c in
                                ConversationRow(conversation: c, avatar: avatarFor(c.agentId)).tag(c.id)
                                    .contextMenu {
                                        Button { Task { await store.setArchived(c.id, false) } } label: {
                                            Label("Unarchive", systemImage: "tray.and.arrow.up")
                                        }
                                    }
                            }
                        } label: {
                            Label("Archived", systemImage: "archivebox").foregroundStyle(NColor.textSecondary)
                        }
                        .onChange(of: showArchived) { _, open in if open { Task { await store.loadArchived() } } }
                    }
                }
            }
        }
        .overlay {
            if store.loaded && store.conversations.isEmpty && query.isEmpty {
                EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "No conversations yet",
                               message: "Start a new conversation with one of your agents.")
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #else
        .listStyle(.sidebar)
        #endif
        .searchable(text: $query, prompt: Text("Search conversations"))
        .onChange(of: query) { _, q in store.search(q) }
        .refreshable { await store.load(force: true) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewChat) { Label("New conversation", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Save") {
                if let c = renaming { Task { await store.rename(c.id, title: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task { await store.load() }
    }

    @ViewBuilder private func searchSections(_ r: SearchResult) -> some View {
        if !r.conversations.isEmpty {
            Section("Conversations") {
                ForEach(r.conversations) { c in ConversationRow(conversation: c, avatar: avatarFor(c.agentId)).tag(c.id) }
            }
        }
        if !r.messages.isEmpty {
            Section("Messages") {
                ForEach(r.messages) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.agentName).font(.footnote.weight(.semibold))
                        Text(hit.snippet).font(.callout).foregroundStyle(NColor.textSecondary).lineLimit(2)
                    }
                    .tag(hit.conversationId)
                }
            }
        }
        if r.conversations.isEmpty && r.messages.isEmpty {
            Text("Nothing found").foregroundStyle(NColor.textSecondary)
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let avatar: AvatarSpec?

    var body: some View {
        HStack(spacing: NSpace.m) {
            ZStack(alignment: .bottomTrailing) {
                NAvatar(name: conversation.agentName, spec: avatar, seed: conversation.agentId, size: 46)
                if conversation.runningTask != nil {
                    Circle().fill(NColor.accent).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(NColor.background, lineWidth: 2))
                        .overlay(ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.5))
                        .accessibilityLabel(Text("Working"))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title.isEmpty ? conversation.agentName : conversation.title)
                        .font(.body.weight(conversation.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: NSpace.s)
                    Text(NFormat.listTime(conversation.sortDate)).font(.caption).foregroundStyle(NColor.textTertiary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(preview).font(.callout).foregroundStyle(NColor.textSecondary).lineLimit(2)
                    Spacer(minLength: NSpace.s)
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)").font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(NColor.onAccent).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(NColor.accent))
                            .accessibilityLabel(Text("\(conversation.unreadCount) unread"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let m = conversation.lastMessage else { return String(localized: "No messages") }
        let text = MarkdownDocument.plainText(from: m.content).replacingOccurrences(of: "\n", with: " ")
        return m.role == "user" ? String(localized: "You: \(text)") : text
    }
}
