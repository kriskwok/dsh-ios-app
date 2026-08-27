import SwiftUI

private struct BasicAuthTokenKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var basicAuthToken: String? {
        get { self[BasicAuthTokenKey.self] }
        set { self[BasicAuthTokenKey.self] = newValue }
    }
}

struct AuthAsyncImage: View {
    let url: URL
    let authToken: String?
    @State private var image: UIImage?
    @State private var didFail = false
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if didFail {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("图片加载失败")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 200)
                    .overlay(ProgressView())
            }
        }
        .task(id: url.absoluteString) {
            guard !didLoad else { return }
            await loadImage()
        }
    }

    private func loadImage() async {
        var request = URLRequest(url: url)
        if let authToken {
            request.setValue("Basic \(authToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                  let uiImage = UIImage(data: data) else {
                await MainActor.run { didFail = true }
                return
            }
            await MainActor.run {
                self.image = uiImage
                self.didLoad = true
            }
        } catch {
            await MainActor.run { didFail = true }
        }
    }
}

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
    case image(alt: String, url: String)
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

            if let image = parseImageLine(trimmed) {
                blocks.append(.image(alt: image.alt, url: image.url))
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
            || parseImageLine(line) != nil
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

    private static func parseImageLine(_ line: String) -> (alt: String, url: String)? {
        guard line.hasPrefix("![") else { return nil }
        guard let closeBracket = line.firstIndex(of: "]") else { return nil }
        let altRange = line.index(line.startIndex, offsetBy: 2)..<closeBracket
        let alt = String(line[altRange])
        let afterBracket = line.index(after: closeBracket)
        guard afterBracket < line.endIndex, line[afterBracket] == "(" else { return nil }
        let urlStart = line.index(after: afterBracket)
        guard let closeParen = line[urlStart...].firstIndex(of: ")") else { return nil }
        let url = String(line[urlStart..<closeParen])
        guard !url.isEmpty else { return nil }
        return (alt, url)
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
    @State private var showFullImage = false

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
        case .image(let alt, let url):
            MarkdownImageView(alt: alt, url: url, isPresented: $showFullImage)
        }
    }

    private func inlineText(_ text: String) -> some View {
        let value = MarkdownInlineParser.parse(text)
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

struct MarkdownImageView: View {
    let alt: String
    let url: String
    @Binding var isPresented: Bool
    @Environment(\.basicAuthToken) private var authToken

    var body: some View {
        Group {
            if let dataURL = parseDataURL(url) {
                base64Image(data: dataURL)
            } else if let imageURL = URL(string: url) {
                AuthAsyncImage(url: imageURL, authToken: authToken)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { isPresented = true }
            } else {
                Text("[\(alt)](\(url))")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .fullScreenCover(isPresented: $isPresented) {
            FullscreenImageView(url: url, alt: alt, isPresented: $isPresented)
        }
    }

    private func parseDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:image/") else { return nil }
        guard let commaIndex = url.firstIndex(of: ",") else { return nil }
        let base64String = String(url[url.index(after: commaIndex)...])
        return Data(base64Encoded: base64String)
    }

    private func base64Image(data: Data) -> some View {
        Group {
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { isPresented = true }
            } else {
                Text("[\(alt)]")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FullscreenImageView: View {
    let url: String
    let alt: String
    @Binding var isPresented: Bool
    @Environment(\.basicAuthToken) private var authToken
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loadedImage: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, min(lastScale * value, 5))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale < 1 {
                                    withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1 {
                                scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
                            } else {
                                scale = 2; lastScale = 2
                            }
                        }
                    }
            } else if didFail {
                Text("加载失败")
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ProgressView()
                    .tint(.white)
            }

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }
            .padding(16)
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        if let dataURL = parseDataURL(url), let uiImage = UIImage(data: dataURL) {
            await MainActor.run { loadedImage = uiImage }
            return
        }
        guard let imageURL = URL(string: url) else {
            await MainActor.run { didFail = true }
            return
        }
        var request = URLRequest(url: imageURL)
        if let authToken {
            request.setValue("Basic \(authToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                  let uiImage = UIImage(data: data) else {
                await MainActor.run { didFail = true }
                return
            }
            await MainActor.run { loadedImage = uiImage }
        } catch {
            await MainActor.run { didFail = true }
        }
    }

    private func parseDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:image/") else { return nil }
        guard let commaIndex = url.firstIndex(of: ",") else { return nil }
        let base64String = String(url[url.index(after: commaIndex)...])
        return Data(base64Encoded: base64String)
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    /// Column width wide enough for typical table content; table scrolls
    /// horizontally when there are more columns than fit on screen.
    private let columnWidth: CGFloat = 160

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true, rowIndex: -1)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, isHeader: false, rowIndex: index)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func tableRow(_ cells: [String], isHeader: Bool, rowIndex: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<max(1, columnCount), id: \.self) { col in
                let text = col < cells.count ? cells[col] : ""
                Text(markdownTableValue(text))
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: columnWidth, alignment: .topLeading)
                    .background(rowBackground(isHeader: isHeader, rowIndex: rowIndex))
                    .overlay(alignment: .trailing) {
                        // Vertical separator between columns
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 0.5)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            // Horizontal separator below each row
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private func rowBackground(isHeader: Bool, rowIndex: Int) -> Color {
        if isHeader {
            return Color.primary.opacity(0.08)
        }
        // Zebra striping for readability
        return rowIndex % 2 == 0 ? Color.clear : Color.primary.opacity(0.03)
    }

    private func markdownTableValue(_ text: String) -> AttributedString {
        MarkdownInlineParser.parse(text)
    }
}

