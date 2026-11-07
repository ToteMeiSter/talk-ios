//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCChatControllerReadMarkerTest: XCTestCase {

    func testReadMarkerIsSentWhenHigherThanKnownMarker() {
        XCTAssertEqual(NCChatController.relayReadMarkerToSend(candidate: 101, knownReadMarker: 100), 101)
        XCTAssertEqual(NCChatController.relayReadMarkerToSend(candidate: 5, knownReadMarker: 0), 5)
    }

    func testReadMarkerIsNotSentWhenEqualToKnownMarker() {
        XCTAssertNil(NCChatController.relayReadMarkerToSend(candidate: 100, knownReadMarker: 100))
    }

    func testReadMarkerIsNeverLowered() {
        // E.g. we sent message 100 (server moved the marker there) and a relay message 95 arrives afterwards
        XCTAssertNil(NCChatController.relayReadMarkerToSend(candidate: 95, knownReadMarker: 100))
    }

}
