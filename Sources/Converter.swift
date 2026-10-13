import AppKit

extension NSAttributedString.Key {
    /// Nesting depth (0 = top level) of a list paragraph whose NSTextList was stripped for display.
    static let listLevel = NSAttributedString.Key("cleanpaste.listLevel")
}

/// Converts rich text (NSAttributedString) into plain text or Markdown.
enum TextCleaner {
    static func plain(_ source: NSAttributedString) -> String {
        Converter(source, markdown: false).run()
    }

    static func markdown(_ source: NSAttributedString) -> String {
        Converter(source, markdown: true).run()
    }
}

private final class TableBox {
    var cells: [Int: [Int: String]] = [:]

    var rows: [[String]] {
        guard let maxRow = cells.keys.max() else { return [] }
        let maxCol = cells.values.flatMap { $0.keys }.max() ?? 0
        return (0...maxRow).map { r in (0...maxCol).map { c in cells[r]?[c] ?? "" } }
    }
}

private enum Block {
    case blank
    case text(String)
    case heading(String)
    case list(String)
    case code(String)
    case table(TableBox)

    var isList: Bool { if case .list = self { return true } else { return false } }
    var isCode: Bool { if case .code = self { return true } else { return false } }
    var isBlank: Bool { if case .blank = self { return true } else { return false } }
}

private struct InlineStyle: Equatable {
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var link: String?
}

private struct Converter {
    let attr: NSAttributedString
    let ns: NSString
    let markdown: Bool
    let baseSize: CGFloat

    // List markers as AppKit/Word emit them: "\t•\t", "\t1.\t", "\to\t", plus Word's Symbol-font bullets
    private static let listRegex = try! NSRegularExpression(
        pattern: "^(\\t*)([•◦▪‣∙·–—\\-\\*\u{F0B7}\u{F0A7}\u{F0D8}§o]|\\d+[.)]?|[a-zA-Z][.)])\\t")

