//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCSignalingResumePolicyTest: XCTestCase {

    private func action(_ type: String?, replaced: Bool) -> NCSignalingResumePolicy.QueuedMessageAction {
        return NCSignalingResumePolicy.queuedMessageAction(messageType: type, sessionReplaced: replaced)
    }

    func testQueuedMessagesAreSentOnTheSameOrTheFirstSession() {
        for type in ["message", "control", "room", "bye", nil] {
            XCTAssertEqual(action(type, replaced: false), .send, "type \(type ?? "nil")")
        }
    }

    func testCallMessagesOfTheOldSessionAreDropped() {
        XCTAssertEqual(action("message", replaced: true), .drop)
        XCTAssertEqual(action("control", replaced: true), .drop)
    }

    func testByeOfTheOldSessionIsDroppedWithoutAnError() {
        // Its goal, a new session, is reached already
        XCTAssertEqual(action("bye", replaced: true), .dropSilently)
    }

    func testRoomJoinAndUnknownMessagesAreKept() {
        XCTAssertEqual(action("room", replaced: true), .send)
        XCTAssertEqual(action("something", replaced: true), .send)
        XCTAssertEqual(action(nil, replaced: true), .send)
    }
}
