//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// The zones of a chat row, and the messages picked in the selection mode.
final class UnitMessageSelectionTest: TestBaseRealm {

    // MARK: - Zone of a touch

    private let bubble = CGRect(x: 100, y: 10, width: 200, height: 60)
    private let avatar = CGRect(x: 10, y: 10, width: 30, height: 30)

    func testTouchOnTheBubbleIsContent() {
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 200, y: 40), interactiveFrames: [bubble, avatar]), .content)
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 100, y: 10), interactiveFrames: [bubble, avatar]), .content, "The edge belongs to the bubble")
    }

    // The reactions are part of the bubble, so a tap or long press on them keeps what it did
    func testTouchOnTheReactionsInsideTheBubbleIsContent() {
        let reactions = CGRect(x: 110, y: 50, width: 80, height: 20)

        XCTAssertTrue(bubble.contains(reactions))
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: reactions.midX, y: reactions.midY), interactiveFrames: [bubble, avatar]), .content)
    }

    func testTouchOnTheAvatarIsContent() {
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 20, y: 20), interactiveFrames: [bubble, avatar]), .content)
    }

    func testTouchNextToTheBubbleIsEmpty() {
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 350, y: 40), interactiveFrames: [bubble, avatar]), .empty, "Right of the bubble")
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 60, y: 40), interactiveFrames: [bubble, avatar]), .empty, "Between avatar and bubble")
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 200, y: 90), interactiveFrames: [bubble, avatar]), .empty, "Below the bubble")
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 20, y: 60), interactiveFrames: [bubble, avatar]), .empty, "Below the avatar, in a row taller than it")
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 5, y: 5), interactiveFrames: []), .empty)
    }

    // The frames come from a real cell: own messages are on the right and have no avatar, the others have one
    private func cell(isOwnMessage: Bool) throws -> BaseChatTableViewCell {
        let account = NCDatabaseManager.sharedInstance().activeAccount()
        let room = NCRoom(value: self.addRoom(withToken: "token", withName: "Room"))

        let dict: [String: Any] = [
            "id": 1,
            "token": "token",
            "message": "Hello",
            "messageType": "comment",
            "systemMessage": "",
            "actorId": isOwnMessage ? account.userId : "someone-else",
            "actorType": "users"
        ]

        let message = try XCTUnwrap(NCChatMessage(dictionary: dict, andAccountId: account.accountId))
        let cell = try XCTUnwrap(UINib(nibName: BaseChatTableViewCell.nibName, bundle: nil)
            .instantiate(withOwner: nil).first as? BaseChatTableViewCell)

        cell.frame = .init(x: 0, y: 0, width: 400, height: 200)
        cell.setup(for: message, inRoom: room, forThread: nil, withAccount: account)
        cell.layoutIfNeeded()

        return cell
    }

    func testCellOfOwnMessageHasEmptyZoneLeftOfTheBubble() throws {
        let cell = try cell(isOwnMessage: true)
        let frames = cell.interactiveFrames()
        let bubbleFrame = cell.convert(cell.bubbleStackView.bounds, from: cell.bubbleStackView)

        XCTAssertTrue(frames.contains(bubbleFrame))
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: bubbleFrame.midX, y: bubbleFrame.midY), interactiveFrames: frames), .content)
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: 5, y: bubbleFrame.midY), interactiveFrames: frames), .empty)
    }

    func testCellOfOtherMessageHasEmptyZoneRightOfTheBubbleAndAvatarIsContent() throws {
        let cell = try cell(isOwnMessage: false)
        let frames = cell.interactiveFrames()
        let bubbleFrame = cell.convert(cell.bubbleStackView.bounds, from: cell.bubbleStackView)
        let avatarFrame = cell.convert(cell.avatarButton.bounds, from: cell.avatarButton)

        XCTAssertFalse(cell.avatarButton.isHidden)
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: avatarFrame.midX, y: avatarFrame.midY), interactiveFrames: frames), .content)
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: bubbleFrame.midX, y: bubbleFrame.midY), interactiveFrames: frames), .content)
        XCTAssertEqual(ChatRowZone.zone(at: CGPoint(x: cell.bounds.width - 5, y: bubbleFrame.midY), interactiveFrames: frames), .empty)
    }

    // MARK: - Selection

    func testSelectionStartsWithOneMessage() {
        var selection = MessageSelection()

        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.count, 0)

        XCTAssertTrue(selection.begin(with: 5, isSelectable: true))

        XCTAssertTrue(selection.isActive)
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.contains(5))
    }

    func testSelectionDoesNotStartWithAMessageThatCantBeSelected() {
        var selection = MessageSelection()

        XCTAssertFalse(selection.begin(with: 5, isSelectable: false))

        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.count, 0)
    }

    func testToggleSelectsAndDeselectsAndCounts() {
        var selection = MessageSelection()
        selection.begin(with: 1, isSelectable: true)

        XCTAssertTrue(selection.toggle(2, isSelectable: true))
        XCTAssertTrue(selection.toggle(3, isSelectable: true))
        XCTAssertEqual(selection.count, 3)

        XCTAssertTrue(selection.toggle(2, isSelectable: true))
        XCTAssertEqual(selection.count, 2)
        XCTAssertFalse(selection.contains(2))
        XCTAssertTrue(selection.isActive)
    }

    func testDeselectingTheLastMessageEndsTheMode() {
        var selection = MessageSelection()
        selection.begin(with: 1, isSelectable: true)
        selection.toggle(2, isSelectable: true)

        selection.toggle(1, isSelectable: true)
        XCTAssertTrue(selection.isActive)

        selection.toggle(2, isSelectable: true)
        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.count, 0)
    }

    func testToggleDoesNothingOutsideOfTheModeOrForAMessageThatCantBeSelected() {
        var selection = MessageSelection()

        XCTAssertFalse(selection.toggle(1, isSelectable: true), "A tap outside of the mode does not start it")
        XCTAssertFalse(selection.isActive)

        selection.begin(with: 1, isSelectable: true)

        XCTAssertFalse(selection.toggle(2, isSelectable: false))
        XCTAssertEqual(selection.count, 1)
        XCTAssertFalse(selection.contains(2))
    }

    func testClearEndsTheMode() {
        var selection = MessageSelection()
        selection.begin(with: 1, isSelectable: true)
        selection.toggle(2, isSelectable: true)

        selection.clear()

        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.count, 0)
        XCTAssertFalse(selection.contains(1))
    }

    func testPruneDropsMessagesThatLeftTheChatAndEndsTheModeWhenNoneIsLeft() {
        var selection = MessageSelection()
        selection.begin(with: 1, isSelectable: true)
        selection.toggle(2, isSelectable: true)

        selection.prune(keeping: [2, 3])
        XCTAssertEqual(selection.selectedIds, [2])
        XCTAssertTrue(selection.isActive)

        selection.prune(keeping: [3])
        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.count, 0)
    }

    // MARK: - What can be selected

    func testMessagesThatHaveNoMenuCantBeSelected() {
        XCTAssertTrue(MessageSelection.isSelectable(messageId: 10, isSystemMessage: false, isDeletedMessage: false))
        XCTAssertFalse(MessageSelection.isSelectable(messageId: 10, isSystemMessage: true, isDeletedMessage: false), "System message")
        XCTAssertFalse(MessageSelection.isSelectable(messageId: 10, isSystemMessage: false, isDeletedMessage: true), "Deleted message")

        for separatorId in [MessageSeparatorTableViewCell.unreadMessagesSeparatorId,
                            MessageSeparatorTableViewCell.unreadMessagesWithSummarySeparatorId,
                            MessageSeparatorTableViewCell.chatBlockSeparatorId] {
            XCTAssertFalse(MessageSelection.hasMenu(messageId: separatorId, isSystemMessage: false, isDeletedMessage: false), "Separator")
            XCTAssertFalse(MessageSelection.isSelectable(messageId: separatorId, isSystemMessage: false, isDeletedMessage: false), "Separator")
        }
    }

    // A message still being sent has no id yet and keeps its menu, but a selection by id could not tell such messages apart
    func testMessageWithoutServerIdHasAMenuButCantBeSelected() {
        XCTAssertTrue(MessageSelection.hasMenu(messageId: 0, isSystemMessage: false, isDeletedMessage: false))
        XCTAssertFalse(MessageSelection.isSelectable(messageId: 0, isSystemMessage: false, isDeletedMessage: false))
    }

    // MARK: - Forward

    func testForwardNeedsEveryMessageToBeForwardableAndNoClassifiedConversation() {
        XCTAssertTrue(MessageSelection.canForward(isClassified: false, forwardableFlags: [true]))
        XCTAssertTrue(MessageSelection.canForward(isClassified: false, forwardableFlags: [true, true, true]))
        XCTAssertFalse(MessageSelection.canForward(isClassified: false, forwardableFlags: [true, false, true]), "One file in the selection")
        XCTAssertFalse(MessageSelection.canForward(isClassified: true, forwardableFlags: [true]), "Classified conversation")
        XCTAssertFalse(MessageSelection.canForward(isClassified: true, forwardableFlags: [true, true]), "Classified conversation")
        XCTAssertFalse(MessageSelection.canForward(isClassified: false, forwardableFlags: []), "Nothing selected")
    }

    // MARK: - Text of several messages

    func testSelectedMessagesAreInTheOrderOfTheChat() {
        var selection = MessageSelection()
        // Picked in another order than they are in the chat
        selection.begin(with: 30, isSelectable: true)
        selection.toggle(10, isSelectable: true)
        selection.toggle(20, isSelectable: true)

        let chat = [(id: 10, text: "first"), (id: 15, text: "not picked"), (id: 20, text: "second"), (id: 30, text: "third")]

        let selected = selection.selectedItems(of: chat, id: { $0.id })

        XCTAssertEqual(selected.map { $0.text }, ["first", "second", "third"])
    }

    func testTextOfSeveralMessagesIsOneMessagePerLine() {
        XCTAssertEqual(MessageSelection.joinedText(of: ["first", "second", "third"]), "first\nsecond\nthird")
        XCTAssertEqual(MessageSelection.joinedText(of: ["only"]), "only")
        XCTAssertEqual(MessageSelection.joinedText(of: ["multi\nline", "next"]), "multi\nline\nnext")
    }
}
