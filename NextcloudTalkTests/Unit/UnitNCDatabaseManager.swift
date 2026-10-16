//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCDatabaseManager: TestBaseRealm {

    func testSavingExternalSignalingVersion() throws {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        let testVersion = "Test version"
        let testVersionUpdated = "Test version updated"

        updateCapabilities { cap in
            cap.externalSignalingServerVersion = testVersion
        }

        var capabilities = NCDatabaseManager.sharedInstance().serverCapabilities(forAccountId: activeAccount.accountId)
        XCTAssertEqual(capabilities?.externalSignalingServerVersion, testVersion)

        NCDatabaseManager.sharedInstance().setExternalSignalingServerVersion(testVersionUpdated, forAccountId: activeAccount.accountId)

        capabilities = NCDatabaseManager.sharedInstance().serverCapabilities(forAccountId: activeAccount.accountId)
        XCTAssertEqual(capabilities?.externalSignalingServerVersion, testVersionUpdated)
    }

    func testAccountIdsWithRoomToken() throws {
        addRoom(withToken: "shared")
        addRoom(withToken: "shared", withAccountId: "otherAccountId")
        addRoom(withToken: "unrelated")

        let accountIds = NCDatabaseManager.sharedInstance().accountIds(withRoomToken: "shared")

        XCTAssertEqual(Set(accountIds), [TestBaseRealm.fakeAccountId, "otherAccountId"])
        XCTAssertEqual(accountIds.count, 2)
        XCTAssertEqual(NCDatabaseManager.sharedInstance().accountIds(withRoomToken: "unrelated"), [TestBaseRealm.fakeAccountId])
        XCTAssertTrue(NCDatabaseManager.sharedInstance().accountIds(withRoomToken: "missing").isEmpty)
    }

    func testRoomsForAccount() throws {
        let nonFavOld = addRoom(withToken: "NonFavOld") { room in
            room.lastActivity = 100
        }

        let nonFavNew = addRoom(withToken: "NonFavNew") { room in
            room.lastActivity = 1000
        }

        let favOld = addRoom(withToken: "FavOld") { room in
            room.lastActivity = 100
            room.isFavorite = true
        }

        let favNew = addRoom(withToken: "FavNew") { room in
            room.lastActivity = 1000
            room.isFavorite = true
        }

        // Add an unrelated room, which should not be returned
        addRoom(withToken: "Unrelated", withAccountId: "foo")

        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        let rooms = NCDatabaseManager.sharedInstance().roomsForAccountId(activeAccount.accountId, withRealm: nil)
        let expectedOrder = [favNew, favOld, nonFavNew, nonFavOld]

        XCTAssertEqual(rooms.count, 4)

        // Check if the order is correct
        for (index, element) in rooms.enumerated() {
            XCTAssertEqual(expectedOrder[index].token, element.token)
        }
    }

    func testLogfileNamePerProcess() throws {
        // The app keeps its name, an extension gets its own file so two processes never write to the same file
        XCTAssertEqual(NCLog.logfileName(dateString: "2026-10-16", processName: ""), "debug-2026-10-16.log")
        XCTAssertEqual(NCLog.logfileName(dateString: "2026-10-16", processName: "ShareExtension"), "debug-2026-10-16-ShareExtension.log")

        // Both names are picked up by the logfile listing, newest date first, other files are ignored
        let fileManager = FileManager.default
        let dirA = fileManager.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
        let dirB = fileManager.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
        try fileManager.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: dirA)
            try? fileManager.removeItem(at: dirB)
        }

        for name in ["debug-2026-10-15.log", "debug-2026-10-16-ShareExtension.log", "other.txt"] {
            fileManager.createFile(atPath: dirA.appendingPathComponent(name).path, contents: Data())
        }
        fileManager.createFile(atPath: dirB.appendingPathComponent("debug-2026-10-16.log").path, contents: Data())

        let names = NCLog.logfiles(in: [dirA, dirB]).map { $0.lastPathComponent }
        XCTAssertEqual(names, ["debug-2026-10-16.log", "debug-2026-10-16-ShareExtension.log", "debug-2026-10-15.log"])
    }
}
