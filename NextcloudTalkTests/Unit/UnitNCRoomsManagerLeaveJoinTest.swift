//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// A join of a room which is still being left must not overtake the exit request: the server ends the session which
/// belongs to the cookie when it handles the DELETE, so a DELETE handled after the join would end the new session.
final class UnitNCRoomsManagerLeaveJoinTest: TestBaseRealm {

    private let manager = NCRoomsManager.shared
    private var accountId: String { TestBaseRealm.fakeAccountId }

    private var originalExitRoomRequest: ((String, TalkAccount, @escaping (OcsError?) -> Void) -> URLSessionTask?)!
    private var originalJoinRoomRequest: ((String, TalkAccount, @escaping (String?, NCRoom?, OcsError?, Int, String?) -> Void) -> URLSessionTask?)!

    // The requests in the order they were sent, answers of the exit requests wait until the test sends them
    private var events = [String]()
    private var pendingExits = [String: (OcsError?) -> Void]()
    private var observer: NSObjectProtocol?

    override func setUpWithError() throws {
        try super.setUpWithError()

        originalExitRoomRequest = manager.exitRoomRequest
        originalJoinRoomRequest = manager.joinRoomRequest

        manager.exitRoomRequest = { [unowned self] token, _, completionBlock in
            self.events.append("exit \(token)")
            self.pendingExits[token] = completionBlock
            return self.makeTask()
        }

        manager.joinRoomRequest = { [unowned self] token, _, _ in
            self.events.append("join \(token)")
            return self.makeTask()
        }

        observer = NotificationCenter.default.addObserver(forName: .NCRoomsManagerDidLeaveRoom, object: manager, queue: nil) { [unowned self] notification in
            self.events.append("left \(notification.userInfo?["token"] as? String ?? "")")
        }
    }

    override func tearDownWithError() throws {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        // Answer open exits and drop open joins, the manager is shared between the tests
        for token in Array(pendingExits.keys) {
            answerExit(of: token)
        }

        for token in ["roomA", "roomB"] {
            manager.activeRooms.removeValue(forKey: token)
            manager.leaveRoom(token, forAccount: NCDatabaseManager.sharedInstance().activeAccount())
        }

        manager.exitRoomRequest = originalExitRoomRequest
        manager.joinRoomRequest = originalJoinRoomRequest

        try super.tearDownWithError()
    }

    private func makeTask() -> URLSessionTask {
        // Never resumed: the answers are sent by the test
        return URLSession.shared.dataTask(with: URL(string: "https://localhost.invalid")!)
    }

    private func activate(_ token: String) {
        manager.activeRooms[token] = NCRoomController(userSessionId: "session-\(token)", inCall: false, inChat: true)
    }

    private func leave(_ token: String) {
        manager.leaveChat(inRoom: token, forAccount: NCDatabaseManager.sharedInstance().activeAccount())
    }

    private func join(_ token: String, forCall call: Bool = false) {
        manager.joinRoom(token, forAccountId: accountId, forCall: call)
    }

    private func answerExit(of token: String, error: OcsError? = nil) {
        pendingExits.removeValue(forKey: token)?(error)
    }

    func testJoinWaitsForRunningExitOfSameRoom() {
        activate("roomA")

        leave("roomA")
        join("roomA")

        // The exit is not called back and the join is not sent while the exit has no answer
        XCTAssertEqual(events, ["exit roomA"])

        answerExit(of: "roomA")

        // The leave is reported before the join starts, the chat view needs that order
        XCTAssertEqual(events, ["exit roomA", "left roomA", "join roomA"])
    }

    func testJoinWaitsAlsoWhenExitFailed() {
        activate("roomA")

        leave("roomA")
        join("roomA")
        answerExit(of: "roomA", error: OcsError.genericError())

        XCTAssertEqual(events, ["exit roomA", "left roomA", "join roomA"])
    }

    func testLeaveWhileWaitingDropsTheJoin() {
        activate("roomA")

        leave("roomA")
        join("roomA")

        // The user left the chat again before the first exit finished
        manager.leaveRoom("roomA", forAccount: NCDatabaseManager.sharedInstance().activeAccount())
        answerExit(of: "roomA")

        XCTAssertEqual(events, ["exit roomA", "left roomA"])
    }

    func testNewerJoinReplacesWaitingJoin() {
        activate("roomA")

        leave("roomA")
        join("roomA")
        join("roomA", forCall: true)
        answerExit(of: "roomA")

        XCTAssertEqual(events.filter { $0 == "join roomA" }.count, 1)
    }

    func testJoinOfOtherRoomIsNotHeldBack() {
        activate("roomA")

        leave("roomA")
        join("roomB")

        XCTAssertEqual(events, ["exit roomA", "join roomB"])
    }

    func testAnswerOfOtherExitDoesNotReleaseWaitingJoin() {
        activate("roomA")
        activate("roomB")

        leave("roomA")
        leave("roomB")
        join("roomA")

        // The exit of roomB must neither end the wait for roomA nor forget that roomA is still being left
        answerExit(of: "roomB")
        XCTAssertFalse(events.contains("join roomA"))

        answerExit(of: "roomA")
        XCTAssertEqual(events.filter { $0.hasPrefix("join") }, ["join roomA"])
        XCTAssertEqual(events.last, "join roomA")
    }

    func testJoinAfterFinishedExitStartsImmediately() {
        activate("roomA")

        leave("roomA")
        answerExit(of: "roomA")
        join("roomA")

        XCTAssertEqual(events, ["exit roomA", "left roomA", "join roomA"])
    }
}
