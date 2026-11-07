//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct FileMessageGroup {

    /// A file drawn the same way without belonging to an upload is a group of one.
    let messages: [NCChatMessage]

    /// The last message, so the group carries the newest timestamp and read state. A caption ends
    /// its group, so the caption of an upload is always the text of this message.
    var anchor: NCChatMessage {
        return self.messages[self.messages.count - 1]
    }

    /// Whether the group continues a block from the same author, and so shows no avatar or name.
    ///
    /// Follows the first message: the group is shown as its last one, which is always a continuation.
    /// An edited caption starts a new block, so its header shows the edit, like message grouping does.
    var continuesAuthorBlock: Bool {
        return self.messages[0].isGroupMessage && self.anchor.lastEditTimestamp == 0
    }

    /// Not the order the messages arrived in: files of one upload can be posted in parallel.
    var messagesInUploadOrder: [NCChatMessage] {
        return self.messages.sorted { first, second in
            (first.fileUploadReference?.position ?? 0) < (second.fileUploadReference?.position ?? 0)
        }
    }

    /// Finds a posted or pending file through the upstream reference-id keyed groups.
    static func containing(_ message: NCChatMessage, in groups: [String: FileMessageGroup]) -> FileMessageGroup? {
        guard let referenceId = message.referenceId else { return nil }
        return groups[referenceId] ?? groups.values.first { group in
            group.messages.contains { $0.referenceId == referenceId }
        }
    }

    /// A group is deleted as a whole, so no file of it is left behind unseen. It is offered only
    /// when every file of it can be deleted.
    func canDelete(for account: TalkAccount, in room: NCRoom) -> Bool {
        return room.canChat && self.messages.allSatisfy { !$0.isTemporary && $0.isDeletable(for: account, in: room) }
    }

    /// Splits the messages of a conversation, in the order they are shown, into the groups of files
    /// that were shared as one upload. Anything that is not a file of the same upload ends a group.
    static func groups(in messages: [NCChatMessage]) -> [FileMessageGroup] {
        var groups: [FileMessageGroup] = []
        var currentGroup: [NCChatMessage] = []

        /// Closes the group being collected. A single file is an ordinary message, not a group.
        func finishCurrentGroup() {
            if currentGroup.count > 1 {
                groups.append(FileMessageGroup(messages: currentGroup))
            }

            currentGroup = []
        }

        for message in messages {
            guard message.isGroupableFileMessage else {
                finishCurrentGroup()
                continue
            }

            if let previous = currentGroup.last, !self.belongToTheSameUpload(message, previous) {
                finishCurrentGroup()
            }

            currentGroup.append(message)

            // The caption is added to the file shared last, so it closes its group
            if !message.sharesFileWithoutCaption {
                finishCurrentGroup()
            }
        }

        finishCurrentGroup()

        return groups
    }

    /// The selected messages with all files of every group they belong to. A group is one row of the chat, so
    /// picking it picks every file of its upload. Each group stands where its first selected message was, its
    /// files in the order of the upload, and the other messages keep their order.
    static func expandingSelection(_ selected: [NCChatMessage], groupForMessage: (NCChatMessage) -> FileMessageGroup?) -> [NCChatMessage] {
        var expanded: [NCChatMessage] = []
        var addedIds = Set<Int>()

        for message in selected {
            let members = groupForMessage(message)?.messagesInUploadOrder ?? [message]

            for member in members where addedIds.insert(member.messageId).inserted {
                expanded.append(member)
            }
        }

        return expanded
    }

    /// Position within the upload is deliberately not compared: a file that failed to upload leaves
    /// a gap, and the files around it still belong together.
    ///
    /// Posted and pending files of a share shared in the background are one group, so it keeps its size while posting.
    /// Pending files have no parent set, a thread or reply only shows once they are posted.
    private static func belongToTheSameUpload(_ message: NCChatMessage, _ other: NCChatMessage) -> Bool {
        let haveSameParent = message.parentId == other.parentId || message.isTemporary || other.isTemporary

        return message.fileUploadReference?.uploadHash == other.fileUploadReference?.uploadHash && haveSameParent
    }
}
