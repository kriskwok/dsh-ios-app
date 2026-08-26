import XCTest
@testable import DSHIOSApp

@MainActor
final class ChatSessionViewModelTests: XCTestCase {
    func testDSHFinalMessageReplacesMatchingChunkAfterToolStarts() {
        let session = AgentSessionSummary(id: "session-1", title: "测试")
        let viewModel = ChatSessionViewModel(
            profile: ServerProfile(
                kind: .dsh,
                name: "DSH",
                baseURL: URL(string: "https://dsh.example.com")!
            ),
            password: "",
            session: session,
            workspace: nil,
            onSessionCreated: { _ in },
            onPromptAccepted: { _ in }
        )

        viewModel.handle(.assistantDelta(
            sessionID: session.id,
            messageKey: "2-0",
            text: "先确认需求",
            reasoning: true
        ))
        viewModel.handle(.assistantDelta(
            sessionID: session.id,
            messageKey: "2-0",
            text: "在的，有什么可以帮你？",
            reasoning: false
        ))
        viewModel.handle(.toolStarted(
            sessionID: session.id,
            id: "tool-1",
            name: "检查状态",
            detail: nil
        ))
        viewModel.handle(.assistantComplete(
            sessionID: session.id,
            messageKey: "2-0",
            text: "在的，有什么可以帮你？",
            reasoning: "先确认需求"
        ))

        let replies = viewModel.messages.filter { $0.role == .assistant }
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].text, "在的，有什么可以帮你？")
        XCTAssertEqual(replies[0].reasoning, "先确认需求")
        XCTAssertFalse(replies[0].isStreaming)
    }

    func testReconnectsEventStreamAfterFailure() async throws {
        let gateway = ReconnectingAgentGateway()
        let session = AgentSessionSummary(id: "session-1", title: "测试")
        let viewModel = ChatSessionViewModel(
            profile: ServerProfile(
                kind: .dsh,
                name: "DSH",
                baseURL: URL(string: "https://dsh.example.com")!
            ),
            password: "",
            session: session,
            workspace: nil,
            onSessionCreated: { _ in },
            onPromptAccepted: { _ in },
            gateway: gateway,
            reconnectDelay: { _ in .milliseconds(5) }
        )

        viewModel.start()
        for _ in 0..<100 {
            if gateway.eventStreamCount >= 2 && viewModel.isConnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertGreaterThanOrEqual(gateway.eventStreamCount, 2)
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertFalse(viewModel.isReconnecting)
        viewModel.stop()
    }
    func testHandlesQuestionRequestAndResolution() {
    func testSessionMetricsStayHiddenUntilDataArrives() {
        let session = AgentSessionSummary(id: "session-1", title: "测试")
        let viewModel = ChatSessionViewModel(
            profile: ServerProfile(kind: .hermes, name: "Hermes", baseURL: URL(string: "https://hm.example.com")!),
            password: "",
            session: session,
            workspace: nil,
            onSessionCreated: { _ in },
            onPromptAccepted: { _ in }
        )

        XCTAssertNil(viewModel.contextUsageRatio)
        XCTAssertNil(viewModel.cacheHitRatio)

        viewModel.handle(.sessionMetrics(sessionID: session.id, metrics: AgentSessionMetrics(contextUsageRatio: 0.07, cacheHitRatio: 0.8)))

        XCTAssertEqual(viewModel.contextUsageRatio ?? 0, 0.07, accuracy: 0.0001)
        XCTAssertEqual(viewModel.cacheHitRatio ?? 0, 0.8, accuracy: 0.0001)
    }

        let session = AgentSessionSummary(id: "session-1", title: "测试")
        let viewModel = ChatSessionViewModel(
            profile: ServerProfile(
                kind: .dsh,
                name: "DSH",
                baseURL: URL(string: "https://dsh.example.com")!
            ),
            password: "",
            session: session,
            workspace: nil,
            onSessionCreated: { _ in },
            onPromptAccepted: { _ in }
        )

        let question = AgentQuestionRequest(
            id: "question-rpc-1",
            sessionID: session.id,
            responseToken: "question-rpc-1",
            questions: [
                AgentQuestion(
                    id: "q-1",
                    question: "请选择方案",
                    detail: nil,
                    header: nil,
                    options: [AgentQuestionOption(id: "A", label: "方案A", description: nil)],
                    multiSelect: false
                )
            ],
            waitsForResolutionEvent: true
        )

        viewModel.handle(.questionRequested(question))
        XCTAssertEqual(viewModel.pendingQuestion?.id, "question-rpc-1")
        XCTAssertEqual(viewModel.pendingQuestions.count, 1)
        XCTAssertTrue(viewModel.isRunning)

        viewModel.handle(.questionResolved(sessionID: session.id, questionRpcId: "question-rpc-1", outcome: "answered"))
        XCTAssertNil(viewModel.pendingQuestion)
        XCTAssertTrue(viewModel.pendingQuestions.isEmpty)
    }

    func testQuestionRequestFromOtherSessionIsIgnored() {
        let session = AgentSessionSummary(id: "session-1", title: "测试")
        let viewModel = ChatSessionViewModel(
            profile: ServerProfile(
                kind: .dsh,
                name: "DSH",
                baseURL: URL(string: "https://dsh.example.com")!
            ),
            password: "",
            session: session,
            workspace: nil,
            onSessionCreated: { _ in },
            onPromptAccepted: { _ in }
        )

        let question = AgentQuestionRequest(
            id: "question-rpc-2",
            sessionID: "other-session",
            responseToken: "question-rpc-2",
            questions: [
                AgentQuestion(
                    id: "q-1",
                    question: "请选择方案",
                    detail: nil,
                    header: nil,
                    options: [],
                    multiSelect: false
                )
            ],
            waitsForResolutionEvent: true
        )

        viewModel.handle(.questionRequested(question))
        XCTAssertTrue(viewModel.pendingQuestions.isEmpty)
    }
}

