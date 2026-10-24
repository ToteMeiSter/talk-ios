//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
import CallKit
@testable import NextcloudTalk

final class UnitCallKitReportFailureTest: XCTestCase {

    private func incomingCallError(_ code: CXErrorCodeIncomingCallError.Code) -> NSError {
        return NSError(domain: CXErrorDomainIncomingCall, code: code.rawValue)
    }

    func testDoNotDisturbCallIsReportedToTheUser() {
        XCTAssertTrue(CallKitReportFailure.shouldNotifyUser(about: incomingCallError(.filteredByDoNotDisturb)))
    }

    func testBlockedCallIsNotReported() {
        XCTAssertFalse(CallKitReportFailure.shouldNotifyUser(about: incomingCallError(.filteredByBlockList)))
    }

    func testDuplicateCallIsNotReported() {
        XCTAssertFalse(CallKitReportFailure.shouldNotifyUser(about: incomingCallError(.callUUIDAlreadyExists)))
    }

    func testOtherCallKitErrorsAreReportedToTheUser() {
        XCTAssertTrue(CallKitReportFailure.shouldNotifyUser(about: incomingCallError(.unknown)))
        XCTAssertTrue(CallKitReportFailure.shouldNotifyUser(about: incomingCallError(.unentitled)))
    }

    func testForeignErrorsAreReportedToTheUser() {
        // Same numeric code as callUUIDAlreadyExists, but a different domain
        let code = CXErrorCodeIncomingCallError.Code.callUUIDAlreadyExists.rawValue
        XCTAssertTrue(CallKitReportFailure.shouldNotifyUser(about: NSError(domain: NSCocoaErrorDomain, code: code)))
    }
}
