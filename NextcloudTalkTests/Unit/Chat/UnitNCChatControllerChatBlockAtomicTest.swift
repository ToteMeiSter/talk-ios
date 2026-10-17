//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// A process killed between the write of the chat block and the write of the messages leaves a block that claims
/// messages which were never stored, they are not requested again. So both must be committed together.
final class UnitNCChatControllerChatBlockAtomicTest: TestBaseRealm {

    /// Fires when the observed object is deleted, which happens inside the transaction that stores the server copy.
    private final class DeletionObserver: NSObject {
        var onDeletion: (() -> Void)?
        var deletionCount = 0

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            guard keyPath == "invalidated" else { return }
            deletionCount += 1
            onDeletion?()
        }
    }

    private let serverMessageId = 100

    private func seedChatBlock(inRoom room: NCRoom, newestMessageId: Int) {
        let block = NCChatBlock()
        block.internalId = room.internalId
        block.accountId = room.accountId
        block.token = room.token
        block.threadId = 0
        block.oldestMessageId = 10
        block.newestMessageId = newestMessageId
        block.hasHistory = true

        try? realm.transaction {
            realm.add(block)
        }
    }

    private func seedTemporaryMessage(referenceId: String, inRoom room: NCRoom) {
        let temporaryMessage = NCChatMessage()
        temporaryMessage.internalId = "temp-\(referenceId)"
        temporaryMessage.referenceId = referenceId
        temporaryMessage.accountId = room.accountId
        temporaryMessage.token = room.token
        temporaryMessage.actorId = TestConstants.username
        temporaryMessage.actorType = "users"
        temporaryMessage.message = "Sending"
        temporaryMessage.timestamp = Int(Date().timeIntervalSince1970) - 3600
        temporaryMessage.isTemporary = true

        try? realm.transaction {
            realm.add(temporaryMessage)
        }
    }

    private func serverCopy(referenceId: String, inRoom room: NCRoom) -> [String: Any] {
        return [
            "id": serverMessageId,
            "token": room.token,
            "actorType": "users",
            "actorId": TestConstants.username,
            "actorDisplayName": "Me",
            "timestamp": Int(Date().timeIntervalSince1970) - 3500,
            "message": "Sending",
            "messageType": "comment",
            "referenceId": referenceId
        ]
    }

    /// Reads what other processes / connections see, that is only what is committed, from another thread.
    private func committedState(ofRoom room: NCRoom) -> (newestBlockMessageId: Int, serverMessageStored: Bool) {
        var state = (newestBlockMessageId: 0, serverMessageStored: false)

        DispatchQueue.global().sync {
            RLMRealm.default().refresh()

            let blockQuery = NSPredicate(format: "internalId = %@ AND threadId = 0", room.internalId)
            let block = NCChatBlock.objects(with: blockQuery).sortedResults(usingKeyPath: "newestMessageId", ascending: true).lastObject() as? NCChatBlock
            state.newestBlockMessageId = block?.newestMessageId ?? 0

            let messageQuery = NSPredicate(format: "accountId = %@ AND token = %@ AND messageId = %ld AND isTemporary = false", room.accountId, room.token, self.serverMessageId)
            state.serverMessageStored = NCChatMessage.objects(with: messageQuery).count > 0
        }

        return state
    }

    func testPullResponseCommitsChatBlockAndMessagesTogether() throws {
        let room = addRoom(withToken: "atomicPullRoom")
        let chatController = NCChatController(for: room)!
        chatController.stopReceivingNewChatMessages()

        seedChatBlock(inRoom: room, newestMessageId: 50)

        // Storing the server copy deletes the temporary message, at that point the transaction of the messages is open
        let referenceId = "ref-\(UUID().uuidString)"
        seedTemporaryMessage(referenceId: referenceId, inRoom: room)
        let temporaryMessage = try XCTUnwrap(NCChatMessage.objects(where: "referenceId = %@ AND isTemporary = true", referenceId).firstObject() as? NCChatMessage)

        var stateWhileStoring: (newestBlockMessageId: Int, serverMessageStored: Bool)?
        let observer = DeletionObserver()
        observer.onDeletion = {
            stateWhileStoring = self.committedState(ofRoom: room)
        }

        temporaryMessage.addObserver(observer, forKeyPath: "invalidated", options: [.new], context: nil)
        defer { if !temporaryMessage.isInvalidated { temporaryMessage.removeObserver(observer, forKeyPath: "invalidated") } }

        // Nothing newer than the server copy is stored, so no new-message notification touches the room
        chatController.handlePullResponse(messages: [serverCopy(referenceId: referenceId, inRoom: room)], lastKnownMessage: serverMessageId, lastCommonReadMessage: 0, error: nil, statusCode: 200, fromMessageId: serverMessageId, requestTimestamp: Int(Date().timeIntervalSince1970))

        XCTAssertEqual(observer.deletionCount, 1, "The temporary message must be deleted while storing the server copy")
        let state = try XCTUnwrap(stateWhileStoring)

        // Before the messages are committed, nobody may see a block which already covers them
        XCTAssertFalse(state.serverMessageStored)
        XCTAssertEqual(state.newestBlockMessageId, 50, "The chat block was committed before the messages")

        // Afterwards both are there
        let finalState = committedState(ofRoom: room)
        XCTAssertEqual(finalState.newestBlockMessageId, serverMessageId)
        XCTAssertTrue(finalState.serverMessageStored)
    }
}