private enum ReconnectTestError: Error {
    case disconnected
}

private final class ReconnectingAgentGateway: AgentGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var streamCount = 0

    var eventStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streamCount
    }

    func connect() async throws {}

    func navigation() async throws -> AgentNavigationSnapshot {
        AgentNavigationSnapshot(sessions: [], workspaces: [], archivedSessionIDs: [])
    }

    func openSession(_ session: AgentSessionSummary) async throws -> AgentConversationContext {
        AgentConversationContext(
            runtimeSessionID: session.id,
            session: session,
            messages: [],
            title: session.title,
            isRunning: false
        )
    }

    func createSession(in workspace: AgentWorkspace?) async throws -> AgentConversationContext {
        let session = AgentSessionSummary(id: "new-session")
        return AgentConversationContext(
            runtimeSessionID: session.id,
            session: session,
            messages: [],
            title: session.title,
            isRunning: false
        )
    }

    func send(text: String, sessionID: String, requestID: String) async throws {}
    func cancel(sessionID: String) async throws {}
    func respond(to approval: AgentApprovalRequest, choice: AgentApprovalChoice) async throws {}
    func fetchModels(sessionID: String) async throws -> AgentModelCatalog {
        AgentModelCatalog(groups: [], currentModel: nil, currentReasoningLevel: nil)
    }
    func selectModel(_ selection: AgentModelSelection, sessionID: String) async throws -> AgentModelSelection? { nil }

    func events() -> AsyncThrowingStream<AgentGatewayEvent, Error> {
        lock.lock()
        streamCount += 1
        let currentCount = streamCount
        lock.unlock()

        return AsyncThrowingStream { continuation in
            if currentCount == 1 {
                continuation.finish(throwing: ReconnectTestError.disconnected)
            } else {
                continuation.yield(.connected)
            }
        }
    }

    func close() {}
}
