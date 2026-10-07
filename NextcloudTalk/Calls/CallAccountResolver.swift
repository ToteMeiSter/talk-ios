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
    ///   - rememberedAccountId: Account that was last used for a call with that token (see `CallAccountMemory`)
    static func resolve(activeAccountId: String, accountIdsWithToken: [String], rememberedAccountId: String? = nil) -> CallAccountResolution {
        let candidates = Array(Set(accountIdsWithToken)).sorted()

        // Unknown token (e.g. conversation not synced yet): keep the previous behavior
        guard !candidates.isEmpty else {
            return CallAccountResolution(accountId: activeAccountId, isAmbiguous: false)
        }

        // The active account always wins, so nothing changes for users with a single matching account
        if candidates.contains(activeAccountId) {
            return CallAccountResolution(accountId: activeAccountId, isAmbiguous: candidates.count > 1)
        }

        // Several accounts (e.g. on the same server) share the conversation: prefer the account used last
        if let rememberedAccountId, candidates.contains(rememberedAccountId) {
            return CallAccountResolution(accountId: rememberedAccountId, isAmbiguous: candidates.count > 1)
        }

        return CallAccountResolution(accountId: candidates[0], isAmbiguous: candidates.count > 1)
    }
}

/// Remembers which account was last used for a call with a token, newest entries last, bounded in size.
struct CallAccountMemoryEntry: Codable, Equatable {
    let token: String
    let accountId: String
}

enum CallAccountMemory {
    static let maxEntries = 50
    private static let defaultsKey = "callAccountMemory"

    /// Returns `entries` with the pair added as the newest entry. An older entry for the same token is replaced.
    static func remembering(token: String, accountId: String, in entries: [CallAccountMemoryEntry], limit: Int = maxEntries) -> [CallAccountMemoryEntry] {
        var result = entries.filter { $0.token != token }
        result.append(CallAccountMemoryEntry(token: token, accountId: accountId))
        return Array(result.suffix(limit))
    }

    static func accountId(forToken token: String, in entries: [CallAccountMemoryEntry]) -> String? {
        return entries.last(where: { $0.token == token })?.accountId
    }

    static func load(from defaults: UserDefaults = .standard) -> [CallAccountMemoryEntry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CallAccountMemoryEntry].self, from: data)) ?? []
    }

    static func remember(token: String, accountId: String, in defaults: UserDefaults = .standard) {
        let entries = remembering(token: token, accountId: accountId, in: load(from: defaults))
        defaults.set(try? JSONEncoder().encode(entries), forKey: defaultsKey)
    }

    static func rememberedAccountId(forToken token: String, from defaults: UserDefaults = .standard) -> String? {
        return accountId(forToken: token, in: load(from: defaults))
    }
}
