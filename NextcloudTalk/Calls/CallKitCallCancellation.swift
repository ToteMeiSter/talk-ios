//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Decides which ringing CallKit calls a server "delete" push has made obsolete.
/// Kept free of CallKit/UIKit calls so it can be unit tested.
enum CallKitCallCancellation {

    /// - Parameter notificationIds: Server notification ids from `delete` / `delete-multiple`, or `nil` for `delete-all`.
    /// - Returns: UUIDs of calls that are still ringing, belong to `accountId` and were deleted by the push.
    static func uuidsToCancel(in calls: [UUID: CallKitCall], accountId: String, notificationIds: [Int]?) -> [UUID] {
        return calls.compactMap { uuid, call in
            guard call.isRinging, call.accountId == accountId else { return nil }

            if let notificationIds {
                // A call without a known notification id can't be matched, the call state polling will end it
                guard call.notificationId != 0, notificationIds.contains(call.notificationId) else { return nil }
            }

            return uuid
        }
    }
}

/// Remembers recently deleted notification ids, because a `delete` push can arrive before the VoIP push of the same call.
struct CallKitDeletedNotifications {

    static let retentionSeconds: TimeInterval = 60

    private var deleted: [String: [Int: Date]] = [:] // accountId -> notificationId -> deletion time

    mutating func record(_ notificationIds: [Int], accountId: String, at now: Date = Date()) {
        var accountEntries = self.deleted[accountId] ?? [:]
        accountEntries = accountEntries.filter { now.timeIntervalSince($0.value) < CallKitDeletedNotifications.retentionSeconds }

        for notificationId in notificationIds {
            accountEntries[notificationId] = now
        }

        self.deleted[accountId] = accountEntries
    }

    func contains(_ notificationId: Int, accountId: String, at now: Date = Date()) -> Bool {
        guard let deletedAt = self.deleted[accountId]?[notificationId] else { return false }

        return now.timeIntervalSince(deletedAt) < CallKitDeletedNotifications.retentionSeconds
    }
}
