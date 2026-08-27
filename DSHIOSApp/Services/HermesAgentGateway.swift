import Foundation
import UIKit

final class HermesAgentGateway: AgentGateway, @unchecked Sendable {
    private let client: HermesRPCClient

    init(profile: ServerProfile, password: String) {
        client = HermesRPCClient(profile: profile, password: password)
    }



    func connect() async throws {
        try await client.connect()
    }

    /// Fetch file data from Hermes Studio by server-side path.
    func fetchFileData(path: String) async throws -> Data {
        try await client.fetchFileData(path: path)
    }

    func navigation() async throws -> AgentNavigationSnapshot {
        try await connect()
        let list = try await client.call(method: "session.list", params: ["limit": .number(500)])
        var sessionsByID: [String: AgentSessionSummary] = [:]
        for raw in list["sessions"]?.arrayValue ?? [] {
            if let session = Self.session(from: raw) { sessionsByID[session.id] = session }
        }

        var archivedIDs: Set<String> = []
        if let tree = try? await client.call(method: "projects.tree", params: ["preview_limit": .number(10)]) {
            for project in tree["projects"]?.arrayValue ?? [] {
                guard let id = project["id"]?.stringValue,
                      project["isNoProject"]?.boolValue != true,
                      project["archived"]?.boolValue != true else { continue }
                let detail = try? await client.call(
                    method: "projects.project_sessions",
                    params: ["project_id": .string(id), "session_limit": .number(5_000)]
                )
                let hydrated = detail?["project"] ?? project
                let rawSessions = Self.projectSessions(hydrated)
                for raw in rawSessions {
                    if var session = Self.session(from: raw) {
                        if session.source == nil {
                            session.source = sessionsByID[session.id]?.source
                        }
                        sessionsByID[session.id] = session
                        if session.workingDirectory == nil {
                            session.workingDirectory = hydrated["path"]?.stringValue
                                ?? hydrated["repos"]?.arrayValue?.first?["path"]?.stringValue
                        }
                        if raw["archived"]?.boolValue == true { archivedIDs.insert(session.id) }
                    }
                }
            }
        }

        // Fetch coding agent sessions from chat-run API
        if let chatRuns = try? await client.httpGet("api/chat-run/runs", query: ["limit": "200"]) {
            let runs = chatRuns["runs"]?.arrayValue ?? chatRuns["data"]?.arrayValue ?? []
            for run in runs {
                guard let runID = run["id"]?.stringValue ?? run["run_id"]?.stringValue else { continue }
                let title = run["title"]?.stringValue ?? run["input"]?.stringValue ?? runID
                let updatedAt = run["updated_at"]?.stringValue ?? run["created_at"]?.stringValue ?? ""
                let date = ISO8601DateFormatter().date(from: updatedAt) ?? Date()
                sessionsByID[runID] = AgentSessionSummary(
                    id: runID,
                    title: title,
                    updatedAt: date,
                    isRunning: run["status"]?.stringValue == "running",
                    isBlank: false,
                    workingDirectory: run["workspace"]?.stringValue,
                    source: "coding_agent",
                    modelProvider: run["provider"]?.stringValue
                )
            }
        }

        return AgentNavigationSnapshot(
            sessions: sessionsByID.values.sorted { $0.updatedAt > $1.updatedAt },
            workspaces: Self.workspaces(from: Array(sessionsByID.values)),
            archivedSessionIDs: archivedIDs
        )
    }

    func openSession(_ session: AgentSessionSummary) async throws -> AgentConversationContext {
        try await connect()
        let result = try await client.call(
            method: "session.resume",
            params: ["session_id": .string(session.id), "cols": .number(100)]
        )
        guard let runtimeID = result["session_id"]?.stringValue else {
            throw HermesClientError.invalidResponse("恢复会话缺少 session_id")
        }
        return AgentConversationContext(
            runtimeSessionID: runtimeID,
            session: session,
            messages: Self.messages(from: result["messages"]),
            title: result["info"]?["title"]?.stringValue?.nilIfEmpty
                ?? result["title"]?.stringValue?.nilIfEmpty
                ?? session.title,
            isRunning: result["running"]?.boolValue ?? false,
            currentModel: Self.extractModel(from: result),
            metrics: AgentSessionMetrics(json: result)
        )
    }

