//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitTypingIndicatorView: XCTestCase {

    func testMentionIdFromServerLocal() throws {
        let typingView = TypingIndicatorView()

        XCTAssertEqual(typingView.typingLabel.text, "")

        typingView.addTyping(userIdentifier: "alice", displayName: "alice")
        XCTAssertEqual(typingView.typingLabel.text, "alice is typing…")

        typingView.addTyping(userIdentifier: "bob", displayName: "bob")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "alice and bob are typing…")

        typingView.addTyping(userIdentifier: "charlie", displayName: "charlie")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "alice, bob and charlie are typing…")

        typingView.addTyping(userIdentifier: "user1", displayName: "user1")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "alice, bob, charlie and 1 other is typing…")

        typingView.addTyping(userIdentifier: "user2", displayName: "user2")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "alice, bob, charlie and 2 others are typing…")
    }

    func testTypingOfUserStaysWhileAnotherSessionTypes() throws {
        let typingView = TypingIndicatorView()

        typingView.addTyping(userIdentifier: "alice", displayName: "alice", sessionId: "session-phone")
        typingView.addTyping(userIdentifier: "alice", displayName: "alice", sessionId: "session-laptop")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "alice is typing…")

        // One session stops typing or leaves, the other one still types
        typingView.removeTyping(userIdentifier: "alice", sessionId: "session-phone")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "alice is typing…")

        // The last session is gone
        typingView.removeTyping(userIdentifier: "alice", sessionId: "session-laptop")
        typingView.updateTypingIndicator()
        XCTAssertFalse(typingView.isVisible)
    }

    func testTypingOfOneGuestStaysWhenAnotherGuestLeaves() throws {
        let typingView = TypingIndicatorView()

        // For guests the sessionId is used as userIdentifier
        typingView.addTyping(userIdentifier: "guest-1", displayName: "Guest", sessionId: "guest-1")
        typingView.addTyping(userIdentifier: "guest-2", displayName: "Guest", sessionId: "guest-2")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "Guest and Guest are typing…")

        typingView.removeTyping(userIdentifier: "guest-1", sessionId: "guest-1")
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "Guest is typing…")

        typingView.removeTyping(userIdentifier: "guest-2", sessionId: "guest-2")
        typingView.updateTypingIndicator()
        XCTAssertFalse(typingView.isVisible)
    }

    func testTypingIsRemovedWhenAllSessionsAreInactive() throws {
        let typingView = TypingIndicatorView()

        typingView.addTyping(userIdentifier: "alice", displayName: "alice", sessionId: "session-phone")
        typingView.addTyping(userIdentifier: "alice", displayName: "alice", sessionId: "session-laptop")

        typingView.checkInactiveTypingUsers(currentUpdateTimestamp: Date().timeIntervalSinceReferenceDate + 16)
        typingView.updateTypingIndicator()
        XCTAssertFalse(typingView.isVisible)
    }

    func testTypingStaysWhenOnlyOneSessionIsInactive() throws {
        let typingView = TypingIndicatorView()

        typingView.addTyping(userIdentifier: "alice", displayName: "alice", sessionId: "session-phone")
        Thread.sleep(forTimeInterval: 0.5)
        typingView.addTyping(userIdentifier: "alice", displayName: "alice", sessionId: "session-laptop")

        // The phone session is older than 15 seconds now, the laptop session is not
        typingView.checkInactiveTypingUsers(currentUpdateTimestamp: Date().timeIntervalSinceReferenceDate + 14.7)
        typingView.updateTypingIndicator()
        XCTAssertEqual(typingView.typingLabel.text, "alice is typing…")

        // The phone session was forgotten, so the user is removed with the laptop session
        typingView.removeTyping(userIdentifier: "alice", sessionId: "session-laptop")
        typingView.updateTypingIndicator()
        XCTAssertFalse(typingView.isVisible)
    }
}
