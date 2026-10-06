//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitCallAccountResolverTest: XCTestCase {

    func testTokenOfActiveAccountKeepsActiveAccount() {
        let result = CallAccountResolver.resolve(activeAccountId: "a", accountIdsWithToken: ["a"])

        XCTAssertEqual(result, CallAccountResolution(accountId: "a", isAmbiguous: false))
    }

    func testTokenOfInactiveAccountSwitchesToThatAccount() {
        let result = CallAccountResolver.resolve(activeAccountId: "a", accountIdsWithToken: ["b"])

        XCTAssertEqual(result, CallAccountResolution(accountId: "b", isAmbiguous: false))
    }

    func testUnknownTokenFallsBackToActiveAccount() {
        let result = CallAccountResolver.resolve(activeAccountId: "a", accountIdsWithToken: [])

        XCTAssertEqual(result, CallAccountResolution(accountId: "a", isAmbiguous: false))
    }

    func testAmbiguousTokenPrefersActiveAccount() {
        let result = CallAccountResolver.resolve(activeAccountId: "b", accountIdsWithToken: ["a", "b"])

        XCTAssertEqual(result, CallAccountResolution(accountId: "b", isAmbiguous: true))
    }

    func testAmbiguousTokenWithoutActiveAccountPicksFirstSortedAccount() {
        let result = CallAccountResolver.resolve(activeAccountId: "x", accountIdsWithToken: ["c", "b"])

        XCTAssertEqual(result, CallAccountResolution(accountId: "b", isAmbiguous: true))
    }

    func testDuplicateEntriesAreNotAmbiguous() {
        let result = CallAccountResolver.resolve(activeAccountId: "a", accountIdsWithToken: ["b", "b"])

        XCTAssertEqual(result, CallAccountResolution(accountId: "b", isAmbiguous: false))
    }
}
