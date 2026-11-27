import Foundation
import SwiftUI
import Testing
@testable import NEBULAChat

/// Checks that each `(fragment, kind)` is covered by a token of that kind (first occurrence of the fragment).
private func expectTokens(_ code: String, _ language: SyntaxLanguage, _ expected: [(String, SyntaxTokenKind?)],
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let tokens = SyntaxHighlighter.tokens(in: code, language: language)
    // Tokens are sorted and never overlap.
    for (a, b) in zip(tokens, tokens.dropFirst()) {
        #expect(a.range.upperBound <= b.range.lowerBound, "overlap \(a) \(b)", sourceLocation: sourceLocation)
    }
    let bytes = Array(code.utf8)
    for (fragment, kind) in expected {
        let needle = Array(fragment.utf8)
        guard let start = (0...(bytes.count - needle.count)).first(where: {
            Array(bytes[$0..<($0 + needle.count)]) == needle
        }) else {
            Issue.record("fragment \(fragment) not found", sourceLocation: sourceLocation)
            continue
        }
        let range = start..<(start + needle.count)
        let token = tokens.first { $0.range.lowerBound <= range.lowerBound && $0.range.upperBound >= range.upperBound }
        #expect(token?.kind == kind, "\(language) \(fragment): \(String(describing: token?.kind))",
                sourceLocation: sourceLocation)
    }
}

@Suite("Syntax highlighter")
struct SyntaxHighlighterTests {
    @Test func languageAliases() {
        #expect(SyntaxLanguage(identifier: "Swift") == .swift)
        #expect(SyntaxLanguage(identifier: "py") == .python)
        #expect(SyntaxLanguage(identifier: "js") == .javascript)
        #expect(SyntaxLanguage(identifier: "ts") == .typescript)
        #expect(SyntaxLanguage(identifier: "tsx") == .tsx)
        #expect(SyntaxLanguage(identifier: "jsx") == .jsx)
        #expect(SyntaxLanguage(identifier: "zsh") == .bash)
        #expect(SyntaxLanguage(identifier: "sh") == .bash)
        #expect(SyntaxLanguage(identifier: "shell") == .bash)
        #expect(SyntaxLanguage(identifier: "yml") == .yaml)
        #expect(SyntaxLanguage(identifier: "c++") == .cpp)
        #expect(SyntaxLanguage(identifier: "kt") == .kotlin)
        #expect(SyntaxLanguage(identifier: "patch") == .diff)
        #expect(SyntaxLanguage(identifier: "svg") == .xml)
        #expect(SyntaxLanguage(identifier: "brainfuck") == nil)
        #expect(SyntaxLanguage.allCases.allSatisfy { SyntaxLanguage(identifier: $0.rawValue) == $0 })
    }

    @Test func swift() {
        expectTokens("""
        import SwiftUI
        /* blok /* vnořený */ */
        @MainActor struct Model: Sendable {
            let name = "NEBULA \\(verze)" // komentář
            func load(count: Int) async throws -> [String] { return [] }
            #if DEBUG
            var hex = 0xFF_FF
            #endif
        }
        """, .swift, [
            ("import", .keyword), ("SwiftUI", .type), ("/* blok /* vnořený */ */", .comment),
            ("@MainActor", .meta), ("struct", .keyword), ("Model", .type), ("Sendable", .type), ("let", .keyword),
            ("\"NEBULA \\(verze)\"", .string), ("// komentář", .comment), ("load", .function), ("Int", .type),
            ("async throws", .keyword), ("String", .type), ("#if", .meta), ("0xFF_FF", .number), ("name", nil),
        ])
    }

    @Test func python() {
        expectTokens("""
        @cache
        class Health:
            ok: bool = True
        def check(url: str) -> None:
            # komentář
            print(f"stav {url}", r'raw', 3.14)
            '''víceřádkový
            text'''
        """, .python, [
            ("@cache", .meta), ("class", .keyword), ("Health", .type), ("bool", .type), ("True", .keyword),
            ("def", .keyword), ("check", .function), ("str", .type), ("None", .keyword), ("# komentář", .comment),
            ("print", .function), ("f\"stav {url}\"", .string), ("r'raw'", .string), ("3.14", .number),
            ("'''víceřádkový\n    text'''", .string),
        ])
    }

    @Test func javascriptAndTypeScript() {
        expectTokens("const greet = (name) => `Ahoj ${name}`; // c\nfunction run() { return null }",
                     .javascript, [
            ("const", .keyword), ("`Ahoj ${name}`", .string), ("// c", .comment), ("function", .keyword),
            ("run", .function), ("null", .keyword),
        ])
        expectTokens("interface User { name: string; age?: number }\nconst u: User = { name: 'Eva', age: 30 }",
                     .typescript, [
            ("interface", .keyword), ("User", .type), ("string", .type), ("number", .type), ("'Eva'", .string),
            ("30", .number),
        ])
        expectTokens("return <Button variant=\"primary\" onClick={() => go(1)}>Ahoj</Button>", .tsx, [
            ("return", .keyword), ("Button", .tag), ("variant", .attribute), ("\"primary\"", .string),
            ("onClick", .attribute),
        ])
        expectTokens("const a = <div className='x' />;\nconst b = list.filter(x => x < 3)", .jsx, [
            ("div", .tag), ("className", .attribute), ("'x'", .string), ("filter", .function), ("3", .number),
        ])
    }

