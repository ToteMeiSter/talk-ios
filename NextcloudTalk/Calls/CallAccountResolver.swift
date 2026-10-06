//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Chooses the account an outgoing call from Recents (CallKit / INStartCallIntent) belongs to.
///
/// The `CXHandle` of such a call only carries the conversation token, so the account has to be derived from the
/// accounts that know a conversation with that token.
struct CallAccountResolution: Equatable {
    let accountId: String
    /// More than one account knows the token and we had to pick one
    let isAmbiguous: Bool
}

enum CallAccountResolver {

    /// - Parameters:
    ///   - activeAccountId: The currently active account
    ///   - accountIdsWithToken: Accounts that have a conversation with the called token
    static func resolve(activeAccountId: String, accountIdsWithToken: [String]) -> CallAccountResolution {
        let candidates = Array(Set(accountIdsWithToken)).sorted()

        // Unknown token (e.g. conversation not synced yet): keep the previous behavior
        guard !candidates.isEmpty else {
            return CallAccountResolution(accountId: activeAccountId, isAmbiguous: false)
        }

        // The active account always wins, so nothing changes for users with a single matching account
        if candidates.contains(activeAccountId) {
            return CallAccountResolution(accountId: activeAccountId, isAmbiguous: candidates.count > 1)
        }

        return CallAccountResolution(accountId: candidates[0], isAmbiguous: candidates.count > 1)
    }
}
