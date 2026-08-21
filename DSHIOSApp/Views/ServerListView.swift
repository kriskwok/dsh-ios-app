import SwiftUI

struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ServerStore
    @State private var editorProfile: ServerProfile?
    @State private var isAddingServer = false
    let onSelect: (ServerProfile) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.profiles.isEmpty {
                    List {
                        themeSection
                        Section {
                            ContentUnavailableView {
                                Label("添加 Agent 服务器", systemImage: "server.rack")
                            } description: {
                                Text("连接受 HTTPS 保护的远程 DSH 或 Hermes。")
                            } actions: {
                                Button("添加服务器") { isAddingServer = true }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                } else {
                    List {
                        themeSection
                        Section {
                            ForEach(store.profiles) { profile in
                                Button {
                                    onSelect(profile)
                                } label: {
                                    HStack {
                                        ServerRow(profile: profile)
                                        Spacer()
                                        if store.selectedProfileID == profile.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading) {
                                    Button("编辑") { editorProfile = profile }
                                        .tint(.blue)
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    store.remove(store.profiles[index])
                                }
                            }
                        } footer: {
                            Text("公网连接必须使用 HTTPS 和身份认证。不要直接暴露 Agent 的内部监听端口。")
                        }
                    }
                }
            }
            .navigationTitle("服务器设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加服务器", systemImage: "plus") { isAddingServer = true }
                }
            }
            .sheet(isPresented: $isAddingServer) {
                ServerEditorView(profile: nil)
            }
            .sheet(item: $editorProfile) { profile in
                ServerEditorView(profile: profile)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 3) {
                    Text("dsh-ios-app v\(appVersion)")
                    Text("github.com/kriskwok/dsh-ios-app")
                        .font(.caption2)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
            }
        }
    }

    private var themeSection: some View {
        Section("外观") {
            Picker("显示模式", selection: Binding(
                get: { store.themeMode },
                set: { store.setThemeMode($0) }
            )) {
                ForEach(AppThemeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }
}

private struct ServerRow: View {
    let profile: ServerProfile

    var body: some View {
        HStack(spacing: 12) {
            AgentLogoView(kind: profile.kind, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.headline)
                    Text(profile.kind.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(profile.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
