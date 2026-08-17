import Charts
import SwiftUI
import UIKit

struct DSHUIRichText: View {
    let segments: [DSHUIContentSegment]
    let onAction: (String, [String: JSONValue]) -> Void

    init(_ text: String, onAction: @escaping (String, [String: JSONValue]) -> Void) {
        segments = DSHUIParser.segments(in: text)
        self.onAction = onAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment {
                case .markdown(_, let text):
                    MarkdownText(text)
                case .interface(let document):
                    DSHUIDocumentView(document: document, onAction: onAction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DSHUIDocumentView: View {
    let document: DSHUIDocument
    let onAction: (String, [String: JSONValue]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: document.gap) {
            if let title = document.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            ForEach(document.items) { component in
                DSHUIComponentView(component: component, onAction: onAction)
            }
        }
        .padding(13)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(document.title ?? "交互界面")
    }
}

struct DSHUIComponentView: View {
    let component: DSHUIComponent
    let onAction: (String, [String: JSONValue]) -> Void

    @ViewBuilder
    var body: some View {
        switch component.type {
        case "text": textView
        case "row":
            HStack(alignment: .top, spacing: gap) { childViews }
        case "col":
            VStack(alignment: .leading, spacing: gap) { childViews }
        case "grid":
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gap) { childViews }
        case "card": cardView
        case "button", "input", "textarea", "select", "checkbox", "switch", "slider", "radio", "submit":
            DSHUIControlView(component: component, onAction: onAction)
        case "link": linkView
        case "badge": badgeView
        case "stat": statView
        case "progress": progressView
        case "divider": Divider()
        case "spacer": Color.clear.frame(height: 8)
        case "list": listView
        case "table": tableView
        case "chart": DSHUIChartView(value: component.value)
        case "tabs": DSHUITabsView(groups: component.groups, onAction: onAction)
        case "accordion": DSHUIAccordionView(groups: component.groups, onAction: onAction)
        case "avatar": avatarView
        case "callout": calloutView
        case "steps": stepsView
        case "keyvalue": keyValueView
        case "json": monospacedCard(jsonString(component.value["value"]))
        case "code": monospacedCard(component.value["code"]?.stringValue ?? "")
        case "diff": diffView
        case "copy": copyView
        case "timeline": timelineView
        case "breadcrumb": breadcrumbView
        case "mermaid": sourceFallback(title: "Mermaid", content: component.value["code"]?.stringValue ?? "")
        case "plot": sourceFallback(title: "函数图", content: component.value["title"]?.stringValue ?? "当前原生版本暂不支持函数拖拽")
        case "scene3d": sourceFallback(title: "3D 场景", content: component.value["title"]?.stringValue ?? "当前原生版本暂不支持 3D 交互")
        case "file-tree": sourceFallback(title: "文件树", content: flattenedDescription(component.value["items"]))
        case "quiz": sourceFallback(title: "互动题目", content: component.value["question"]?.stringValue ?? "")
        default: EmptyView()
        }
    }

    private var gap: CGFloat { min(20, max(4, component.value["gap"]?.doubleValue ?? 10)) }

    @ViewBuilder private var childViews: some View {
        ForEach(component.children) { child in
            DSHUIComponentView(component: child, onAction: onAction)
        }
    }

    private var gridColumns: [GridItem] {
        let count = min(4, max(1, component.value["cols"]?.intValue ?? 2))
        return Array(repeating: GridItem(.flexible(), spacing: gap), count: count)
    }

    private var textView: some View {
        let size = component.value["size"]?.stringValue ?? "body"
        let text = component.value["content"]?.stringValue ?? ""
        return Text(text)
            .font(textFont(size))
            .foregroundStyle(["muted", "caption"].contains(size) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: component.value["center"]?.boolValue == true ? .center : .leading)
            .textSelection(.enabled)
    }

    private func textFont(_ size: String) -> Font {
        switch size {
        case "h1": .title.bold()
        case "h2": .title2.bold()
        case "h3": .headline
        case "caption": .caption
        default: .body
        }
    }

    private var cardView: some View {
        VStack(alignment: .leading, spacing: gap) {
            if let title = component.value["title"]?.stringValue { Text(title).font(.subheadline.weight(.semibold)) }
            childViews
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var linkView: some View {
        let label = component.value["label"]?.stringValue ?? "链接"
        if let value = component.value["href"]?.stringValue,
           let url = URL(string: value), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            Link(destination: url) { Label(label, systemImage: "arrow.up.right.square") }
        } else {
            Text(label)
        }
    }

    private var badgeView: some View {
        Text([component.value["icon"]?.stringValue, component.value["label"]?.stringValue].compactMap { $0 }.joined(separator: " "))
            .font(.caption.weight(.semibold))
            .foregroundStyle(toneColor(component.value["tone"]?.stringValue))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(toneColor(component.value["tone"]?.stringValue).opacity(0.12), in: Capsule())
    }

    private var statView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(component.value["label"]?.stringValue ?? "").font(.caption).foregroundStyle(.secondary)
            Text(component.value["value"]?.stringValue ?? "—").font(.title3.weight(.semibold))
            if let delta = component.value["delta"]?.stringValue {
                Text(delta).font(.caption.weight(.medium)).foregroundStyle(delta.hasPrefix("-") ? .red : .green)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 11))
    }

    private var progressView: some View {
        let value = min(100, max(0, component.value["value"]?.doubleValue ?? 0))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(component.value["label"]?.stringValue ?? "进度").font(.subheadline)
                Spacer()
                Text(component.value["valueLabel"]?.stringValue ?? "\(Int(value))%").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: value, total: 100).tint(.accentColor)
        }
        .accessibilityValue("\(Int(value))%")
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((component.value["items"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.stringValue ?? item["title"]?.stringValue ?? flattenedDescription(item))
                        if let description = item["desc"]?.stringValue {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var tableView: some View {
        let columns = component.value["columns"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let rows = component.value["rows"]?.arrayValue ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Text(column).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array((row.arrayValue ?? []).enumerated()), id: \.offset) { _, cell in
                            Text(flattenedDescription(cell)).font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var avatarView: some View {
        HStack(spacing: 9) {
            Circle().fill(Color.accentColor.opacity(0.16)).frame(width: 34, height: 34)
                .overlay(Text(String((component.value["name"]?.stringValue ?? "AI").prefix(1))).font(.subheadline.weight(.bold)))
            Text(component.value["name"]?.stringValue ?? "AI").font(.subheadline.weight(.medium))
        }
    }

    private var calloutView: some View {
        let color = toneColor(component.value["tone"]?.stringValue)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: calloutIcon(component.value["tone"]?.stringValue)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                if let title = component.value["title"]?.stringValue { Text(title).font(.subheadline.weight(.semibold)) }
                Text(component.value["content"]?.stringValue ?? "").font(.subheadline)
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
    }

    private var stepsView: some View {
        let current = component.value["current"]?.intValue ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((component.value["steps"]?.arrayValue ?? []).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: index < current ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(index < current ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step["title"]?.stringValue ?? "步骤 \(index + 1)").font(.subheadline.weight(.medium))
                        if let description = step["desc"]?.stringValue { Text(description).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var keyValueView: some View {
        VStack(spacing: 7) {
            ForEach(Array((component.value["pairs"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top) {
                    Text(pair["key"]?.stringValue ?? "").foregroundStyle(.secondary)
                    Spacer(minLength: 20)
                    Text(pair["value"]?.stringValue ?? flattenedDescription(pair["value"])).multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
            }
        }
    }

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((component.value["diffs"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, diff in
                VStack(alignment: .leading, spacing: 5) {
                    Text(diff["path"]?.stringValue ?? "文件变更").font(.caption.weight(.semibold))
                    if let old = diff["oldText"]?.stringValue, !old.isEmpty {
                        Text(old).foregroundStyle(.red).strikethrough().font(.system(.caption, design: .monospaced))
                    }
                    Text(diff["newText"]?.stringValue ?? "").foregroundStyle(.green).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .padding(10).background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var copyView: some View {
        Button {
            UIPasteboard.general.string = component.value["text"]?.stringValue ?? ""
        } label: {
            Label(component.value["label"]?.stringValue ?? "复制", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
    }

    private var timelineView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((component.value["items"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(item["title"]?.stringValue ?? "").font(.subheadline.weight(.medium)); Spacer(); Text(item["time"]?.stringValue ?? "").font(.caption2).foregroundStyle(.secondary) }
                        if let description = item["desc"]?.stringValue { Text(description).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var breadcrumbView: some View {
        HStack(spacing: 5) {
            ForEach(Array((component.value["items"]?.arrayValue?.compactMap(\.stringValue) ?? []).enumerated()), id: \.offset) { index, item in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Text(item).font(.caption).lineLimit(1)
            }
        }
    }

    private func monospacedCard(_ value: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .padding(10).background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceFallback(title: String, content: String) -> some View {
        DisclosureGroup(title) { monospacedCard(content) }
            .font(.subheadline).tint(.secondary)
    }

    private func toneColor(_ tone: String?) -> Color {
        switch tone {
        case "danger", "error": .red
        case "success": .green
        case "warn", "warning": .orange
        default: .accentColor
        }
    }

    private func calloutIcon(_ tone: String?) -> String {
        switch tone {
        case "success": "checkmark.circle.fill"
        case "warning": "exclamationmark.triangle.fill"
        case "error": "xmark.octagon.fill"
        default: "info.circle.fill"
        }
    }
}
