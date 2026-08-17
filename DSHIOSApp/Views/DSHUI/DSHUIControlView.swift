import SwiftUI

struct DSHUIControlView: View {
    let component: DSHUIComponent
    let onAction: (String, [String: JSONValue]) -> Void
    @State private var text: String
    @State private var selected: Int
    @State private var checked: Bool
    @State private var sliderValue: Double
    @State private var wasTriggered = false

    init(component: DSHUIComponent, onAction: @escaping (String, [String: JSONValue]) -> Void) {
        self.component = component
        self.onAction = onAction
        let minimum = component.value["min"]?.doubleValue ?? 0
        let step = max(0.0001, component.value["step"]?.doubleValue ?? 1)
        let maximum = max(minimum + step, component.value["max"]?.doubleValue ?? 100)
        let sliderValue = component.value["value"]?.doubleValue ?? minimum
        _text = State(initialValue: component.value["value"]?.stringValue ?? "")
        _selected = State(initialValue: component.value["selected"]?.intValue ?? 0)
        _checked = State(initialValue: component.value["checked"]?.boolValue ?? false)
        _sliderValue = State(initialValue: min(maximum, max(minimum, sliderValue)))
    }

    @ViewBuilder var body: some View {
        switch component.type {
        case "button", "submit":
            Button { emit(["type": .string(component.type), "label": .string(label)]); wasTriggered = true } label: {
                Label(wasTriggered ? "已触发" : label, systemImage: component.value["icon"]?.stringValue == nil ? "arrow.right.circle" : "sparkles")
                    .frame(maxWidth: component.value["full"]?.boolValue == true ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(tone)
            .disabled(action == nil)
        case "input":
            if [nil, "text", "email"].contains(component.value["inputType"]?.stringValue) {
                VStack(alignment: .leading, spacing: 5) {
                    if !label.isEmpty { Text(label).font(.caption).foregroundStyle(.secondary) }
                    TextField(component.value["placeholder"]?.stringValue ?? "", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { emit(["type": .string("input"), "value": .string(text), "submit": .bool(true)]) }
                }
            } else {
                Label("不支持在生成界面中输入敏感信息", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
        case "textarea":
            VStack(alignment: .leading, spacing: 6) {
                if !label.isEmpty { Text(label).font(.caption).foregroundStyle(.secondary) }
                TextField(component.value["placeholder"]?.stringValue ?? "", text: $text, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
                if action != nil { Button("提交") { emit(["type": .string("textarea"), "value": .string(text), "submit": .bool(true)]) }.buttonStyle(.bordered) }
            }
        case "select":
            Picker(label, selection: $selected) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in Text(option).tag(index) }
            }
            .pickerStyle(.menu)
            .onChange(of: selected) { _, value in emit(["type": .string("select"), "selected": .number(Double(value)), "value": .string(options.indices.contains(value) ? options[value] : "")]) }
        case "checkbox", "switch":
            Toggle(label, isOn: $checked)
                .onChange(of: checked) { _, value in emit(["type": .string(component.type), "checked": .bool(value)]) }
        case "slider":
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(label).font(.caption); Spacer(); Text(sliderValue.formatted()).font(.caption).foregroundStyle(.secondary) }
                Slider(value: $sliderValue, in: minimum...maximum, step: step) { editing in
                    if !editing { emit(["type": .string("slider"), "value": .number(sliderValue)]) }
                }
            }
        case "radio":
            VStack(alignment: .leading, spacing: 7) {
                if !label.isEmpty { Text(label).font(.subheadline.weight(.medium)) }
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        selected = index
                        emit(["type": .string("radio"), "selected": .number(Double(index)), "value": .string(option)])
                    } label: {
                        Label(option, systemImage: selected == index ? "largecircle.fill.circle" : "circle").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }
        default: EmptyView()
        }
    }

    private var action: String? { component.value["action"]?.stringValue }
    private var label: String { component.value["label"]?.stringValue ?? (component.type == "submit" ? "提交" : "") }
    private var options: [String] { component.value["options"]?.arrayValue?.compactMap { $0.stringValue ?? $0["label"]?.stringValue } ?? [] }
    private var minimum: Double { component.value["min"]?.doubleValue ?? 0 }
    private var maximum: Double { max(minimum + step, component.value["max"]?.doubleValue ?? 100) }
    private var step: Double { max(0.0001, component.value["step"]?.doubleValue ?? 1) }
    private var tone: Color { component.value["tone"]?.stringValue == "danger" ? .red : .accentColor }

    private func emit(_ payload: [String: JSONValue]) {
        guard let action else { return }
        onAction(action, payload)
    }
}
