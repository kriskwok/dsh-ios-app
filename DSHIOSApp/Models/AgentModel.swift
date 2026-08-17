import Foundation

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

    var allModels: [AgentModel] {
        groups.flatMap(\.models)
    }

    var isEmpty: Bool {
        groups.allSatisfy { $0.models.isEmpty }
    }

    func isAvailable(_ selection: AgentModelSelection) -> Bool {
        allModels.contains { $0.providerID == selection.providerID && $0.id == selection.modelID }
    }
}

struct AgentModelSelection: Hashable, Sendable {
    let providerID: String
    let modelID: String

    var displayLabel: String {
        modelID
    }
}
