import Foundation

enum ReasoningLevel: String, CaseIterable, Sendable {
    case off, low, high, max

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}

struct AgentModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let providerID: String
    let providerName: String
    let isOfficial: Bool
    let description: String?

    var displayName: String {
        name.nilIfEmpty ?? id
    }

    var isDeepSeek: Bool {
        providerID.lowercased().contains("deepseek") || providerName.lowercased().contains("deepseek")
    }
}

struct AgentModelGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isOfficial: Bool
    let models: [AgentModel]
}

struct AgentModelCatalog: Sendable {
    let groups: [AgentModelGroup]
    let currentModel: AgentModelSelection?
    let currentReasoningLevel: ReasoningLevel?

    init(groups: [AgentModelGroup], currentModel: AgentModelSelection?, currentReasoningLevel: ReasoningLevel? = nil) {
        self.groups = groups
        self.currentModel = currentModel
        self.currentReasoningLevel = currentReasoningLevel
    }

    var allModels: [AgentModel] {
        groups.flatMap(\.models)
    }

    var isEmpty: Bool {
        groups.allSatisfy { $0.models.isEmpty }
    }

    func isAvailable(_ selection: AgentModelSelection) -> Bool {
        allModels.contains { $0.providerID == selection.providerID && $0.id == selection.modelID }
    }

    var selectedModel: AgentModel? {
        guard let selection = currentModel else { return nil }
        return allModels.first { $0.providerID == selection.providerID && $0.id == selection.modelID }
    }

    var shouldShowReasoningLevel: Bool {
        selectedModel?.isDeepSeek ?? false
    }
}

struct AgentModelSelection: Hashable, Sendable {
    let providerID: String
    let modelID: String
    var reasoningLevel: ReasoningLevel?

    init(providerID: String, modelID: String, reasoningLevel: ReasoningLevel? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningLevel = reasoningLevel
    }

    var displayLabel: String {
        modelID
    }
}
