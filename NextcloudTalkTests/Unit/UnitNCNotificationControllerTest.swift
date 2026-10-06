//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCNotificationControllerTest: XCTestCase {

    func testServerNotificationIdIsReadFromUserInfo() {
        XCTAssertEqual(NCNotificationController.serverNotificationId(fromUserInfo: ["notificationId": NSNumber(value: 42)]), 42)
    }

    func testLocalNotificationsHaveNoServerNotificationId() {
        // Local missed call notification: accountId and type, but no notificationId
        let missedCall: [AnyHashable: Any] = ["accountId": "user@example.com", "localNotificationType": NCLocalNotificationType.missedCall.rawValue]

        XCTAssertNil(NCNotificationController.serverNotificationId(fromUserInfo: missedCall))
        XCTAssertNil(NCNotificationController.serverNotificationId(fromUserInfo: ["notificationId": NSNumber(value: 0)]))
        XCTAssertNil(NCNotificationController.serverNotificationId(fromUserInfo: ["notificationId": "42"]))
    }
}
