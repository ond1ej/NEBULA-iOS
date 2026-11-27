import Foundation
import Testing
@testable import NEBULAChat

private func blocks(_ text: String, streaming: Bool = false) -> [MarkdownBlock] {
    MarkdownDocument(parsing: text, isStreaming: streaming).blocks
}

private func item(_ text: String, task: MarkdownTaskState? = nil) -> MarkdownListItem {
    MarkdownListItem(task: task, blocks: [.paragraph(text: text)])
}

private func bullets(_ items: [MarkdownListItem], tight: Bool = true) -> MarkdownBlock {
    .list(MarkdownList(kind: .bullet, isTight: tight, items: items))
}

private func ordered(_ start: Int, _ items: [MarkdownListItem], tight: Bool = true) -> MarkdownBlock {
    .list(MarkdownList(kind: .ordered(start: start), isTight: tight, items: items))
}

@Suite("Markdown – blocks")
struct MarkdownParserTests {
    @Test func empty() {
        #expect(blocks("").isEmpty)
        #expect(blocks("\n\n   \n").isEmpty)
    }

    @Test func atxHeadings() {
        #expect(blocks("# Nadpis\n## Druhý ##\n###### Šestý\n#Bez mezery\n####### Sedm") == [
            .heading(level: 1, text: "Nadpis"),
            .heading(level: 2, text: "Druhý"),
            .heading(level: 6, text: "Šestý"),
            .paragraph(text: "#Bez mezery\n####### Sedm"),
        ])
        #expect(blocks("# C# jazyk\n#") == [.heading(level: 1, text: "C# jazyk"), .heading(level: 1, text: "")])
    }

    @Test func setextHeadings() {
        #expect(blocks("Titulek\n=======\n\nPodtitulek\n---\n\nVíce\nřádků\n===") == [
            .heading(level: 1, text: "Titulek"),
            .heading(level: 2, text: "Podtitulek"),
            .heading(level: 1, text: "Více\nřádků"),
        ])
    }

    @Test func paragraphsSoftAndHardBreaks() {
        #expect(blocks("jedna\ndva  \ntři\\\nčtyři   \n\n  další odstavec") == [
            .paragraph(text: "jedna\ndva\u{2028}tři\u{2028}čtyři"),
            .paragraph(text: "další odstavec"),
        ])
        // A trailing backslash or spaces at the end of a paragraph are not a hard break.
        #expect(blocks("konec\\") == [.paragraph(text: "konec\\")])
        #expect(blocks("a\\\\\nb") == [.paragraph(text: "a\\\\\nb")])
    }

    @Test func thematicBreaks() {
        #expect(blocks("text\n\n***\n- - -\n___\n  * * *") == [
            .paragraph(text: "text"), .thematicBreak, .thematicBreak, .thematicBreak, .thematicBreak,
        ])
        #expect(blocks("text\n***") == [.paragraph(text: "text"), .thematicBreak])
    }

    @Test func bulletLists() {
        #expect(blocks("- a\n- b\n* c\n+ d") == [
            bullets([item("a"), item("b")]), bullets([item("c")]), bullets([item("d")]),
        ])
        #expect(blocks("- a\n\n- b") == [bullets([item("a"), item("b")], tight: false)])
    }

    @Test func orderedLists() {
        #expect(blocks("1. jedna\n2. dva\n10. deset") == [ordered(1, [item("jedna"), item("dva"), item("deset")])])
        #expect(blocks("3) tři\n4) čtyři") == [ordered(3, [item("tři"), item("čtyři")])])
        // An ordered list only interrupts a paragraph when it starts at 1.
        #expect(blocks("Rok\n2026. bude") == [.paragraph(text: "Rok\n2026. bude")])
        #expect(blocks("Kroky:\n1. první") == [.paragraph(text: "Kroky:"), ordered(1, [item("první")])])
    }

    @Test func nestedLists() {
        let text = """
        - ovoce
          - jablka
            1. červená
            2. zelená
          - hrušky
        - zelenina
        """
        let inner = ordered(1, [item("červená"), item("zelená")])
        let fruits = bullets([
            MarkdownListItem(blocks: [.paragraph(text: "jablka"), inner]),
            item("hrušky"),
        ])
        #expect(blocks(text) == [
            bullets([MarkdownListItem(blocks: [.paragraph(text: "ovoce"), fruits]), item("zelenina")]),
        ])
    }

    @Test func taskLists() {
        #expect(blocks("- [ ] udělat\n- [x] hotovo\n- [X] Hotovo\n- [ ]\n- [y] ne") == [
            bullets([
                item("udělat", task: .unchecked),
                item("hotovo", task: .checked),
                item("Hotovo", task: .checked),
                MarkdownListItem(task: .unchecked, blocks: []),
                item("[y] ne"),
            ]),
        ])
    }

    @Test func listContinuationAndLazyLines() {
        #expect(blocks("- první řádek\npokračování\n- druhý") == [
            bullets([item("první řádek\npokračování"), item("druhý")]),
        ])
        let withCode = """
        1. Spusťte:

           ```bash
           ls -la
           ```
        2. Hotovo
        """
        #expect(blocks(withCode) == [
            ordered(1, [
                MarkdownListItem(blocks: [
                    .paragraph(text: "Spusťte:"),
                    .codeBlock(MarkdownCodeBlock(language: "bash", code: "ls -la")),
                ]),
                item("Hotovo"),
            ], tight: false),
        ])
        // An empty first line followed by a blank line ends the item.
        #expect(blocks("-\n\n  text") == [bullets([MarkdownListItem(blocks: [])]), .paragraph(text: "text")])
    }

    @Test func blockQuotes() {
        #expect(blocks("> citace\nlíná\n\n> b\n> > vnořená\n> > dál") == [
            .blockQuote([.paragraph(text: "citace\nlíná")]),
            .blockQuote([.paragraph(text: "b"), .blockQuote([.paragraph(text: "vnořená\ndál")])]),
        ])
        #expect(blocks("> # Nadpis\n> - a\n> - b") == [
            .blockQuote([.heading(level: 1, text: "Nadpis"), bullets([item("a"), item("b")])]),
        ])
        #expect(blocks(">kód:\n>\n>     x = 1") == [
            .blockQuote([.paragraph(text: "kód:"),
                         .codeBlock(MarkdownCodeBlock(language: nil, code: "x = 1", isFenced: false))]),
        ])
    }

    @Test func fencedCode() {
        #expect(blocks("```swift\nlet x = 1\n\nprint(x)\n```\npo") == [
            .codeBlock(MarkdownCodeBlock(language: "swift", code: "let x = 1\n\nprint(x)")),
            .paragraph(text: "po"),
        ])
        #expect(blocks("~~~ python title=\"x.py\"\nprint('a')\n~~~") == [
            .codeBlock(MarkdownCodeBlock(language: "python", code: "print('a')")),
        ])
        #expect(blocks("````md\n```\nvnořeno\n```\n````") == [
            .codeBlock(MarkdownCodeBlock(language: "md", code: "```\nvnořeno\n```")),
        ])
        #expect(blocks("  ```\n  odsazeno\n    víc\n  ```") == [
            .codeBlock(MarkdownCodeBlock(language: nil, code: "odsazeno\n  víc")),
        ])
        #expect(blocks("```{.rust}\nfn main() {}\n```") == [
            .codeBlock(MarkdownCodeBlock(language: "rust", code: "fn main() {}")),
        ])
        // Raw HTML and Markdown inside code stay verbatim; tabs are preserved.
        #expect(blocks("```\n<b>**x**</b>\n\tgo\n```") == [
            .codeBlock(MarkdownCodeBlock(language: nil, code: "<b>**x**</b>\n\tgo")),
        ])
    }

    @Test func unterminatedFenceIsACodeBlock() {
        for streaming in [false, true] {
            #expect(blocks("Text\n\n```swift\nlet a = 1\nlet b", streaming: streaming) == [
                .paragraph(text: "Text"),
                .codeBlock(MarkdownCodeBlock(language: "swift", code: "let a = 1\nlet b", isClosed: false)),
            ])
            #expect(blocks("```python\nx = 1\n", streaming: streaming) == [
                .codeBlock(MarkdownCodeBlock(language: "python", code: "x = 1", isClosed: false)),
            ])
            #expect(blocks("```", streaming: streaming) == [
                .codeBlock(MarkdownCodeBlock(language: nil, code: "", isClosed: false)),
            ])
        }
    }

    @Test func indentedCode() {
        #expect(blocks("odstavec\n\n    kód 1\n\n    kód 2\n\npo") == [
            .paragraph(text: "odstavec"),
            .codeBlock(MarkdownCodeBlock(language: nil, code: "kód 1\n\nkód 2", isFenced: false)),
            .paragraph(text: "po"),
        ])
        // An indented line cannot interrupt a paragraph.
        #expect(blocks("odstavec\n    pokračuje") == [.paragraph(text: "odstavec\npokračuje")])
        #expect(blocks("\tx") == [.codeBlock(MarkdownCodeBlock(language: nil, code: "x", isFenced: false))])
    }

    @Test func tables() {
        let text = """
        | Název | Počet | Cena | Pozn. |
        |:------|:-----:|-----:|-------|
        | a | 1 | 2 | x |
        | b \\| c | 3 |
        | d | 4 | 5 | 6 | 7 |

        po tabulce
        """
        #expect(blocks(text) == [
            .table(MarkdownTable(alignments: [.left, .center, .right, .none],
                                 header: ["Název", "Počet", "Cena", "Pozn."],
                                 rows: [["a", "1", "2", "x"], ["b | c", "3", "", ""], ["d", "4", "5", "6"]])),
            .paragraph(text: "po tabulce"),
        ])
        #expect(blocks("a | b\n--- | ---\nc | d") == [
            .table(MarkdownTable(alignments: [.none, .none], header: ["a", "b"], rows: [["c", "d"]])),
        ])
        // The delimiter row must match the header's cell count.
        #expect(blocks("| a |\n|---|---|") == [.paragraph(text: "| a |\n|---|---|")])
        // A table can interrupt a paragraph (the last line is the header).
        #expect(blocks("Úvod\n| x |\n|---|\n| 1 |") == [
            .paragraph(text: "Úvod"),
            .table(MarkdownTable(alignments: [.none], header: ["x"], rows: [["1"]])),
        ])
        // Inline code and pipes.
        #expect(blocks("| `a` | **b** |\n| --- | --- |") == [
            .table(MarkdownTable(alignments: [.none, .none], header: ["`a`", "**b**"], rows: [])),
        ])
    }

    @Test func rawHTMLStaysParagraphText() {
        let html = "<div class=\"x\">\n<script>alert(1)</script>\n</div>"
        #expect(blocks(html) == [.paragraph(text: html)])
        #expect(blocks("<!-- komentář -->") == [.paragraph(text: "<!-- komentář -->")])
    }

    @Test func lineEndingsAreNormalized() {
        #expect(blocks("# A\r\n\r\ntext\rdalší") == blocks("# A\n\ntext\ndalší"))
    }

    @Test func mixedDocument() {
        let document = MarkdownDocument(parsing: MarkdownSamples.sampleAgentReply)
        let kinds = document.blocks.map { block -> String in
            switch block {
            case .heading: "h"
            case .paragraph: "p"
            case .list: "l"
            case .blockQuote: "q"
            case .codeBlock: "c"
            case .table: "t"
            case .thematicBreak: "-"
            }
        }.joined()
        #expect(kinds == "hphlhlhlqht-hpcpcpcpcpp")
    }

    @Test func plainText() {
        let document = MarkdownDocument(parsing: """
        # Nadpis
        Text s **tučným** a [odkazem](https://example.com).

        - [x] hotovo
        1. první

        | a | b |
        |---|---|
        | 1 | 2 |

        ```
        kód
        ```
        """)
        #expect(document.plainText == "Nadpis\n\nText s tučným a odkazem.\n\n☑︎ hotovo\n\n1. první\n\na\tb\n1\t2\n\nkód")
    }
}

