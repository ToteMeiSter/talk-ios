//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitCallKitCallCancellationTest: XCTestCase {

    private func makeCall(accountId: String?, notificationId: Int, isRinging: Bool = true) -> (UUID, CallKitCall) {
        let uuid = UUID()
        let call = CallKitCall()
        call.uuid = uuid
        call.accountId = accountId
        call.notificationId = notificationId
        call.isRinging = isRinging
        return (uuid, call)
    }

    func testDeleteCancelsOnlyMatchingNotificationId() {
        let (matchingUUID, matching) = makeCall(accountId: "a1", notificationId: 10)
        let (otherUUID, other) = makeCall(accountId: "a1", notificationId: 11)
        let calls = [matchingUUID: matching, otherUUID: other]

        XCTAssertEqual(CallKitCallCancellation.uuidsToCancel(in: calls, accountId: "a1", notificationIds: [10]), [matchingUUID])
    }

    func testDeleteMultipleCancelsAllListedCalls() {
        let (firstUUID, first) = makeCall(accountId: "a1", notificationId: 10)
        let (secondUUID, second) = makeCall(accountId: "a1", notificationId: 11)
        let (thirdUUID, third) = makeCall(accountId: "a1", notificationId: 12)
        let calls = [firstUUID: first, secondUUID: second, thirdUUID: third]

        let result = CallKitCallCancellation.uuidsToCancel(in: calls, accountId: "a1", notificationIds: [10, 12, 99])
        XCTAssertEqual(Set(result), [firstUUID, thirdUUID])
    }

    func testDeleteAllCancelsRingingCallsOfAccountOnly() {
        let (ownUUID, own) = makeCall(accountId: "a1", notificationId: 10)
        let (noIdUUID, noId) = makeCall(accountId: "a1", notificationId: 0)
        let (foreignUUID, foreign) = makeCall(accountId: "a2", notificationId: 10)
        let calls = [ownUUID: own, noIdUUID: noId, foreignUUID: foreign]

        let result = CallKitCallCancellation.uuidsToCancel(in: calls, accountId: "a1", notificationIds: nil)
        XCTAssertEqual(Set(result), [ownUUID, noIdUUID])
    }

    func testOtherAccountIsNotCancelled() {
        let (uuid, call) = makeCall(accountId: "a2", notificationId: 10)

        XCTAssertTrue(CallKitCallCancellation.uuidsToCancel(in: [uuid: call], accountId: "a1", notificationIds: [10]).isEmpty)
    }

    func testAnsweredOrOngoingCallIsNotCancelled() {
        let (uuid, call) = makeCall(accountId: "a1", notificationId: 10, isRinging: false)

        XCTAssertTrue(CallKitCallCancellation.uuidsToCancel(in: [uuid: call], accountId: "a1", notificationIds: [10]).isEmpty)
        XCTAssertTrue(CallKitCallCancellation.uuidsToCancel(in: [uuid: call], accountId: "a1", notificationIds: nil).isEmpty)
    }

    func testCallWithoutNotificationIdIsNotMatchedById() {
        let (uuid, call) = makeCall(accountId: "a1", notificationId: 0)

        XCTAssertTrue(CallKitCallCancellation.uuidsToCancel(in: [uuid: call], accountId: "a1", notificationIds: [0]).isEmpty)
    }

    func testDeletedNotificationIsRememberedPerAccountForRetentionTime() {
        var deleted = CallKitDeletedNotifications()
        let now = Date()
        deleted.record([10, 11], accountId: "a1", at: now)

        XCTAssertTrue(deleted.contains(10, accountId: "a1", at: now.addingTimeInterval(1)))
        XCTAssertTrue(deleted.contains(11, accountId: "a1", at: now.addingTimeInterval(1)))
        XCTAssertFalse(deleted.contains(12, accountId: "a1", at: now.addingTimeInterval(1)))
        XCTAssertFalse(deleted.contains(10, accountId: "a2", at: now.addingTimeInterval(1)))
        XCTAssertFalse(deleted.contains(10, accountId: "a1", at: now.addingTimeInterval(CallKitDeletedNotifications.retentionSeconds + 1)))
    }

    func testExpiredEntriesAreDroppedOnRecord() {
        var deleted = CallKitDeletedNotifications()
        let now = Date()
        deleted.record([10], accountId: "a1", at: now)
        deleted.record([11], accountId: "a1", at: now.addingTimeInterval(CallKitDeletedNotifications.retentionSeconds + 5))

        XCTAssertFalse(deleted.contains(10, accountId: "a1", at: now.addingTimeInterval(CallKitDeletedNotifications.retentionSeconds + 6)))
        XCTAssertTrue(deleted.contains(11, accountId: "a1", at: now.addingTimeInterval(CallKitDeletedNotifications.retentionSeconds + 6)))
    }
}
