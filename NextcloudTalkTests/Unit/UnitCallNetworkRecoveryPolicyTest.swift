//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitCallNetworkRecoveryPolicyTest: XCTestCase {

    func testLostPublisherIsReplacedAtOnce() {
        XCTAssertEqual(CallNetworkRecoveryPolicy.onNetworkChanged(publisher: .lost), .rejoin)
    }

    func testOtherPublisherStatesGetTimeToComeBack() {
        XCTAssertEqual(CallNetworkRecoveryPolicy.onNetworkChanged(publisher: .connected), .recheck)
        XCTAssertEqual(CallNetworkRecoveryPolicy.onNetworkChanged(publisher: .unknown), .recheck)
    }

    func testConnectionWhichCameBackIsKept() {
        for look in 1 ... CallNetworkRecoveryPolicy.maxRechecks {
            XCTAssertEqual(CallNetworkRecoveryPolicy.onRecheck(publisher: .connected, recheck: look), .keep)
        }
    }

    func testConnectionWhichFailedIsReplacedAtOnce() {
        XCTAssertEqual(CallNetworkRecoveryPolicy.onRecheck(publisher: .lost, recheck: 1), .rejoin)
    }

    func testConnectionWhichIsStillOpenIsLookedAtUntilTheLimit() {
        XCTAssertEqual(CallNetworkRecoveryPolicy.onRecheck(publisher: .unknown, recheck: 1), .recheck)
        XCTAssertEqual(CallNetworkRecoveryPolicy.onRecheck(publisher: .unknown, recheck: 2), .recheck)
        XCTAssertEqual(CallNetworkRecoveryPolicy.onRecheck(publisher: .unknown, recheck: 3), .rejoin)
    }

    func testWaitsNineSecondsInTotal() {
        XCTAssertEqual(CallNetworkRecoveryPolicy.recheckDelay * Double(CallNetworkRecoveryPolicy.maxRechecks), 9)
    }

    func testWithoutPublisherThereIsNeverARejoin() {
        // A listener has no publisher of its own: a network change must not leave and enter the call again
        XCTAssertEqual(CallNetworkRecoveryPolicy.onNetworkChanged(publisher: .absent), .recheck)

        for look in 1 ... CallNetworkRecoveryPolicy.maxRechecks + 3 {
            XCTAssertEqual(CallNetworkRecoveryPolicy.onRecheck(publisher: .absent, recheck: look), .refreshSubscribers)
        }
    }
}
