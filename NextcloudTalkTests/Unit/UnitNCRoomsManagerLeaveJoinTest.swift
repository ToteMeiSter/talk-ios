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
    private var pendingJoins = [String: (String?, NCRoom?, OcsError?, Int, String?) -> Void]()
    private var observer: NSObjectProtocol?
    private var joinObserver: NSObjectProtocol?

    override func setUpWithError() throws {
        try super.setUpWithError()

        originalExitRoomRequest = manager.exitRoomRequest
        originalJoinRoomRequest = manager.joinRoomRequest

        manager.exitRoomRequest = { [unowned self] token, _, completionBlock in
            self.events.append("exit \(token)")
            self.pendingExits[token] = completionBlock
            return self.makeTask()
        }

        manager.joinRoomRequest = { [unowned self] token, _, completionBlock in
            self.events.append("join \(token)")
            self.pendingJoins[token] = completionBlock
            return self.makeTask()
        }

        // No signaling server in the tests: a successful join ends right after the answer of the join request
        manager.externalSignalingRequest = { _, _, completion in
            completion(nil, nil, nil)
        }

        joinObserver = NotificationCenter.default.addObserver(forName: .NCRoomsManagerDidJoinRoom, object: manager, queue: nil) { [unowned self] notification in
            let failed = notification.userInfo?["error"] != nil
            self.events.append("joined \(notification.userInfo?["token"] as? String ?? "")\(failed ? " failed" : "")")
        }

        observer = NotificationCenter.default.addObserver(forName: .NCRoomsManagerDidLeaveRoom, object: manager, queue: nil) { [unowned self] notification in
            self.events.append("left \(notification.userInfo?["token"] as? String ?? "")")
        }
    }

    override func tearDownWithError() throws {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        if let joinObserver {
            NotificationCenter.default.removeObserver(joinObserver)
        }

        // Answer open joins and exits, the manager is shared between the tests
        for token in Array(pendingJoins.keys) {
            answerJoin(of: token, error: OcsError.genericError(), statusCode: 403)
        }

        for token in Array(pendingExits.keys) {
            answerExit(of: token)
        }

        for token in ["roomA", "roomB"] {
            manager.activeRooms.removeValue(forKey: token)
            manager.leaveRoom(token, forAccount: NCDatabaseManager.sharedInstance().activeAccount())
        }

        manager.exitRoomRequest = originalExitRoomRequest
        manager.joinRoomRequest = originalJoinRoomRequest
        manager.externalSignalingRequest = nil

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

    private func answerJoin(of token: String, sessionId: String? = "session-new", error: OcsError? = nil, statusCode: Int = 0) {
        pendingJoins.removeValue(forKey: token)?(error == nil ? sessionId : nil, nil, error, statusCode, nil)
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

    func testJoinIsNotBlockedWhenNoExitRequestWasMade() {
        activate("roomA")
        manager.exitRoomRequest = { [unowned self] token, _, _ in
            self.events.append("exit \(token)")
            return nil
        }

        leave("roomA")
        join("roomA")

        // Nothing answers a request which was not made, so nothing may wait for it
        XCTAssertEqual(events, ["exit roomA", "join roomA"])
    }

    func testJoinAfterFinishedExitStartsImmediately() {
        activate("roomA")

        leave("roomA")
        answerExit(of: "roomA")
        join("roomA")

        XCTAssertEqual(events, ["exit roomA", "left roomA", "join roomA"])
    }

    // MARK: - Two joins of the same room (the flags say who needs the room: the chat, the call, or both)

    func testChatThenCallWhileWaitingForExitKeepsBothFlags() {
        activate("roomA")

        leave("roomA")
        join("roomA")
        join("roomA", forCall: true)
        answerExit(of: "roomA")
        answerJoin(of: "roomA")

        // One session for both. Without the chat flag the end of the call would leave the room under the open chat
        XCTAssertEqual(events.filter { $0 == "join roomA" }.count, 1)
        XCTAssertEqual(manager.activeRooms["roomA"]?.inChat, true)
        XCTAssertEqual(manager.activeRooms["roomA"]?.inCall, true)
    }

    func testCallThenChatWhileWaitingForExitKeepsBothFlags() {
        activate("roomA")

        leave("roomA")
        join("roomA", forCall: true)
        join("roomA")
        answerExit(of: "roomA")
        answerJoin(of: "roomA")

        // Without the call flag the end of the chat would leave the room under the running call
        XCTAssertEqual(manager.activeRooms["roomA"]?.inChat, true)
        XCTAssertEqual(manager.activeRooms["roomA"]?.inCall, true)
    }

    func testSecondJoinWhileFirstIsRunningDoesNotSendASecondRequest() {
        join("roomA")
        join("roomA", forCall: true)

        // Two requests would create two sessions, the call would start with the one which the server already closed
        XCTAssertEqual(events.filter { $0 == "join roomA" }.count, 1)

        answerJoin(of: "roomA")

        XCTAssertEqual(manager.activeRooms["roomA"]?.inChat, true)
        XCTAssertEqual(manager.activeRooms["roomA"]?.inCall, true)
    }

    // MARK: - A re-join of a call room must not touch the join of another room

    func testRejoinOfOtherRoomDoesNotCancelWaitingJoin() {
        activate("roomA")
        activate("roomB")

        leave("roomA")
        join("roomA")
        manager.rejoinRoomForCall("roomB", forAccount: NCDatabaseManager.sharedInstance().activeAccount()) { _, _, _, _, _ in }
        answerExit(of: "roomA")

        // The re-join ends first and must not clear the state of the join of roomA
        answerJoin(of: "roomB", error: OcsError.genericError(), statusCode: 500)
        answerJoin(of: "roomA", error: OcsError.genericError(), statusCode: 403)

        XCTAssertTrue(events.contains("joined roomA failed"))
        XCTAssertEqual(events.filter { $0 == "exit roomA" }.count, 1)
    }

    func testRejoinOfOtherRoomDoesNotTakeOverRunningJoin() {
        activate("roomB")

        join("roomA")
        manager.rejoinRoomForCall("roomB", forAccount: NCDatabaseManager.sharedInstance().activeAccount()) { _, _, _, _, _ in }
        answerJoin(of: "roomA", error: OcsError.genericError(), statusCode: 403)

        XCTAssertTrue(events.contains("joined roomA failed"))
    }

    // MARK: - The answer of a join which is not wanted any more

    private func cancelledError() -> OcsError {
        return OcsError(withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), withTask: nil)
    }

    func testCancelledJoinOfLeftRoomIsLeftOnServer() {
        join("roomA")
        manager.leaveRoom("roomA", forAccount: NCDatabaseManager.sharedInstance().activeAccount())

        // The server may have handled the request before it was cancelled, so there can be a session to end
        answerJoin(of: "roomA", error: cancelledError(), statusCode: 0)

        XCTAssertEqual(events.filter { $0 == "exit roomA" }.count, 1)
    }

    func testFailedJoinOfLeftRoomIsNotLeftOnServer() {
        join("roomA")
        manager.leaveRoom("roomA", forAccount: NCDatabaseManager.sharedInstance().activeAccount())

        answerJoin(of: "roomA", error: OcsError(withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), withTask: nil), statusCode: 0)

        XCTAssertFalse(events.contains("exit roomA"))
    }

    func testSuccessfulJoinOfLeftRoomIsLeftOnServer() {
        join("roomA")
        manager.leaveRoom("roomA", forAccount: NCDatabaseManager.sharedInstance().activeAccount())

        answerJoin(of: "roomA")

        XCTAssertEqual(events.filter { $0 == "exit roomA" }.count, 1)
    }
}
