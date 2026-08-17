import Charts
import SwiftUI

struct DSHUIChartView: View {
    struct Entry: Identifiable { let id: Int; let label: String; let value: Double }
    let kind: String
    let entries: [Entry]

    init(value: JSONValue) {
        kind = value["kind"]?.stringValue ?? "bars"
        entries = (value["data"]?.arrayValue ?? []).enumerated().compactMap { index, item in
            guard let number = item["value"]?.doubleValue else { return nil }
            return Entry(id: index, label: item["label"]?.stringValue ?? "\(index + 1)", value: number)
        }
    }

    var body: some View {
        Chart(entries) { entry in
            if kind == "line" {
                LineMark(x: .value("项目", entry.label), y: .value("数值", entry.value)).interpolationMethod(.catmullRom)
                PointMark(x: .value("项目", entry.label), y: .value("数值", entry.value))
            } else if kind == "donut" {
                SectorMark(angle: .value("数值", max(0, entry.value)), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .foregroundStyle(by: .value("项目", entry.label))
            } else {
                BarMark(x: .value("项目", entry.label), y: .value("数值", max(0, entry.value)))
                    .foregroundStyle(Color.accentColor.gradient)
            }
        }
        .frame(height: 190)
        .chartLegend(kind == "donut" ? .visible : .hidden)
    }
}
