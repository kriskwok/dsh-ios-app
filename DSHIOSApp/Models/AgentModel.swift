import Foundation

struct ReasoningLevel: Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    private init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var displayName: String {
        switch rawValue {
        case "off": return "Off"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "X-High"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return rawValue.capitalized
        }
    }

    static let off = ReasoningLevel("off")
    static let minimal = ReasoningLevel("minimal")
    static let low = ReasoningLevel("low")
    static let medium = ReasoningLevel("medium")
    static let high = ReasoningLevel("high")
    static let xhigh = ReasoningLevel("xhigh")
    static let max = ReasoningLevel("max")
    static let ultra = ReasoningLevel("ultra")

    static let allCases: [ReasoningLevel] = [.off, .minimal, .low, .medium, .high, .xhigh, .max, .ultra]
    static let hermesCases: [ReasoningLevel] = [.minimal, .low, .medium, .high, .xhigh, .max, .ultra]
}

struct AgentModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let providerID: String
    let providerName: String
    let isOfficial: Bool
    let description: String?
    let reasoningLevels: [ReasoningLevel]
    let defaultReasoningLevel: ReasoningLevel?

    init(
        id: String,
        name: String,
        providerID: String,
        providerName: String,
        isOfficial: Bool,
        description: String? = nil,
        reasoningLevels: [ReasoningLevel] = [],
        defaultReasoningLevel: ReasoningLevel? = nil
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.providerName = providerName
        self.isOfficial = isOfficial
        self.description = description
        self.reasoningLevels = reasoningLevels
        self.defaultReasoningLevel = defaultReasoningLevel
    }

    var displayName: String {
        name.nilIfEmpty ?? id
    }

    var isDeepSeek: Bool {
        providerID.lowercased().contains("deepseek") || providerName.lowercased().contains("deepseek")
    }

    var supportsReasoningLevel: Bool {
        !reasoningLevels.isEmpty
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
    let reasoningLevels: [ReasoningLevel]
    let supportsReasoningLevel: Bool

    init(
        groups: [AgentModelGroup],
        currentModel: AgentModelSelection?,
        currentReasoningLevel: ReasoningLevel? = nil,
        reasoningLevels: [ReasoningLevel]? = nil,
        supportsReasoningLevel: Bool = true
    ) {
        self.groups = groups
        self.currentModel = currentModel
        self.currentReasoningLevel = currentReasoningLevel
        self.reasoningLevels = reasoningLevels ?? ReasoningLevel.allCases
        self.supportsReasoningLevel = supportsReasoningLevel
    }

    var allModels: [AgentModel] {
        groups.flatMap(\.models)
    }

    var isEmpty: Bool {
        groups.allSatisfy { $0.models.isEmpty }
    }

    func isAvailable(_ selection: AgentModelSelection) -> Bool {
        if allModels.contains(where: { $0.providerID == selection.providerID && $0.id == selection.modelID }) {
            return true
        }
        return allModels.contains {
            $0.providerID.lowercased() == selection.providerID.lowercased()
                && $0.id.lowercased() == selection.modelID.lowercased()
        }
    }

    var selectedModel: AgentModel? {
        guard let selection = currentModel else { return nil }
        if let exact = allModels.first(where: { $0.providerID == selection.providerID && $0.id == selection.modelID }) {
            return exact
        }
        return allModels.first {
            $0.providerID.lowercased() == selection.providerID.lowercased()
                && $0.id.lowercased() == selection.modelID.lowercased()
        }
    }

    var availableReasoningLevels: [ReasoningLevel] {
        if let selected = selectedModel, !selected.reasoningLevels.isEmpty {
            return selected.reasoningLevels
        }
        if selectedModel?.isDeepSeek == true {
            return reasoningLevels
        }
        return []
    }

    var shouldShowReasoningLevel: Bool {
        supportsReasoningLevel && !availableReasoningLevels.isEmpty
    }

    var displayedReasoningLevel: ReasoningLevel? {
        let levels = availableReasoningLevels
        guard !levels.isEmpty else { return nil }
        let current = currentReasoningLevel ?? currentModel?.reasoningLevel
        if let current, levels.contains(current) { return current }
        return selectedModel?.defaultReasoningLevel ?? levels.first
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
