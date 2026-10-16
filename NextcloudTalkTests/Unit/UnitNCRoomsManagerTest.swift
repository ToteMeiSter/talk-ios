//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitNCRoomsManagerTest: TestBaseRealm {

    func testOfflineMessageFailure() throws {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        let roomToken = "offToken"

        addRoom(withToken: roomToken)

        // Create 2 messages which are in different sections
        let oldOfflineMessage = NCChatMessage()

        oldOfflineMessage.internalId = "internal1"
        oldOfflineMessage.accountId = activeAccount.accountId
        oldOfflineMessage.actorDisplayName = activeAccount.userDisplayName
        oldOfflineMessage.actorId = activeAccount.userId
        oldOfflineMessage.actorType = "users"
        oldOfflineMessage.token = roomToken
        oldOfflineMessage.message = "Message 1"
        oldOfflineMessage.isOfflineMessage = true
        oldOfflineMessage.sendingFailed = false

        // 12h is the threshold, set it to 13 hours
        oldOfflineMessage.timestamp = Int(Date().timeIntervalSince1970) - (60 * 60 * 13)

        try? realm.transaction {
            realm.add(oldOfflineMessage)
        }

        XCTAssertEqual(NCChatMessage.allObjects().count, 1)

        let exp = expectation(description: "\(#function)\(#line)")
        expectation(forNotification: .NCChatControllerDidSendChatMessage, object: NCRoomsManager.shared)

        NCRoomsManager.shared.resendOfflineMessages(forToken: roomToken) {
            exp.fulfill()
        }

        waitForExpectations(timeout: TestConstants.timeoutShort, handler: nil)

        let realmMessage = NCChatMessage.allObjects().firstObject()!
        XCTAssertTrue(realmMessage.sendingFailed)
        XCTAssertFalse(realmMessage.isOfflineMessage)
    }

    func testResendOfflineMessagesContinuesWhenChatControllerCannotBeCreated() throws {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        let ghostAccountId = "ghostAccountId"

        // A room of an account which is not available, so no NCChatController can be created for it
        addRoom(withToken: "ghostToken", withAccountId: ghostAccountId)
        addRoom(withToken: "offToken")

        func offlineMessage(internalId: String, accountId: String, token: String, age: Int) -> NCChatMessage {
            let message = NCChatMessage()
            message.internalId = internalId
            message.accountId = accountId
            message.actorId = activeAccount.userId
            message.actorType = "users"
            message.token = token
            message.message = internalId
            message.isOfflineMessage = true
            message.sendingFailed = false
            message.timestamp = Int(Date().timeIntervalSince1970) - age
            return message
        }

        // The first message can't be sent. The second one is older than 12h and must be marked as failed
        let unsendableMessage = offlineMessage(internalId: "internal1", accountId: ghostAccountId, token: "ghostToken", age: 60)
        let oldMessage = offlineMessage(internalId: "internal2", accountId: activeAccount.accountId, token: "offToken", age: 60 * 60 * 13)

        try? realm.transaction {
            realm.add(unsendableMessage)
            realm.add(oldMessage)
        }

        let exp = expectation(description: "\(#function)\(#line)")

        NCRoomsManager.shared.resendOfflineMessages(forToken: nil) {
            exp.fulfill()
        }

        // The completion block is also what the background fetch waits for
        waitForExpectations(timeout: TestConstants.timeoutShort, handler: nil)

        let realmOldMessage = try XCTUnwrap(NCChatMessage.objects(where: "internalId = %@", "internal2").firstObject() as? NCChatMessage)
        XCTAssertTrue(realmOldMessage.sendingFailed)
        XCTAssertFalse(realmOldMessage.isOfflineMessage)

        // The message of the unknown account is not failed, it is sent again on the next start
        let realmUnsendableMessage = try XCTUnwrap(NCChatMessage.objects(where: "internalId = %@", "internal1").firstObject() as? NCChatMessage)
        XCTAssertTrue(realmUnsendableMessage.isOfflineMessage)
        XCTAssertFalse(realmUnsendableMessage.sendingFailed)
    }

    func testUpdateRoomWithDict() throws {
        let dataJson = """
            {
                "id": 5,
                "token": "noszqmnh",
                "type": 2,
                "name": "Test2",
                "displayName": "Test2",
                "objectType": "",
                "objectId": "",
                "participantType": 1,
                "participantFlags": 0,
                "readOnly": 0,
                "hasPassword": false,
                "hasCall": false,
                "callStartTime": 0,
                "callRecording": 0,
                "canStartCall": true,
                "lastActivity": 1769032238,
                "lastReadMessage": 74,
                "unreadMessages": 0,
                "unreadMention": false,
                "unreadMentionDirect": false,
                "isFavorite": false,
                "canLeaveConversation": true,
                "canDeleteConversation": true,
                "notificationLevel": 1,
                "notificationCalls": 1,
                "lobbyState": 0,
                "lobbyTimer": 0,
                "lastPing": 0,
                "sessionId": "0",
                "sipEnabled": 0,
                "actorType": "users",
                "actorId": "admin",
                "attendeeId": 5,
                "permissions": 254,
                "attendeePermissions": 0,
                "callPermissions": 0,
                "defaultPermissions": 0,
                "canEnableSIP": false,
                "attendeePin": "",
                "description": "",
                "lastCommonReadMessage": 74,
                "listable": 0,
                "callFlag": 0,
                "messageExpiration": 0,
                "avatarVersion": "02234d2d",
                "isCustomAvatar": false,
                "breakoutRoomMode": 0,
                "breakoutRoomStatus": 0,
                "recordingConsent": 0,
                "mentionPermissions": 0,
                "liveTranscriptionLanguageId": "",
                "lastPinnedId": 0,
                "hiddenPinnedId": 0,
                "isArchived": false,
                "isImportant": false,
                "isSensitive": false,
                "hasScheduledMessages": 0,
                "lastMessage": {
                    "id": 74,
                    "token": "noszqmnh",
                    "actorType": "users",
                    "actorId": "admin",
                    "actorDisplayName": "admin",
                    "timestamp": 1769032238,
                    "message": "Hey",
                    "messageParameters": [],
                    "systemMessage": "",
                    "messageType": "comment",
                    "isReplyable": true,
                    "referenceId": "",
                    "reactions": {},
                    "expirationTimestamp": 0,
                    "markdown": true,
                    "threadId": 74
                }
            }
        """

        let roomDict = try JSONSerialization.jsonObject(with: dataJson.data(using: .utf8)!) as! [String: Any]

        XCTAssertEqual(NCChatMessage.allObjects().count, 0)
        XCTAssertEqual(NCRoom.allObjects().count, 0)

        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()

        try realm.transaction {
            NCRoomsManager.shared.updateRoom(withDict: roomDict, withAccount: activeAccount, withTimestamp: Int(Date().timeIntervalSince1970), withRealm: realm)
        }

        XCTAssertEqual(NCChatMessage.allObjects().count, 1)
        XCTAssertEqual(NCRoom.allObjects().count, 1)

        let message = try XCTUnwrap(NCChatMessage.allObjects().firstObject() as? NCChatMessage)
        let room = try XCTUnwrap(NCRoom.allObjects().firstObject() as? NCRoom)

        XCTAssertEqual(message.message, "Hey")
        XCTAssertEqual(message.timestamp, 1769032238)

        XCTAssertEqual(room.name, "Test2")
        XCTAssertEqual(room.token, "noszqmnh")
    }

    // MARK: - Write order

    private func roomDict(token: String, name: String = "Room", unreadMessages: Int = 0, lastReadMessage: Int = 0, lastCommonReadMessage: Int = 0, isFavorite: Bool = false) -> [String: Any] {
        return [
            "token": token,
            "type": 2,
            "name": name,
            "displayName": name,
            "unreadMessages": unreadMessages,
            "lastReadMessage": lastReadMessage,
            "lastCommonReadMessage": lastCommonReadMessage,
            "lastActivity": 1000,
            "isFavorite": isFavorite
        ]
    }

    private func store(_ roomDict: [String: Any], requestStart: Int, timestamp: Int = Int(Date().timeIntervalSince1970)) throws {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()

        try realm.transaction {
            NCRoomsManager.shared.updateRoom(withDict: roomDict, withAccount: activeAccount, withTimestamp: timestamp, withRealm: realm, withRequestStart: requestStart)
        }
    }

    private func managedRoom(_ token: String) -> NCRoom? {
        let internalId = "\(NCDatabaseManager.sharedInstance().activeAccount().accountId)@\(token)"
        return NCRoom.objects(where: "internalId = %@", internalId).firstObject() as? NCRoom
    }

    func testLateOlderRoomResponseDoesNotOverwriteNewerOne() throws {
        let olderStart = NCRoomsManager.shared.nextWriteStamp()
        let newerStart = NCRoomsManager.shared.nextWriteStamp()

        // The newer request answers first
        try store(roomDict(token: "lateToken", unreadMessages: 0, isFavorite: true), requestStart: newerStart)
        // The older request answers late with outdated data
        try store(roomDict(token: "lateToken", unreadMessages: 5, isFavorite: false), requestStart: olderStart)

        let room = try XCTUnwrap(managedRoom("lateToken"))
        XCTAssertEqual(room.unreadMessages, 0)
        XCTAssertTrue(room.isFavorite)
    }

    func testOlderRoomsListDoesNotDeleteRoomStoredByNewerRequest() throws {
        let listStart = NCRoomsManager.shared.nextWriteStamp()
        let roomStart = NCRoomsManager.shared.nextWriteStamp()

        // The room is stored (with an old lastUpdate) by a request that started after the list
        try store(roomDict(token: "newRoom"), requestStart: roomStart, timestamp: 1)

        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        _ = NCRoomsManager.shared.storeRooms([roomDict(token: "listedRoom")], forAccount: activeAccount, requestStart: listStart, onlyLastModified: false, isExpired: { false })

        XCTAssertNotNil(managedRoom("newRoom"))
        XCTAssertNotNil(managedRoom("listedRoom"))
    }

    func testOlderResponseDoesNotRevertFieldsWrittenLocally() throws {
        try store(roomDict(token: "localToken", unreadMessages: 3, lastReadMessage: 20, lastCommonReadMessage: 10), requestStart: NCRoomsManager.shared.nextWriteStamp())

        let requestStart = NCRoomsManager.shared.nextWriteStamp()

        // Local writes after the request was started
        let room = try XCTUnwrap(managedRoom("localToken"))
        NCRoomsManager.shared.updateLastReadMessage(50, forRoom: room)
        NCRoomsManager.shared.updateLastCommonReadMessage(40, forRoom: room)
        NCRoomsManager.shared.setNoUnreadMessages(forRoom: room, withLastMessage: nil)

        // The response is from before the local writes: other fields are written, the local ones are kept
        try store(roomDict(token: "localToken", name: "Renamed", unreadMessages: 7, lastReadMessage: 10, lastCommonReadMessage: 5, isFavorite: true), requestStart: requestStart)

        let stored = try XCTUnwrap(managedRoom("localToken"))
        XCTAssertEqual(stored.lastReadMessage, 50)
        XCTAssertEqual(stored.lastCommonReadMessage, 40)
        XCTAssertEqual(stored.unreadMessages, 0)
        XCTAssertEqual(stored.name, "Renamed")
        XCTAssertTrue(stored.isFavorite)
    }

    func testResponseInRequestOrderStillWritesAndDeletes() throws {
        try store(roomDict(token: "goneRoom"), requestStart: NCRoomsManager.shared.nextWriteStamp(), timestamp: 1)
        try store(roomDict(token: "keptRoom", unreadMessages: 1, lastReadMessage: 5), requestStart: NCRoomsManager.shared.nextWriteStamp(), timestamp: 1)

        // Local write before the next request starts must not hold back its response
        NCRoomsManager.shared.updateLastReadMessage(8, forRoom: try XCTUnwrap(managedRoom("keptRoom")))

        let listStart = NCRoomsManager.shared.nextWriteStamp()
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        _ = NCRoomsManager.shared.storeRooms([roomDict(token: "keptRoom", unreadMessages: 4, lastReadMessage: 12)], forAccount: activeAccount, requestStart: listStart, onlyLastModified: false, isExpired: { false })

        XCTAssertNil(managedRoom("goneRoom"))

        let kept = try XCTUnwrap(managedRoom("keptRoom"))
        XCTAssertEqual(kept.unreadMessages, 4)
        XCTAssertEqual(kept.lastReadMessage, 12)
    }

    func testOlderResponseDoesNotRevertLastActivityToOlderValue() throws {
        // The response is older than the local write, but carries a newer activity than the stored room
        var seed = roomDict(token: "activityToken")
        seed["lastActivity"] = 1000
        try store(seed, requestStart: NCRoomsManager.shared.nextWriteStamp())

        let requestStart = NCRoomsManager.shared.nextWriteStamp()
        let room = try XCTUnwrap(managedRoom("activityToken"))

        // Without a last message nothing is written for the last message, so the response wins
        NCRoomsManager.shared.setNoUnreadMessages(forRoom: room, withLastMessage: nil)

        var response = roomDict(token: "activityToken")
        response["lastActivity"] = 2000
        try store(response, requestStart: requestStart)
        XCTAssertEqual(try XCTUnwrap(managedRoom("activityToken")).lastActivity, 2000)

        // Now a last message is written locally: an older response must not take the activity back to an older value
        let newRequestStart = NCRoomsManager.shared.nextWriteStamp()
        let lastMessage = NCChatMessage()
        lastMessage.internalId = "activityMessage"
        lastMessage.timestamp = 3000
        NCRoomsManager.shared.setNoUnreadMessages(forRoom: try XCTUnwrap(managedRoom("activityToken")), withLastMessage: lastMessage)

        var olderResponse = roomDict(token: "activityToken")
        olderResponse["lastActivity"] = 2500
        try store(olderResponse, requestStart: newRequestStart)

        let stored = try XCTUnwrap(managedRoom("activityToken"))
        XCTAssertEqual(stored.lastActivity, 3000)
        XCTAssertEqual(stored.lastMessageId, "activityMessage")
    }

    func testCancelledRoomsWriteDoesNotRejectOlderResponse() throws {
        let olderStart = NCRoomsManager.shared.nextWriteStamp()
        let listStart = NCRoomsManager.shared.nextWriteStamp()

        // The write is cancelled when the second room is about to be stored
        var checks = 0
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        _ = NCRoomsManager.shared.storeRooms([roomDict(token: "cancelRoomA"), roomDict(token: "cancelRoomB")], forAccount: activeAccount, requestStart: listStart, onlyLastModified: true, isExpired: {
            checks += 1
            return checks > 1
        })

        XCTAssertNil(managedRoom("cancelRoomA"))

        // An older response must still be stored, nothing newer is in the database
        try store(roomDict(token: "cancelRoomA", name: "FromOlderResponse"), requestStart: olderStart)
        XCTAssertEqual(managedRoom("cancelRoomA")?.name, "FromOlderResponse")
    }

}
