//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation

/// Which part of a chat row a touch landed on.
enum ChatRowZone {

    /// The bubble with its reactions, or another element that handles touches itself (the avatar).
    case content

    /// The rest of the row, left and right of the bubble.
    case empty

    /// `interactiveFrames` are the frames of the bubble and the avatar, in the coordinate space of `point`.
    static func zone(at point: CGPoint, interactiveFrames: [CGRect]) -> ChatRowZone {
        return interactiveFrames.contains(where: { $0.contains(point) }) ? .content : .empty
    }
}

/// The messages picked in the multi-selection mode of a chat, by message id.
struct MessageSelection {

    /// Separate lines, as the messages are in the chat
    static let textSeparator = "\n"

    private(set) var selectedIds: Set<Int> = []
    private(set) var isActive = false

    var count: Int {
        return self.selectedIds.count
    }

    func contains(_ messageId: Int) -> Bool {
        return self.selectedIds.contains(messageId)
    }

    /// The messages that get a message menu: no system or deleted messages and no separators.
    static func hasMenu(messageId: Int, isSystemMessage: Bool, isDeletedMessage: Bool) -> Bool {
        return !isSystemMessage && !isDeletedMessage &&
            messageId != MessageSeparatorTableViewCell.unreadMessagesSeparatorId &&
            messageId != MessageSeparatorTableViewCell.unreadMessagesWithSummarySeparatorId &&
            messageId != MessageSeparatorTableViewCell.chatBlockSeparatorId
    }

    /// The messages with a menu, once the server knows them: a message is picked by its id, and the
    /// messages that are still being sent don't have one yet.
    static func isSelectable(messageId: Int, isSystemMessage: Bool, isDeletedMessage: Bool) -> Bool {
        return messageId > 0 && self.hasMenu(messageId: messageId, isSystemMessage: isSystemMessage, isDeletedMessage: isDeletedMessage)
    }

    /// Starts the mode with one message selected. Returns false and does nothing for a message that can't be selected.
    @discardableResult
    mutating func begin(with messageId: Int, isSelectable: Bool) -> Bool {
        guard isSelectable else { return false }

        self.selectedIds = [messageId]
        self.isActive = true

        return true
    }

    /// Selects or deselects a message. The mode ends when the last message is deselected.
    /// Returns false and does nothing outside of the mode and for a message that can't be selected.
    @discardableResult
    mutating func toggle(_ messageId: Int, isSelectable: Bool) -> Bool {
        guard self.isActive, isSelectable else { return false }

        if self.selectedIds.contains(messageId) {
            self.selectedIds.remove(messageId)
        } else {
            self.selectedIds.insert(messageId)
        }

        if self.selectedIds.isEmpty {
            self.isActive = false
        }

        return true
    }

    mutating func clear() {
        self.selectedIds = []
        self.isActive = false
    }

    /// Drops messages that are not in the chat anymore or can't be selected anymore, e.g. removed by a reload or deleted.
    /// Ends the mode when none is left.
    mutating func prune<T>(to items: [T], id: (T) -> Int, isSelectable: (T) -> Bool) {
        guard self.isActive else { return }

        self.selectedIds.formIntersection(items.filter(isSelectable).map(id))

        if self.selectedIds.isEmpty {
            self.isActive = false
        }
    }

    /// The selected items of `items`, in the order of `items` (the messages of the chat from the oldest).
    /// An item that is not selectable anymore, e.g. a message deleted while it was selected, is left out.
    func selectedItems<T>(of items: [T], id: (T) -> Int, isSelectable: (T) -> Bool = { _ in true }) -> [T] {
        return items.filter { self.selectedIds.contains(id($0)) && isSelectable($0) }
    }

    /// One text for several messages to copy, one message per line.
    static func joinedText(of texts: [String]) -> String {
        return texts.joined(separator: self.textSeparator)
    }
}

// MARK: - Deleting the selected messages

extension MessageSelection {

    /// The messages a delete of the `selected` ones applies to, each once. Nil when nothing is selected or one of them
    /// can't be deleted: `targets` gives the rule of the message menu, so that the delete action is only offered when
    /// every selected message could be deleted on its own.
    static func deletionTargets<T>(of selected: [T], id: (T) -> Int, targets: (T) -> [T]?) -> [T]? {
        guard !selected.isEmpty else { return nil }

        var result: [T] = []
        var seenIds = Set<Int>()

        for item in selected {
            guard let itemTargets = targets(item) else { return nil }

            for target in itemTargets where seenIds.insert(id(target)).inserted {
                result.append(target)
            }
        }

        return result
    }
}

/// What deleting several messages did. The server deletes one message per request, so some can fail.
struct DeleteOutcome: Equatable {

    let total: Int
    let failedIds: [Int]

    var deletedCount: Int {
        return self.total - self.failedIds.count
    }

    var allDeleted: Bool {
        return self.failedIds.isEmpty
    }
}

/// Collects the results of the single deletes and reports once, when every message has an answer.
final class DeletionCollector {

    private let ids: [Int]
    private var answered = Set<Int>()
    private var failedIds: [Int] = []
    private let completion: (DeleteOutcome) -> Void

    init(ids: [Int], completion: @escaping (DeleteOutcome) -> Void) {
        self.ids = ids
        self.completion = completion
    }

    /// An answer for a message that is not expected, or a second one for it, is ignored.
    func record(id: Int, deleted: Bool) {
        guard self.ids.contains(id), self.answered.insert(id).inserted else { return }

        if !deleted {
            self.failedIds.append(id)
        }

        if self.answered.count == self.ids.count {
            self.completion(DeleteOutcome(total: self.ids.count, failedIds: self.failedIds))
        }
    }
}

