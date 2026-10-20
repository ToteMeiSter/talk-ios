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
    private var originalSignalingJoinTimeout: TimeInterval = 0
    private var originalJoinRoomRequest: ((String, TalkAccount, @escaping (String?, NCRoom?, OcsError?, Int, String?) -> Void) -> URLSessionTask?)!

    // The requests in the order they were sent, answers of the exit requests wait until the test sends them
    private var events = [String]()
    private var pendingExits = [String: (OcsError?) -> Void]()
    private var pendingJoins = [String: [(String?, NCRoom?, OcsError?, Int, String?) -> Void]]()
    // Every join request in the order it was sent, to see which of them was cancelled
    private var joinTasks = [String: [URLSessionTask]]()
    private var observer: NSObjectProtocol?
    private var joinObserver: NSObjectProtocol?

    override func setUpWithError() throws {
        try super.setUpWithError()

        originalExitRoomRequest = manager.exitRoomRequest
        originalJoinRoomRequest = manager.joinRoomRequest
        originalSignalingJoinTimeout = manager.externalSignalingJoinTimeout

        manager.exitRoomRequest = { [unowned self] token, _, completionBlock in
            self.events.append("exit \(token)")
            self.pendingExits[token] = completionBlock
            return self.makeTask()
        }

        manager.joinRoomRequest = { [unowned self] token, _, completionBlock in
            self.events.append("join \(token)")
            self.pendingJoins[token, default: []].append(completionBlock)

            let task = self.makeTask()
            self.joinTasks[token, default: []].append(task)
            return task
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
        while let token = pendingJoins.keys.first {
            answerJoin(of: token, error: OcsError.genericError(), statusCode: 403)
        }

        // An answer can start another exit (the repeated exit of a left room)
        while let token = pendingExits.keys.first {
            answerExit(of: token)
        }

        for token in ["roomA", "roomB"] {
            manager.activeRooms.removeValue(forKey: token)
            manager.leaveRoom(token, forAccount: NCDatabaseManager.sharedInstance().activeAccount())
        }

        manager.exitRoomRequest = originalExitRoomRequest
        manager.joinRoomRequest = originalJoinRoomRequest
        manager.externalSignalingRequest = nil
        manager.externalSignalingJoinTimeout = originalSignalingJoinTimeout

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

    /// Answers the oldest open join request of the room, requests of one room are answered in the order they were sent
    private func answerJoin(of token: String, sessionId: String? = "session-new", error: OcsError? = nil, statusCode: Int = 0) {
        guard var requests = pendingJoins[token], !requests.isEmpty else { return }

        let answer = requests.removeFirst()
        pendingJoins[token] = requests.isEmpty ? nil : requests

        answer(error == nil ? sessionId : nil, nil, error, statusCode, nil)
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

    func testChatLeavesWhileMergedJoinWaitsForExitCallKeepsTheJoin() {
        activate("roomA")

        leave("roomA")
        join("roomA")
        join("roomA", forCall: true)

        // The chat is closed again, the call still needs the room
        leave("roomA")
        answerExit(of: "roomA")
        answerJoin(of: "roomA")

        XCTAssertEqual(events.filter { $0 == "join roomA" }.count, 1)
        XCTAssertEqual(manager.activeRooms["roomA"]?.inCall, true)
        XCTAssertEqual(manager.activeRooms["roomA"]?.inChat, false)
    }

    func testChatLeavesWhileMergedJoinIsRunningCallKeepsTheJoin() {
        join("roomA", forCall: true)
        join("roomA")

        leave("roomA")
        answerJoin(of: "roomA")

        XCTAssertFalse(events.contains("exit roomA"))
        XCTAssertEqual(manager.activeRooms["roomA"]?.inCall, true)
        XCTAssertEqual(manager.activeRooms["roomA"]?.inChat, false)
    }

    func testLastUseLeavingWhileJoinIsRunningStopsTheJoin() {
        join("roomA", forCall: true)
        join("roomA")

        leave("roomA")
        manager.leaveRoom("roomA", forAccount: NCDatabaseManager.sharedInstance().activeAccount())
        answerJoin(of: "roomA")

        // Nobody needs the room any more: its answer is ignored and the session is ended
        XCTAssertNil(manager.activeRooms["roomA"])
        XCTAssertEqual(events.filter { $0 == "exit roomA" }.count, 1)
    }

    // MARK: - A re-join which is cancelled or answered after the room was left must not leave a session behind

    private var account: TalkAccount { NCDatabaseManager.sharedInstance().activeAccount() }

    private func rejoin(_ token: String, completion: @escaping (String?, Error?, Int) -> Void = { _, _, _ in }) {
        manager.rejoinRoomForCall(token, forAccount: account) { sessionId, _, error, statusCode, _ in
            completion(sessionId, error, statusCode)
        }
    }

    private func exitCount(of token: String) -> Int {
        return events.filter { $0 == "exit \(token)" }.count
    }

    func testCancelledRejoinOfLeftRoomIsLeftOnServerAfterTheExit() {
        activate("roomA")

        rejoin("roomA")
        leave("roomA")

        // The cancel does not revoke the request: the server can handle it after the DELETE of the leave and
        // the session which it creates then belongs to nobody
        answerJoin(of: "roomA", error: cancelledError(), statusCode: 0)
        XCTAssertEqual(exitCount(of: "roomA"), 1)

        answerExit(of: "roomA")
        XCTAssertEqual(exitCount(of: "roomA"), 2)

        answerExit(of: "roomA")
        XCTAssertEqual(exitCount(of: "roomA"), 2)
    }

    func testRejoinAnsweredAfterTheExitOfLeftRoomIsLeftOnServer() {
        activate("roomA")

        rejoin("roomA")
        leave("roomA")
        answerExit(of: "roomA")
        answerJoin(of: "roomA")

        XCTAssertEqual(exitCount(of: "roomA"), 2)
    }

    func testRejoinOfLeftRoomIsReportedAsNotActive() {
        activate("roomA")

        var result: (String?, Error?, Int)?
        rejoin("roomA") { result = ($0, $1, $2) }
        leave("roomA")
        answerJoin(of: "roomA")

        // The call must not go on with a session of a room it has left
        XCTAssertNil(result?.0)
        XCTAssertEqual(result?.2, NCRoomsManager.statusCodeRoomNotActive)
    }

    func testFailedRejoinOfLeftRoomIsNotLeftOnServer() {
        activate("roomA")

        rejoin("roomA")
        leave("roomA")
        answerExit(of: "roomA")
        answerJoin(of: "roomA", error: OcsError(withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), withTask: nil), statusCode: 0)

        XCTAssertEqual(exitCount(of: "roomA"), 1)
    }

    func testRejoinOfLeftRoomDoesNotEndTheSessionOfANewJoin() {
        activate("roomA")

        rejoin("roomA")
        leave("roomA")
        answerExit(of: "roomA")
        join("roomA")
        answerJoin(of: "roomA")
        answerJoin(of: "roomA")

        // The first answer is the one of the re-join, the second one of the new join. The new join is the answer to the rejoin as well: the server replaces the session of the cookie
        XCTAssertEqual(exitCount(of: "roomA"), 1)
        XCTAssertNotNil(manager.activeRooms["roomA"])
    }

    func testReplacedRejoinOfActiveRoomIsNotLeftOnServer() {
        activate("roomA")

        rejoin("roomA")
        rejoin("roomA")

        // The earlier request is cancelled, the later one serves the room. An exit would end the later session
        XCTAssertNotEqual(joinTasks["roomA"]?.first?.state, .suspended)
        XCTAssertEqual(exitCount(of: "roomA"), 0)
    }

    // MARK: - Re-joins of two rooms are tracked each on its own

    func testLeavingRoomCancelsItsRejoinAlthoughAnotherRoomRejoinedLater() {
        activate("roomA")
        activate("roomB")

        rejoin("roomA")
        rejoin("roomB")
        leave("roomA")

        XCTAssertNotEqual(joinTasks["roomA"]?.first?.state, .suspended)
        XCTAssertEqual(joinTasks["roomB"]?.first?.state, .suspended)
    }

    func testSecondRejoinOfRoomCancelsTheFirstAlthoughAnotherRoomRejoinedBetween() {
        activate("roomA")
        activate("roomB")

        rejoin("roomA")
        rejoin("roomB")
        rejoin("roomA")

        XCTAssertEqual(joinTasks["roomA"]?.count, 2)
        XCTAssertNotEqual(joinTasks["roomA"]?.first?.state, .suspended)
        XCTAssertEqual(joinTasks["roomA"]?.last?.state, .suspended)
    }

    // MARK: - A signaling server which does not answer must not keep the room for ever

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)

        while !condition() && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// A controller which is not connected keeps the room message in its queue and never answers it
    private func useSilentSignalingServer() {
        let silentController = NCExternalSignalingController(account: account, serverUrl: "https://localhost.invalid", ticket: "fakeTicket")
        manager.externalSignalingJoinTimeout = 0.3
        manager.externalSignalingRequest = { _, _, completion in
            completion(silentController, nil, nil)
        }
    }

    func testJoinIsRetriedAndEndsWhenSignalingServerDoesNotAnswer() {
        useSilentSignalingServer()

        join("roomA", forCall: true)
        answerJoin(of: "roomA")

        // The wait for the signaling server is bounded: the join is tried again like after any other failure
        waitUntil { events.filter { $0 == "join roomA" }.count >= 2 }
        XCTAssertEqual(events.filter { $0 == "join roomA" }.count, 2)

        answerJoin(of: "roomA", error: OcsError.genericError(), statusCode: 403)
        XCTAssertTrue(events.contains("joined roomA failed"))

        // The room is free again: a new join sends a request, it is not merged into a join which never ends
        join("roomA")
        XCTAssertEqual(events.filter { $0 == "join roomA" }.count, 3)
    }

    func testRejoinFailsWhenSignalingServerDoesNotAnswer() {
        useSilentSignalingServer()
        activate("roomA")

        var result: (String?, Error?, Int)?
        rejoin("roomA") { result = ($0, $1, $2) }
        answerJoin(of: "roomA")

        waitUntil { result != nil }

        // The caller is told, so it can repeat the re-join
        XCTAssertNotNil(result)
        XCTAssertNil(result?.0)
        XCTAssertNotNil(result?.1)
    }

    func testRejoinAnsweredBySignalingServerAfterLeaveIsReportedAsNotActive() {
        useSilentSignalingServer()
        activate("roomA")

        var result: (String?, Error?, Int)?
        rejoin("roomA") { result = ($0, $1, $2) }
        answerJoin(of: "roomA")

        // The room is left while the signaling server is asked
        leave("roomA")
        waitUntil { result != nil }

        XCTAssertEqual(result?.2, NCRoomsManager.statusCodeRoomNotActive)
    }
}
