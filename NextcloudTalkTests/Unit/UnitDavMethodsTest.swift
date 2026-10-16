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

    func testShareForbiddenIsOnlyAlreadySharedWithTheRightToShare() throws {
        // 403 for a node the user may share: the path is already shared with the conversation
        XCTAssertTrue(NCAPIController.isAlreadyShared(statusCode: 403, canShare: true))
        // 403 for a node without the right to share is a real refusal
        XCTAssertFalse(NCAPIController.isAlreadyShared(statusCode: 403, canShare: false))
        // Other answers are never "already shared"
        XCTAssertFalse(NCAPIController.isAlreadyShared(statusCode: 404, canShare: true))
        XCTAssertFalse(NCAPIController.isAlreadyShared(statusCode: 0, canShare: true))
        // Errors that did not come from an OCS response are not "already shared"
        XCTAssertFalse(NCAPIController.isAlreadyShared(OcsError.genericError(), canShare: true))
        XCTAssertFalse(NCAPIController.isAlreadyShared(NCAPIController.ApiControllerError.preconditionError, canShare: true))
    }

    func testRightToShareFromDavPermissions() throws {
        // File: share ("R") and update ("W")
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "RGDNVW", isDirectory: false))
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "SRGDNVW", isDirectory: false))
        // No right to share
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "SGDNVW", isDirectory: false))
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "G", isDirectory: false))
        // Right to share, but no update (permissions 17): the server refuses with 403 "more permission"
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "RG", isDirectory: false))
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "SRGDNV", isDirectory: false))
        // Nothing known, e.g. the server did not return the property
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "", isDirectory: false))
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "", isDirectory: true))
    }

    func testRightToShareFolderFromDavPermissions() throws {
        // Folder: share, update, create and delete
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "RGDNVWCK", isDirectory: true))
        // Without create and delete the default folder share (31) is refused with 403 "more permission"
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "RGDNVCK", isDirectory: true))
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "RGDNVW", isDirectory: true))
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "RGNVWCK", isDirectory: true))
        // The same letters are enough for a file
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "RGDNVW", isDirectory: false))
    }
}
