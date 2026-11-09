import Foundation

enum MarkdownColumnAlignment: Equatable { case leading, center, trailing }

indirect enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case listItem(Int, String, String, Bool?)
    case quote([MarkdownBlock])
    case code(String, String)
    case rule
    case table([String], [[String]], [MarkdownColumnAlignment])
    case image(String, String)
}

/// Presentation only: source Markdown and archived evidence are never rewritten.
/// Raw HTML is literal text, not executable content. No remote resources are loaded.
enum MarkdownDocument {
    static func matches(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func cells(_ line: String) -> [String] {
        var parts = [String](), cell = "", escaped = false, ticks = 0
        let chars = Array(line.trimmingCharacters(in: .whitespaces)); var i = 0
        while i < chars.count {
            let c = chars[i]
            if escaped { cell.append(c); escaped = false; i += 1; continue }
            if c == "\\" { cell.append(c); escaped = true; i += 1; continue }
            if c == "`" {
                var n = 1
                while i+n < chars.count && chars[i+n] == "`" { n += 1 }
                if ticks == 0 { ticks = n } else if ticks == n { ticks = 0 }
                cell += String(repeating: "`", count: n); i += n; continue
            }
            if c == "|" && ticks == 0 { parts.append(cell); cell = "" }
            else { cell.append(c) }
            i += 1
        }
        parts.append(cell)
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func alignment(_ line: String) -> [MarkdownColumnAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty, parts.allSatisfy({ matches("^:?-{3,}:?$", $0) != nil }) else { return nil }
        return parts.map { $0.hasPrefix(":") && $0.hasSuffix(":") ? .center : $0.hasSuffix(":") ? .trailing : .leading }
    }
    static func list(_ line: String) -> [String]? {
        matches("^( *)([-+*]|[0-9]+[.)]) +(?:\\[([ xX])\\] +)?(.*)$", line)
    }
    static func rule(_ line: String) -> Bool {
        matches("^ {0,3}((?:\\* *){3,}|(?:- *){3,}|(?:_ *){3,})$", line) != nil
    }
    static func fence(_ line: String) -> [String]? { matches("^ {0,3}(`{3,}|~{3,})(.*)$", line) }
    static func startsBlock(_ line: String) -> Bool {
        fence(line) != nil || matches("^ {0,3}#{1,6} +", line) != nil ||
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">") || rule(line) || list(line) != nil ||
        matches("^!\\[([^\\]]*)\\]\\((.*)\\)$", line) != nil
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks = [MarkdownBlock](), i = 0
        // Only an actual first-line YAML envelope is removed from the reading view.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"),
           lines[1..<end].contains(where: { matches("^[A-Za-z_][A-Za-z0-9_-]*:", $0) != nil }) { i = end+1 }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if let f = fence(line) {
                let marker = f[1]; var content = [String](); i += 1
                while i < lines.count {
                    let end = lines[i].trimmingCharacters(in: .whitespaces)
                    if end.count >= marker.count && end.allSatisfy({ $0 == marker.first! }) { i += 1; break }
                    content.append(lines[i]); i += 1
                }
                blocks.append(.code(f[2].trimmingCharacters(in: .whitespaces), content.joined(separator: "\n"))); continue
            }
            if let h = matches("^ {0,3}(#{1,6}) +(.*?)(?: +#+)?$", line) {
                blocks.append(.heading(h[1].count, h[2])); i += 1; continue
            }
            if i+1 < lines.count, matches("^ {0,3}(=+|-+) *$", lines[i+1]) != nil,
               !startsBlock(line), !trimmed.contains("|") {
                blocks.append(.heading(lines[i+1].trimmingCharacters(in: .whitespaces).hasPrefix("=") ? 1 : 2, trimmed)); i += 2; continue
            }
            if i+1 < lines.count, let align = alignment(lines[i+1]),
               cells(line).count == align.count, (line.contains("|") || align.count > 1) {
                let header = cells(line); var rows = [[String]](); i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty && !startsBlock(lines[i]) {
                    var row = cells(lines[i]); row += Array(repeating: "", count: max(0, header.count-row.count))
                    // Keep excess cells instead of silently dropping source text.
                    if row.count > header.count { row = Array(row.prefix(header.count-1)) + [row.dropFirst(header.count-1).joined(separator: " | ")] }
                    rows.append(row); i += 1
                }
                blocks.append(.table(header, rows, align)); continue
            }
            if rule(line) { blocks.append(.rule); i += 1; continue }
            if trimmed.hasPrefix(">") {
                var quote = [String]()
                while i < lines.count, let q = matches("^ {0,3}> ?(.*)$", lines[i]) { quote.append(q[1]); i += 1 }
                blocks.append(.quote(parse(quote.joined(separator: "\n")))); continue
            }
            if let l = list(line) {
                var text = l[4]; let indent = l[1].count; i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                      list(lines[i]) == nil, !startsBlock(lines[i]),
                      lines[i].prefix(while: { $0 == " " }).count > indent {
                    text += "\n" + lines[i].trimmingCharacters(in: .whitespaces); i += 1
                }
                let checked: Bool? = l[3].isEmpty ? nil : l[3].lowercased() == "x"
                blocks.append(.listItem(indent/2, l[2], text, checked)); continue
            }
            if let m = matches("^!\\[([^\\]]*)\\]\\((.*)\\)$", trimmed) {
                blocks.append(.image(m[1], m[2].trimmingCharacters(in: CharacterSet(charactersIn: "<>")))); i += 1; continue
            }
            var paragraph = [line]; i += 1
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty && !startsBlock(lines[i]) {
                if i+1 < lines.count && alignment(lines[i+1]) != nil { break }
                paragraph.append(lines[i]); i += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    static func permittedLink(_ url: URL) -> Bool {
        // No executable schemes, network file shares or credential-bearing URLs.
        guard url.user == nil, url.password == nil else { return false }
        if url.isFileURL { return url.host == nil || url.host == "" || url.host == "localhost" }
        return ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
    static func inline(_ text: String, baseURL: URL?) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace), baseURL: baseURL)) ?? AttributedString(text)
        for run in value.runs {
            if let link = run.link, !permittedLink(link) { value[run.range].link = nil }
        }
        return value
    }
}
