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

    func testLogDescriptionsCarryNoFileNameOrPath() {
        // The description of a file error contains the name and the path, so only domain and code are logged
        let fileError = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [NSFilePathErrorKey: "/private/var/Alice Passport.pdf",
                                                                                 NSLocalizedDescriptionKey: "The file “Alice Passport.pdf” couldn’t be opened."])
        XCTAssertEqual(NCLog.errorCode(fileError), "NSCocoaErrorDomain 260")

        XCTAssertEqual(NCLog.fileTraits(fileName: "Alice Passport.PDF"), "file with extension pdf")
        XCTAssertEqual(NCLog.fileTraits(fileName: "Notes"), "file without extension")
        XCTAssertFalse(NCLog.fileTraits(fileName: "Alice Passport.pdf").contains("Alice"))

        // A dot inside the name is no extension: the part after it is either dropped by pathExtension (a space makes
        // it "no extension") or reported as unusual, the name is never part of the result
        XCTAssertEqual(NCLog.fileTraits(fileName: "Встреча 10.10 Иванов"), "file without extension")
        XCTAssertEqual(NCLog.fileTraits(fileName: "Договор Петров И.И"), "file with unusual extension")

        // A word after a dot is no extension the system knows
        XCTAssertEqual(NCLog.fileTraits(fileName: "J.Smith"), "file with unusual extension")
        XCTAssertEqual(NCLog.fileTraits(fileName: "Contract A.Petrov"), "file with unusual extension")
        XCTAssertEqual(NCLog.fileTraits(fileName: "photo.jpeg"), "file with extension jpeg")

        // The error of a request is logged with its status and codes, not with its URL
        let urlError = NSError(domain: NSURLErrorDomain, code: -1202, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://cloud.example.org/ocs/v2.php/search=Alice"])
        let ocsError = OcsError(withError: urlError, withTask: nil)
        XCTAssertEqual(NCLog.errorCode(ocsError), "OcsError http 0, NSURLErrorDomain -1202")
        XCTAssertFalse(NCLog.errorCode(ocsError).contains("example.org"))
        XCTAssertEqual(NCLog.errorCode(ChatFileUploadError.uploadFailed(errorCode: 413, errorDescription: "Alice Passport.pdf")), "ChatFileUploadError http 413")

        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSUnderlyingErrorKey: urlError])
        XCTAssertEqual(NCLog.errorCode(wrapped), "NSCocoaErrorDomain 4, underlying NSURLErrorDomain -1202")
    }

    func testPushProxyFailureDescriptionKeepsReasonAndMasksSensitiveParts() throws {
        let token = "e5a1c2d3b4f5e6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1"
        let identifier = "aGVsbG8gd29ybGQgdGhpcyBpcyBhIGRldmljZSBpZGVudGlmaWVy"

        func failure(_ body: String) -> String {
            let userInfo = [AFNetworkingOperationFailingURLResponseDataErrorKey: Data(body.utf8)]
            let error = NSError(domain: NSURLErrorDomain, code: -1011, userInfo: userInfo)
            return NCPushProxySessionManager.failureDescription(forTask: nil, error: error)
        }

        // A JSON answer keeps the reason and drops every other field
        let json = failure("{\"message\":\"Invalid signature\",\"pushToken\":\"\(token)\",\"deviceIdentifier\":\"\(identifier)\",\"cloudId\":\"alice@cloud.example.org\"}")
        XCTAssertEqual(json, "HTTP status: none, body: message=Invalid signature, error: NSURLErrorDomain -1011")

        // A plain text answer is masked: tokens, URLs and accounts are replaced, the reason stays
        let text = failure("Invalid device identifier signature \(identifier) for \(token), user alice@cloud.example.org at https://cloud.example.org/index.php")
        XCTAssertTrue(text.contains("body: Invalid device identifier signature <redacted> for <redacted>, user <account> at <url>"))
        for secret in [token, identifier, "alice", "cloud.example.org"] {
            XCTAssertFalse(text.contains(secret))
        }

        // The answer is cut, a token that crosses the limit is not left half readable
        let long = failure(String(repeating: "x ", count: 245) + token)
        XCTAssertFalse(long.contains(String(token.prefix(12))))
        XCTAssertLessThan(long.count, 700)

        // No answer, no body part
        XCTAssertEqual(failure(""), "HTTP status: none, error: NSURLErrorDomain -1011")
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
