import XCTest
@testable import DSHIOSApp

final class HermesProtocolTests: XCTestCase {
    func testOfficialPKCEChallengeVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            HermesNativeOAuth.codeChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testBuildsNativeAuthorizeURLWithPrefix() throws {
        let url = try XCTUnwrap(HermesNativeOAuth.authorizeURL(
            baseURL: URL(string: "https://hm.example:8650/hermes")!,
            challenge: "challenge",
            redirectURI: "http://127.0.0.1:54321/callback",
            state: "state",
            provider: "nous"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(components.path, "/hermes/auth/native/authorize")
        XCTAssertEqual(items["code_challenge"]!, "challenge")
        XCTAssertEqual(items["code_challenge_method"]!, "S256")
        XCTAssertEqual(items["redirect_uri"]!, "http://127.0.0.1:54321/callback")
        XCTAssertEqual(items["state"]!, "state")
        XCTAssertEqual(items["provider"]!, "nous")
    }

    func testValidatesNativeCallbackState() throws {
        let callback = URL(string: "http://127.0.0.1:54321/callback?code=one-time&state=expected")!
        XCTAssertEqual(
            try HermesNativeOAuth.authorizationCode(from: callback, expectedState: "expected"),
            "one-time"
        )
        XCTAssertThrowsError(try HermesNativeOAuth.authorizationCode(from: callback, expectedState: "wrong")) { error in
            XCTAssertEqual(error as? HermesNativeOAuth.OAuthError, .stateMismatch)
        }
    }

    func testNativeCallbackToleratesRepeatedQueryKeys() throws {
        let callback = URL(string: "http://127.0.0.1:54321/callback?state=stale&code=old&state=expected&code=current")!

        XCTAssertEqual(
            try HermesNativeOAuth.authorizationCode(from: callback, expectedState: "expected"),
            "current"
        )
    }

    func testDetectsOfficialNativeAuthCapability() {
        let status = HermesAuthStatus(value: .object([
            "auth_flows": .array([.string("cookie"), .string("native_pkce")]),
            "auth_providers": .array([.string("basic"), .string("nous")]),
        ]))

        XCTAssertTrue(status.supportsNativePKCE)
        XCTAssertEqual(status.nativeProvider, "nous")
    }

    func testMapsSessionListRow() throws {
        let row: JSONValue = .object([
            "id": .string("stored-1"),
            "title": .string("修复部署问题"),
            "started_at": .number(1_700_000_000),
            "message_count": .number(4),
            "source": .string("desktop")
        ])

        let session = try XCTUnwrap(HermesAgentGateway.session(from: row))

        XCTAssertEqual(session.id, "stored-1")
        XCTAssertEqual(session.title, "修复部署问题")
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(session.isBlank)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.source, "desktop")
        XCTAssertEqual(session.channel.title, "桌面端")
    }

    func testReadsHydratedProjectLanes() {
        let project: JSONValue = .object([
            "repos": .array([
                .object([
                    "groups": .array([
                        .object(["sessions": .array([
                            .object(["id": .string("one")]),
                            .object(["id": .string("two")])
                        ])])
                    ])
                ])
            ])
        ])

        XCTAssertEqual(
            HermesAgentGateway.projectSessions(project).compactMap { $0["id"]?.stringValue },
            ["one", "two"]
        )
    }

    func testGroupsHermesWorkspacesBySessionWorkingDirectory() {
        let sessions = [
            AgentSessionSummary(
                id: "old",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                workingDirectory: "/repos/dsh",
                source: "cli"
            ),
            AgentSessionSummary(
                id: "new",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                workingDirectory: " /repos/dsh ",
                source: "ios"
            ),
            AgentSessionSummary(
                id: "other",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
                workingDirectory: "/repos/other",
                source: "cli"
            ),
            AgentSessionSummary(
                id: "unknown",
                updatedAt: Date(timeIntervalSince1970: 1_699_999_000),
                workingDirectory: nil,
                source: "cli"
            )
        ]

        let workspaces = HermesAgentGateway.workspaces(from: sessions)

        XCTAssertEqual(workspaces.map(\.path), ["/repos/other", "/repos/dsh", ""])
        XCTAssertEqual(workspaces[1].id, "cwd:/repos/dsh")
        XCTAssertEqual(Set(workspaces[1].sessionIDs), ["old", "new"])
        XCTAssertEqual(workspaces[2].title, "未知工作区")
    }

    func testConvertsHermesHistoryMessages() {
        let history: JSONValue = .array([
            .object(["role": .string("user"), "text": .string("你好")]),
            .object([
                "role": .string("assistant"),
                "text": .string("你好，我来处理。"),
                "reasoning": .string("先确认需求")
            ]),
            .object(["role": .string("tool"), "name": .string("terminal")])
        ])

        let messages = HermesAgentGateway.messages(from: history)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .activity])
        XCTAssertEqual(messages[1].text, "你好，我来处理。")
        XCTAssertEqual(messages[1].reasoning, "先确认需求")
        XCTAssertEqual(messages[2].text, "已使用 terminal")
    }

    func testMapsOfficialDeltaEvent() {
    func testParsesSessionUsageMetrics() throws {
        let payload: JSONValue = .object([
            "usage": .object([
                "context_percent": .number(7.0),
                "context_used": .number(18242.0),
                "context_max": .number(262144.0)
            ])
        ])

        let metrics = try XCTUnwrap(AgentSessionMetrics(json: payload))
        XCTAssertEqual(metrics.contextUsageRatio ?? 0, 0.07, accuracy: 0.0001)
        XCTAssertNil(metrics.cacheHitRatio)
    }

    func testComputesContextRatioFromTokens() throws {
        let payload: JSONValue = .object([
            "usage": .object([
                "context_used": .number(18242.0),
                "context_max": .number(262144.0)
            ])
        ])

        let metrics = try XCTUnwrap(AgentSessionMetrics(json: payload))
        XCTAssertEqual(metrics.contextUsageRatio ?? 0, 18242.0 / 262144.0, accuracy: 0.0001)
    }

    func testMapsMessageCompleteUsageMetrics() {
        let event = HermesGatewayEvent(
            type: "message.complete",
            sessionID: "runtime-1",
            payload: .object([
                "text": .string("完成"),
                "usage": .object([
                    "context_percent": .number(7.0),
                    "context_used": .number(18242.0),
                    "context_max": .number(262144.0)
                ])
            ])
        )

        let events = HermesAgentGateway.map(event)
        XCTAssertEqual(events.count, 2)
        guard case .sessionMetrics(_, let metrics) = events[1] else {
            return XCTFail("Expected session metrics")
        }
        XCTAssertEqual(metrics.contextUsageRatio ?? 0, 0.07, accuracy: 0.0001)
    }

        let event = HermesGatewayEvent(
            type: "message.delta",
            sessionID: "runtime-1",
            payload: .object(["text": .string("增量")])
        )

        guard let mapped = HermesAgentGateway.map(event).first,
              case .assistantDelta(let sessionID, _, let text, let reasoning) = mapped else {
            return XCTFail("Expected assistant delta")
        }
        XCTAssertEqual(sessionID, "runtime-1")
        XCTAssertEqual(text, "增量")
        XCTAssertFalse(reasoning)
    }

    func testMapsOfficialApprovalRequestChoices() {
        let event = HermesGatewayEvent(
            type: "approval.request",
            sessionID: "runtime-1",
            payload: .object([
                "command": .string("rm -rf ./cache"),
                "description": .string("recursive deletion"),
                "choices": .array([.string("once"), .string("session"), .string("deny")]),
                "allow_permanent": .bool(false)
            ])
        )

        guard let mapped = HermesAgentGateway.map(event).first,
              case .approvalRequested(let approval) = mapped else {
            return XCTFail("Expected approval request")
        }
        XCTAssertEqual(approval.sessionID, "runtime-1")
        XCTAssertEqual(approval.command, "rm -rf ./cache")
        XCTAssertEqual(approval.choices, [.once, .session, .deny])
        XCTAssertFalse(approval.waitsForResolutionEvent)
    }

    func testGroupsKnownAndFutureHermesSources() {
        XCTAssertEqual(AgentSessionChannel(source: "ios").title, "APP")
        XCTAssertEqual(AgentSessionChannel(source: "weixin").title, "微信")
        XCTAssertEqual(AgentSessionChannel(source: "feishu").title, "飞书")
        XCTAssertEqual(AgentSessionChannel(source: "subagent").id, "automation")
        XCTAssertEqual(AgentSessionChannel(source: "telegram").title, "Telegram")
    }
}
