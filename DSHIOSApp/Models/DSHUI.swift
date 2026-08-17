import Foundation

struct DSHUIDocument: Identifiable, Equatable {
    let id: String
    let title: String?
    let gap: Double
    let items: [DSHUIComponent]
}

struct DSHUIGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [DSHUIComponent]
}

struct DSHUIComponent: Identifiable, Equatable {
    let id: String
    let type: String
    let value: JSONValue
    let children: [DSHUIComponent]
    let groups: [DSHUIGroup]
}

enum DSHUIContentSegment: Identifiable, Equatable {
    case markdown(id: String, text: String)
    case interface(DSHUIDocument)

    var id: String {
        switch self {
        case .markdown(let id, _): id
        case .interface(let document): document.id
        }
    }
}

enum DSHUIParser {
    private static let openingMarker = "```dsh-ui"
    private static let maximumJSONBytes = 256 * 1_024
    private static let maximumNodes = 200
    private static let maximumDepth = 8
    private static let supportedTypes: Set<String> = [
        "text", "row", "col", "grid", "card", "button", "input", "textarea",
        "select", "checkbox", "switch", "slider", "radio", "submit", "quiz",
        "link", "badge", "stat", "progress", "divider", "spacer", "list", "table",
        "chart", "tabs", "accordion", "avatar", "plot", "callout", "steps",
        "keyvalue", "json", "code", "diff", "copy", "mermaid", "scene3d",
        "timeline", "file-tree", "breadcrumb"
    ]

    static func segments(in text: String) -> [DSHUIContentSegment] {
        var output: [DSHUIContentSegment] = []
        var cursor = text.startIndex
        var segmentIndex = 0

        while let opening = nextOpening(in: text, from: cursor),
              let closing = closingFence(in: text, after: opening.upperBound) {
            appendMarkdown(String(text[cursor..<opening.lowerBound]), index: &segmentIndex, to: &output)

            let jsonText = String(text[opening.upperBound..<closing.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let document = document(from: jsonText, id: "dsh-ui-\(segmentIndex)") {
                output.append(.interface(document))
            } else {
                let fallback = String(text[opening.lowerBound..<closing.upperBound])
                appendMarkdown(fallback, index: &segmentIndex, to: &output)
            }
            segmentIndex += 1
            cursor = closing.upperBound
        }

        appendMarkdown(String(text[cursor...]), index: &segmentIndex, to: &output)
        return output
    }

    private static func nextOpening(in text: String, from start: String.Index) -> Range<String.Index>? {
        var searchStart = start
        while let marker = text.range(of: openingMarker, range: searchStart..<text.endIndex) {
            let lineStart = text[..<marker.lowerBound].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
            let lineEnd = text[marker.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let prefix = text[lineStart..<marker.lowerBound]
            let suffix = text[marker.upperBound..<lineEnd]
            if prefix.allSatisfy(\.isWhitespace), suffix.allSatisfy(\.isWhitespace) {
                let bodyStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                return marker.lowerBound..<bodyStart
            }
            searchStart = marker.upperBound
        }
        return nil
    }

    private static func closingFence(in text: String, after start: String.Index) -> Range<String.Index>? {
        var searchStart = start
        while let marker = text.range(of: "```", range: searchStart..<text.endIndex) {
            let lineStart = text[..<marker.lowerBound].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
            let lineEnd = text[marker.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let prefix = text[lineStart..<marker.lowerBound]
            let suffix = text[marker.upperBound..<lineEnd]
            if prefix.allSatisfy(\.isWhitespace), suffix.allSatisfy(\.isWhitespace) {
                let consumedEnd = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                return lineStart..<consumedEnd
            }
            searchStart = marker.upperBound
        }
        return nil
    }

    private static func appendMarkdown(
        _ text: String,
        index: inout Int,
        to output: inout [DSHUIContentSegment]
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        output.append(.markdown(id: "markdown-\(index)", text: text))
        index += 1
    }

    private static func document(from text: String, id: String) -> DSHUIDocument? {
        guard let data = text.data(using: .utf8), data.count <= maximumJSONBytes,
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = json.objectValue,
              let rawItems = object["items"]?.arrayValue else { return nil }

        var nodeCount = 0
        let items = rawItems.enumerated().compactMap { index, value in
            component(from: value, path: "\(index)", depth: 1, nodeCount: &nodeCount)
        }
        return DSHUIDocument(
            id: id,
            title: object["title"]?.stringValue?.prefixString(200),
            gap: min(24, max(4, object["gap"]?.doubleValue ?? 12)),
            items: items
        )
    }

    private static func component(
        from value: JSONValue,
        path: String,
        depth: Int,
        nodeCount: inout Int
    ) -> DSHUIComponent? {
        guard depth <= maximumDepth, nodeCount < maximumNodes,
              let type = value["type"]?.stringValue,
              supportedTypes.contains(type) else { return nil }
        nodeCount += 1

        let children: [DSHUIComponent]
        if ["row", "col", "grid", "card"].contains(type) {
            children = (value["items"]?.arrayValue ?? []).enumerated().compactMap { index, child in
                component(from: child, path: "\(path).\(index)", depth: depth + 1, nodeCount: &nodeCount)
            }
        } else {
            children = []
        }

        let rawGroups: [JSONValue]
        if type == "tabs" {
            rawGroups = value["tabs"]?.arrayValue ?? []
        } else if type == "accordion" {
            rawGroups = value["items"]?.arrayValue ?? []
        } else {
            rawGroups = []
        }
        let groups = rawGroups.enumerated().map { groupIndex, group -> DSHUIGroup in
            let items = (group["items"]?.arrayValue ?? []).enumerated().compactMap { index, child in
                component(
                    from: child,
                    path: "\(path).g\(groupIndex).\(index)",
                    depth: depth + 1,
                    nodeCount: &nodeCount
                )
            }
            return DSHUIGroup(
                id: "\(path).g\(groupIndex)",
                title: (group["label"]?.stringValue ?? group["title"]?.stringValue ?? "第 \(groupIndex + 1) 项").prefixString(100),
                items: items
            )
        }

        return DSHUIComponent(id: path, type: type, value: value, children: children, groups: groups)
    }
}

private extension String {
    func prefixString(_ maximumLength: Int) -> String {
        String(prefix(maximumLength))
    }
}
