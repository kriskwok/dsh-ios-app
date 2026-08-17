import SwiftUI

struct DSHUITabsView: View {
    let groups: [DSHUIGroup]
    let onAction: (String, [String: JSONValue]) -> Void
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("标签", selection: $selected) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in Text(group.title).tag(index) }
            }.pickerStyle(.segmented)
            if groups.indices.contains(selected) {
                ForEach(groups[selected].items) { DSHUIComponentView(component: $0, onAction: onAction) }
            }
        }
    }
}

struct DSHUIAccordionView: View {
    let groups: [DSHUIGroup]
    let onAction: (String, [String: JSONValue]) -> Void

    var body: some View {
        VStack(spacing: 7) {
            ForEach(groups) { group in
                DisclosureGroup(group.title) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.items) { DSHUIComponentView(component: $0, onAction: onAction) }
                    }.padding(.top, 7)
                }
            }
        }
    }
}
