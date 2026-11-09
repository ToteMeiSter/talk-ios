//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum AnsweredCallAction: Equatable {
    /// Show the call screen of the answered room
    case start
    /// The app is not ready yet, try again once it is
    case wait
    /// The call screen of the answered room is already shown, nothing to do
    case keep
    /// The call can't be shown, end the CallKit call and inform the user
    case fail
}

enum AnsweredCallPolicy {

    /// Decides what to do with a call that was answered via CallKit.
    /// - Parameters:
    ///   - appState: current state of the app
    ///   - shownCallToken: room token of the call screen that is currently shown, `nil` if there is none
    ///   - answeredToken: room token of the answered call
    static func action(appState: AppState, shownCallToken: String?, answeredToken: String) -> AnsweredCallAction {
        if let shownCallToken {
            return shownCallToken == answeredToken ? .keep : .fail
        }

        return appState == .ready ? .start : .wait
    }
}
