//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCIceRestartTrackerTest: XCTestCase {

    func testOffererRestartsWithoutMCU() {
        var tracker = NCIceRestartTracker()

        XCTAssertTrue(tracker.startRestart(hasMCU: false, isOfferer: true, isSignalingStable: true))
        XCTAssertEqual(tracker.attempts, 1)
    }

    func testNoRestartWithMCU() {
        var tracker = NCIceRestartTracker()

        XCTAssertFalse(tracker.startRestart(hasMCU: true, isOfferer: true, isSignalingStable: true))
        XCTAssertEqual(tracker.attempts, 0)
    }

    func testAnswererDoesNotRestart() {
        var tracker = NCIceRestartTracker()

        XCTAssertFalse(tracker.startRestart(hasMCU: false, isOfferer: false, isSignalingStable: true))
        XCTAssertEqual(tracker.attempts, 0)
    }

    func testNoRestartDuringNegotiation() {
        var tracker = NCIceRestartTracker()

        XCTAssertFalse(tracker.startRestart(hasMCU: false, isOfferer: true, isSignalingStable: false))
        XCTAssertEqual(tracker.attempts, 0)
    }

    func testAttemptsAreLimited() {
        var tracker = NCIceRestartTracker()

        for _ in 0 ..< NCIceRestartTracker.maxAttempts {
            XCTAssertTrue(tracker.startRestart(hasMCU: false, isOfferer: true, isSignalingStable: true))
        }

        XCTAssertTrue(tracker.isExhausted)
        XCTAssertFalse(tracker.startRestart(hasMCU: false, isOfferer: true, isSignalingStable: true))
        XCTAssertEqual(tracker.attempts, NCIceRestartTracker.maxAttempts)
    }

    func testResetAllowsRestartsAgain() {
        var tracker = NCIceRestartTracker()

        for _ in 0 ..< NCIceRestartTracker.maxAttempts {
            _ = tracker.startRestart(hasMCU: false, isOfferer: true, isSignalingStable: true)
        }

        tracker.reset()

        XCTAssertFalse(tracker.isExhausted)
        XCTAssertTrue(tracker.startRestart(hasMCU: false, isOfferer: true, isSignalingStable: true))
        XCTAssertEqual(tracker.attempts, 1)
    }

    func testWatchdogIsArmedOnceOnFailureWithoutMCU() {
        XCTAssertTrue(NCIceRestartTracker.shouldArmRecoveryWatchdog(hasMCU: false, isFailed: true, isAlreadyArmed: false))
        XCTAssertFalse(NCIceRestartTracker.shouldArmRecoveryWatchdog(hasMCU: false, isFailed: true, isAlreadyArmed: true))
        XCTAssertFalse(NCIceRestartTracker.shouldArmRecoveryWatchdog(hasMCU: false, isFailed: false, isAlreadyArmed: false))
        XCTAssertFalse(NCIceRestartTracker.shouldArmRecoveryWatchdog(hasMCU: true, isFailed: true, isAlreadyArmed: false))
    }

    func testWatchdogFallsBackToRejoinOnlyIfStillNotConnected() {
        // A restart that succeeded in time must not trigger a rejoin
        XCTAssertFalse(NCIceRestartTracker.shouldFallBackToRejoin(hasMCU: false, isConnected: true))
        XCTAssertTrue(NCIceRestartTracker.shouldFallBackToRejoin(hasMCU: false, isConnected: false))
        XCTAssertFalse(NCIceRestartTracker.shouldFallBackToRejoin(hasMCU: true, isConnected: false))
    }

    func testRecoveryTimeoutIsLongerThanARestartAndTheDisconnectDelay() {
        XCTAssertGreaterThan(NCIceRestartTracker.recoveryTimeout, NCIceRestartTracker.disconnectedDelay)
    }
}
