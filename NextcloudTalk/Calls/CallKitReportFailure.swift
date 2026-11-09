//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CallKit

/// Decides what to do when `CXProvider.reportNewIncomingCall` fails.
enum CallKitReportFailure {

    /// Returns true if the user should be told about the call with a local notification.
    ///
    /// iOS refuses to show the call for example when a Focus / Do Not Disturb filters it. Without a notification
    /// the user would not notice the call at all. No notification is wanted for:
    /// - `callUUIDAlreadyExists`, because then the call is already known to CallKit
    /// - `filteredByBlockList`, because the user explicitly blocked the caller
    /// For all other (unknown) errors a notification is shown, as a possibly redundant notification is better than a lost call.
    static func shouldNotifyUser(about error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == CXErrorDomainIncomingCall {
            switch nsError.code {
            case CXErrorCodeIncomingCallError.Code.callUUIDAlreadyExists.rawValue,
                 CXErrorCodeIncomingCallError.Code.filteredByBlockList.rawValue:
                return false
            default:
                break
            }
        }

        return true
    }
}
