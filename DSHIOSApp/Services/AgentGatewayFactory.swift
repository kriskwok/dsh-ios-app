import Foundation

enum AgentGatewayFactory {
    static func make(profile: ServerProfile, password: String) -> any AgentGateway {
        switch profile.kind {
        case .dsh:
            return DSHAgentGateway(profile: profile, password: password)
        case .hermes:
            return HermesAgentGateway(profile: profile, password: password)
        }
    }
}