// MARK: - Inline Markdown Parser

/// A lightweight inline markdown parser that handles inline code, bold, italic,
/// strikethrough, and links. More robust than `AttributedString(markdown:)` for
/// partial / streaming content and gives explicit control over inline-code styling.
enum MarkdownInlineParser {
    static func parse(_ text: String) -> AttributedString {
        var result = AttributedString()
        var i = text.startIndex
        while i < text.endIndex {
            if let (seg, next) = scanInlineCode(text, from: i) {
                result.append(seg); i = next; continue
            }
            if let (seg, next) = scanStrikethrough(text, from: i) {
                result.append(seg); i = next; continue
            }
            if let (seg, next) = scanBold(text, from: i) {
                result.append(seg); i = next; continue
            }
            if let (seg, next) = scanItalic(text, from: i) {
                result.append(seg); i = next; continue
            }
            if let (seg, next) = scanLink(text, from: i) {
                result.append(seg); i = next; continue
            }
            // Accumulate plain-text runs to avoid per-character attribute overhead.
            var j = i
            while j < text.endIndex {
                let ch = text[j]
                if ch == "`" || ch == "~" || ch == "*" || ch == "_" || ch == "[" { break }
                j = text.index(after: j)
            }
            if j == i { j = text.index(after: i) }
            result.append(AttributedString(String(text[i..<j])))
            i = j
        }
        return result
    }

    // MARK: Pattern scanners

    /// Inline code: `` `code` `` — content is literal, no nested parsing.
    private static func scanInlineCode(_ text: String, from i: String.Index) -> (AttributedString, String.Index)? {
        guard text[i] == "`" else { return nil }
        let contentStart = text.index(after: i)
        guard let end = text[contentStart...].firstIndex(of: "`") else { return nil }
        let code = String(text[contentStart..<end])
        var attr = AttributedString(code)
        attr.font = .system(.callout, design: .monospaced)
        attr.backgroundColor = Color.secondary.opacity(0.15)
        attr.foregroundColor = Color.primary
        return (attr, text.index(after: end))
    }

