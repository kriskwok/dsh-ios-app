import SwiftUI

struct AgentLogoView: View {
    let kind: AgentServerKind
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .secondarySystemBackground))
            switch kind {
            case .dsh:
                    Image("DSHLogo")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(colorScheme == .dark ? .white : .black)
                    .padding(size * 0.12)
            case .hermes:
                Image("HermesLogo")
                    .resizable()
                    .scaledToFill()
            case .codex:
                Image("ChatGPTLogo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(colorScheme == .dark ? .white : .black)
                    .padding(size * 0.10)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
