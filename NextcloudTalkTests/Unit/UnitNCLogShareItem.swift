//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCLogShareItem: XCTestCase {

    func testShareItemLineCarriesNoFileNameOrPath() {
        let fileName = "Alice Passport.pdf"
        let fileURL = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/Alice Passport.pdf")

        // The old line was "Adding shareItem: <name> <url>"
        let line = NCLog.shareItemLine("Adding shareItem", fileName: fileName)

        XCTAssertEqual(line, "Adding shareItem: file with extension pdf")
        XCTAssertFalse(line.contains("Alice"))
        XCTAssertFalse(line.contains("Passport"))
        XCTAssertFalse(line.contains(fileURL.path))
        XCTAssertFalse(line.contains("/private"))
    }

    func testShareItemLineWithoutOrUnusualName() {
        XCTAssertEqual(NCLog.shareItemLine("Removing shareItem", fileName: nil), "Removing shareItem: file without extension")
        XCTAssertEqual(NCLog.shareItemLine("Updating shareItem", fileName: "J.Smith"), "Updating shareItem: file with unusual extension")
        XCTAssertFalse(NCLog.shareItemLine("Updating shareItem", fileName: "J.Smith").contains("Smith"))
    }
}