    func createSession(in workspace: AgentWorkspace?) async throws -> AgentConversationContext {
        try await connect()
        var params: [String: JSONValue] = ["source": .string("ios"), "cols": .number(100)]
        // Hermes uses server-default cwd; do not override
        let result = try await client.call(method: "session.create", params: params)
        guard let runtimeID = result["session_id"]?.stringValue else {
            throw HermesClientError.invalidResponse("创建会话缺少 session_id")
        }
        let storedID = result["stored_session_id"]?.stringValue ?? runtimeID
        let session = AgentSessionSummary(
            id: storedID,
            isBlank: true,
            workingDirectory: result["info"]?["cwd"]?.stringValue ?? workspace?.path,
            source: "ios"
        )
        return AgentConversationContext(
            runtimeSessionID: runtimeID,
            session: session,
            messages: Self.messages(from: result["messages"]),
            title: "新对话",
            isRunning: false,
            currentModel: Self.extractModel(from: result)
        )
    }

    private static func extractModel(from result: JSONValue) -> AgentModelSelection? {
        let info = result["info"] ?? .object([:])
        let model = result["model"]?.stringValue?.nilIfEmpty
            ?? info["model"]?.stringValue?.nilIfEmpty
        let provider = result["provider"]?.stringValue?.nilIfEmpty
            ?? info["provider"]?.stringValue?.nilIfEmpty
        guard let model, !model.isEmpty else { return nil }
        return AgentModelSelection(
            providerID: provider ?? "",
            modelID: model,
            reasoningLevel: nil
        )
    }

    func send(text: String, sessionID: String, requestID: String) async throws {
        _ = try await client.call(
            method: "prompt.submit",
            params: ["session_id": .string(sessionID), "text": .string(text)]
        )
    }

    func send(images: [ImageContentBlock], text: String, sessionID: String, requestID: String) async throws {
        // 1. Compress images to stay under nginx client_max_body_size (default 1MB).
        let compressed = images.map { Self.compressImageIfNeeded($0) }

        // 2. Upload all files via multipart to hermes-web-ui /upload endpoint
        let files = compressed.map { ($0.name, $0.data, $0.mediaType) }
        let uploadResult = try await client.uploadFiles(files)

        // 3. Extract server paths from response {files: [{name, path}]}.
        //    Upload response only has name+path; use the input mediaType to
        //    distinguish images from files.
        var uploadedPaths: [(name: String, path: String, isImage: Bool)] = []
        for (index, file) in (uploadResult["files"]?.arrayValue ?? []).enumerated() {
            guard let name = file["name"]?.stringValue,
                  let path = file["path"]?.stringValue else { continue }
            let inputType = index < compressed.count ? compressed[index].mediaType : ""
            let isImage = inputType.hasPrefix("image/")
            uploadedPaths.append((name, path, isImage))
        }

        // 4. Build prompt with file references prepended (same format as web UI:
        //    images use ![name](path), files use [name](path)).
        var parts: [String] = []
        for (name, path, isImage) in uploadedPaths {
            if isImage {
                parts.append("![\(name)](\(path))")
            } else {
                parts.append("[\(name)](\(path))")
            }
        }
        if !text.isEmpty {
            parts.append(text)
        }
        let prompt = parts.joined(separator: "\n\n")

        // 5. Send via prompt.submit
        _ = try await client.call(
            method: "prompt.submit",
            params: ["session_id": .string(sessionID), "text": .string(prompt)]
        )
    }

    func cancel(sessionID: String) async throws {
        _ = try await client.call(method: "session.interrupt", params: ["session_id": .string(sessionID)])
    }

    func renameSession(_ sessionID: String, title: String) async throws {
        print("[Hermes-Manage] rename session=\(sessionID) title=\(title)")
        do {
            try await connect()
            let command = "/title \(title)"
            _ = try await client.call(
                method: "slash.exec",
                params: [
                    "session_id": .string(sessionID),
                    "command": .string(command)
                ]
            )
            print("[Hermes-Manage] rename success")
        } catch {
            print("[Hermes-Manage] rename failed: \(error)")
            throw error
        }
    }

    func archiveSession(_ sessionID: String, archived: Bool) async throws {
        print("[Hermes-Manage] archive session=\(sessionID) archived=\(archived)")
        do {
            try await connect()
            let command = archived ? "/archive" : "/unarchive"
            _ = try await client.call(
                method: "slash.exec",
                params: [
                    "session_id": .string(sessionID),
                    "command": .string(command)
                ]
            )
            print("[Hermes-Manage] archive success")
        } catch {
            print("[Hermes-Manage] archive failed: \(error)")
            throw error
        }
    }

