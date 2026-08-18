import XCTest
@testable import DSHIOSApp

final class DSHProtocolTests: XCTestCase {
    func testSessionSummaryUsesProjectedTitle() throws {
        let json: JSONValue = .object([
            "sessionId": .string("session-1"),
            "updatedAt": .number(1_700_000_000_000),
            "running": .bool(true),
            "blank": .bool(false),
            "cwd": .string("/srv/project"),
            "projections": .object([
                "asOfSeq": .number(8),
                "values": .object(["title": .string("修复登录问题")])
            ])
        ])

        let summary = try DSHSessionSummary(json: json)

        XCTAssertEqual(summary.id, "session-1")
        XCTAssertEqual(summary.title, "修复登录问题")
        XCTAssertTrue(summary.isRunning)
        XCTAssertEqual(summary.workingDirectory, "/srv/project")
    }

    func testProjectorReplacesStreamingChunkWithFinalAssistantMessage() throws {
        var projector = ConversationProjector()
        let events = try [
            event(type: "user/message", seq: 0, data: .object([
                "id": .string("user-1"),
                "content": textBlocks("你好"),
                "source": .object(["kind": .string("user")])
            ])),
            event(type: "assistant/chunk", seq: 1, data: .object([
                "turn": .number(0), "step": .number(0),
                "chunk": .object(["type": .string("text-delta"), "index": .number(0), "text": .string("你")])
            ])),
            event(type: "assistant/chunk", seq: 2, data: .object([
                "turn": .number(0), "step": .number(0),
                "chunk": .object(["type": .string("text-delta"), "index": .number(0), "text": .string("好")])
            ])),
            event(type: "assistant/message", seq: 3, data: .object([
                "turn": .number(0), "step": .number(0),
                "message": .object([
                    "id": .string("assistant-1"),
                    "content": .array([
                        .object(["type": .string("reasoning"), "text": .string("简短思考")]),
                        .object(["type": .string("text"), "text": .string("你好，有什么可以帮你？")])
                    ])
                ])
            ]))
        ]

        projector.replace(with: events)
        let messages = projector.messages()

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "你好")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "你好，有什么可以帮你？")
        XCTAssertEqual(messages[1].reasoning, "简短思考")
        XCTAssertFalse(messages[1].isStreaming)
    }

    func testProjectorFindsTurnAndStepInsideFinalMessageSource() throws {
        var projector = ConversationProjector()
        projector.replace(with: try [
            event(type: "assistant/chunk", seq: 1, data: .object([
                "turn": .number(3), "step": .number(1),
                "chunk": .object(["type": .string("text-delta"), "text": .string("在的")])
            ])),
            event(type: "assistant/message", seq: 2, data: .object([
                "message": .object([
                    "id": .string("assistant-final"),
                    "source": .object(["turn": .number(3), "step": .number(1)]),
                    "content": textBlocks("在的")
                ])
            ]))
        ])

        let messages = projector.messages()

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "在的")
        XCTAssertFalse(messages[0].isStreaming)
    }

    func testProjectorToleratesDuplicateEventSequences() throws {
        var projector = ConversationProjector()
        projector.replace(with: try [
            event(type: "assistant/message", seq: 7, data: .object([
                "message": .object(["content": textBlocks("旧内容")])
            ])),
            event(type: "assistant/message", seq: 7, data: .object([
                "message": .object(["content": textBlocks("最新内容")])
            ]))
        ])

        XCTAssertEqual(projector.messages().map(\.text), ["最新内容"])
    }

    func testHistoryPageReadsEventEnvelopeAndTitleProjection() throws {
        let rawEvent: JSONValue = .object([
            "type": .string("turn/start"),
            "seq": .number(4),
            "time": .number(1_700_000_000_000),
            "data": .object(["turn": .number(1)])
        ])
        let page = try DSHHistoryPage(json: .object([
            "events": .array([.object(["event": rawEvent])]),
            "hasMore": .bool(true),
            "projections": .object([
                "asOfSeq": .number(4),
                "values": .object(["title": .string("测试会话")])
            ])
        ]))

        XCTAssertEqual(page.events.map(\.type), ["turn/start"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.title, "测试会话")
    }

    func testUnauthorizedErrorDoesNotExposeProxyHTML() {
        let error = DSHClientError.httpStatus(401, "<html><h1>Authorization Required</h1></html>")

        XCTAssertEqual(
            error.localizedDescription,
            "认证失败。请返回服务器列表，左滑该服务器并选择“编辑”，重新填写用户名和密码。"
        )
    }

    func testWorkspaceListPreservesWorkspaceAndSessionOrder() throws {
        let list = try DSHWorkspaceList(json: .object([
            "items": .array([
                .object([
                    "workspaceId": .string("workspace-a"),
                    "path": .string("/srv/a"),
                    "title": .string("项目 A"),
                    "sessionIds": .array([.string("session-2"), .string("session-1")]),
                    "createdAt": .string("2026-08-15T00:00:00.000Z"),
                    "updatedAt": .string("2026-08-15T01:00:00.000Z")
                ])
            ]),
            "archivedSessionIds": .array([.string("session-old")])
        ]))

        XCTAssertEqual(list.items.map(\.id), ["workspace-a"])
        XCTAssertEqual(list.items[0].sessionIDs, ["session-2", "session-1"])
        XCTAssertEqual(list.archivedSessionIDs, ["session-old"])
    }

    func testMapsOfficialApprovalRequestAndKeepsResponseRPCID() throws {
        let request = DSHServerRequest(
            type: "server-request",
            rpcId: "approval-rpc-1",
            method: "approval/requested",
            payload: .object([
                "type": .string("approval/requested"),
                "sessionId": .string("session-1"),
                "approvalId": .string("approval-1"),
                "toolName": .string("bash"),
                "callId": .string("call-1"),
                "reason": .string("需要写入工作区外部")
            ])
        )

        guard let mapped = try DSHAgentGateway.mapMux(request),
              case .approvalRequested(let approval) = mapped else {
            return XCTFail("Expected approval request")
        }
        XCTAssertEqual(approval.id, "approval-1")
        XCTAssertEqual(approval.sessionID, "session-1")
        XCTAssertEqual(approval.responseToken, "approval-rpc-1")
        XCTAssertEqual(approval.choices, [.deny, .once])
        XCTAssertTrue(approval.waitsForResolutionEvent)
    }

    func testMapsOfficialApprovalResolution() throws {
        let request = DSHServerRequest(
            type: "server-request",
            rpcId: "resolved-rpc",
            method: "approval/resolved",
            payload: .object([
                "sessionId": .string("session-1"),
                "approvalId": .string("approval-1"),
                "outcome": .string("allowed-once")
            ])
        )

        guard let mapped = try DSHAgentGateway.mapMux(request),
              case .approvalResolved(let sessionID, let approvalID, let outcome) = mapped else {
            return XCTFail("Expected approval resolution")
        }
        XCTAssertEqual(sessionID, "session-1")
        XCTAssertEqual(approvalID, "approval-1")
        XCTAssertEqual(outcome, "allowed-once")
    }

    func testMapsQuestionRequestAndKeepsResponseRPCID() throws {
        let request = DSHServerRequest(
            type: "server-request",
            rpcId: "question-rpc-1",
            method: "question/requested",
            payload: .object([
                "type": .string("question/requested"),
                "sessionId": .string("session-1"),
                "questions": .array([
                    .object([
                        "id": .string("q-1"),
                        "question": .string("请选择部署方案"),
                        "header": .string("部署"),
                        "detail": .string("选择部署方式"),
                        "multiSelect": .bool(false),
                        "options": .array([
                            .object(["label": .string("方案A"), "description": .string("快速")]),
                            .object(["label": .string("方案B")])
                        ])
                    ])
                ])
            ])
        )

        guard let mapped = try DSHAgentGateway.mapMux(request),
              case .questionRequested(let question) = mapped else {
            return XCTFail("Expected question request")
        }
        XCTAssertEqual(question.id, "question-rpc-1")
        XCTAssertEqual(question.sessionID, "session-1")
        XCTAssertEqual(question.responseToken, "question-rpc-1")
        XCTAssertEqual(question.questions.count, 1)
        XCTAssertEqual(question.questions[0].id, "q-1")
        XCTAssertEqual(question.questions[0].question, "请选择部署方案")
        XCTAssertEqual(question.questions[0].header, "部署")
        XCTAssertEqual(question.questions[0].detail, "选择部署方式")
        XCTAssertEqual(question.questions[0].options.count, 2)
        XCTAssertEqual(question.questions[0].options[0].label, "方案A")
        XCTAssertEqual(question.questions[0].options[0].description, "快速")
        XCTAssertFalse(question.questions[0].multiSelect)
        XCTAssertTrue(question.waitsForResolutionEvent)
    }

    func testMapsQuestionResolution() throws {
        let request = DSHServerRequest(
            type: "server-request",
            rpcId: "resolved-rpc",
            method: "question/resolved",
            payload: .object([
                "sessionId": .string("session-1"),
                "questionRpcId": .string("question-rpc-1"),
                "outcome": .string("answered")
            ])
        )

        guard let mapped = try DSHAgentGateway.mapMux(request),
              case .questionResolved(let sessionID, let questionRpcId, let outcome) = mapped else {
            return XCTFail("Expected question resolution")
        }
        XCTAssertEqual(sessionID, "session-1")
        XCTAssertEqual(questionRpcId, "question-rpc-1")
        XCTAssertEqual(outcome, "answered")
    }

    private func event(type: String, seq: Int, data: JSONValue) throws -> DSHSessionEvent {
        try DSHSessionEvent(json: .object([
            "type": .string(type),
            "seq": .number(Double(seq)),
            "time": .number(1_700_000_000_000 + Double(seq)),
            "data": data
        ]))
    }

    private func textBlocks(_ text: String) -> JSONValue {
        .array([.object(["type": .string("text"), "text": .string(text)])])
    }
}