@Suite("Markdown – streaming parse")
struct MarkdownStreamingParseTests {
    @Test func loneListMarkerStartsAnItemWhileStreaming() {
        #expect(blocks("Seznam:\n-", streaming: true) == [
            .paragraph(text: "Seznam:"), bullets([MarkdownListItem(blocks: [])]),
        ])
        #expect(blocks("Seznam:\n-") == [.heading(level: 2, text: "Seznam:")])
        #expect(blocks("Kroky:\n1.", streaming: true) == [
            .paragraph(text: "Kroky:"), ordered(1, [MarkdownListItem(blocks: [])]),
        ])
        #expect(blocks("1. a\n2.", streaming: true) == [ordered(1, [item("a"), MarkdownListItem(blocks: [])])])
    }

    @Test func pendingFragmentsAreHeldBack() {
        #expect(blocks("1. a\n2", streaming: true) == [ordered(1, [item("a")])])
        #expect(blocks("1. a\n2") == [ordered(1, [item("a\n2")])])
        #expect(blocks("Text\n``", streaming: true) == [.paragraph(text: "Text")])
        #expect(blocks("Text\n``") == [.paragraph(text: "Text\n``")])
        // A complete line is never held back.
        #expect(blocks("Celkem:\n42\n", streaming: true) == [.paragraph(text: "Celkem:\n42")])
    }

    @Test func shortSetextUnderlineWaitsWhileStreaming() {
        #expect(blocks("Foo\n--", streaming: true) == [.paragraph(text: "Foo\n--")])
        #expect(blocks("Foo\n---", streaming: true) == [.heading(level: 2, text: "Foo")])
        #expect(blocks("Foo\n--") == [.heading(level: 2, text: "Foo")])
    }

    @Test func startedDelimiterRowMakesATableWhileStreaming() {
        let expected: [MarkdownBlock] = [
            .table(MarkdownTable(alignments: [.none, .none], header: ["a", "b"], rows: [])),
        ]
        #expect(blocks("| a | b |\n|", streaming: true) == expected)
        #expect(blocks("| a | b |\n|--", streaming: true) == expected)
        #expect(blocks("| a | b |\n|:-", streaming: true) == [
            .table(MarkdownTable(alignments: [.left, .none], header: ["a", "b"], rows: [])),
        ])
        #expect(blocks("| a | b |\n|--") == [.paragraph(text: "| a | b |\n|--")])
    }
}