    func respond(to approval: AgentApprovalRequest, choice: AgentApprovalChoice) async throws {
        guard approval.choices.contains(choice) else {
            throw HermesClientError.invalidResponse("该审批选项不可用")
        }
        let result = try await client.call(
            method: "approval.respond",
            params: [
                "session_id": .string(approval.sessionID),
                "choice": .string(choice.rawValue)
            ]
        )
        if result["resolved"]?.boolValue == false {
            throw HermesClientError.invalidResponse("审批已失效或已由其他客户端处理")
        }
    }

    func events() -> AsyncThrowingStream<AgentGatewayEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let events = await client.events()
                do {
                    for try await event in events {
                        continuation.yield(.connected)
                        for mapped in Self.map(event) { continuation.yield(mapped) }
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func close() {
        Task { await client.close() }
    }

    private static let hiddenProviderSlugs: Set<String> = []
    private static let hiddenProviderNames: Set<String> = ["mixture of agents"]

    func fetchModels(sessionID: String) async throws -> AgentModelCatalog {
        try await client.connect()
        let result = try await client.call(
            method: "model.options",
            params: ["session_id": .string(sessionID)]
        )
        let currentProvider = result["provider"]?.stringValue ?? ""
        let currentModel = result["model"]?.stringValue ?? ""


        let groups: [AgentModelGroup] = (result["providers"]?.arrayValue ?? []).compactMap { raw in
            guard let slug = raw["slug"]?.stringValue, !slug.isEmpty else { return nil }
            if Self.hiddenProviderSlugs.contains(slug) { return nil }
            let name = raw["name"]?.stringValue ?? slug
            let lowerName = name.lowercased()
            if Self.hiddenProviderNames.contains(where: { lowerName.contains($0) }) { return nil }
            let isUserDefined = raw["is_user_defined"]?.boolValue ?? false
            var modelIDs = raw["models"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            if lowerName.contains("opencode zen")
                || lowerName.contains("nous portal") {
                modelIDs = modelIDs.filter { $0.lowercased().contains("free") }
            }
            guard !modelIDs.isEmpty else { return nil }
            let models = modelIDs.map { modelID in
                AgentModel(
                    id: modelID,
                    name: modelID,
                    providerID: slug,
                    providerName: name,
                    isOfficial: !isUserDefined,
                    description: nil,
                    reasoningLevels: []
                )
            }
            return AgentModelGroup(id: slug, name: name, isOfficial: !isUserDefined, models: models)
        }
        let current: AgentModelSelection? = {
            guard !currentProvider.isEmpty, !currentModel.isEmpty else { return nil }
            return AgentModelSelection(providerID: currentProvider, modelID: currentModel, reasoningLevel: nil)
        }()
        return AgentModelCatalog(groups: groups, currentModel: current, currentReasoningLevel: nil, reasoningLevels: nil, supportsReasoningLevel: false)
    }

    func selectModel(_ selection: AgentModelSelection, sessionID: String) async throws -> AgentModelSelection? {
        let command = "/model \(selection.modelID) --provider \(selection.providerID) --session"
        _ = try? await client.call(
            method: "slash.exec",
            params: ["session_id": .string(sessionID), "command": .string(command)]
        )
        return selection
    }

    static func map(_ event: HermesGatewayEvent) -> [AgentGatewayEvent] {
        print("[DEBUG-MAP] event.type:", event.type, "sessionID:", event.sessionID ?? "nil")
        guard let sessionID = event.sessionID else {
            return event.type == "error"
                ? [.failure(event.payload["message"]?.stringValue ?? "Hermes 返回错误")]
                : []
        }
        switch event.type {
        case "message.delta":
            return [.assistantDelta(sessionID: sessionID, messageKey: nil, text: event.payload["text"]?.stringValue ?? "", reasoning: false)]
        case "reasoning.delta", "thinking.delta":
            return [.assistantDelta(sessionID: sessionID, messageKey: nil, text: event.payload["text"]?.stringValue ?? "", reasoning: true)]
        case "message.start":
            return [.running(sessionID: sessionID, value: true)]
        case "message.complete":
            var output: [AgentGatewayEvent] = [.assistantComplete(
                sessionID: sessionID,
                messageKey: nil,
                text: event.payload["text"]?.stringValue ?? "",
                reasoning: event.payload["reasoning"]?.stringValue ?? ""
            )]
            if let metrics = AgentSessionMetrics(json: event.payload) {
                output.append(.sessionMetrics(sessionID: sessionID, metrics: metrics))
            }
            return output
        case "tool.start":
            return [.toolStarted(
                sessionID: sessionID,
                id: event.payload["tool_id"]?.stringValue ?? UUID().uuidString,
                name: event.payload["name"]?.stringValue ?? "工具",
                detail: event.payload["command"]?.stringValue
            )]
        case "tool.complete":
            return [.toolCompleted(
                sessionID: sessionID,
                id: event.payload["tool_id"]?.stringValue ?? "",
                name: event.payload["name"]?.stringValue
            )]
        case "session.info":
            var output: [AgentGatewayEvent] = []
            if let running = event.payload["running"]?.boolValue {
                output.append(.running(sessionID: sessionID, value: running))
            }
            if let title = event.payload["title"]?.stringValue, !title.isEmpty {
                output.append(.title(sessionID: sessionID, value: title))
            }
            if let metrics = AgentSessionMetrics(json: event.payload) {
                output.append(.sessionMetrics(sessionID: sessionID, metrics: metrics))
            }
            return output
        case "status.update":
            let kind = event.payload["kind"]?.stringValue
            if kind == "running" || kind == "thinking" { return [.running(sessionID: sessionID, value: true)] }
            if kind == "idle" || kind == "complete" { return [.running(sessionID: sessionID, value: false)] }
            return []
        case "approval.request":
            let choices = approvalChoices(from: event.payload)
            let toolName = event.payload["tool_name"]?.stringValue
                ?? event.payload["name"]?.stringValue
                ?? "远程工具"
            return [.approvalRequested(AgentApprovalRequest(
                id: "hermes-\(sessionID)",
                sessionID: sessionID,
                responseToken: nil,
                toolName: toolName,
                description: event.payload["description"]?.stringValue
                    ?? "\(toolName) 请求执行需要确认的操作",
                command: event.payload["command"]?.stringValue,
                callID: event.payload["tool_id"]?.stringValue,
                choices: choices,
                isSmartDenied: event.payload["smart_denied"]?.boolValue ?? false,
                waitsForResolutionEvent: false
            ))]
        case "error":
            return [.failure(event.payload["message"]?.stringValue ?? "Hermes 返回错误")]
        default:
            return []
        }
    }

    static func session(from value: JSONValue) -> AgentSessionSummary? {
        guard let id = value["id"]?.stringValue else { return nil }
        let timestamp = value["last_active"]?.doubleValue ?? value["started_at"]?.doubleValue ?? Date().timeIntervalSince1970
        return AgentSessionSummary(
            id: id,
            title: value["title"]?.stringValue?.nilIfEmpty ?? "新对话",
            updatedAt: Date(timeIntervalSince1970: timestamp),
            isRunning: false,
            isBlank: (value["message_count"]?.intValue ?? 1) == 0,
            workingDirectory: value["cwd"]?.stringValue,
            source: value["source"]?.stringValue?.nilIfEmpty
        )
    }

    static func approvalChoices(from payload: JSONValue) -> [AgentApprovalChoice] {
        let explicit = payload["choices"]?.arrayValue?
            .compactMap(\.stringValue)
            .compactMap(AgentApprovalChoice.init(rawValue:)) ?? []
        if !explicit.isEmpty { return explicit }
        if payload["smart_denied"]?.boolValue == true { return [.once, .deny] }
        if payload["allow_permanent"]?.boolValue == false { return [.once, .session, .deny] }
        return [.once, .session, .always, .deny]
    }

    static func workspaces(from sessions: [AgentSessionSummary]) -> [AgentWorkspace] {
        let grouped = Dictionary(grouping: sessions) { session in
            session.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return grouped.map { path, sessions in
            AgentWorkspace(
                id: "cwd:\(path)",
                path: path,
                title: path.isEmpty ? "未知工作区" : path,
                sessionIDs: sessions.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = AgentSessionOrdering.latestUpdate(in: grouped[lhs.path] ?? []) ?? .distantPast
            let rhsDate = AgentSessionOrdering.latestUpdate(in: grouped[rhs.path] ?? []) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func projectSessions(_ project: JSONValue) -> [JSONValue] {
        var output: [JSONValue] = []
        for repo in project["repos"]?.arrayValue ?? [] {
            for group in repo["groups"]?.arrayValue ?? [] {
                output.append(contentsOf: group["sessions"]?.arrayValue ?? [])
            }
        }
        return output
    }

    static func messages(from value: JSONValue?) -> [ConversationMessage] {
        var output: [ConversationMessage] = []
        for (index, raw) in (value?.arrayValue ?? []).enumerated() {
            let role = raw["role"]?.stringValue ?? ""
            // Hermes messages may carry content in `text` (JSON string or plain
            // text) or `content` (array). Try both, preferring `content`.
            let contentValue = raw["content"] ?? raw["text"]
            let content = parseContent(contentValue)
            let reasoning = role == "assistant" ? reasoningText(raw) : ""
            guard !content.text.isEmpty || !reasoning.isEmpty || !content.attachments.isEmpty || role == "tool" else { continue }
            switch role {
            case "user":
                output.append(message(
                    id: "hermes-user-\(index)", role: .user, text: content.text,
                    reasoning: "", attachments: content.attachments, index: index, raw: raw
                ))
            case "assistant":
                output.append(message(
                    id: "hermes-assistant-\(index)", role: .assistant, text: content.text,
                    reasoning: reasoning, attachments: content.attachments, index: index, raw: raw
                ))
            case "tool":
                let name = raw["name"]?.stringValue ?? raw["tool_name"]?.stringValue ?? "工具"
                output.append(message(
                    id: "hermes-tool-\(index)", role: .activity, text: "已使用 \(name)",
                    reasoning: "", attachments: [], index: index, raw: raw
                ))
            default:
                continue
            }
        }
        return output
    }

    /// Parse Hermes content into text + attachments.
    /// Handles: array of content blocks, JSON-serialized string of blocks,
    /// or plain text string.
    /// Hermes content blocks: {"type":"text","text":"..."},
    /// {"type":"image","name":"...","path":"...","media_type":"image/png"}
    private static func parseContent(_ value: JSONValue?) -> (text: String, attachments: [MessageAttachment]) {
        // Case 1: already an array of content blocks.
        if let blocks = value?.arrayValue {
            return parseContentBlocks(blocks)
        }
        // Case 2: a JSON-serialized string (web UI stores content as JSON string).
        if let str = value?.stringValue, !str.isEmpty {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                if let data = str.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
                   let blocks = parsed.arrayValue {
                    return parseContentBlocks(blocks)
                }
            }
            // Plain text string — may contain Markdown images ![name](path).
            return parseMarkdownAttachments(str)
        }
        return ("", [])
    }

    /// Extract Markdown image/file references `![name](path)` and `[name](path)`
    /// from text. Only local file paths (starting with "/") are treated as
    /// attachments; regular http(s) links are left untouched.
    private static func parseMarkdownAttachments(_ text: String) -> (text: String, attachments: [MessageAttachment]) {
        var attachments: [MessageAttachment] = []
        var result = text
        // Pattern: optional "!" + [name](path) — matches both images and links.
        let pattern = #"(!?)\[([^\]]*)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, [])
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        // Remove from end to start to preserve indices.
        for match in matches.reversed() {
            guard let bangRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let pathRange = Range(match.range(at: 3), in: text),
                  let fullRange = Range(match.range, in: text) else { continue }
            let hasBang = !text[bangRange].isEmpty
            let name = String(text[nameRange])
            let path = String(text[pathRange])
            // Only treat local file paths (starting with "/") as attachments.
            // Regular http(s) links are left as Markdown.
            guard path.hasPrefix("/") else { continue }
            let id = path
            let ext = (path as NSString).pathExtension.lowercased()
            let isImage = hasBang || ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"].contains(ext)
            let mimeType: String
            if isImage {
                mimeType = ext == "jpg" ? "image/jpeg" : "image/\(ext)"
            } else {
                mimeType = "application/octet-stream"
            }
            let att = MessageAttachment(
                id: id,
                kind: isImage ? .image : .file,
                name: name.isEmpty ? (path as NSString).lastPathComponent : name,
                size: 0,
                mimeType: mimeType,
                remotePath: path
            )
            attachments.insert(att, at: 0)
            result.removeSubrange(fullRange)
        }
        // Clean up leftover blank lines.
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result, attachments)
    }

    private static func parseContentBlocks(_ blocks: [JSONValue]) -> (text: String, attachments: [MessageAttachment]) {
        var textParts: [String] = []
        var attachments: [MessageAttachment] = []
        for (i, block) in blocks.enumerated() {
            let type = block["type"]?.stringValue ?? ""
            switch type {
            case "text":
                if let t = block["text"]?.stringValue, !t.isEmpty { textParts.append(t) }
            case "image":
                if let att = hermesImageAttachment(from: block, index: i) {
                    attachments.append(att)
                }
            case "file":
                if let att = hermesFileAttachment(from: block, index: i) {
                    attachments.append(att)
                }
            default:
                if let t = block["text"]?.stringValue ?? block["content"]?.stringValue, !t.isEmpty {
                    textParts.append(t)
                }
            }
        }
        return (textParts.joined(separator: "\n\n"), attachments)
    }

    private static func hermesImageAttachment(from block: JSONValue, index: Int) -> MessageAttachment? {
        let name = block["name"]?.stringValue ?? "image.png"
        let path = block["path"]?.stringValue
        let mediaType = block["media_type"]?.stringValue ?? block["mediaType"]?.stringValue ?? "image/png"
        let id = path ?? "hermes-img-\(index)"
        return MessageAttachment(
            id: id,
            kind: .image,
            name: name,
            size: 0,
            mimeType: mediaType,
            remotePath: path
        )
    }

    private static func hermesFileAttachment(from block: JSONValue, index: Int) -> MessageAttachment? {
        let name = block["name"]?.stringValue ?? "file"
        let path = block["path"]?.stringValue
        let mediaType = block["media_type"]?.stringValue ?? block["mediaType"]?.stringValue
        let id = path ?? "hermes-file-\(index)"
        return MessageAttachment(
            id: id,
            kind: .file,
            name: name,
            size: 0,
            mimeType: mediaType,
            remotePath: path
        )
    }

    private static func message(
        id: String,
        role: ConversationMessage.Role,
        text: String,
        reasoning: String,
        attachments: [MessageAttachment],
        index: Int,
        raw: JSONValue
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: role,
            text: text,
            reasoning: reasoning,
            timestamp: Date(timeIntervalSince1970: raw["timestamp"]?.doubleValue ?? Date().timeIntervalSince1970),
            sequence: index,
            isStreaming: false,
            isPending: false,
            attachments: attachments
        )
    }

    private static func reasoningText(_ value: JSONValue) -> String {
        for key in ["reasoning", "reasoning_content"] {
            if let text = value[key]?.stringValue, !text.isEmpty { return text }
        }
        return (value["reasoning_details"]?.arrayValue ?? []).compactMap {
            $0["text"]?.stringValue ?? $0["content"]?.stringValue
        }.joined(separator: "\n\n")
    }

    // MARK: - Image Compression

    /// Maximum upload size in bytes. nginx default client_max_body_size is 1MB,
    /// so target under 900KB to leave room for multipart overhead.
    private static let maxUploadBytes = 900 * 1024

    /// Compress an image if its data exceeds the upload limit.
    /// Tries JPEG quality reduction first, then downscaling if still too large.
    static func compressImageIfNeeded(_ block: ImageContentBlock) -> ImageContentBlock {
        guard block.mediaType.hasPrefix("image/"),
              block.data.count > maxUploadBytes else {
            return block
        }
        guard let image = UIImage(data: block.data) else {
            return block
        }

        // Try reducing JPEG quality first.
        for quality in stride(from: 0.8, through: 0.3, by: -0.15) {
            if let data = image.jpegData(compressionQuality: quality),
               data.count <= maxUploadBytes {
                print("[HermesUpload] compressed \(block.name): \(block.data.count) -> \(data.count) bytes (quality=\(quality))")
                return ImageContentBlock(data: data, name: block.name, mediaType: "image/jpeg")
            }
        }

        // Still too large: downscale the image.
        let targetWidth: CGFloat = 1280
        let scale = min(1.0, targetWidth / image.size.width)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        if let resized,
           let data = resized.jpegData(compressionQuality: 0.7) {
            print("[HermesUpload] compressed+resized \(block.name): \(block.data.count) -> \(data.count) bytes (size=\(newSize))")
            return ImageContentBlock(data: data, name: block.name, mediaType: "image/jpeg")
        }

        return block
    }
}
