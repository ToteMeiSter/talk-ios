//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatAttachmentFolderTest: TestBaseRealm {

    /// The fake account has no capabilities, so there is no URL of the attachment folder and no request is made.
    func testAnAccountWithoutAttachmentFolderUrlReportsAnError() throws {
        let account = try XCTUnwrap(NCDatabaseManager.sharedInstance().talkAccount(forAccountId: TestBaseRealm.fakeAccountId))
        let expectation = expectation(description: "Folder checked")
        var result: (created: Bool, statusCode: Int)?

        NCAPIController.sharedInstance().checkOrCreateAttachmentFolder(forAccount: account) { created, statusCode in
            result = (created, statusCode)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(result?.created, false)
        XCTAssertEqual(result?.statusCode, NCAPIController.attachmentFolderUnknownCode)
        XCTAssertNotEqual(result?.statusCode, 0)
    }

    func testAnExistingFolderIsAvailable() {
        // What the callback reports for a folder that is there, and for one that was created
        XCTAssertTrue(NCAPIController.isAttachmentFolderAvailable(created: false, statusCode: 0))
        XCTAssertTrue(NCAPIController.isAttachmentFolderAvailable(created: true, statusCode: 0))
    }

    func testErrorsAreNoAvailableFolder() {
        XCTAssertFalse(NCAPIController.isAttachmentFolderAvailable(created: false, statusCode: NCAPIController.attachmentFolderUnknownCode))
        XCTAssertFalse(NCAPIController.isAttachmentFolderAvailable(created: false, statusCode: 507))
        XCTAssertFalse(NCAPIController.isAttachmentFolderAvailable(created: false, statusCode: 403))
    }
}
