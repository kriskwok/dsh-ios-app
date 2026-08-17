import SwiftUI

struct MarkdownText: View {
    let text: String
    @State private var blocks: [MarkdownBlock]?

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let blocks {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                }
            } else {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(5)
            }
        }
        .textSelection(.enabled)
        .task(id: text) {
            let normalized = MarkdownBlockParser.normalize(text)
            blocks = MarkdownBlockParser.blocks(in: normalized)
        }
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, text: String)
    case table(headers: [String], rows: [[String]])
    case divider
}

enum MarkdownBlockParser {
    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    static func blocks(in text: String) -> [MarkdownBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if isFenceStart(line) {
                let language = fenceLanguage(in: line)
                index += 1
                var code: [String] = []
                while index < lines.count, !isFenceEnd(lines[index]) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headers = tableRow(lines[index]),
               isTableDelimiter(lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableRow(lines[index]), !row.isEmpty {
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if let item = unorderedItem(trimmed) {
                var items = [item]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = unorderedItem(next) else { break }
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(trimmed) {
                var items = [item.text]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = orderedItem(next) else { break }
                    items.append(item.text)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if let quote = quoteLine(trimmed) {
                var linesInQuote = [quote]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let quote = quoteLine(next) else { break }
                    linesInQuote.append(quote)
                    index += 1
                }
                blocks.append(.quote(linesInQuote.joined(separator: "\n")))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || startsBlock(nextTrimmed, nextLine: index + 1 < lines.count ? lines[index + 1] : nil) {
                    break
                }
                paragraph.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks
    }

    private static func startsBlock(_ line: String, nextLine: String?) -> Bool {
        isFenceStart(line)
            || parseHeading(line) != nil
            || isDivider(line)
            || unorderedItem(line) != nil
            || orderedItem(line) != nil
            || quoteLine(line) != nil
            || (nextLine.map(isTableDelimiter) ?? false && tableRow(line) != nil)
    }

    private static func isFenceStart(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func fenceLanguage(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? nil : language
    }

    private static func isFenceEnd(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (level, text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "***" || compact == "___"
    }

    private static func unorderedItem(_ line: String) -> String? {
        guard let marker = line.first, "-*+".contains(marker) else { return nil }
        let remainder = line.dropFirst()
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        let item = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.isEmpty ? nil : item
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        var digits = ""
        var remainder = line[...]
        while let first = remainder.first, first.isNumber {
            digits.append(first)
            remainder = remainder.dropFirst()
        }
        guard !digits.isEmpty, remainder.first == "." || remainder.first == ")" else { return nil }
        remainder = remainder.dropFirst()
        guard remainder.first == " " || remainder.first == "\t",
              let number = Int(digits) else { return nil }
        return (number, remainder.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func quoteLine(_ line: String) -> String? {
        guard line.first == ">" else { return nil }
        return String(line.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func tableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.first == "|" { value.removeFirst() }
        if value.last == "|" { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard let cells = tableRow(line), cells.count >= 1 else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard value.count >= 3 else { return false }
            let withoutAlignment = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return withoutAlignment.allSatisfy { $0 == "-" }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item)
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", text: item)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 5) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ text: String) -> some View {
        let value = (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
        return Text(value)
            .font(.body)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(5)
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(.body.weight(.semibold))
                .frame(minWidth: marker.count == 1 ? 10 : 22, alignment: .trailing)
            inlineText(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private let columnWidth: CGFloat = 128

    var body: some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(columnWidth), spacing: 0), count: max(1, columnCount)),
                spacing: 0
            ) {
                ForEach(0..<(max(1, columnCount) * (rows.count + 1)), id: \.self) { index in
                    let row = index / max(1, columnCount)
                    let column = index % max(1, columnCount)
                    let cells = row == 0 ? headers : rows[row - 1]
                    let text = column < cells.count ? cells[column] : ""
                    Text(markdownTableValue(text))
                        .font(row == 0 ? .subheadline.weight(.semibold) : .subheadline)
                        .multilineTextAlignment(.leading)
                        .frame(width: columnWidth, alignment: .leading)
                        .padding(8)
                        .background(row == 0 ? Color.primary.opacity(0.08) : Color.clear)
                        .overlay {
                            Rectangle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func markdownTableValue(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}
