import SwiftUI

struct EmptyChatHomeView: View {
    let onOpenDrawer: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 38))
                .foregroundStyle(Color.accentColor)
            Text("添加 Agent 服务器")
                .font(.title2.weight(.semibold))
            Text("添加服务器后，这里会直接显示新会话窗口。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("打开服务器设置", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .safeAreaInset(edge: .top) {
            HStack {
                Button(action: onOpenDrawer) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("打开会话列表")
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
