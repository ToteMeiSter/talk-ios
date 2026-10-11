//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitCallNetworkChangeTrackerTest: XCTestCase {

    private let wifi = CallNetworkPath(isSatisfied: true, primaryInterface: .wifi)
    private let cellular = CallNetworkPath(isSatisfied: true, primaryInterface: .cellular)
    private let wired = CallNetworkPath(isSatisfied: true, primaryInterface: .wired)
    private let vpnOnly = CallNetworkPath(isSatisfied: true, primaryInterface: nil)
    private let offline = CallNetworkPath(isSatisfied: false, primaryInterface: nil)

    func testFirstPathIsOnlyTheStartingPoint() {
        var tracker = CallNetworkChangeTracker()

        XCTAssertNil(tracker.update(wifi))
    }

    func testSwitchFromWifiToCellularIsAChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)

        XCTAssertEqual(tracker.update(cellular), .interfaceSwitched)
    }

    func testSwitchFromCellularToWifiIsAChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(cellular)

        XCTAssertEqual(tracker.update(wifi), .interfaceSwitched)
    }

    func testSwitchToWiredIsAChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)

        XCTAssertEqual(tracker.update(wired), .interfaceSwitched)
    }

    func testSamePathAgainIsNoChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)

        // Path updates come when only flags such as low data mode or a second link change
        XCTAssertNil(tracker.update(wifi))
        XCTAssertNil(tracker.update(wifi))
    }

    func testVpnSwitchedOnOrOffIsNoChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)

        // A tunnel is no physical link: the preferred physical link stays the same, the tracker sees the same path
        XCTAssertNil(tracker.update(wifi))
        XCTAssertNil(tracker.update(wifi))
    }

    func testPathWithoutPhysicalLinkIsNoChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)

        XCTAssertNil(tracker.update(vpnOnly))
    }

    func testLosingTheNetworkIsNoChangeButGettingItBackIs() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)

        XCTAssertNil(tracker.update(offline))
        XCTAssertEqual(tracker.update(wifi), .networkReturned)
    }

    func testNetworkBackOnAnotherLinkIsOneChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)
        _ = tracker.update(offline)

        XCTAssertEqual(tracker.update(cellular), .networkReturned)
        XCTAssertNil(tracker.update(cellular))
    }

    func testStartingOfflineAndGoingOnlineIsAChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(offline)

        XCTAssertEqual(tracker.update(wifi), .networkReturned)
    }

    func testSwitchingTheVpnOffIsNoChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)

        // VPN on: the path lists the tunnel only. VPN off: the same Wi-Fi is back
        XCTAssertNil(tracker.update(vpnOnly))
        XCTAssertNil(tracker.update(wifi))
    }

    func testSwitchingTheVpnOnAndOffOnCellularIsNoChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(cellular)

        XCTAssertNil(tracker.update(vpnOnly))
        XCTAssertNil(tracker.update(cellular))
    }

    func testAnotherLinkAfterTheVpnIsAChange() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(wifi)
        _ = tracker.update(vpnOnly)

        XCTAssertEqual(tracker.update(cellular), .interfaceSwitched)
    }

    func testStartingBehindAVpnHasNoLinkToCompareWith() {
        var tracker = CallNetworkChangeTracker()
        _ = tracker.update(vpnOnly)

        XCTAssertNil(tracker.update(wifi))
        XCTAssertEqual(tracker.update(cellular), .interfaceSwitched)
    }

    // MARK: - Reaction limiter

    func testFirstReactionIsAllowed() {
        var limiter = CallNetworkReactionLimiter()

        XCTAssertEqual(limiter.reserve(now: 5), 0)
    }

    func testReactionInsideThePauseWaitsForTheRest() {
        var limiter = CallNetworkReactionLimiter()
        _ = limiter.reserve(now: 100)

        XCTAssertEqual(limiter.reserve(now: 103), CallNetworkReactionLimiter.minInterval - 3)
        // A refused reaction does not move the pause
        XCTAssertEqual(limiter.reserve(now: 104), CallNetworkReactionLimiter.minInterval - 4)
    }

    func testReactionAfterThePauseIsAllowedAgain() {
        var limiter = CallNetworkReactionLimiter()
        _ = limiter.reserve(now: 100)

        XCTAssertEqual(limiter.reserve(now: 100 + CallNetworkReactionLimiter.minInterval), 0)
        XCTAssertGreaterThan(limiter.reserve(now: 101 + CallNetworkReactionLimiter.minInterval), 0)
    }
}
