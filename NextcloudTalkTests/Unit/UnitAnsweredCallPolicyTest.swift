//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitAnsweredCallPolicyTest: XCTestCase {

    func testStartsWhenReadyAndNoCallShown() {
        XCTAssertEqual(AnsweredCallPolicy.action(appState: .ready, shownCallToken: nil, answeredToken: "a"), .start)
    }

    func testWaitsWhenNotReady() {
        let notReadyStates: [AppState] = [.unknown, .noServerProvided, .missingUserProfile, .missingServerCapabilities, .missingSignalingConfiguration]

        for state in notReadyStates {
            XCTAssertEqual(AnsweredCallPolicy.action(appState: state, shownCallToken: nil, answeredToken: "a"), .wait)
        }
    }

    func testKeepsWhenSameRoomIsShown() {
        XCTAssertEqual(AnsweredCallPolicy.action(appState: .ready, shownCallToken: "a", answeredToken: "a"), .keep)
        XCTAssertEqual(AnsweredCallPolicy.action(appState: .unknown, shownCallToken: "a", answeredToken: "a"), .keep)
    }

    func testFailsWhenOtherRoomIsShown() {
        XCTAssertEqual(AnsweredCallPolicy.action(appState: .ready, shownCallToken: "b", answeredToken: "a"), .fail)
        XCTAssertEqual(AnsweredCallPolicy.action(appState: .unknown, shownCallToken: "b", answeredToken: "a"), .fail)
    }
}
