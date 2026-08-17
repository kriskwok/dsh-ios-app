import XCTest

final class DrawerInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testMenuButtonOpensDrawer() {
        let menuButton = app.buttons["打开会话列表"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 3))

        menuButton.tap()

        XCTAssertTrue(app.buttons["服务器设置"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Conversation drawer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRightSwipeFromLeftEdgeOpensDrawer() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5))

        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(app.buttons["服务器设置"].waitForExistence(timeout: 3))
    }
}
