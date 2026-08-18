import SwiftUI

struct ModelSelectorPopover: View {
    @ObservedObject var viewModel: ChatSessionViewModel
    @Binding var isPresented: Bool

    private var catalog: AgentModelCatalog? { viewModel.modelCatalog }

    private var sortedGroups: [AgentModelGroup] {
        guard let catalog else { return [] }
        return catalog.groups.sorted { lhs, rhs in
            if lhs.isOfficial != rhs.isOfficial { return lhs.isOfficial }
            if lhs.name.lowercased().contains("deepseek") != rhs.name.lowercased().contains("deepseek") {
                return lhs.name.lowercased().contains("deepseek")
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var currentSelection: AgentModelSelection? {
        catalog?.currentModel
    }

    private func isSelected(_ model: AgentModel) -> Bool {
        guard let selection = currentSelection else { return false }
        return model.providerID == selection.providerID && model.id == selection.modelID
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isModelLoading {
                loadingView
            } else if let catalog, catalog.isEmpty {
                emptyView
            } else {
                if let selection = currentSelection, !catalog!.isAvailable(selection) {
                    deletedModelBanner(selection: selection)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedGroups) { group in
                            providerSection(group)
                        }
                    }
                    .padding(.bottom, 8)
                }
                if catalog?.shouldShowReasoningLevel == true {
                    reasoningLevelBar
                }
            }
        }
        .frame(maxWidth: 300)
        .frame(maxHeight: 360)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var currentReasoningLevel: ReasoningLevel {
        catalog?.currentReasoningLevel ?? currentSelection?.reasoningLevel ?? .high
    }

    private var reasoningLevelBar: some View {
        VStack(spacing: 6) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("推理强度")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                ReasoningSlider(level: currentReasoningLevel) { newLevel in
                    Task { await viewModel.selectReasoningLevel(newLevel) }
                }
                .disabled(viewModel.isModelSelecting)
                .padding(.horizontal, 14)
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载模型列表…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("暂无可用模型")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func deletedModelBanner(selection: AgentModelSelection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("当前模型「\(selection.modelID)」已不可用，请重新选择")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func providerSection(_ group: AgentModelGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if group.isOfficial {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                }
                Text(group.name)
                    .font(.caption2.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ForEach(group.models) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: AgentModel) -> some View {
        Button {
            Task {
                await viewModel.selectModel(model)
                if viewModel.isCurrentModelAvailable {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
            }
        } label: {
            HStack {
                Text(model.displayName)
                    .font(.subheadline.weight(isSelected(model) ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if isSelected(model) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                if viewModel.isModelSelecting && isSelected(model) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isModelSelecting)
    }
}

private struct ReasoningSlider: View {
    let level: ReasoningLevel
    let onChange: (ReasoningLevel) -> Void

    @State private var dragOffset: CGFloat?

    private var levels: [ReasoningLevel] { ReasoningLevel.allCases }
    private var index: Int { levels.firstIndex(of: level) ?? 2 }
    private var segmentCount: Int { levels.count }
    private var progress: CGFloat { CGFloat(index) / CGFloat(segmentCount - 1) }

    private var gradient: LinearGradient {
        switch level {
        case .off:
            return LinearGradient(colors: [Color.secondary.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
        case .low:
            return LinearGradient(colors: [Color(red: 0.25, green: 0.5, blue: 0.85).opacity(0.6), Color(red: 0.15, green: 0.4, blue: 0.95)], startPoint: .leading, endPoint: .trailing)
        case .high:
            return LinearGradient(colors: [Color(red: 0.85, green: 0.45, blue: 0.15).opacity(0.6), Color(red: 0.95, green: 0.55, blue: 0.0)], startPoint: .leading, endPoint: .trailing)
        case .max:
            return LinearGradient(colors: [Color(red: 0.55, green: 0.2, blue: 0.85).opacity(0.6), Color(red: 0.65, green: 0.15, blue: 0.95)], startPoint: .leading, endPoint: .trailing)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 22
            let labelWidth = geo.size.width / CGFloat(segmentCount)

            VStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(gradient)
                        .frame(width: max(0, geo.size.width * progress), height: trackHeight)

                    Circle()
                        .fill(Color.white)
                        .frame(width: trackHeight, height: trackHeight)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .offset(x: max(0, geo.size.width * progress) - trackHeight / 2)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    dragOffset = value.location.x
                                    let clamped = min(max(value.location.x / geo.size.width, 0), 1)
                                    let newIndex = Int(round(clamped * CGFloat(segmentCount - 1)))
                                    let newLevel = levels[min(newIndex, segmentCount - 1)]
                                    if newLevel != level {
                        onChange(newLevel)
                                    }
                                }
                                .onEnded { _ in
                                    dragOffset = nil
                                }
                        )
                }
                .frame(height: trackHeight)
                .frame(maxWidth: .infinity)

                HStack(spacing: 0) {
                    ForEach(levels, id: \.self) { lvl in
                        Text(lvl.displayName)
                            .font(.system(size: 10, weight: lvl == level ? .bold : .medium))
                            .foregroundStyle(lvl == level ? gradientFrameColor : .secondary)
                            .frame(width: labelWidth)
                    }
                }
            }
        }
        .frame(height: 48)
    }

    private var gradientFrameColor: Color {
        switch level {
        case .off: return .secondary
        case .low: return Color(red: 0.15, green: 0.4, blue: 0.95)
        case .high: return Color(red: 0.95, green: 0.55, blue: 0.0)
        case .max: return Color(red: 0.65, green: 0.15, blue: 0.95)
        }
    }
}
