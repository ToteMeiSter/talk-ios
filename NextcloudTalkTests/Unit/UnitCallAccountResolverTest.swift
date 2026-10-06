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

    func testAmbiguousTokenWithoutActiveAccountPrefersRememberedAccount() {
        let result = CallAccountResolver.resolve(activeAccountId: "x", accountIdsWithToken: ["a", "b"], rememberedAccountId: "b")

        XCTAssertEqual(result, CallAccountResolution(accountId: "b", isAmbiguous: true))
    }

    func testActiveAccountWinsOverRememberedAccount() {
        let result = CallAccountResolver.resolve(activeAccountId: "a", accountIdsWithToken: ["a", "b"], rememberedAccountId: "b")

        XCTAssertEqual(result, CallAccountResolution(accountId: "a", isAmbiguous: true))
    }

    func testRememberedAccountWithoutConversationIsIgnored() {
        let result = CallAccountResolver.resolve(activeAccountId: "x", accountIdsWithToken: ["a", "b"], rememberedAccountId: "gone")

        XCTAssertEqual(result, CallAccountResolution(accountId: "a", isAmbiguous: true))
    }

    func testMemoryKeepsNewestAccountPerToken() {
        var entries = CallAccountMemory.remembering(token: "t", accountId: "a", in: [])
        entries = CallAccountMemory.remembering(token: "u", accountId: "c", in: entries)
        entries = CallAccountMemory.remembering(token: "t", accountId: "b", in: entries)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(CallAccountMemory.accountId(forToken: "t", in: entries), "b")
        XCTAssertEqual(CallAccountMemory.accountId(forToken: "u", in: entries), "c")
        XCTAssertNil(CallAccountMemory.accountId(forToken: "other", in: entries))
    }

    func testMemoryIsBoundedAndDropsOldestEntries() {
        var entries: [CallAccountMemoryEntry] = []
        for index in 0 ..< 5 {
            entries = CallAccountMemory.remembering(token: "t\(index)", accountId: "a", in: entries, limit: 3)
        }

        XCTAssertEqual(entries.map(\.token), ["t2", "t3", "t4"])
    }

    func testMemoryIsPersisted() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))

        CallAccountMemory.remember(token: "t", accountId: "a", in: defaults)
        CallAccountMemory.remember(token: "t", accountId: "b", in: defaults)

        XCTAssertEqual(CallAccountMemory.rememberedAccountId(forToken: "t", from: defaults), "b")
        XCTAssertNil(CallAccountMemory.rememberedAccountId(forToken: "u", from: defaults))
    }
}
