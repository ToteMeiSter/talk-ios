//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

final class UIMessageSelectionTest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let toolbar = app.otherElements["SLKTextInputbar"]
        let textView = toolbar.textViews["Write message, @ to mention someone …"]
        XCTAssert(textView.waitForExistence(timeout: TestConstants.timeoutShort))
        textView.tap()
        app.typeText(text)
        toolbar.buttons["Send message"].tap()
    }

    func testSelectCopyAndLeaveSelectionMode() {
        let app = launchAndLogin()

        self.createConversation(for: app, with: "SelectionTest")

        self.send("SelectionOne", in: app)
        waitForCount(query: app.cells.matching(identifier: "CellMessageSent"), count: 1, timeout: TestConstants.timeoutShort)
        self.send("SelectionTwo", in: app)
        waitForCount(query: app.cells.matching(identifier: "CellMessageSent"), count: 2, timeout: TestConstants.timeoutShort)

        let sentCells = app.cells.matching(identifier: "CellMessageSent")
        let first = sentCells.element(boundBy: 0)
        let second = sentCells.element(boundBy: 1)

        // A long press next to the bubble (own messages sit at the right edge) starts the selection mode
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.5)
        XCTAssert(app.staticTexts["1 selected"].waitForExistence(timeout: TestConstants.timeoutShort))
        XCTAssert(app.toolbars.buttons["Forward"].exists)
        XCTAssert(app.toolbars.buttons["Copy"].exists)

        // A tap on another row picks it, a second tap drops it again
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssert(app.staticTexts["2 selected"].waitForExistence(timeout: TestConstants.timeoutShort))
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssert(app.staticTexts["1 selected"].waitForExistence(timeout: TestConstants.timeoutShort))

        // Close leaves the mode and brings the input bar back
        waitForReady(object: app.navigationBars.buttons["Close"]).tap()
        XCTAssertFalse(app.staticTexts["1 selected"].waitForExistence(timeout: TestConstants.timeoutShort))
        XCTAssertFalse(app.toolbars.buttons["Copy"].exists)
        XCTAssert(app.otherElements["SLKTextInputbar"].textViews["Write message, @ to mention someone …"].waitForExistence(timeout: TestConstants.timeoutShort))

        // Copy leaves the mode, too
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.5)
        XCTAssert(app.staticTexts["1 selected"].waitForExistence(timeout: TestConstants.timeoutShort))
        waitForReady(object: app.toolbars.buttons["Copy"]).tap()
        XCTAssertFalse(app.toolbars.buttons["Copy"].waitForExistence(timeout: TestConstants.timeoutShort))
    }

    func testTapNextToBubbleShowsMenu() {
        let app = launchAndLogin()

        self.createConversation(for: app, with: "SelectionMenuTest")

        self.send("MenuByTap", in: app)
        let cell = app.cells["CellMessageSent"]
        XCTAssert(cell.waitForExistence(timeout: TestConstants.timeoutShort))

        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        waitForReady(object: app.buttons["Reply"])
    }
}
