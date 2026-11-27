import Foundation
import Testing
@testable import NEBULAChat

/// Deterministic random numbers (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Constructs that stress block boundaries: setext underlines, lazy lines, loose lists, indented code after lists,
/// tables without outer pipes, nested quotes, ~~~ fences, HTML, hard breaks.
let trickyMarkdown = """
Úvodní odstavec
pokračuje na druhém řádku
a má tvrdý zlom.

Setext nadpis
=============

- položka
líná pokračovací řádka
- druhá

  odstavec uvnitř položky

      kód v položce
- třetí
    1. vnořená
    2. vnořená dvě

1) jiný oddělovač
2) dva

    odsazený kód po seznamu

    pokračování kódu
odstavec hned za kódem
---

> citace
> > vnořená
líná citace

> - seznam v citaci
> - druhý

a | b | c
:-- | :-: | --:
1 | 2 | 3
4 | 5

~~~js
const x = `template`;
~~~

<div>
  <p>HTML zůstane textem</p>
</div>

Podtržení dvojí
---
* * *
1. [x] úkol
2. [ ] další
+ plus seznam

```
neuzavřený blok kódu
"""

@Suite("Markdown – incremental parsing")
struct MarkdownIncrementalTests {
    static let samples = [MarkdownSamples.sampleAgentReply, trickyMarkdown, trickyMarkdown + "\n```\n\n" + MarkdownSamples.sampleAgentReply]

    /// Streams every sample in random chunk sizes and checks that each incremental re-parse equals a full parse.
    @Test(arguments: [false, true])
    func growingPrefixesMatchFullParse(streaming: Bool) {
        var random = SeededRandom(seed: streaming ? 7 : 42)
        var checked = 0
        var reused = 0
        for sample in Self.samples {
            let characters = Array(sample)
            var cut = 0
            var base: MarkdownDocument?
            while cut < characters.count {
                cut = min(characters.count, cut + Int.random(in: 1...24, using: &random))
                let prefix = String(characters[..<cut])
                let full = MarkdownDocument(parsing: prefix, isStreaming: streaming)
                if let base, let incremental = MarkdownDocument.reparse(prefix, reusing: base, streaming: streaming) {
                    #expect(incremental == full, "prefix length \(cut)")
                    reused += 1
                }
                checked += 1
                base = full
            }
        }
        #expect(checked > 300)
        // The incremental path must actually be taken most of the time.
        #expect(reused * 10 > checked * 7, "reused \(reused) of \(checked)")
    }

    /// Arbitrary (also shrinking or edited) pairs of prefixes.
    @Test func randomPrefixPairsMatchFullParse() {
        var random = SeededRandom(seed: 2026)
        for sample in Self.samples {
            let characters = Array(sample)
            for _ in 0..<150 {
                let a = Int.random(in: 0...characters.count, using: &random)
                let b = Int.random(in: 0...characters.count, using: &random)
                let first = String(characters[..<a])
                var second = String(characters[..<b])
                if Bool.random(using: &random), !second.isEmpty {
                    // Edit somewhere in the tail.
                    let position = Int.random(in: 0..<second.count, using: &random)
                    let index = second.index(second.startIndex, offsetBy: position)
                    second.insert(contentsOf: ["x", "\n", "-", "|", "`", " "].randomElement(using: &random)!, at: index)
                }
                let streaming = Bool.random(using: &random)
                let base = MarkdownDocument(parsing: first, isStreaming: Bool.random(using: &random))
                let full = MarkdownDocument(parsing: second, isStreaming: streaming)
                if let incremental = MarkdownDocument.reparse(second, reusing: base, streaming: streaming) {
                    #expect(incremental == full, "a=\(a) b=\(b)")
                }
            }
        }
    }

