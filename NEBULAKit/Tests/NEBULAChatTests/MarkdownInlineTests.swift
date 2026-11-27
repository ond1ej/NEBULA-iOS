import Foundation
import SwiftUI
import Testing
@testable import NEBULAChat

private func links(in markdown: String) -> [String] {
    let attributed = MarkdownInlineRenderer.render(markdown)
    return attributed.runs.compactMap { $0.link?.absoluteString }
}

@Suite("Markdown – inline")
struct MarkdownInlineTests {
    @Test func emphasisStrikethroughAndCode() {
        let attributed = MarkdownInlineRenderer.render("**tučně** *kurzíva* ~~škrtnuto~~ `kód` ***obojí***")
        #expect(String(attributed.characters) == "tučně kurzíva škrtnuto kód obojí")
        var intents: [String: InlinePresentationIntent] = [:]
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent {
                intents[String(attributed[run.range].characters)] = intent
            }
        }
        #expect(intents["tučně"] == .stronglyEmphasized)
        #expect(intents["kurzíva"] == .emphasized)
        #expect(intents["škrtnuto"] == .strikethrough)
        #expect(intents["kód"] == .code)
        #expect(intents["obojí"] == [.emphasized, .stronglyEmphasized])
    }

    @Test func inlineCodeGetsABackground() {
        let attributed = MarkdownInlineRenderer.render("spusťte `make test` teď")
        let code = attributed.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(code != nil)
        #expect(code?.backgroundColor != nil)
        let plain = attributed.runs.first { $0.inlinePresentationIntent == nil }
        #expect(plain?.backgroundColor == nil)
    }

    @Test func onlySafeLinksAreTappable() {
        let markdown = """
        [ok](https://example.com/a) [http](http://example.org) [mail](mailto:podpora@example.com) \
        [js](javascript:alert(1)) [JS](JaVaScRiPt:alert(1)) [data](data:text/html;base64,PGI+) \
        [file](file:///etc/passwd) [rel](relativni/cesta) [tel](tel:+420123) [ftp](ftp://example.com) \
        [vb](vbscript:msgbox) [nohost](https:evil)
        """
        #expect(links(in: markdown) == ["https://example.com/a", "http://example.org", "mailto:podpora@example.com"])
        let text = String(MarkdownInlineRenderer.render(markdown).characters)
        #expect(text.contains("js JS data file rel tel ftp vb nohost"))
    }

    @Test func bareURLsAreAutolinked() {
        #expect(links(in: "Viz https://example.com/cesta?x=1. a www.apple.com nebo <https://nebula.example>") == [
            "https://example.com/cesta?x=1", "http://www.apple.com", "https://nebula.example",
        ])
        #expect(links(in: "Napište na podpora@example.com") == ["mailto:podpora@example.com"])
        #expect(links(in: "file:///etc/passwd a javascript:alert(1) ftp://example.com").isEmpty)
    }

    @Test func rawHTMLIsLiteralText() {
        let markdown = "Ahoj <b>světe</b> <script>alert(1)</script> <img src=x onerror=alert(1)> <!-- c -->"
        let attributed = MarkdownInlineRenderer.render(markdown)
        #expect(String(attributed.characters) == markdown)
        for run in attributed.runs {
            #expect(run.inlinePresentationIntent?.contains(.inlineHTML) != true)
            #expect(run.link == nil)
        }
    }

    @Test func imagesShowTheirAltText() {
        let attributed = MarkdownInlineRenderer.render("![logo NEBULA](https://example.com/logo.png) text")
        #expect(String(attributed.characters) == "logo NEBULA text")
        #expect(attributed.runs.allSatisfy { $0.imageURL == nil })
    }

    @Test func hardBreaksAndEscapes() {
        #expect(MarkdownInlineRenderer.plainText("a\u{2028}b\nc") == "a\nb\nc")
        #expect(MarkdownInlineRenderer.plainText(#"\*není tučně\* a \`kód\`"#) == "*není tučně* a `kód`")
        #expect(MarkdownInlineRenderer.plainText("&amp; &lt;b&gt;") == "& <b>")
    }

    @Test func plainLinesSkipTheParser() {
        let text = "Jednoduchá věta bez značek"
        #expect(MarkdownInlineRenderer.render(text) == AttributedString(text))
    }

    @Test func cacheReturnsTheSameResult() {
        let a = MarkdownInlineRenderer.attributedString("**x** [y](https://example.com)")
        let b = MarkdownInlineRenderer.attributedString("**x** [y](https://example.com)")
        #expect(a == b)
        #expect(a == MarkdownInlineRenderer.render("**x** [y](https://example.com)"))
    }

    @Test func allowedLinkPolicy() {
        #expect(MarkdownInlineRenderer.isAllowedLink(URL(string: "https://example.com")!))
        #expect(MarkdownInlineRenderer.isAllowedLink(URL(string: "HTTP://EXAMPLE.COM")!))
        #expect(MarkdownInlineRenderer.isAllowedLink(URL(string: "mailto:a@b.cz")!))
        #expect(!MarkdownInlineRenderer.isAllowedLink(URL(string: "mailto:")!))
        #expect(!MarkdownInlineRenderer.isAllowedLink(URL(string: "javascript:alert(1)")!))
        #expect(!MarkdownInlineRenderer.isAllowedLink(URL(string: "data:text/plain,x")!))
        #expect(!MarkdownInlineRenderer.isAllowedLink(URL(string: "file:///tmp/x")!))
        #expect(!MarkdownInlineRenderer.isAllowedLink(URL(string: "nebula://open")!))
    }
}
