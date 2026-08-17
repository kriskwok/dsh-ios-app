import SwiftUI

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ServerStore

    private let existingProfile: ServerProfile?
    @State private var kind: AgentServerKind
    @State private var name: String
    @State private var address: String
    @State private var username: String
    @State private var password = ""
    @State private var errorMessage: String?

    init(profile: ServerProfile?) {
        existingProfile = profile
        _kind = State(initialValue: profile?.kind ?? .dsh)
        _name = State(initialValue: profile?.name ?? "")
        _address = State(initialValue: profile?.baseURL.absoluteString ?? "")
        _username = State(initialValue: profile?.username ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    Picker("Agent 类型", selection: $kind) {
                        ForEach(AgentServerKind.allCases) { kind in
                            Label {
                                Text(kind.title)
                            } icon: {
                                AgentLogoView(kind: kind, size: 18)
                            }
                            .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(existingProfile != nil)
                    TextField("名称，例如：生产服务器", text: $name)
                    TextField(addressPlaceholder, text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(existingProfile == nil ? "密码" : "新密码（留空则不修改）", text: $password)
                } header: {
                    Text(authTitle)
                } footer: {
                    Text(authFooter)
                }
                Section {
                    Label("公网地址必须使用有效 HTTPS 证书。自签名证书不会被绕过。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existingProfile == nil ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                }
            }
            .alert("无法保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func save() {
        do {
            let profile = try ServerProfile.validated(
                id: existingProfile?.id ?? UUID(),
                kind: kind,
                name: name,
                address: address,
                username: username
            )
            try store.upsert(profile, password: password.isEmpty ? nil : password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var addressPlaceholder: String {
        kind == .dsh ? "https://dsh.example.com" : "https://hermes.example.com"
    }

    private var authTitle: String {
        kind == .dsh ? "HTTP Basic Auth（可选）" : "Hermes 登录"
    }

    private var authFooter: String {
        switch kind {
        case .dsh:
            return "密码只保存在本机钥匙串，不写入服务器列表或日志。"
        case .hermes:
            return "新版 Hermes 会打开系统登录页并使用官方 OAuth，令牌只保存在本机钥匙串。用户名和密码仅用于兼容旧版 Basic Auth，可留空。"
        }
    }
}