    /// Strikethrough: `~~text~~`
    private static func scanStrikethrough(_ text: String, from i: String.Index) -> (AttributedString, String.Index)? {
        guard text[i] == "~" else { return nil }
        let next = text.index(after: i)
        guard next < text.endIndex, text[next] == "~" else { return nil }
        let contentStart = text.index(after: next)
        guard let end = findClosing(text, from: contentStart, marker: "~~") else { return nil }
        var attr = parse(String(text[contentStart..<end]))
        attr.strikethroughStyle = .single
        return (attr, text.index(end, offsetBy: 2))
    }

    /// Bold: `**text**` or `__text__`
    private static func scanBold(_ text: String, from i: String.Index) -> (AttributedString, String.Index)? {
        let ch = text[i]
        guard ch == "*" || ch == "_" else { return nil }
        let next = text.index(after: i)
        guard next < text.endIndex, text[next] == ch else { return nil }
        let marker = String(ch) + String(ch)
        let contentStart = text.index(next, offsetBy: 1)
        guard let end = findClosing(text, from: contentStart, marker: marker) else { return nil }
        var attr = parse(String(text[contentStart..<end]))
        attr.font = .body.weight(.bold)
        return (attr, text.index(end, offsetBy: 2))
    }

    /// Italic: `*text*` or `_text_` (underscore only at word boundaries).
    private static func scanItalic(_ text: String, from i: String.Index) -> (AttributedString, String.Index)? {
        let ch = text[i]
        guard ch == "*" || ch == "_" else { return nil }
        // Avoid matching the first char of ** or __
        let next = text.index(after: i)
        guard next >= text.endIndex || text[next] != ch else { return nil }
        // Underscore italic requires word boundary on the left.
        if ch == "_" {
            let prev = text.index(before: i)
            if i > text.startIndex, text[prev].isLetter || text[prev].isNumber { return nil }
        }
        let contentStart = next
        guard let end = findClosingSingle(text, from: contentStart, marker: ch) else { return nil }
        // Underscore italic requires word boundary on the right of content.
        if ch == "_" {
            let after = text.index(after: end)
            if after < text.endIndex, text[after].isLetter || text[after].isNumber { return nil }
        }
        var attr = parse(String(text[contentStart..<end]))
        attr.font = .body.italic()
        return (attr, text.index(after: end))
    }

    /// Link: `[text](url)`
    private static func scanLink(_ text: String, from i: String.Index) -> (AttributedString, String.Index)? {
        guard text[i] == "[" else { return nil }
        let contentStart = text.index(after: i)
        guard let closeBracket = text[contentStart...].firstIndex(of: "]") else { return nil }
        let afterBracket = text.index(after: closeBracket)
        guard afterBracket < text.endIndex, text[afterBracket] == "(" else { return nil }
        let urlStart = text.index(after: afterBracket)
        guard let closeParen = text[urlStart...].firstIndex(of: ")") else { return nil }
        let urlString = String(text[urlStart..<closeParen]).trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return nil }
        let label = String(text[contentStart..<closeBracket])
        var attr = parse(label)
        if let url = URL(string: urlString) {
            attr.link = url
        }
        attr.foregroundColor = Color.accentColor
        attr.underlineStyle = .single
        return (attr, text.index(after: closeParen))
    }

    // MARK: Helpers

    /// Find the next occurrence of a two-char marker (e.g. `**`, `~~`).
    private static func findClosing(_ text: String, from start: String.Index, marker: String) -> String.Index? {
        var i = start
        while i < text.endIndex {
            if text[i] == marker.first {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == marker.last { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Find the next single-char marker that is not part of a double marker.
    private static func findClosingSingle(_ text: String, from start: String.Index, marker: Character) -> String.Index? {
        var i = start
        while i < text.endIndex {
            if text[i] == marker {
                let next = text.index(after: i)
                // Skip double markers (they belong to bold/strikethrough).
                if next < text.endIndex, text[next] == marker {
                    i = text.index(after: next)
                    continue
                }
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }
}
