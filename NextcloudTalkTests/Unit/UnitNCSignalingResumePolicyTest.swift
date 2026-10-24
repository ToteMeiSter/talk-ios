//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCSignalingResumePolicyTest: XCTestCase {

    func testResumeWithinTheWindow() {
        XCTAssertTrue(NCSignalingResumePolicy.canResume(resumeId: "abc", connectionLostTime: 1000, now: 1000))
        XCTAssertTrue(NCSignalingResumePolicy.canResume(resumeId: "abc", connectionLostTime: 1000, now: 1029.9))
    }

    func testNoResumeOutsideTheWindow() {
        XCTAssertFalse(NCSignalingResumePolicy.canResume(resumeId: "abc", connectionLostTime: 1000, now: 1030))
        XCTAssertFalse(NCSignalingResumePolicy.canResume(resumeId: "abc", connectionLostTime: 1000, now: 5000))
    }

    func testNoResumeWithoutResumeIdOrLostTime() {
        XCTAssertFalse(NCSignalingResumePolicy.canResume(resumeId: nil, connectionLostTime: 1000, now: 1001))
        XCTAssertFalse(NCSignalingResumePolicy.canResume(resumeId: "", connectionLostTime: 1000, now: 1001))
        XCTAssertFalse(NCSignalingResumePolicy.canResume(resumeId: "abc", connectionLostTime: nil, now: 1001))
    }

    func testFirstLostTimeIsKeptOnRepeatedReconnects() {
        let first = NCSignalingResumePolicy.connectionLostTime(existing: nil, now: 1000)
        XCTAssertEqual(first, 1000)

        // A failed reconnect attempt must not extend the window
        XCTAssertEqual(NCSignalingResumePolicy.connectionLostTime(existing: first, now: 1020), 1000)
        XCTAssertFalse(NCSignalingResumePolicy.canResume(resumeId: "abc", connectionLostTime: first, now: 1031))
    }

    // MARK: - Queued messages

    private func action(_ type: String?, replaced: Bool, rejoin: Bool = false) -> NCSignalingResumePolicy.QueuedMessageAction {
        return NCSignalingResumePolicy.queuedMessageAction(messageType: type, sessionReplaced: replaced, rejoinFollows: rejoin)
    }

    func testQueuedMessagesAreSentOnTheSameOrTheFirstSession() {
        for type in ["message", "control", "room", "bye", nil] {
            XCTAssertEqual(action(type, replaced: false), .send, "type \(type ?? "nil")")
            XCTAssertEqual(action(type, replaced: false, rejoin: true), .send, "type \(type ?? "nil")")
        }
    }

    func testCallMessagesOfTheOldSessionAreDropped() {
        XCTAssertEqual(action("message", replaced: true), .drop)
        XCTAssertEqual(action("message", replaced: true, rejoin: true), .drop)
        XCTAssertEqual(action("control", replaced: true), .drop)
    }

    func testByeOfTheOldSessionIsDroppedWithoutAnError() {
        // Its goal, a new session, is reached already
        XCTAssertEqual(action("bye", replaced: true), .dropSilently)
    }

    func testRoomJoinIsKeptUnlessTheRejoinSendsItAgain() {
        XCTAssertEqual(action("room", replaced: true, rejoin: false), .send)
        XCTAssertEqual(action("room", replaced: true, rejoin: true), .drop)
    }

    func testUnknownMessagesAreKept() {
        XCTAssertEqual(action("something", replaced: true), .send)
        XCTAssertEqual(action(nil, replaced: true), .send)
    }
}
