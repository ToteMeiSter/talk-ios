//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

// The call controller treats the merged list as the complete list of users: a session that is in it with
// an inCall flag above 0 is in the call, a session that is not in it (or has inCall 0) has left the call.
final class UnitCallUsersMergeTest: XCTestCase {

    private func user(_ sessionId: String, inCall: Int, internalClient: Bool = false) -> [String: Any] {
        var user: [String: Any] = ["sessionId": sessionId, "inCall": inCall]

        if internalClient {
            user["internal"] = true
        }

        return user
    }

    private func sessionIds(_ users: [[String: Any]]) -> [String] {
        return users.compactMap { $0["sessionId"] as? String }
    }

    private func inCall(_ sessionId: String, in users: [[String: Any]]) -> Int? {
        return users.first(where: { $0["sessionId"] as? String == sessionId })?["inCall"] as? Int
    }

    // MARK: - Partial update

    func testPartialUpdateWithoutOwnSessionKeepsOwnSession() {
        let known = [user("own", inCall: 7), user("other", inCall: 7)]
        let update = [user("recorder", inCall: 3, internalClient: true)]

        let merged = CallUsersMerge.merging(update, into: known)

        XCTAssertEqual(inCall("own", in: merged), 7)
        XCTAssertEqual(inCall("other", in: merged), 7)
        XCTAssertEqual(inCall("recorder", in: merged), 3)
        XCTAssertEqual(merged.count, 3)
    }

    func testPartialUpdateWithoutOtherSessionsKeepsTheirState() {
        let known = [user("own", inCall: 7), user("a", inCall: 7), user("b", inCall: 3)]

        let merged = CallUsersMerge.merging([user("a", inCall: 1)], into: known)

        XCTAssertEqual(sessionIds(merged), ["own", "a", "b"])
        XCTAssertEqual(inCall("a", in: merged), 1)
        XCTAssertEqual(inCall("b", in: merged), 3)
    }

    func testUpdateWithInCallZeroForOwnSessionMarksItAsLeft() {
        let known = [user("own", inCall: 7), user("other", inCall: 7)]

        let merged = CallUsersMerge.merging([user("own", inCall: 0)], into: known)

        XCTAssertEqual(inCall("own", in: merged), 0)
        XCTAssertEqual(inCall("other", in: merged), 7)
    }

    func testUpdateWithInCallZeroForOtherSessionKeepsOwnSession() {
        let known = [user("own", inCall: 7), user("other", inCall: 7)]

        let merged = CallUsersMerge.merging([user("other", inCall: 0)], into: known)

        XCTAssertEqual(inCall("own", in: merged), 7)
        XCTAssertEqual(inCall("other", in: merged), 0)
    }

    func testUpdateAddsNewSessionsAndIgnoresEntriesWithoutSessionId() {
        let known = [user("own", inCall: 7)]

        let merged = CallUsersMerge.merging([user("new", inCall: 7), ["inCall": 7]], into: known)

        XCTAssertEqual(sessionIds(merged), ["own", "new"])
    }

    func testEmptyUpdateKeepsKnownUsers() {
        let known = [user("own", inCall: 7), user("other", inCall: 7)]

        XCTAssertEqual(sessionIds(CallUsersMerge.merging([], into: known)), ["own", "other"])
    }

    // MARK: - Leave

    func testLeaveRemovesOnlyTheNamedSessions() {
        let known = [user("own", inCall: 7), user("a", inCall: 7), user("b", inCall: 7)]

        let remaining = CallUsersMerge.removing(sessionIds: ["a", "unknown"], from: known)

        XCTAssertEqual(sessionIds(remaining), ["own", "b"])
    }

    func testLeaveWithoutKnownSessionsChangesNothing() {
        let known = [user("own", inCall: 7)]

        XCTAssertEqual(CallUsersMerge.removing(sessionIds: ["unknown"], from: known).count, known.count)
        XCTAssertEqual(CallUsersMerge.removing(sessionIds: [], from: known).count, known.count)
    }
}
