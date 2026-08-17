import XCTest
@testable import DSHIOSApp

final class AgentPresentationTests: XCTestCase {
    func testDSHUIParserKeepsReplyOrderAndBuildsNativeComponents() throws {
        let text = """
        先看概览。

        ```dsh-ui
        {"title":"运行状态","items":[{"type":"grid","cols":2,"items":[{"type":"stat","label":"任务","value":"8"},{"type":"progress","label":"完成","value":75}]}]}
        ```

        以上为实时结果。
        """

        let segments = DSHUIParser.segments(in: text)

        XCTAssertEqual(segments.count, 3)
        guard case .interface(let document) = segments[1] else {
            return XCTFail("Expected a dsh-ui document")
        }
        XCTAssertEqual(document.title, "运行状态")
        XCTAssertEqual(document.items.map(\.type), ["grid"])
        XCTAssertEqual(document.items[0].children.map(\.type), ["stat", "progress"])
    }

    func testDSHUIParserLeavesMalformedFenceVisibleAsMarkdown() {
        let text = """
        ```dsh-ui
        {"items":[{"type":"stat"}]
        ```
        """

        let segments = DSHUIParser.segments(in: text)

        XCTAssertEqual(segments.count, 1)
        guard case .markdown(_, let fallback) = segments[0] else {
            return XCTFail("Expected malformed dsh-ui to remain visible")
        }
        XCTAssertTrue(fallback.contains("```dsh-ui"))
    }

    func testMarkdownTextUsesFullSyntax() {
        let rendered = MarkdownText("**重点**").value

        XCTAssertEqual(String(rendered.characters), "重点")
        XCTAssertTrue(rendered.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    func testMarkdownBlocksKeepSoftBreaksAndFencedCode() {
        let text = "第一行\n第二行\n\n```swift\nlet a = 1\nlet b = 2\n```"
        let blocks = MarkdownBlockParser.blocks(in: MarkdownBlockParser.normalize(text))

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .paragraph("第一行\n第二行"))
        XCTAssertEqual(blocks[1], .code(language: "swift", text: "let a = 1\nlet b = 2"))
    }

    func testMarkdownBlocksKeepTableAndListStructure() {
        let text = "| 名称 | 状态 |\n| --- | --- |\n| 任务 | 完成 |\n\n- 第一项\n- 第二项"
        let blocks = MarkdownBlockParser.blocks(in: MarkdownBlockParser.normalize(text))

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .table(headers: ["名称", "状态"], rows: [["任务", "完成"]]))
        XCTAssertEqual(blocks[1], .unorderedList(["第一项", "第二项"]))
    }

    func testDrawerMotionClampsAndUsesHalfwayReleaseThreshold() {
        XCTAssertEqual(DrawerMotion.clamped(-0.2), 0)
        XCTAssertEqual(DrawerMotion.clamped(1.2), 1)
        XCTAssertEqual(DrawerMotion.targetProgress(current: 0.48, predicted: 0.49), 0)
        XCTAssertEqual(DrawerMotion.targetProgress(current: 0.52, predicted: 0.51), 1)
        XCTAssertEqual(DrawerMotion.targetProgress(current: 0.2, predicted: 0.8), 1)
        XCTAssertEqual(DrawerMotion.targetProgress(current: 0.8, predicted: 0.2), 0)
    }

    func testSessionsSortByNewestUpdateFirst() {
        let older = AgentSessionSummary(
            id: "older",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = AgentSessionSummary(
            id: "newer",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let sorted = [older, newer].sorted(by: AgentSessionOrdering.newestFirst)

        XCTAssertEqual(sorted.map(\.id), ["newer", "older"])
        XCTAssertEqual(AgentSessionOrdering.latestUpdate(in: sorted), newer.updatedAt)
    }

    func testSessionTimestampUsesTimeDayAndYearTiers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 15, hour: 21
        )))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 15, hour: 20, minute: 48
        )))
        let thisYear = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 14, hour: 13, minute: 14
        )))
        let priorYear = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2025, month: 12, day: 31
        )))

        XCTAssertEqual(SessionTimestampFormatter.string(for: today, relativeTo: now, calendar: calendar), "20:48")
        XCTAssertEqual(SessionTimestampFormatter.string(for: thisYear, relativeTo: now, calendar: calendar), "8月14日")
        XCTAssertEqual(SessionTimestampFormatter.string(for: priorYear, relativeTo: now, calendar: calendar), "2025年")
    }

    func testServerDisplayAddressKeepsPortAndHermesPath() throws {
        let profile = ServerProfile(
            kind: .hermes,
            name: "Hermes",
            baseURL: try XCTUnwrap(URL(string: "https://hm.czwyf.ltd:8650/hermes"))
        )

        XCTAssertEqual(profile.displayAddress, "hm.czwyf.ltd:8650/hermes")
    }

    func testFindsDefaultDSHWorkspaceByTitleOrPath() {
        let byTitle = AgentWorkspace(
            id: "title-match",
            path: "/srv/anything",
            title: "DSH-Workspace",
            sessionIDs: []
        )
        let byPath = AgentWorkspace(
            id: "path-match",
            path: "/srv/dsh_workspace",
            title: "默认工作区",
            sessionIDs: []
        )

        XCTAssertEqual(AgentWorkspaceSelection.defaultDSHWorkspaceID(in: [byTitle, byPath]), "title-match")
        XCTAssertEqual(AgentWorkspaceSelection.defaultDSHWorkspaceID(in: [byPath]), "path-match")
    }
}
