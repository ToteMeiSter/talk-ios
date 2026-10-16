//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitDavMethodsTest: TestBaseRealm {

    func testAlternativeNames() throws {
        XCTAssertEqual(NCAPIController.sharedInstance().alternativeName(forFileName: "test.pdf", isOriginal: true), "test (1).pdf")
        XCTAssertEqual(NCAPIController.sharedInstance().alternativeName(forFileName: "test (1).pdf", isOriginal: true), "test (1) (1).pdf")
        XCTAssertEqual(NCAPIController.sharedInstance().alternativeName(forFileName: "test (1).pdf", isOriginal: false), "test (2).pdf")
        XCTAssertEqual(NCAPIController.sharedInstance().alternativeName(forFileName: "test (24).pdf", isOriginal: false), "test (25).pdf")
        XCTAssertEqual(NCAPIController.sharedInstance().alternativeName(forFileName: "test (24) (1).pdf", isOriginal: false), "test (24) (2).pdf")
        XCTAssertEqual(NCAPIController.sharedInstance().alternativeName(forFileName: "test (24) (1)", isOriginal: false), "test (24) (2)")
    }

    // The avatar methods must report an error (asynchronously, like the network path) instead of returning silently, otherwise the caller keeps its activity indicator forever
    func testAvatarMethodsWithoutSessionCallCompletionWithError() throws {
        let unknownAccount = TalkAccount()
        unknownAccount.accountId = "no-such-account"
        unknownAccount.server = "https://nextcloud.invalid"

        let unknownRoom = NCRoom()
        unknownRoom.accountId = "no-such-account"
        unknownRoom.token = "token"

        let userImageExpectation = expectation(description: "setUserProfileImage completion")
        var userImageCompletedSynchronously = true
        NCAPIController.sharedInstance().setUserProfileImage(UIImage(), forAccount: unknownAccount) { error in
            XCTAssertNotNil(error)
            XCTAssertFalse(userImageCompletedSynchronously)
            userImageExpectation.fulfill()
        }
        userImageCompletedSynchronously = false

        let roomImageExpectation = expectation(description: "setAvatar completion")
        NCAPIController.sharedInstance().setAvatar(forRoom: "token", withImage: UIImage(), forAccount: unknownAccount) { error in
            XCTAssertNotNil(error)
            roomImageExpectation.fulfill()
        }

        let emojiExpectation = expectation(description: "setEmojiAvatar completion")
        NCAPIController.sharedInstance().setEmojiAvatar(forRoom: "token", withEmoji: "😀", withColor: "", forAccount: unknownAccount) { error in
            XCTAssertNotNil(error)
            emojiExpectation.fulfill()
        }

        let removeRoomAvatarExpectation = expectation(description: "removeAvatar completion")
        NCAPIController.sharedInstance().removeAvatar(forRoom: unknownRoom) { error in
            XCTAssertNotNil(error)
            removeRoomAvatarExpectation.fulfill()
        }

        let removeProfileImageExpectation = expectation(description: "removeUserProfileImage completion")
        NCAPIController.sharedInstance().removeUserProfileImage(forAccount: unknownAccount) { error in
            XCTAssertNotNil(error)
            removeProfileImageExpectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }
}
