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
}
