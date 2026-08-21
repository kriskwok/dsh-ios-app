import XCTest
@testable import DSHIOSApp

final class CodexProtocolTests: XCTestCase {
    func testThreadSummaryUsesNamePreviewAndCwd() throws {
        let thread: JSONValue = .object([
            "id": .string("thread-1"),
            "name": .string("修复 CI"),
            "preview": .string("请修复 CI"),
            "createdAt": .number(1_700_000_000),
            "updatedAt": .number(1_700_000_100),
            "cwd": .string("/repo"),
            "status": .object(["type": .string("idle")])
        ])

        let summary = try XCTUnwrap(CodexAgentGateway.threadSummary(from: thread))

        XCTAssertEqual(summary.id, "thread-1")
        XCTAssertEqual(summary.title, "修复 CI")
        XCTAssertEqual(summary.workingDirectory, "/repo")
        XCTAssertEqual(summary.updatedAt, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertFalse(summary.isRunning)
    }

    func testWorkspacesGroupSessionsByCwd() {
        let sessions = [
            AgentSessionSummary(id: "a", workingDirectory: "/root"),
            AgentSessionSummary(id: "b", workingDirectory: "/root"),
            AgentSessionSummary(id: "c", workingDirectory: "/root/surewin")
        ]

        let workspaces = CodexAgentGateway.workspaces(from: sessions)

        XCTAssertEqual(workspaces.count, 3)
        let root = workspaces.first { $0.path == "/root" }
        XCTAssertEqual(root?.title, "root")
        XCTAssertEqual(root?.sessionIDs, ["a", "b"])
        let surewin = workspaces.first { $0.path == "/root/surewin" }
        XCTAssertEqual(surewin?.title, "surewin")
        XCTAssertEqual(surewin?.sessionIDs, ["c"])
        let defaultWorkspace = workspaces.first { $0.path == CodexAgentGateway.defaultWorkspacePath }
        XCTAssertEqual(defaultWorkspace?.title, "Codex")
        XCTAssertEqual(defaultWorkspace?.sessionIDs, [])
    }

    func testMessagesRebuildTurnsIntoConversation() {
        let turns: JSONValue = .array([
            .object([
                "items": .array([
                    .object([
                        "type": .string("userMessage"),
                        "id": .string("u1"),
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("你好")])
                        ])
                    ]),
                    .object([
                        "type": .string("reasoning"),
                        "id": .string("r1"),
                        "content": .array([.string("先看代码")])
                    ]),
                    .object([
                        "type": .string("agentMessage"),
                        "id": .string("a1"),
                        "text": .string("我来看一下")
                    ])
                ])
            ])
        ])

        let messages = CodexAgentGateway.messages(from: turns)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages[1].text, "我来看一下")
        XCTAssertEqual(messages[1].reasoning, "先看代码")
    }

    func testMapsAgentMessageDeltaToAssistantText() {
        let threadState = CodexThreadState()
        let notification = CodexRPCNotification(
            method: "agentMessage/delta",
            params: .object([
                "threadId": .string("t1"),
                "turnId": .string("turn-1"),
                "itemId": .string("a1"),
                "delta": .string("增量")
            ])
        )

        let events = CodexAgentGateway.map(notification, threadState: threadState)

        guard case .assistantDelta(let sessionID, let key, let text, let reasoning)? = events.first else {
            return XCTFail("Expected assistant delta")
        }
        XCTAssertEqual(sessionID, "t1")
        XCTAssertEqual(key, "a1")
        XCTAssertEqual(text, "增量")
        XCTAssertFalse(reasoning)
    }

    func testMapsLiveAgentMessageDeltaMethod() {
        let threadState = CodexThreadState()
        let notification = CodexRPCNotification(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string("t1"),
                "turnId": .string("turn-1"),
                "itemId": .string("a1"),
                "delta": .string("正在回复")
            ])
        )

        let events = CodexAgentGateway.map(notification, threadState: threadState)

        guard case .assistantDelta(let sessionID, let key, let text, let reasoning)? = events.first else {
            return XCTFail("Expected assistant delta")
        }
        XCTAssertEqual(sessionID, "t1")
        XCTAssertEqual(key, "a1")
        XCTAssertEqual(text, "正在回复")
        XCTAssertFalse(reasoning)
    }

    func testMapsReasoningTextDelta() {
        let threadState = CodexThreadState()
        let notification = CodexRPCNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string("t1"),
                "turnId": .string("turn-1"),
                "itemId": .string("r1"),
                "contentIndex": .number(0),
                "delta": .string("先看代码")
            ])
        )

        let events = CodexAgentGateway.map(notification, threadState: threadState)

        guard case .assistantDelta(_, _, let text, let reasoning)? = events.first else {
            return XCTFail("Expected reasoning delta")
        }
        XCTAssertEqual(text, "先看代码")
        XCTAssertTrue(reasoning)
        XCTAssertEqual(threadState.reasoningItems["r1"], ["先看代码"])
    }

    func testTurnCompletedEmitsFinalAssistantMessage() {
        let threadState = CodexThreadState()
        threadState.reasoningItems["r1"] = ["先想一下"]
        let notification = CodexRPCNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("t1"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "type": .string("agentMessage"),
                            "id": .string("a1"),
                            "text": .string("完成")
                        ])
                    ])
                ])
            ])
        )

        let events = CodexAgentGateway.map(notification, threadState: threadState)
        let complete = events.compactMap { event -> (String, String?, String, String)? in
            guard case .assistantComplete(let sessionID, let key, let text, let reasoning) = event else {
                return nil
            }
            return (sessionID, key, text, reasoning)
        }.first

        XCTAssertEqual(complete?.0, "t1")
        XCTAssertEqual(complete?.1, "a1")
        XCTAssertEqual(complete?.2, "完成")
        XCTAssertEqual(complete?.3, "先想一下")
    }

    func testMapsServerRequestResolvedByRequestId() {
        let threadState = CodexThreadState()
        let notification = CodexRPCNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("t1"),
                "requestId": .string("rpc-1")
            ])
        )

        let events = CodexAgentGateway.map(notification, threadState: threadState) { requestID in
            requestID == "rpc-1" ? .commandApproval : nil
        }

        guard case .approvalResolved(let sessionID, let approvalID, _)? = events.first else {
            return XCTFail("Expected approval resolved")
        }
        XCTAssertEqual(sessionID, "t1")
        XCTAssertEqual(approvalID, "rpc-1")
    }

    func testBuildsCommandApprovalRequestAndDecision() {
        let request = CodexServerRequest(
            id: .string("rpc-1"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("t1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "command": .string("rm -rf ./cache"),
                "proposedExecpolicyAmendment": .array([.string("write:~/cache")])
            ])
        )

        let approval = CodexAgentGateway.approvalRequest(from: request)

        XCTAssertEqual(approval.sessionID, "t1")
        XCTAssertEqual(approval.responseToken, "rpc-1")
        XCTAssertEqual(approval.command, "rm -rf ./cache")
        XCTAssertEqual(approval.choices, [.once, .session, .always, .deny])
        XCTAssertTrue(approval.waitsForResolutionEvent)
        XCTAssertEqual(
            CodexAgentGateway.decisionValue(.always, params: request.params),
            .object([
                "acceptWithExecpolicyAmendment": .object([
                    "execpolicy_amendment": .array([.string("write:~/cache")])
                ])
            ])
        )
    }

    func testBuildsUserInputQuestionAndAnswerResponse() {
        let request = CodexServerRequest(
            id: .number(7),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("t1"),
                "questions": .array([
                    .object([
                        "id": .string("q1"),
                        "header": .string("选择仓库"),
                        "question": .string("要在哪个仓库执行？"),
                        "options": .array([
                            .object(["label": .string("repo-a")]),
                            .object(["label": .string("repo-b")])
                        ])
                    ])
                ])
            ])
        )

        let question = CodexAgentGateway.questionRequest(from: request)

        XCTAssertEqual(question.sessionID, "t1")
        XCTAssertEqual(question.responseToken, "7")
        XCTAssertEqual(question.questions.count, 1)
        XCTAssertEqual(question.questions[0].options.map(\.label), ["repo-a", "repo-b"])
    }

    func testModelProviderInfersOpenAI() {
        XCTAssertEqual(CodexAgentGateway.providerID(for: "gpt-5.6-sol"), "openai")
        XCTAssertEqual(CodexAgentGateway.providerID(for: "codex-mini"), "openai")
        XCTAssertEqual(CodexAgentGateway.providerID(for: "o3"), "openai")
    }
}
