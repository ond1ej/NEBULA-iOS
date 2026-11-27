import Foundation
import SwiftUI
import Testing
@testable import NEBULAChat

/// Smoke tests: the views lay out and render offscreen (light and dark). Set `NEBULA_MARKDOWN_SNAPSHOTS` to a
/// directory to also write the rendered PNGs there for a visual check.
@MainActor
@Suite("Markdown – rendering")
struct MarkdownRenderingTests {
    private func render(_ view: some View, name: String, scheme: ColorScheme) -> CGSize? {
        let content = view
            .frame(width: 390)
            .padding()
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        if let directory = ProcessInfo.processInfo.environment["NEBULA_MARKDOWN_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        return CGSize(width: image.width, height: image.height)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func sampleMessageRenders(scheme: ColorScheme) throws {
        let size = try #require(render(MarkdownView(text: MarkdownSamples.sampleAgentReply, id: "render-test"),
                                       name: "sample", scheme: scheme))
        #expect(size.width > 700)
        #expect(size.height > 2000)
    }

    @Test func streamingAndComponentsRender() throws {
        let streaming = VStack(alignment: .leading, spacing: 16) {
            MarkdownView(text: "Píšu odpověď s **tučným** textem a seznamem:\n\n- první\n- dru", isStreaming: true)
            MarkdownView(text: "", isStreaming: true)
            TypingIndicator()
            CodeBlockView(code: "func hello() {\n    print(\"Ahoj\")\n}", language: "swift")
            MessageBubbleContent(text: "> citace\n\n| a | b |\n|---|--:|\n| 1 | 2 |")
        }
        let size = try #require(render(streaming, name: "components", scheme: .light))
        #expect(size.height > 300)
    }
}
