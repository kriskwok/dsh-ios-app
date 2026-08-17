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
