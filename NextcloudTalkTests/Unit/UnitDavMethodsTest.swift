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

    // The avatar upload methods must report an error instead of returning silently, otherwise the caller keeps its activity indicator forever
    func testSetAvatarWithoutSessionCallsCompletionWithError() throws {
        let unknownAccount = TalkAccount()
        unknownAccount.accountId = "no-such-account"
        unknownAccount.server = "https://nextcloud.invalid"

        var userImageError: Error?
        var userImageCompleted = false
        NCAPIController.sharedInstance().setUserProfileImage(UIImage(), forAccount: unknownAccount) { error in
            userImageError = error
            userImageCompleted = true
        }

        XCTAssertTrue(userImageCompleted)
        XCTAssertNotNil(userImageError)

        var roomImageError: Error?
        var roomImageCompleted = false
        NCAPIController.sharedInstance().setAvatar(forRoom: "token", withImage: UIImage(), forAccount: unknownAccount) { error in
            roomImageError = error
            roomImageCompleted = true
        }

        XCTAssertTrue(roomImageCompleted)
        XCTAssertNotNil(roomImageError)
    }
}
