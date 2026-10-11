//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network

/// Reports the changes of the network the device is on while a call is running (see `CallNetworkChangeTracker`).
/// The connections of a call are bound to the address of the network they were created on, so after a switch
/// of the network they are dead, but ICE notices that only after many seconds.
///
/// A path update is not reported at once. A device at the edge of a Wi-Fi flips between the links within seconds,
/// and every report costs a new signaling session. The monitor waits until the path holds still for `settleDelay`
/// and compares the path with the one of the last settled moment: a flip which is over by then is no change.
///
/// `onChange` is called on a private serial queue of the monitor, not on the WebRTC queue.
final class CallNetworkMonitor {

    /// Time the path has to stay the same before it counts
    static let settleDelay: TimeInterval = 2

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "callNetworkMonitorQueue")
    private let onChange: (CallNetworkChange) -> Void

    // Used on `queue` only
    private var tracker = CallNetworkChangeTracker()
    private var hasStartingPoint = false
    private var settleWorkItem: DispatchWorkItem?
    private var isStopped = false

    init(onChange: @escaping (CallNetworkChange) -> Void) {
        self.onChange = onChange
    }

    deinit {
        // No-op if stopped already. The handler holds `self` weakly, so it does not keep the monitor alive
        monitor.cancel()
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Called on `queue`
            self?.handle(CallNetworkPath(path))
        }

        monitor.start(queue: queue)
    }

    /// A stopped monitor can not be started again. The handler is not reset (it could run at this moment on `queue`),
    /// `cancel()` ends the updates and `isStopped` drops what is still on its way.
    func stop() {
        monitor.cancel()

        queue.async {
            self.isStopped = true
            self.settleWorkItem?.cancel()
            self.settleWorkItem = nil
        }
    }

    private func handle(_ path: CallNetworkPath) {
        guard !isStopped else { return }

        // The first update is the starting point, nothing to wait for
        guard hasStartingPoint else {
            hasStartingPoint = true
            _ = tracker.update(path)
            return
        }

        settleWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }

            self.settleWorkItem = nil

            if let change = self.tracker.update(path) {
                self.onChange(change)
            }
        }

        settleWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: workItem)
    }
}

extension CallNetworkPath {

    init(_ path: NWPath) {
        // The interfaces are listed in the order of preference. A VPN tunnel is of type `.other`, so it is skipped
        let primary = path.availableInterfaces.lazy.compactMap { interface -> CallNetworkInterface? in
            switch interface.type {
            case .wifi: return .wifi
            case .cellular: return .cellular
            case .wiredEthernet: return .wired
            default: return nil
            }
        }.first

        self.init(isSatisfied: path.status == .satisfied, primaryInterface: primary)
    }
}
