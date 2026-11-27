import SwiftUI
import NEBULADesignSystem

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The content of an agent's message bubble: ``MarkdownView`` plus a "Copy" context menu (once the message is
/// complete) and a VoiceOver-friendly structure.
public struct MessageBubbleContent: View {
    private let text: String
    private let isStreaming: Bool
    private let id: String?

    public init(text: String, isStreaming: Bool = false, id: String? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.id = id
    }

    public var body: some View {
        if isStreaming {
            MarkdownView(text: text, isStreaming: true, id: id)
        } else {
            CopyableText(text) {
                MarkdownView(text: text, isStreaming: false, id: id)
            }
        }
    }
}

/// Adds a context menu with "Copy text" (plain text, markup removed) and "Copy as Markdown".
public struct CopyableText<Content: View>: View {
    private let markdown: String
    private let content: Content

    /// - Parameters:
    ///   - markdown: The message's Markdown source.
    ///   - content: The view that shows it.
    public init(_ markdown: String, @ViewBuilder content: () -> Content) {
        self.markdown = markdown
        self.content = content()
    }

    public var body: some View {
        content.contextMenu {
            Button {
                MarkdownPasteboard.copy(MarkdownDocument.parse(markdown).plainText)
                Haptics.success()
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
            Button {
                MarkdownPasteboard.copy(markdown)
                Haptics.success()
            } label: {
                Label("Copy as Markdown", systemImage: "number")
            }
        }
    }
}

public extension View {
    /// Wraps the view in ``CopyableText`` for `markdown`.
    func copyableText(_ markdown: String) -> some View {
        CopyableText(markdown) { self }
    }
}

/// System pasteboard access for the Markdown components.
@MainActor
enum MarkdownPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
