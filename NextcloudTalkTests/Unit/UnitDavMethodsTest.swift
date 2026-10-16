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
        // Share ("R") and update ("W")
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "RGDNVW"))
        XCTAssertTrue(NCAPIController.canShare(davPermissions: "SRGDNVW"))
        // No right to share
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "SGDNVW"))
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "G"))
        // Right to share, but no update (permissions 17): the server refuses with 403 "more permission"
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "RG"))
        XCTAssertFalse(NCAPIController.canShare(davPermissions: "SRGDNV"))
        // Nothing known, e.g. the server did not return the property
        XCTAssertTrue(NCAPIController.canShare(davPermissions: ""))
    }
}