    /// The cached public API (with a message id) returns exactly what a fresh parse returns.
    @Test func cachedStreamingAPIMatchesFullParse() {
        let id = "test-stream-\(UUID().uuidString)"
        let characters = Array(MarkdownSamples.sampleAgentReply)
        var cut = 0
        var random = SeededRandom(seed: 99)
        while cut < characters.count {
            cut = min(characters.count, cut + Int.random(in: 1...40, using: &random))
            let prefix = String(characters[..<cut])
            let streaming = cut < characters.count
            #expect(MarkdownDocument.parse(prefix, id: id, isStreaming: streaming)
                    == MarkdownDocument(parsing: prefix, isStreaming: streaming))
        }
        // Anonymous (no id) parses use recently parsed prefixes.
        let text = MarkdownSamples.sampleAgentReply
        #expect(MarkdownDocument.parse(text + "\n\nDovětek") == MarkdownDocument(parsing: text + "\n\nDovětek"))
    }

    @Test func cacheHitsReturnTheSameDocument() {
        let id = "cache-\(UUID().uuidString)"
        let first = MarkdownDocument.parse("# A\n\ntext", id: id)
        let second = MarkdownDocument.parse("# A\n\ntext", id: id)
        #expect(first == second)
        #expect(MarkdownDocument.parse("# A\n\ntext", id: id, isStreaming: true).isStreaming)
        #expect(!MarkdownDocument.parse("# A\n\ntext", id: id).isStreaming)
    }

    @Test func reuseNeedsTwoCompleteLines() {
        // The last block's first line is still open: no restart point.
        let base = MarkdownDocument(parsing: "# A\n\npara", isStreaming: true)
        #expect(MarkdownDocument.reparse("# A\n\nparagraph", reusing: base, streaming: true) == nil)
        // Lines L and L + 1 of block 1 are complete: the heading is reused, the tail re-parsed.
        let complete = MarkdownDocument(parsing: "# A\n\npara\nmore\n", isStreaming: true)
        let grown = "# A\n\npara\nmore\nlast"
        #expect(MarkdownDocument.reparse(grown, reusing: complete, streaming: true)
                == MarkdownDocument(parsing: grown, isStreaming: true))
        // A table header must not be reused while its delimiter row is still open (it may stop being one).
        let tableBase = MarkdownDocument(parsing: "text\n\n| a |\n|-", isStreaming: true)
        #expect(MarkdownDocument.reparse("text\n\n| a |\n|-x", reusing: tableBase, streaming: true) == nil)
        #expect(MarkdownDocument(parsing: "text\n\n| a |\n|-x", isStreaming: true).blocks
                == [.paragraph(text: "text"), .paragraph(text: "| a |\n|-x")])
    }

    @Test func commonPrefixLength() {
        #expect(MarkdownDocument.commonPrefixLength("abc", "abd") == 2)
        #expect(MarkdownDocument.commonPrefixLength("abc", "abc") == 3)
        #expect(MarkdownDocument.commonPrefixLength("", "abc") == 0)
        #expect(MarkdownDocument.commonPrefixLength("ač", "aď") == 2)   // shares the first byte of the scalar
    }

    @Test func lruEvictsLeastRecentlyUsed() {
        var lru = MarkdownLRU<Int, String>(capacity: 4, costLimit: 1000)
        for key in 0..<4 { lru.insert("\(key)", for: key, cost: 1) }
        _ = lru.value(for: 0)              // 0 is now the most recent
        lru.insert("4", for: 4, cost: 1)   // over capacity → evicts down to 3 entries
        #expect(lru.count == 3)
        #expect(lru.value(for: 0) == "0")
        #expect(lru.value(for: 4) == "4")
        #expect(lru.value(for: 1) == nil)
        var costly = MarkdownLRU<Int, String>(capacity: 100, costLimit: 10)
        for key in 0..<5 { costly.insert("\(key)", for: key, cost: 4) }
        #expect(costly.totalCost <= 10)
        #expect(costly.value(for: 4) == "4")
    }
}

@Suite("Markdown – performance")
struct MarkdownPerformanceTests {
    static let twentyKilobytes: String = {
        var text = ""
        var round = 0
        while text.utf8.count < 20_000 {
            text += (round.isMultiple(of: 2) ? MarkdownSamples.sampleAgentReply : trickyMarkdown + "\n```") + "\n\n"
            round += 1
        }
        return text
    }()

    /// Full parse of a 20 kB message. Release builds take a few milliseconds (target < 15 ms); the bound here is
    /// generous because tests run unoptimized.
    @Test func parseTwentyKilobytes() {
        let text = Self.twentyKilobytes
        #expect(text.utf8.count >= 20_000)
        _ = MarkdownDocument(parsing: text)
        let clock = ContinuousClock()
        let runs = 5
        let elapsed = clock.measure {
            for _ in 0..<runs { _ = MarkdownDocument(parsing: text) }
        } / runs
        print("[perf] full parse of \(text.utf8.count) B: \(elapsed)")
        #expect(elapsed < .milliseconds(150))
    }

    /// Streaming the 20 kB message in ~60 byte chunks re-parses only the tail.
    @Test func streamingIsIncremental() {
        let text = Self.twentyKilobytes
        let characters = Array(text)
        let id = "perf-\(UUID().uuidString)"
        var prefixes: [String] = []
        var cut = 0
        while cut < characters.count {
            cut = min(characters.count, cut + 60)
            prefixes.append(String(characters[..<cut]))
        }
        let clock = ContinuousClock()
        let incremental = clock.measure {
            for prefix in prefixes { _ = MarkdownDocument.parse(prefix, id: id, isStreaming: true) }
        }
        let full = clock.measure {
            for prefix in prefixes.suffix(40) { _ = MarkdownDocument(parsing: prefix, isStreaming: true) }
        }
        let perChunkIncremental = incremental / prefixes.count
        let perChunkFull = full / 40
        print("[perf] streaming \(prefixes.count) chunks: \(perChunkIncremental) per chunk (full parse of the "
              + "same size: \(perChunkFull))")
        #expect(perChunkIncremental < perChunkFull)
        #expect(perChunkIncremental < .milliseconds(30))
    }
}