    init(_ source: NSAttributedString, markdown: Bool) {
        attr = source
        ns = source.string as NSString
        self.markdown = markdown
        var weights: [CGFloat: Int] = [:]
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            let size = ((value as? NSFont)?.pointSize ?? 12).rounded()
            weights[size, default: 0] += range.length
        }
        let dominant = weights.max { $0.value < $1.value }?.key ?? 12
        baseSize = dominant > 0 ? dominant : 12
    }

    // MARK: Paragraph walk

    func run() -> String {
        var blocks: [Block] = []
        var tables: [ObjectIdentifier: TableBox] = [:]
        var lastSpacingAfter: CGFloat = 0
        var loc = 0

        while loc < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(paragraph)
            var range = paragraph
            while range.length > 0, isNewline(ns.character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
            let style = attr.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle

            // Table: cells are collected, the table is emitted where its first cell appears
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                let text = inline(runs(in: range), stripBold: cell.startingRow == 0)
                    .replacingOccurrences(of: "  \n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                let box: TableBox
                if let existing = tables[ObjectIdentifier(cell.table)] {
                    box = existing
                } else {
                    box = TableBox()
                    tables[ObjectIdentifier(cell.table)] = box
                    blocks.append(.table(box))
                }
                var row = box.cells[cell.startingRow] ?? [:]
                if let current = row[cell.startingColumn], !text.isEmpty, !current.isEmpty {
                    row[cell.startingColumn] = current + " " + text
                } else if row[cell.startingColumn] == nil || !text.isEmpty {
                    row[cell.startingColumn] = text
                }
                box.cells[cell.startingRow] = row
                continue
            }

            let line = ns.substring(with: range)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.blank)
                lastSpacingAfter = 0
                continue
            }

            // Paragraph spacing becomes a blank line (only matters for plain-text output)
            let before = style?.paragraphSpacingBefore ?? 0
            let after = style?.paragraphSpacing ?? 0

            var block: Block
            let storedLevel = attr.attribute(.listLevel, at: paragraph.location, effectiveRange: nil) as? Int
            let hasTextList = storedLevel != nil || !(style?.textLists.isEmpty ?? true)
            if let match = Converter.listRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
               // A bare number ("\t1\t") is only a list marker when AppKit says this paragraph is in a list
               hasTextList || !(line as NSString).substring(with: match.range(at: 2)).allSatisfy(\.isNumber) {
                let tabs = match.range(at: 1).length
                let marker = (line as NSString).substring(with: match.range(at: 2))
                let level = storedLevel
                    ?? ((style?.textLists.count ?? 0) > 0 ? style!.textLists.count - 1 : max(0, tabs - 1))
                let contentRange = NSRange(location: range.location + match.range.length,
                                           length: range.length - match.range.length)
                let content = inline(runs(in: contentRange)).trimmingCharacters(in: .whitespaces)
                let ordered = marker.first?.isNumber == true
                let number = marker.filter(\.isNumber)
                if markdown {
                    let bullet = ordered ? "\(number). " : "- "
                    block = .list(String(repeating: "    ", count: level) + bullet + content)
                } else {
                    let bullet = ordered ? "\(number)." : "•"
                    block = .list(String(repeating: "  ", count: level) + bullet + " " + content)
                }
            } else {
                let paragraphRuns = runs(in: range)
                let significant = paragraphRuns.filter { !$0.text.allSatisfy(\.isWhitespace) }
                if markdown, !significant.isEmpty, significant.allSatisfy({ $0.style.code }) {
                    block = .code(paragraphRuns.map { clean($0.text) }.joined())
                } else if markdown, let level = headingLevel(for: range, length: line.count) {
                    block = .heading(String(repeating: "#", count: level) + " "
                        + inline(paragraphRuns, stripBold: true).trimmingCharacters(in: .whitespaces))
                } else {
                    block = .text(markdown
                        ? inline(paragraphRuns).trimmingCharacters(in: .whitespaces)
                        : inline(paragraphRuns))
                }
            }

            if !markdown, let previous = blocks.last, !previous.isBlank,
               !(previous.isList && block.isList),
               lastSpacingAfter + before >= 6 || (previous.isList && !block.isList) {
                blocks.append(.blank)
            }
            blocks.append(block)
            lastSpacingAfter = after
        }

        return markdown ? renderMarkdown(blocks) : renderPlain(blocks)
    }

    // MARK: Output

    private func renderPlain(_ blocks: [Block]) -> String {
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .blank: lines.append("")
            case .text(let s), .heading(let s), .list(let s), .code(let s): lines.append(s)
            case .table(let box):
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines += box.rows.map { $0.joined(separator: "\t") }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderMarkdown(_ blocks: [Block]) -> String {
        // Blank lines between two code lines stay inside the same code block
        var prepared = blocks
        for i in prepared.indices where prepared[i].isBlank && i > 0 && i < prepared.count - 1 {
            if prepared[i - 1].isCode && prepared[i + 1].isCode { prepared[i] = .code("") }
        }

        var out: [(kind: Block, text: String)] = []
        for block in prepared {
            switch block {
            case .blank:
                continue
            case .code(let line):
                if let last = out.last, last.kind.isCode {
                    out[out.count - 1].text += "\n" + line
                } else {
                    out.append((block, line))
                }
            case .text(let s), .heading(let s), .list(let s):
                out.append((block, s))
            case .table(let box):
                out.append((block, markdownTable(box.rows)))
            }
        }

        var result = ""
        for (index, item) in out.enumerated() {
            var piece = item.text
            if item.kind.isCode { piece = "```\n" + piece + "\n```" }
            if index > 0 {
                // Consecutive items of the same kind of list stay tight; switching bullet <-> numbered needs a gap
                let sameList = out[index - 1].kind.isList && item.kind.isList
                    && isOrdered(out[index - 1].text) == isOrdered(item.text)
                result += sameList ? "\n" : "\n\n"
            }
            result += piece
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isOrdered(_ listItem: String) -> Bool {
        listItem.trimmingCharacters(in: .whitespaces).first?.isNumber == true
    }

    private func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        func line(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        var lines = [line(header), line(header.map { _ in "---" })]
        lines += rows.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }

    // MARK: Inline

    private func runs(in range: NSRange) -> [(text: String, style: InlineStyle)] {
        var result: [(text: String, style: InlineStyle)] = []
        guard range.length > 0 else { return result }
        attr.enumerateAttributes(in: range) { attrs, r, _ in
            var style = InlineStyle()
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                style.bold = traits.contains(.bold) || NSFontManager.shared.weight(of: font) >= 9
                style.italic = traits.contains(.italic)
                style.code = traits.contains(.monoSpace) || font.isFixedPitch
            }
            if let skew = attrs[.obliqueness] as? NSNumber, skew.doubleValue != 0 { style.italic = true }
            if let strike = attrs[.strikethroughStyle] as? NSNumber, strike.intValue != 0 { style.strike = true }
            if let link = attrs[.link] { style.link = (link as? URL)?.absoluteString ?? (link as? String) }

            let text = ns.substring(with: r)
            if let last = result.last, last.style == style {
                result[result.count - 1].text += text
            } else {
                result.append((text, style))
            }
        }
        return result
    }

    private func inline(_ runs: [(text: String, style: InlineStyle)], stripBold: Bool = false) -> String {
        var out = ""
        for (raw, style) in runs {
            let text = clean(raw)
            guard markdown else { out += text; continue }

            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if core.isEmpty { out += text; continue }
            let lead = String(text.prefix { $0.isWhitespace || $0.isNewline })
            let trail = String(text.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())

            var piece: String
            if style.code && !core.contains("`") {
                piece = "`\(core)`"
            } else {
                piece = escape(core)
                let bold = style.bold && !stripBold
                if bold && style.italic { piece = "***\(piece)***" }
                else if bold { piece = "**\(piece)**" }
                else if style.italic { piece = "*\(piece)*" }
                if style.strike { piece = "~~\(piece)~~" }
            }
            if let link = style.link, !link.isEmpty {
                piece = core == link ? "<\(link)>" : "[\(piece)](\(link))"
            }
            out += lead + piece + trail
        }
        return out
    }

    private func headingLevel(for range: NSRange, length: Int) -> Int? {
        guard length <= 300 else { return nil }
        let text = ns.substring(with: range) as NSString
        let first = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound,
              let font = attr.attribute(.font, at: range.location + first.location, effectiveRange: nil) as? NSFont
        else { return nil }
        let ratio = font.pointSize / baseSize
        switch ratio {
        case 1.75...: return 1
        case 1.4...: return 2
        case 1.1...: return 3
        default: return nil
        }
    }

    // MARK: Text helpers

    private func clean(_ s: String) -> String {
        var t = s
        for (from, to) in [("\u{00A0}", " "), ("\u{FFFC}", ""), ("\u{200B}", ""), ("\u{FEFF}", "")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        let newline = markdown ? "  \n" : "\n"
        for separator in ["\u{2028}", "\u{0B}"] {
            t = t.replacingOccurrences(of: separator, with: newline)
        }
        return t
    }

    private func escape(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            switch c {
            case "*", "`":
                out += "\\" + String(c)
            case "_":
                let prevWord = i > 0 && chars[i - 1].isLetter || i > 0 && chars[i - 1].isNumber
                let nextWord = i < chars.count - 1 && (chars[i + 1].isLetter || chars[i + 1].isNumber)
                out += (prevWord && nextWord) ? "_" : "\\_"
            default:
                out.append(c)
            }
        }
        return out
    }

    private func isNewline(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x2029
    }
}