    @Test func json() {
        expectTokens(#"{"name": "NEBULA", "port": 3101, "tls": true, "limit": null, "ratio": -2.5e3, "tags": ["a"]}"#,
                     .json, [
            ("\"name\"", .property), ("\"NEBULA\"", .string), ("3101", .number), ("true", .keyword),
            ("null", .keyword), ("-2.5e3", .number), ("\"a\"", .string),
        ])
    }

    @Test func bash() {
        expectTokens("""
        #!/bin/bash
        # záloha
        export NEBULA_HOME="$HOME/.nebula"
        if [ -f "$FILE" ]; then
          tar -czf backup.tgz ${DIR} | grep -v tmp && echo 'hotovo'
        fi
        for soubor in *.log; do rm "$soubor"; done
        """, .bash, [
            ("#!/bin/bash", .meta), ("# záloha", .comment), ("export", .keyword), ("NEBULA_HOME", .variable),
            ("$HOME", .variable), ("/.nebula\"", .string), ("if", .keyword), ("then", .keyword), ("tar", .function),
            ("-czf", .attribute), ("${DIR}", .variable), ("grep", .function), ("-v", .attribute),
            ("echo", .function), ("'hotovo'", .string), ("fi", .keyword), ("for", .keyword), ("soubor", .variable),
            ("rm", .function), ("done", .keyword),
        ])
    }

    @Test func htmlAndXML() {
        expectTokens("""
        <!DOCTYPE html>
        <!-- komentář -->
        <div class="karta" id=hlavni data-x='1'>&amp; text
          <script>const x = 42;</script>
          <style>.a { color: red; }</style>
        </div>
        """, .html, [
            ("<!DOCTYPE html>", .meta), ("<!-- komentář -->", .comment), ("div", .tag), ("class", .attribute),
            ("\"karta\"", .string), ("hlavni", .string), ("data-x", .attribute), ("&amp;", .meta),
            ("script", .tag), ("const", .keyword), ("42", .number), ("style", .tag), (".a", .type),
            ("color", .property), ("text", nil),
        ])
        expectTokens("<?xml version=\"1.0\"?>\n<plist lang=\"cs\"><key>Name</key><![CDATA[x < y]]></plist>",
                     .xml, [
            ("<?xml version=\"1.0\"?>", .meta), ("plist", .tag), ("lang", .attribute), ("key", .tag),
            ("<![CDATA[x < y]]>", .string),
        ])
    }

    @Test func css() {
        expectTokens("""
        /* tlačítko */
        .btn:hover > li, #main { color: #6D4AFF; margin: 0 4px !important; }
        @media (max-width: 600px) { body { font-size: 1.2rem; background: rgb(0, 0, 0); } }
        """, .css, [
            ("/* tlačítko */", .comment), (".btn", .type), (":hover", .attribute), ("li", .tag), ("#main", .type),
            ("color", .property), ("#6D4AFF", .number), ("4px", .number), ("!important", .keyword),
            ("@media", .keyword), ("body", .tag), ("font-size", .property), ("1.2rem", .number), ("rgb", .function),
        ])
    }

    @Test func sql() {
        expectTokens("SELECT id, COUNT(*) FROM users WHERE name = 'O''Brien' -- komentář\nORDER BY id DESC LIMIT 10;",
                     .sql, [
            ("SELECT", .keyword), ("COUNT", .function), ("FROM", .keyword), ("'O''Brien'", .string),
            ("-- komentář", .comment), ("ORDER BY", .keyword), ("DESC", .keyword), ("10", .number), ("users", nil),
        ])
        expectTokens("create table t (id integer primary key, body text)", .sql, [
            ("create table", .keyword), ("integer", .type), ("primary key", .keyword), ("text", .type),
        ])
    }

    @Test func go() {
        expectTokens("package main\n\nfunc main() {\n\tx := `raw\nstring`\n\tvar n int = 0x1F\n\tfmt.Println(x, 'a')\n}",
                     .go, [
            ("package", .keyword), ("func", .keyword), ("main()", nil), ("`raw\nstring`", .string), ("var", .keyword),
            ("int", .type), ("0x1F", .number), ("Println", .function), ("'a'", .string),
        ])
    }

    @Test func rust() {
        expectTokens("""
        #[derive(Debug)]
        fn longest<'a>(x: &'a str) -> Option<u8> {
            let c = 'x';
            println!("{}", x);
            let r = r#"raw "text""#;
        }
        """, .rust, [
            ("#[derive(Debug)]", .meta), ("fn", .keyword), ("longest", .function), ("'a", .meta), ("str", .type),
            ("Option", .type), ("u8", .type), ("'x'", .string), ("println!", .function), ("\"{}\"", .string),
            ("r#\"raw \"text\"\"#", .string),
        ])
    }

