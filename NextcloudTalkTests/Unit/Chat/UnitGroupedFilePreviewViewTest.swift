//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// Which file of a group a point of its row belongs to, which is the file the Delete entry of the menu removes.
final class UnitGroupedFilePreviewViewTest: TestBaseRealm {

    private let upload = String(repeating: "a", count: 60)

    private func message(id: Int, position: Int, name: String, mimetype: String) throws -> NCChatMessage {
        let dict: [String: Any] = [
            "id": id,
            "token": "token",
            "message": "{file}",
            "messageType": "comment",
            "systemMessage": "",
            "actorId": "alice",
            "actorType": "users",
            "referenceId": "\(self.upload)-\(String(format: "%03d", position))",
            "messageParameters": ["file": ["type": "file", "id": "\(id)", "name": name, "path": name, "mimetype": mimetype]]
        ]

        return try XCTUnwrap(NCChatMessage(dictionary: dict, andAccountId: TestBaseRealm.fakeAccountId))
    }

    private func laidOutView(for messages: [NCChatMessage], availableWidth: CGFloat = 300) -> GroupedFilePreviewView {
        let account = NCDatabaseManager.sharedInstance().activeAccount()
        let view = GroupedFilePreviewView(frame: CGRect(x: 0, y: 0, width: availableWidth, height: 400))

        view.setup(with: FileMessageGroup(messages: messages), account: account, availableWidth: availableWidth)
        view.layoutIfNeeded()

        return view
    }

    private func tileCenter(_ index: Int) -> CGPoint {
        let step = GroupedFilePreviewView.tileSize + GroupedFilePreviewView.contentSpacing
        return CGPoint(x: GroupedFilePreviewView.tileSize / 2 + CGFloat(index) * step, y: GroupedFilePreviewView.tileSize / 2)
    }

    func testThePointPicksTheTileUnderIt() throws {
        let messages = [try self.message(id: 1, position: 1, name: "a.jpg", mimetype: "image/jpeg"),
                        try self.message(id: 2, position: 2, name: "b.jpg", mimetype: "image/jpeg"),
                        try self.message(id: 3, position: 3, name: "c.jpg", mimetype: "image/jpeg")]
        let view = self.laidOutView(for: messages)

        XCTAssertEqual(view.fileIndex(at: self.tileCenter(0)), 0)
        XCTAssertEqual(view.fileIndex(at: self.tileCenter(1)), 1)
        XCTAssertEqual(view.fileIndex(at: self.tileCenter(2)), 2)
    }

    func testThePointPicksTheRowOfAFileWithoutPreview() throws {
        let messages = [try self.message(id: 1, position: 1, name: "a.jpg", mimetype: "image/jpeg"),
                        try self.message(id: 2, position: 2, name: "b.pdf", mimetype: "application/pdf")]
        let view = self.laidOutView(for: messages)

        let rowPoint = CGPoint(x: 20, y: GroupedFilePreviewView.tileSize + GroupedFilePreviewView.contentSpacing + 10)

        XCTAssertEqual(view.fileIndex(at: rowPoint), 1)
    }

    func testNoFileIsPickedOutsideOfTheFiles() throws {
        let messages = [try self.message(id: 1, position: 1, name: "a.jpg", mimetype: "image/jpeg"),
                        try self.message(id: 2, position: 2, name: "b.jpg", mimetype: "image/jpeg")]
        let view = self.laidOutView(for: messages)

        XCTAssertNil(view.fileIndex(at: CGPoint(x: GroupedFilePreviewView.tileSize + 1, y: 10)), "The gap between two tiles")
        XCTAssertNil(view.fileIndex(at: CGPoint(x: 10, y: GroupedFilePreviewView.tileSize + 30)), "Below the tiles")
    }

    /// The last tile stands for itself and the files that do not fit, so deleting by it would pick one at random
    func testTheBadgeTileIsNoFile() throws {
        let fitting = GroupedFilePreviewView.tileCount(forAvailableWidth: 300)
        var messages: [NCChatMessage] = []

        for position in 1...(fitting + 2) {
            messages.append(try self.message(id: position, position: position, name: "\(position).jpg", mimetype: "image/jpeg"))
        }

        let view = self.laidOutView(for: messages)

        XCTAssertEqual(view.fileIndex(at: self.tileCenter(fitting - 2)), fitting - 2)
        XCTAssertNil(view.fileIndex(at: self.tileCenter(fitting - 1)))
    }

    /// The tiles are drawn in the order the files were shared in, not the order the messages arrived in
    func testTheIndexFollowsTheUploadOrder() throws {
        let messages = [try self.message(id: 10, position: 2, name: "b.jpg", mimetype: "image/jpeg"),
                        try self.message(id: 11, position: 1, name: "a.jpg", mimetype: "image/jpeg")]
        let group = FileMessageGroup(messages: messages)
        let view = self.laidOutView(for: messages)

        let index = try XCTUnwrap(view.fileIndex(at: self.tileCenter(0)))

        XCTAssertEqual(group.messagesInUploadOrder[index].messageId, 11)
    }
}
