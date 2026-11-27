import SwiftUI
import NEBULADesignSystem

/// Realistic sample messages (previews, tests).
enum MarkdownSamples {
    /// A long agent reply covering every supported block type.
    static let sampleAgentReply = #"""
    # NEBULA 1.0 deployment summary

    Hello! The deployment **went well** and all checks passed. Below you will find a *short overview*, the code changes
    and the next steps. The full log is in `logs/deploy-2026-11-22.txt`, the documentation is at https://www.apple.com/ and
    questions go to [support](mailto:support@example.com).

    ## What changed

    - Native apps for **iPhone** and **Mac**
      - sign-in with Face ID / Touch ID
      - live streaming of the agent's replies
    - Faster search in conversations (~3× faster)
    - ~~The old web preview~~ was removed

    ### Checklist

    - [x] Database migration `0009_apple_devices`
    - [x] Device pairing via QR code
    - [ ] Verify push notifications on a real device
    - [ ] Update the *user guide*

    ### Recovery steps

    1. Stop the service.
    2. Restore the backup:

       ```bash
       # restore from backup
       export NEBULA_HOME="$HOME/.nebula"
       nebula restore --from ~/Backups/nebula-2026-11-21.tar.gz --verify
       ```

    3. Start the service again and check its status.

    > **Note:** The password vault stays encrypted during recovery.
    > The key never leaves the Secure Enclave.
    >
    > > Nested quote: “Security first.”

    ## Performance

    | Operation          | Before | After | Change |
    |:-------------------|-------:|------:|:------:|
    | Cold start         | 1.8 s  | 0.6 s | −67 % |
    | Open conversation  | 420 ms | 90 ms | −79 % |
    | Parse 20 kB        | 35 ms  | 4 ms  | −89 % |

    ---

    ## Code samples

    The message model in Swift:

    ```swift
    /// One message in a conversation.
    struct Message: Identifiable, Sendable {
        let id: UUID
        var text: String
        var isStreaming = false

        func preview(limit: Int = 80) -> String {
            text.count > limit ? "\(text.prefix(limit))…" : text
        }
    }

    @MainActor
    final class ChatStore {
        private(set) var messages: [Message] = []
        func append(_ chunk: String, to id: UUID) async throws {
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[index].text += chunk
        }
    }
    ```

    A server health check in Python:

    ```python
    import asyncio
    from dataclasses import dataclass

    @dataclass
    class Health:
        ok: bool
        latency_ms: float = 0.0

    async def check(url: str, retries: int = 3) -> Health:
        """Return the service status."""
        for attempt in range(retries):
            if await ping(url):
                return Health(ok=True, latency_ms=12.5)
            await asyncio.sleep(2 ** attempt)  # exponential back-off
        return Health(ok=False)
    ```

    Configuration (JSON):

    ```json
    {
      "port": 3101,
      "gateway": { "port": 3102, "tls": true },
      "agents": ["research", "code"],
      "limit": null
    }
    ```

    Configuration changes:

    ```diff
    --- a/config.yaml
    +++ b/config.yaml
    @@ -1,3 +1,3 @@
     server:
    -  port: 3000
    +  port: 3101
    ```

    Raw HTML is never rendered: <b>bold</b> <script>alert(1)</script> stays text, just like
    [a dangerous link](javascript:alert(1)).

    Done. If you like, I can also prepare **automated tests** for the new screens.
    """#
}

#if DEBUG
private struct MarkdownPreviewScreen: View {
    var body: some View {
        ScrollView {
            MarkdownView(text: MarkdownSamples.sampleAgentReply, id: "preview-sample")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(NColor.bubbleAssistant, in: RoundedRectangle(cornerRadius: NRadius.bubble,
                                                                         style: .continuous))
                .padding()
        }
        .background(NColor.background)
    }
}

/// Simulates a streaming reply (a few characters every 30 ms).
private struct StreamingPreviewScreen: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.m) {
                if text.isEmpty {
                    TypingIndicator()
                } else {
                    MarkdownView(text: text, isStreaming: text.count < MarkdownSamples.sampleAgentReply.count,
                                 id: "preview-stream")
                }
            }
            .padding()
        }
        .background(NColor.background)
        .task {
            try? await Task.sleep(for: .seconds(1))
            var index = MarkdownSamples.sampleAgentReply.startIndex
            let source = MarkdownSamples.sampleAgentReply
            while index < source.endIndex {
                let next = source.index(index, offsetBy: 6, limitedBy: source.endIndex) ?? source.endIndex
                text = String(source[..<next])
                index = next
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }
}

#Preview("Markdown – light") {
    MarkdownPreviewScreen()
        .preferredColorScheme(.light)
}

#Preview("Markdown – dark") {
    MarkdownPreviewScreen()
        .preferredColorScheme(.dark)
}

#Preview("Streaming") {
    StreamingPreviewScreen()
}

#Preview("Code block") {
    VStack(spacing: NSpace.l) {
        CodeBlockView(code: "let greeting = \"Hello, world!\"\nprint(greeting) // greeting", language: "swift")
        CodeBlockView(code: "SELECT id, name FROM agents WHERE active = TRUE ORDER BY name;", language: "sql")
            .preferredColorScheme(.dark)
    }
    .padding()
}

#Preview("Agent is typing") {
    HStack {
        TypingIndicator()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(NColor.bubbleAssistant, in: Capsule())
        Spacer()
    }
    .padding()
}
#endif
