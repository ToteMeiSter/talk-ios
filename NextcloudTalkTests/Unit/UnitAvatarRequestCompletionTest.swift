//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitAvatarRequestCompletionTest: TestBaseRealm {

    // The NotificationServiceExtension waits for these completion blocks, so they must be called even if no request can be started
    func testImageRequestsWithoutSessionCallCompletionWithError() throws {
        let unknownAccount = TalkAccount()
        unknownAccount.accountId = "no-such-account"
        unknownAccount.server = "https://nextcloud.invalid"

        let unknownRoom = NCRoom()
        unknownRoom.accountId = "no-such-account"
        unknownRoom.token = "token"

        let userAvatarExpectation = expectation(description: "getUserAvatar completion")
        _ = NCAPIController.sharedInstance().getUserAvatar(forUser: "user", withStyle: .light, forAccount: unknownAccount) { image, error in
            XCTAssertNil(image)
            XCTAssertNotNil(error)
            userAvatarExpectation.fulfill()
        }

        let roomAvatarExpectation = expectation(description: "getAvatar completion")
        _ = NCAPIController.sharedInstance().getAvatar(forRoom: unknownRoom, withStyle: .light) { image, error in
            XCTAssertNil(image)
            XCTAssertNotNil(error)
            roomAvatarExpectation.fulfill()
        }

        let previewExpectation = expectation(description: "getPreviewForFile completion")
        _ = NCAPIController.sharedInstance().getPreviewForFile("1", width: 0, height: 512, forAccount: unknownAccount) { image, error in
            XCTAssertNil(image)
            XCTAssertNotNil(error)
            previewExpectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }
}
