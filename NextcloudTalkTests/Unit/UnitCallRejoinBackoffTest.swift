//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitCallRejoinBackoffTest: XCTestCase {

    func testDelaysGrowAndTheLastOneRepeats() {
        var backoff = CallRejoinBackoff(delays: [2, 4, 8, 15], maxAttempts: 6)

        XCTAssertEqual(backoff.nextDelay(), 2)
        XCTAssertEqual(backoff.nextDelay(), 4)
        XCTAssertEqual(backoff.nextDelay(), 8)
        XCTAssertEqual(backoff.nextDelay(), 15)
        XCTAssertEqual(backoff.nextDelay(), 15)
        XCTAssertEqual(backoff.nextDelay(), 15)
        XCTAssertEqual(backoff.attempts, 6)
    }

    func testNoDelayAfterTheLastAttempt() {
        var backoff = CallRejoinBackoff(delays: [1], maxAttempts: 2)

        XCTAssertFalse(backoff.isExhausted)
        XCTAssertEqual(backoff.nextDelay(), 1)
        XCTAssertEqual(backoff.nextDelay(), 1)
        XCTAssertTrue(backoff.isExhausted)
        XCTAssertNil(backoff.nextDelay())
        XCTAssertNil(backoff.nextDelay())

        // A refused repeat is not counted
        XCTAssertEqual(backoff.attempts, 2)
    }

    func testResetStartsWithTheShortestPause() {
        var backoff = CallRejoinBackoff()

        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        XCTAssertEqual(backoff.attempts, 2)

        backoff.reset()
        XCTAssertEqual(backoff.attempts, 0)
        XCTAssertFalse(backoff.isExhausted)
        XCTAssertEqual(backoff.nextDelay(), CallRejoinBackoff.defaultDelays.first)
    }

    func testResetAfterExhaustionAllowsRepeatsAgain() {
        var backoff = CallRejoinBackoff(delays: [3], maxAttempts: 1)

        XCTAssertEqual(backoff.nextDelay(), 3)
        XCTAssertNil(backoff.nextDelay())

        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 3)
    }

    func testDefaultsAreTwoFourEightFifteen() {
        var backoff = CallRejoinBackoff()
        var delays = [TimeInterval]()

        while let delay = backoff.nextDelay() {
            delays.append(delay)
        }

        XCTAssertEqual(delays, [2, 4, 8, 15, 15, 15])
    }

    func testZeroAttemptsNeverRepeats() {
        var backoff = CallRejoinBackoff(delays: [1], maxAttempts: 0)

        XCTAssertTrue(backoff.isExhausted)
        XCTAssertNil(backoff.nextDelay())
    }

    func testEmptyDelaysFallBackToTheDefaults() {
        var backoff = CallRejoinBackoff(delays: [], maxAttempts: 1)

        XCTAssertEqual(backoff.nextDelay(), 2)
    }

    func testTemporaryFailuresAreRetried() {
        // No response / network, request timeout, too many requests, server errors
        for statusCode in [0, 404, 408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(CallRejoinBackoff.isRetryable(statusCode: statusCode), "status \(statusCode)")
        }

        // Codes which are no HTTP status (join at the signaling server failed)
        XCTAssertTrue(CallRejoinBackoff.isRetryable(statusCode: 997))
    }

    func testFinalFailuresEndTheCall() {
        // Consent required, unauthorized, read-only / forbidden, method, conflict, gone, lobby
        for statusCode in [400, 401, 403, 405, 409, 410, 412, 413, 499] {
            XCTAssertFalse(CallRejoinBackoff.isRetryable(statusCode: statusCode), "status \(statusCode)")
        }
    }
}
