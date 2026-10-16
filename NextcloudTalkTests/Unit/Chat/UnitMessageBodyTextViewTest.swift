//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitMessageBodyTextViewTest: TestBaseRealm {

    func testCellWithMarkdownQuoteHeight() throws {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        let testMessage = NCChatMessage(dictionary: [:], andAccountId: activeAccount.accountId)!

        // Markdown message
        testMessage.message = "> 1234567890123456789012345678"
        testMessage.isMarkdownMessage = true

        let messageTextView = MessageBodyTextView()
        messageTextView.attributedText = testMessage.parsedMarkdownForChat()

        XCTAssertEqual(messageTextView.intrinsicContentSize, CGSize(width: 259, height: 20))
    }

    func testRoomLinkOpensChatOnlyOnDefaultAction() throws {
        let messageTextView = MessageBodyTextView()
        let roomLink = "\(TestConstants.server)/call/abcd1234"

        XCTAssertTrue(messageTextView.shouldOpenChat(forLink: roomLink, interaction: .invokeDefaultAction))
        XCTAssertFalse(messageTextView.shouldOpenChat(forLink: roomLink, interaction: .presentActions))
        XCTAssertFalse(messageTextView.shouldOpenChat(forLink: roomLink, interaction: .preview))
    }

    func testOtherLinkNeverOpensChat() throws {
        let messageTextView = MessageBodyTextView()

        XCTAssertFalse(messageTextView.shouldOpenChat(forLink: "https://example.com/call/abcd1234", interaction: .invokeDefaultAction))
        XCTAssertFalse(messageTextView.shouldOpenChat(forLink: "https://example.com/page", interaction: .presentActions))
    }

    func testLongPressOnRoomLinkKeepsSystemBehavior() throws {
        let messageTextView = MessageBodyTextView()
        let roomLink = try XCTUnwrap(URL(string: "\(TestConstants.server)/call/abcd1234"))
        let range = NSRange(location: 0, length: 0)

        XCTAssertTrue(messageTextView.textView(messageTextView, shouldInteractWith: roomLink, in: range, interaction: .presentActions))
        XCTAssertTrue(messageTextView.textView(messageTextView, shouldInteractWith: roomLink, in: range, interaction: .preview))
    }

}