    @Test func javaAndKotlin() {
        expectTokens("@Override\npublic String toString() { return \"x\" + 1L; } // c", .java, [
            ("@Override", .meta), ("public", .keyword), ("String", .type), ("toString", .function),
            ("\"x\"", .string), ("1L", .number), ("// c", .comment),
        ])
        expectTokens("data class User(val name: String)\nfun main() { println(\"\"\"raw\"\"\") }", .kotlin, [
            ("data class", .keyword), ("User", .type), ("val", .keyword), ("String", .type), ("fun", .keyword),
            ("main", .function), ("println", .function), ("\"\"\"raw\"\"\"", .string),
        ])
    }

    @Test func cAndCpp() {
        expectTokens("#include <stdio.h>\nint main(void) {\n  printf(\"%d\\n\", 42); /* c */\n  return 0;\n}", .c, [
            ("#include", .meta), ("<stdio.h>", .string), ("int", .keyword), ("main", .function), ("void", .keyword),
            ("printf", .function), ("\"%d\\n\"", .string), ("42", .number), ("/* c */", .comment),
        ])
        expectTokens("template <typename T>\nclass Box { public: std::vector<T> items; auto p = nullptr; };", .cpp, [
            ("template", .keyword), ("typename", .keyword), ("T", .type), ("class", .keyword), ("Box", .type),
            ("public", .keyword), ("std", .type), ("vector", .type), ("nullptr", .keyword),
        ])
    }

    @Test func yaml() {
        expectTokens("""
        # konfigurace
        name: NEBULA
        port: 3101
        enabled: true
        "quoted key": 'hodnota' # pozn.
        list:
          - "a"
          - &kotva b
          - { x: 1, y: [ano, ne] }
        popis: |
          první řádek
          druhý řádek
        dalsi: ~
        """, .yaml, [
            ("# konfigurace", .comment), ("name", .property), ("NEBULA", .string), ("3101", .number),
            ("true", .keyword), ("\"quoted key\"", .property), ("'hodnota'", .string), ("# pozn.", .comment),
            ("\"a\"", .string), ("&kotva", .variable), ("x", .property), ("1", .number), ("|", .meta),
            ("první řádek", .string), ("~", .keyword),
        ])
    }

    @Test func diff() {
        let code = "--- a/config.yaml\n+++ b/config.yaml\n@@ -1,2 +1,2 @@\n server:\n-  port: 3000\n+  port: 3101"
        expectTokens(code, .diff, [
            ("--- a/config.yaml", .meta), ("+++ b/config.yaml", .meta), ("@@ -1,2 +1,2 @@", .meta),
            (" server:", nil), ("-  port: 3000", .deleted), ("+  port: 3101", .inserted),
        ])
        let attributed = SyntaxHighlighter.highlight(code, language: .diff)
        #expect(attributed.runs.contains { $0.backgroundColor != nil })
    }

    @Test func attributedOutput() {
        let code = "let název = \"čeština 👋\" // ok"
        let attributed = SyntaxHighlighter.highlight(code, language: "swift")
        #expect(String(attributed.characters) == code)
        let colored = attributed.runs.filter { $0.foregroundColor != nil }.map { String(attributed[$0.range].characters) }
        #expect(colored == ["let", "\"čeština 👋\"", "// ok"])
        // Unknown languages stay plain.
        let plain = SyntaxHighlighter.highlight(code, language: "brainfuck")
        #expect(plain.runs.allSatisfy { $0.foregroundColor == nil })
        #expect(SyntaxHighlighter.highlight(code, language: nil) == AttributedString(code))
        // Cached.
        #expect(SyntaxHighlighter.cachedHighlight(code, language: "swift") == attributed)
    }

    @Test func robustAgainstUnterminatedConstructs() {
        for language in SyntaxLanguage.allCases {
            for code in ["\"neuzavřený", "/* komentář", "`", "'", "<div class=\"", "#", "@", "r#\"", "0x", "${", "-", ""] {
                let tokens = SyntaxHighlighter.tokens(in: code, language: language)
                #expect(tokens.allSatisfy { $0.range.upperBound <= code.utf8.count && !$0.range.isEmpty })
                _ = SyntaxHighlighter.highlight(code, language: language)
            }
        }
    }

    /// 200 lines must tokenize in < 2 ms in release builds; the bound here is generous for debug builds.
    @Test func tokenizerPerformance() {
        var lines: [String] = []
        for i in 0..<200 {
            lines.append("    let value\(i) = try await service.fetch(id: \"item-\(i)\", limit: \(i * 3)) // řádek \(i)")
        }
        let code = lines.joined(separator: "\n")
        _ = SyntaxHighlighter.tokens(in: code, language: .swift)
        let clock = ContinuousClock()
        let runs = 10
        let tokenize = clock.measure {
            for _ in 0..<runs { _ = SyntaxHighlighter.tokens(in: code, language: .swift) }
        } / runs
        let attribute = clock.measure {
            _ = SyntaxHighlighter.attributedString(code, tokens: SyntaxHighlighter.tokens(in: code, language: .swift))
        }
        print("[perf] tokenize 200 lines: \(tokenize); tokenize + attributed string: \(attribute)")
        #expect(tokenize < .milliseconds(40))
    }
}
