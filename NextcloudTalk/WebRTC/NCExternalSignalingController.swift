//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@objc public protocol NCExternalSignalingControllerDelegate {
    @objc func externalSignalingController(_ externalSignalingController: NCExternalSignalingController, didReceivedSignalingMessage signalingMessageDict: [AnyHashable: Any])
    @objc func externalSignalingController(_ externalSignalingController: NCExternalSignalingController, didReceivedParticipantListMessage participantListMessageDict: [AnyHashable: Any])
    @objc func externalSignalingController(_ externalSignalingController: NCExternalSignalingController, didReceiveLeaveOfSessions sessionIds: [String])
    @objc func externalSignalingControllerShouldRejoinCall(_ externalSignalingController: NCExternalSignalingController)
    @objc func externalSignalingControllerWillRejoinCall(_ externalSignalingController: NCExternalSignalingController)
    /// Joining the room for the call again failed, so the call must not be joined (POST /call) without a new session.
    /// `statusCode` is the HTTP status of the failed request, or 0 if there was none.
    @objc optional func externalSignalingController(_ externalSignalingController: NCExternalSignalingController, didFailRejoiningCallWithStatusCode statusCode: Int, error: Error?)
    @objc func externalSignalingController(_ externalSignalingController: NCExternalSignalingController, shouldSwitchToCall roomToken: String)
}

@objc extension NSNotification {
    public static let ExtSignalingDidReceiveChatMessage = Notification.Name.extSignalingDidReceiveChatMessage
    public static let ExtSignalingDidReconnect = Notification.Name.extSignalingDidReconnect
}

extension Notification.Name {
    static let extSignalingDidUpdateParticipants = Notification.Name(rawValue: "NCExternalSignalingControllerDidUpdateParticipantsNotification")
    static let extSignalingDidReceiveJoinOfParticipant = Notification.Name(rawValue: "NCExternalSignalingControllerDidReceiveJoinOfParticipantNotification")
    static let extSignalingDidReceiveLeaveOfParticipant = Notification.Name(rawValue: "NCExternalSignalingControllerDidReceiveLeaveOfParticipantNotification")
    static let extSignalingDidReceiveStartedTyping = Notification.Name(rawValue: "NCExternalSignalingControllerDidReceiveStartedTypingNotification")
    static let extSignalingDidReceiveStoppedTyping = Notification.Name(rawValue: "NCExternalSignalingControllerDidReceiveStoppedTypingNotification")
    static let extSignalingDidReceiveChatMessage = Notification.Name(rawValue: "NCExternalSignalingControllerDidReceiveChatMessageNotification")
    static let extSignalingDidRequestChatRefresh = Notification.Name(rawValue: "NCExternalSignalingControllerDidRequestChatRefreshNotification")
    static let extSignalingDidReconnect = Notification.Name(rawValue: "NCExternalSignalingControllerDidReconnectNotification")
}

public typealias SendMessageCompletionBlock = (_ task: URLSessionWebSocketTask?, _ status: NCExternalSignalingSendMessageStatus) -> Void

public enum NCExternalSignalingSendMessageStatus {
    case success
    case socketError
    case applicationError
}

@objcMembers public class NCExternalSignalingController: NSObject, URLSessionWebSocketDelegate, CCCertificateDelegate {

    public weak var delegate: NCExternalSignalingControllerDelegate?

    public var currentRoom: String?

    // The room our session is in on the signaling server right now, cleared on every reconnect unlike `currentRoom`.
    public private(set) var joinedRoomToken: String?

    public private(set) var account: TalkAccount
    public private(set) var disconnected: Bool = true
    public private(set) var hasMCU: Bool = false
    public private(set) var hasUpdateSdp: Bool = false
    public private(set) var hasSimulcast: Bool = false
    public private(set) var hasChatRelay: Bool = false
    public private(set) var sessionId: String?
    public private(set) var participantsMap = [String: SignalingParticipant]()

    private let initialReconnectInterval = 1
    private let maxReconnectInterval = 16
    private let webSocketTimeoutInterval = 15.0

    private var webSocket: URLSessionWebSocketTask?
    private var serverUrl: String
    private var ticket: String
    private var resumeId: String?
    private var authenticationBackendUrl: String
    private var helloResponseReceived = false

    // Counts the sessions which started a join of the room again (main thread only), see `rejoinRoomForCall`
    private var rejoinGeneration = 0
    private var nextMessageId: Int = 0
    private var pendingMessages = [WSMessage]()
    private var helloMessage: WSMessage?
    private var messagesWithCompletionBlock = [WSMessage]()

    // Reason of the last error response of the signaling server to a join message (e.g. "no_such_room: ..."),
    // read and cleared by the completion of `joinRoom` (main thread only)
    private var lastJoinFailureReason: String?
    private var reconnectInterval: Int = 0
    private var reconnectTimer: Timer?
    private var disconnectTime: TimeInterval?

    init(account: TalkAccount, serverUrl: String, ticket: String) {
        self.account = account
        self.serverUrl = serverUrl
        self.ticket = ticket

        self.authenticationBackendUrl = NCAPIController.sharedInstance().authenticationBackendUrl(forAccount: account)
        self.serverUrl = NCExternalSignalingController.getWebSocketUrl(forServer: serverUrl)

        super.init()

        self.reconnectInterval = self.initialReconnectInterval
        self.connect()
    }

    static func getWebSocketUrl(forServer server: String) -> String {
        var wsUrl = server

        wsUrl = wsUrl.replacingOccurrences(of: "https://", with: "wss://")
        wsUrl = wsUrl.replacingOccurrences(of: "http://", with: "ws://")

        if wsUrl.hasSuffix("/") {
            wsUrl = String(wsUrl.dropLast())
        }

        wsUrl += "/spreed"

        return wsUrl
    }

    // MARK: - WebSocket connection

    func connect() {
        self.connect(force: false)
    }

    func forceConnect() {
        self.connect(force: true)
    }

    func connect(force: Bool) {
        let forceConnect = force || NCRoomsManager.shared.callViewController != nil

        // Do not try to connect if the app is running in the background (unless forcing a connection or in a call)
        if !forceConnect, UIApplication.shared.applicationState == .background {
            NCLog.log("Trying to create websocket connection while app is in the background")
            self.disconnected = true
            return
        }

        guard let url = URL(string: self.serverUrl) else { return }

        self.invalidateReconnectionTimer()

        self.disconnected = false
        self.nextMessageId = 1
        self.messagesWithCompletionBlock = []
        self.helloResponseReceived = false

        NCLog.log("Connecting to the signaling server")

        let wsSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var wsRequest = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: webSocketTimeoutInterval)
        wsRequest.setValue(NCAppBranding.userAgent(), forHTTPHeaderField: "User-Agent")

        if self.resumeId != nil {
            // We are only allowed to resume a session shortly after the connection was lost
            if !NCSignalingResumePolicy.canResume(resumeId: self.resumeId, connectionLostTime: self.disconnectTime, now: Date().timeIntervalSince1970) {
                NCLog.log("We have a resumeId, but the connection was lost outside of the resume window. Connecting without resumeId.")
                self.resumeId = nil
            }
        }

        let webSocket = wsSession.webSocketTask(with: wsRequest)
        self.webSocket = webSocket

        webSocket.resume()
        self.receiveMessage()
    }

    func reconnect() {
        // Note: Make sure to call reconnect only from the main-thread!
        dispatchPrecondition(condition: .onQueue(.main))

        guard self.reconnectTimer == nil else { return }

        NCLog.log("Reconnecting to the signaling server")

        // Remember when the connection was lost, so we can try to resume the session (like the web client does).
        // Keep the first moment, as failed reconnect attempts end up here again.
        self.disconnectTime = NCSignalingResumePolicy.connectionLostTime(existing: self.disconnectTime, now: Date().timeIntervalSince1970)

        self.resetWebSocket()

        // Execute completion blocks on all messages
        for message in self.messagesWithCompletionBlock {
            message.executeCompletionBlock(withStatus: .socketError)
        }

        self.setReconnectionTimer()
    }

    func forceReconnect() {
        DispatchQueue.main.async {
            self.resumeId = nil
            self.currentRoom = nil
            self.reconnect()
        }
    }

    /// The device changed its network. The websocket is bound to the address of the old network: it dies by itself
    /// only when the old network goes away completely, otherwise it stays silent until a timeout, and there is no
    /// ping of the client. A call needs the signaling right now (offers of an ICE restart, a new join), so the socket
    /// is replaced. The session is kept (resume), if the server still holds it.
    func reconnectAfterNetworkChange() {
        DispatchQueue.main.async {
            NCLog.log("Reconnecting to the signaling server because the network changed")

            // A new network deserves a new attempt now, not after the rest of the growing pause
            self.reconnectInterval = self.initialReconnectInterval

            if self.reconnectTimer != nil {
                // The connection was lost already and a reconnect is waiting for its time
                self.connect(force: true)
            } else {
                self.reconnect()
            }
        }
    }

    func forceReconnectForRejoin() {
        // In case we force reconnect in order to rejoin the call again, we need to keep the currently joined room.
        // In `helloResponseReceived` we determine that we were in a room and that the sessionId changed, in that case
        // we trigger a re-join in `NCRoomsManager` which takes care of re-joining.

        DispatchQueue.main.async {
            let byeDict = [
                "type": "bye",
                "bye": [:]
            ]

            // Close our current session. Don't leave the room, as that would defeat the above mentioned purpose
            self.send(message: byeDict) { _, _ in
                self.resumeId = nil
                self.reconnect()
            }
        }
    }

    func disconnect() {
        NCLog.log("Disconnecting from the signaling server")

        DispatchQueue.main.async {
            // Keep an earlier moment of a lost connection, so the resume window is not extended.
            // `disconnectTime` is only accessed on the main thread.
            self.disconnectTime = NCSignalingResumePolicy.connectionLostTime(existing: self.disconnectTime, now: Date().timeIntervalSince1970)

            self.invalidateReconnectionTimer()
            self.resetWebSocket()
        }
    }

    func resetWebSocket() {
        self.webSocket?.cancel()
        self.webSocket = nil
        self.helloResponseReceived = false
        self.joinedRoomToken = nil
        self.helloMessage?.ignoreCompletionBlock()
        self.helloMessage = nil
        self.disconnected = true
    }

    func setReconnectionTimer() {
        self.invalidateReconnectionTimer()

        // Wiggle interval a little bit to prevent all clients from connecting
        // simultaneously in case the server connection is interrupted.
        let interval = self.reconnectInterval - (self.reconnectInterval / 2) + Int.random(in: 1...self.reconnectInterval)
        NCLog.log("Reconnecting in \(interval)s")

        DispatchQueue.main.async {
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: false, block: { [weak self] _ in
                self?.connect()
            })
        }

        self.reconnectInterval = min(self.reconnectInterval * 2, maxReconnectInterval)
    }

    func invalidateReconnectionTimer() {
        self.reconnectTimer?.invalidate()
        self.reconnectTimer = nil
    }

    // MARK: - WebSocket messages

    func send(message jsonDict: [AnyHashable: Any], withCompletionBlock block: SendMessageCompletionBlock?) {
        let wsMessage = WSMessage(message: jsonDict, completionBlock: block)

        // Add message as pending message if websocket is not connected
        if !self.helloResponseReceived, !wsMessage.isHelloMessage {
            DispatchQueue.main.async {
                if wsMessage.isJoinMessage {
                    // We join a new room, so any message which wasn't send by now is not relevant for the new room anymore
                    self.pendingMessages = []
                }

                NCLog.log("Trying to send message before we received a hello response -> adding to pendingMessages")
                self.pendingMessages.append(wsMessage)
            }

            return
        }

        self.send(message: wsMessage)
    }

    func send(message wsMessage: WSMessage) {
        guard let webSocket = self.webSocket else { return }

        // Assign messageId and timeout to messages with completionBlocks
        if wsMessage.completionBlock != nil {
            wsMessage.messageId = "\(self.nextMessageId)"
            self.nextMessageId += 1

            if wsMessage.isHelloMessage {
                self.helloMessage?.ignoreCompletionBlock()
                self.helloMessage = wsMessage
            } else {
                self.messagesWithCompletionBlock.append(wsMessage)
            }
        }

        wsMessage.send(withWebSocket: webSocket)
    }

    func sendHelloMessage() {
        var helloDict: [String: Any] = [
            "type": "hello",
            "hello": [
                "version": "1.0",
                "auth": [
                    "url": self.authenticationBackendUrl,
                    "params": [
                        "userid": account.userId,
                        "ticket": ticket
                    ]
                ],
                "features": [
                    "chat-relay"
                ]
            ]
        ]

        if let resumeId = self.resumeId {
            helloDict = [
                "type": "hello",
                "hello": [
                    "version": "1.0",
                    "resumeid": resumeId,
                    "features": [
                        "chat-relay"
                    ]
                ]
            ]
        }

        NCLog.log("Sending hello message")

        self.send(message: helloDict) { task, status in
            if status == .socketError, task == self.webSocket {
                NCLog.log("Reconnecting from sendHelloMessage")
                self.reconnect()
            }
        }
    }

    func helloResponseReceived(messageDict: [AnyHashable: Any]) {
        self.helloResponseReceived = true

        NCLog.log("Hello received with \(self.pendingMessages.count) pending messages")

        let messageId = messageDict["id"] as? String ?? "0"
        self.executeCompletionBlock(forMessageId: messageId, withStatus: .success)

        guard let helloDict = messageDict["hello"] as? [AnyHashable: Any],
              let newSessionId = helloDict["sessionid"] as? String
        else {
            NCLog.log("Unable to access hello dictionary")
            return
        }

        self.resumeId = helloDict["resumeid"] as? String

        // We are connected again, the next connection loss starts a new resume window
        DispatchQueue.main.async {
            self.disconnectTime = nil
        }

        let sessionChanged = self.sessionId != newSessionId

        // The very first session has no predecessor, so there is nothing a queued message could be stale for
        let sessionReplaced = sessionChanged && self.sessionId != nil
        let rejoinToken = sessionChanged ? self.currentRoom : nil
        self.sessionId = newSessionId

        if sessionChanged {
            // The new session did not join any room yet, the re-join below takes care of that
            self.joinedRoomToken = nil

            // The sessions of the old signaling session are gone and their leave events are not replayed. The re-join
            // reports the sessions of the room again, but `roomMessageReceived` keeps the map for an unchanged room
            self.participantsMap = [:]
        } else {
            // The session was resumed, so the server kept us in the room and replays what we missed
            self.joinedRoomToken = self.currentRoom
        }

        guard let serverDict = helloDict["server"] as? [AnyHashable: Any],
              let serverFeatures = serverDict["features"] as? [String],
              let serverVersion = serverDict["version"] as? String
        else {
            NCLog.log("Unable to access server dictionary")
            return
        }

        self.hasMCU = serverFeatures.contains(where: { $0 == "mcu" })
        self.hasUpdateSdp = serverFeatures.contains(where: { $0 == "update-sdp" })
        self.hasSimulcast = serverFeatures.contains(where: { $0 == "simulcast" })
        self.hasChatRelay = serverFeatures.contains(where: { $0 == "chat-relay" })

        DispatchQueue.main.async {
            // The new session starts a new join of the room. What the joins of the old session report from now on
            // (e.g. the failure of a queued join which is dropped below) is stale, see `rejoinRoomForCall`
            if sessionChanged {
                self.rejoinGeneration += 1
            }

            let bgTask = BGTaskHelper.startBackgroundTask(withName: "NCUpdateSignalingVersionTransaction")
            NCDatabaseManager.sharedInstance().setExternalSignalingServerVersion(serverVersion, forAccountId: self.account.accountId)

            let queuedMessages = self.pendingMessages
            self.pendingMessages = []

            var droppedCount = 0

            // Send pending messages. With a new session, the ones for the old session are dropped
            for wsMessage in queuedMessages {
                let messageType = wsMessage.message["type"] as? String
                let action = NCSignalingResumePolicy.queuedMessageAction(messageType: messageType, sessionReplaced: sessionReplaced, rejoinFollows: rejoinToken != nil)

                switch action {
                case .send:
                    self.send(message: wsMessage)
                case .drop:
                    droppedCount += 1
                    wsMessage.executeCompletionBlock(withStatus: .applicationError)
                case .dropSilently:
                    droppedCount += 1
                    wsMessage.ignoreCompletionBlock()
                }
            }

            if droppedCount > 0 {
                NCLog.log("Hello with a new session: dropped \(droppedCount) of \(queuedMessages.count) pending messages of the old session")
            }

            // Re-join if user was in a room. On the main thread, as the rooms manager needs it, and after the queue
            // above was dealt with, so a dropped message can not report its failure for the new join
            if let rejoinToken {
                self.delegate?.externalSignalingControllerWillRejoinCall(self)

                self.rejoinRoomForCall(rejoinToken)
            }

            bgTask.stopBackgroundTask()
        }

        // Notify that we (re)connected, passing whether the session changed. If the session was
        // resumed the server replays the chat relay messages we missed while disconnected (within
        // its ~30s resume window); if a new session was created those messages are lost.
        NotificationCenter.default.post(name: .extSignalingDidReconnect, object: self, userInfo: ["sessionChanged": sessionChanged])
    }

    /// Joins the room of the call again (a new room session, then the join at the signaling server) and tells the
    /// delegate to join the call only if that worked. POST /call without a joined room fails with 404, so a failure
    /// is reported to the delegate, which decides about a repeat (see `retryRejoinRoomForCall`).
    ///
    /// Main thread only. The result of a join which belongs to an older session than the current one (a new hello came
    /// in the meantime, which started a join of its own) is dropped: it is not the answer to the question of the call.
    private func rejoinRoomForCall(_ token: String) {
        dispatchPrecondition(condition: .onQueue(.main))

        let generation = self.rejoinGeneration

        NCRoomsManager.shared.rejoinRoomForCall(token, forAccount: self.account) { [weak self] sessionId, _, error, statusCode, _ in
            // Hop to the main thread, where the generation is counted. Also puts the result behind the code which
            // is on the main thread now, e.g. the drop of the queue in `helloResponseReceived`.
            DispatchQueue.main.async {
                guard let self else { return }

                guard generation == self.rejoinGeneration else {
                    NCLog.log("Ignoring the result of an old re-join of room \(token) (StatusCode \(statusCode))")
                    return
                }

                guard error == nil, sessionId != nil else {
                    NCLog.log("Re-joining room \(token) failed, StatusCode: \(statusCode), Error: \(error.map { NCLog.errorCode($0) } ?? "none")")
                    self.delegate?.externalSignalingController?(self, didFailRejoiningCallWithStatusCode: statusCode, error: error)
                    return
                }

                self.delegate?.externalSignalingControllerShouldRejoinCall(self)
            }
        }
    }

    /// Repeats a failed re-join of the room. Uses the given token, as `currentRoom` is cleared when the join at
    /// the signaling server fails (that forces a reconnect without resuming).
    func retryRejoinRoomForCall(_ token: String) {
        // The rooms manager is used from the main thread, the delegate calls this from the WebRTC queue
        DispatchQueue.main.async {
            // The call was left while the retry was on its way (the delegate is removed then). The room may still be
            // open for a chat, a join would only create a room session nobody needs
            guard self.delegate != nil else {
                NCLog.log("Not retrying to re-join room \(token), the call is over")
                return
            }

            NCLog.log("Retrying to re-join room \(token)")
            self.rejoinRoomForCall(token)
        }
    }

    func errorResponseReceived(messageDict: [AnyHashable: Any]) {
        guard let errorDict = messageDict["error"] as? [AnyHashable: Any],
              let errorCode = errorDict["code"] as? String,
              let messageId = messageDict["id"] as? String
        else { return }

        NCLog.log("Received error response \(errorCode)")

        let errorReason = [errorCode, errorDict["message"] as? String].compactMap { $0 }.joined(separator: ": ")

        DispatchQueue.main.async {
            // Queued before the completion block is executed, so the reason is available there
            if let message = self.messagesWithCompletionBlock.first(where: { messageId == $0.messageId }), message.isJoinMessage {
                self.lastJoinFailureReason = errorReason
            }
        }

        if errorCode == "no_such_session" || errorCode == "too_many_requests" {
            // We could not resume the previous session, but the websocket is still alive -> resend the hello message without a resumeId
            self.resumeId = nil
            self.sendHelloMessage()

            return
        } else if errorCode == "already_joined" {
            // We already joined this room on the signaling server
            guard let detailsDict = errorDict["details"] as? [AnyHashable: Any],
                  let roomDict = detailsDict["room"] as? [AnyHashable: Any],
                  let roomId = roomDict["roomid"] as? String
            else { return }

            // If we are aware that we were in this room before, we should treat this as a success.
            // No room message follows here, so we have to set the joined room ourselves.
            if currentRoom == roomId {
                self.joinedRoomToken = roomId
                self.executeCompletionBlock(forMessageId: messageId, withStatus: .success)
                return
            }
        }

        self.executeCompletionBlock(forMessageId: messageId, withStatus: .applicationError)
    }

    func joinRoom(withRoomId roomId: String, withSessionId sessionId: String, withFederation federationDict: [AnyHashable: Any]?, withCompletionBlock block: ((_ error: NSError?) -> Void)?) {
        if self.disconnected {
            NCLog.log("Joining room \(roomId), but the websocket is disconnected.")
        }

        if self.webSocket == nil {
            NCLog.log("Joining room \(roomId), but the websocket is nil.")
        }

        var messageDict: [AnyHashable: Any] = [
            "type": "room",
            "room": [
                "roomid": roomId,
                "sessionid": sessionId
            ]
        ]

        if let federationDict {
            messageDict = [
                "type": "room",
                "room": [
                    "roomid": roomId,
                    "sessionid": sessionId,
                    "federation": federationDict
                ]
            ]
        }

        self.send(message: messageDict) { task, status in
            if status == .socketError, task == self.webSocket {
                // Reconnect if this is still the same socket we tried to send the message on
                NCLog.log("Reconnect from joinRoom")

                // When we failed to join a room, we shouldn't try to resume a session but instead do a force reconnect
                self.forceReconnect()
            }

            let failureReason = self.lastJoinFailureReason
            self.lastJoinFailureReason = nil

            if status != .success {
                let reason: String

                switch status {
                case .socketError:
                    reason = "websocket error or no answer from the signaling server in time"
                default:
                    reason = failureReason ?? "request was dropped or rejected without an error response"
                }

                NCLog.log("Room request (roomId '\(roomId)') at the signaling server failed: \(reason)")

                block?(NSError(domain: "NCExternalSignalingController", code: status == .socketError ? 1 : 2, userInfo: [NSLocalizedDescriptionKey: reason]))
            } else {
                block?(nil)
            }
        }
    }

    func leaveRoom(withRoomId roomId: String) {
        if self.currentRoom == roomId {
            self.currentRoom = nil
            self.joinedRoomToken = nil
            self.joinRoom(withRoomId: "", withSessionId: "", withFederation: nil, withCompletionBlock: nil)
        } else {
            NCLog.log("External signaling: Not leaving because it's not the room we joined")
        }
    }

    func sendCallMessage(_ message: NCSignalingMessage) {
        let messageDict: [AnyHashable: Any] = [
            "type": "message",
            "message": [
                "recipient": [
                    "type": "session",
                    "sessionid": message.to!
                ],
                "data": message.functionDict()
            ]
        ]

        self.send(message: messageDict, withCompletionBlock: nil)
    }

    func sendSendOfferMessage(withSessionId sessionId: String, andRoomType roomType: String) {
        let messageDict: [AnyHashable: Any] = [
            "type": "message",
            "message": [
                "recipient": [
                    "type": "session",
                    "sessionid": sessionId
                ],
                "data": [
                    "type": "sendoffer",
                    "roomType": roomType
                ]
            ]
        ]

        self.send(message: messageDict, withCompletionBlock: nil)
    }

    func requestOffer(forSessionId sessionId: String, andRoomType roomType: String, withSid sid: String? = nil) {
        // When a "sid" of an existing connection is provided (and the server supports "update-sdp"),
        // the MCU updates that connection with a renegotiation offer instead of creating a new one
        var dataDict: [AnyHashable: Any] = [
            "type": "requestoffer",
            "roomType": roomType
        ]

        if let sid {
            dataDict["sid"] = sid
        }

        let messageDict: [AnyHashable: Any] = [
            "type": "message",
            "message": [
                "recipient": [
                    "type": "session",
                    "sessionid": sessionId
                ],
                "data": dataDict
            ]
        ]

        self.send(message: messageDict, withCompletionBlock: nil)
    }

    func sendRoomMessage(ofType messageType: String, andRoomType roomType: String) {
        let messageDict: [AnyHashable: Any] = [
            "type": "message",
            "message": [
                "recipient": [
                    "type": "room"
                ],
                "data": [
                    "type": messageType,
                    "roomType": roomType
                ]
            ]
        ]

        self.send(message: messageDict, withCompletionBlock: nil)
    }

    func roomMessageReceived(messageDict: [AnyHashable: Any]) {
        guard let roomDict = messageDict["room"] as? [AnyHashable: Any],
              let newRoomId = roomDict["roomid"] as? String
        else { return }

        // Only reset the participant map when the room actually changed
        // Otherwise we would loose participant information for example when a recording is started
        if self.currentRoom != newRoomId {
            self.participantsMap = [:]
            self.currentRoom = newRoomId.isEmpty ? nil : newRoomId
        }

        // Outside the check above on purpose: re-joining after a reconnect leaves `currentRoom`
        // unchanged, but it is the moment we are part of the room on the signaling server again.
        self.joinedRoomToken = newRoomId.isEmpty ? nil : newRoomId

        if let messageId = messageDict["id"] as? String {
            self.executeCompletionBlock(forMessageId: messageId, withStatus: .success)
        }
    }

    func eventMessageReceived(eventDict: [AnyHashable: Any]) {
        let eventTarget = eventDict["target"] as? String

        if eventTarget == "room" {
            self.processRoomEvent(eventDict: eventDict)
        } else if eventTarget == "roomlist" {
            self.processRoomListEvent(eventDict: eventDict)
        } else if eventTarget == "participants" {
            self.processRoomParticipantsEvents(eventDict: eventDict)
        } else {
            NCLog.log("Unsupported event target: \(eventTarget ?? "nil")")
        }
    }

    func processRoomEvent(eventDict: [AnyHashable: Any]) {
        guard let eventType = eventDict["type"] as? String
        else { return }

        if eventType == "join" {
            guard let joinDict = eventDict["join"] as? [[AnyHashable: Any]]
            else { return }

            for participantDict in joinDict {
                let participant = SignalingParticipant(withJoinDictionary: participantDict)

                guard let signalingSessionId = participant.signalingSessionId else { continue }

                self.participantsMap[signalingSessionId] = participant

                if !participant.isFederated, participant.userId == self.account.userId {
                    NCLog.log("App user joined room")
                    continue
                }

                // Only notify if another participant joined the room and not ourselves from a different device
                NCLog.log("Participant joined room")

                guard let currentRoom else { continue }

                var userInfo = [String: String]()
                userInfo["roomToken"] = currentRoom
                userInfo["sessionId"] = signalingSessionId

                NotificationCenter.default.post(name: .extSignalingDidReceiveJoinOfParticipant, object: self, userInfo: userInfo)
            }
        } else if eventType == "leave" {
            guard let leftSessions = eventDict["leave"] as? [String]
            else { return }

            // The call needs to know every session that left, also the ones not in the participants map
            let otherSessions = leftSessions.filter { $0 != self.sessionId }

            if !otherSessions.isEmpty {
                self.delegate?.externalSignalingController(self, didReceiveLeaveOfSessions: otherSessions)
            }

            for sessionId in leftSessions {
                guard let participant = self.getParticipant(fromSessionId: sessionId)
                else { continue }

                self.participantsMap.removeValue(forKey: sessionId)

                guard let currentRoom else { continue }

                if participant.signalingSessionId == self.sessionId || (participant.isFederated && participant.userId == self.account.userId) {
                    // Ignore own session
                    continue
                }

                var userInfo = [String: String]()
                userInfo["roomToken"] = currentRoom
                userInfo["sessionId"] = sessionId

                if let userId = participant.userId {
                    userInfo["userId"] = userId
                }

                NotificationCenter.default.post(name: .extSignalingDidReceiveLeaveOfParticipant, object: self, userInfo: userInfo)
            }
        } else if eventType == "message", let wrappedMessage = eventDict["message"] as? [AnyHashable: Any] {
            self.processRoomMessageEvent(messageDict: wrappedMessage)
        } else if eventType == "switchto", let wrappedMessage = eventDict["switchto"] as? [AnyHashable: Any] {
            self.processSwitchToMessageEvent(messageDict: wrappedMessage)
        } else {
            NCLog.log("Unknown room event: \(eventType)")
        }
    }

    func processRoomMessageEvent(messageDict: [AnyHashable: Any]) {
        guard let dataDict = messageDict["data"] as? [AnyHashable: Any],
              let messageType = dataDict["type"] as? String
        else { return }

        if messageType == "chat" {
            if hasChatRelay,
               let roomToken = messageDict["roomid"] as? String,
               let chatDict = dataDict["chat"] as? [String: Any] {
                if let message = chatDict["comment"] as? [String: Any] {
                    NotificationCenter.default.post(name: .extSignalingDidReceiveChatMessage, object: self, userInfo: ["roomToken": roomToken, "message": message])
                } else if (chatDict["refresh"] as? Bool) == true {
                    NotificationCenter.default.post(name: .extSignalingDidRequestChatRefresh, object: self, userInfo: ["roomToken": roomToken])
                }
            }
        } else if messageType == "recording" {
            self.delegate?.externalSignalingController(self, didReceivedSignalingMessage: messageDict)
        } else {
            NCLog.log("Unknown room message type \(messageType)")
        }
    }

    func processSwitchToMessageEvent(messageDict: [AnyHashable: Any]) {
        let roomToken = messageDict["roomid"] as? String

        if let roomToken, !roomToken.isEmpty {
            self.delegate?.externalSignalingController(self, shouldSwitchToCall: roomToken)
        } else {
            NCLog.log("Unknown switchTo message without a room token")
        }
    }

    func processRoomListEvent(eventDict: [AnyHashable: Any]) {
        print("Refresh room list.")
    }

    func processRoomParticipantsEvents(eventDict: [AnyHashable: Any]) {
        guard let eventType = eventDict["type"] as? String
        else { return }

        if eventType == "update" {
            guard let updateDict = eventDict["update"] as? [AnyHashable: Any]
            else { return }

            var userInfo = [String: Any]()

            if let roomToken = updateDict["roomid"] as? String {
                userInfo["roomToken"] = roomToken
            }

            if let users = updateDict["users"] as? [[AnyHashable: Any]] {
                for userDict in users {
                    if let sessionId = userDict["sessionId"] as? String {
                        self.getParticipant(fromSessionId: sessionId)?.update(withUpdateDictionary: userDict)
                    }
                }

                userInfo["users"] = users
            }

            // Update the participants map before notifying the delegate, so actor information
            // is already available when the participant list is processed (e.g. when peer
            // connections are created and their actors are resolved)
            self.delegate?.externalSignalingController(self, didReceivedParticipantListMessage: updateDict)

            NotificationCenter.default.post(name: .extSignalingDidUpdateParticipants, object: self, userInfo: userInfo)
        } else {
            NCLog.log("Unknown participants event: \(eventType)")
        }
    }

    func messageReceived(messageDict: [AnyHashable: Any]) {
        guard let dataDict = messageDict["data"] as? [AnyHashable: Any],
              let messageType = dataDict["type"] as? String
        else { return }

        if messageType == "startedTyping" || messageType == "stoppedTyping" {
            var userInfo = [String: Any]()

            guard let sender = messageDict["sender"] as? [AnyHashable: Any],
                  let fromSession = sender["sessionid"] as? String,
                  let participant = self.getParticipant(fromSessionId: fromSession),
                  let currentRoom
            else { return }

            userInfo["roomToken"] = currentRoom
            userInfo["sessionId"] = fromSession

            if let fromUser = sender["userid"] as? String {
                userInfo["userId"] = fromUser
            }

            userInfo["isFederated"] = participant.isFederated

            if let displayName = participant.displayName {
                userInfo["displayName"] = displayName
            }

            if messageType == "startedTyping" {
                NotificationCenter.default.post(name: .extSignalingDidReceiveStartedTyping, object: self, userInfo: userInfo)
            } else {
                NotificationCenter.default.post(name: .extSignalingDidReceiveStoppedTyping, object: self, userInfo: userInfo)
            }
        } else {
            self.delegate?.externalSignalingController(self, didReceivedSignalingMessage: messageDict)
        }
    }

    // MARK: - Completion blocks

    func executeCompletionBlock(forMessageId messageId: String, withStatus status: NCExternalSignalingSendMessageStatus) {
        DispatchQueue.main.async {
            if let helloMessage = self.helloMessage, helloMessage.messageId == messageId {
                self.helloMessage?.executeCompletionBlock(withStatus: status)
                self.helloMessage = nil

                return
            }

            if let message = self.messagesWithCompletionBlock.first(where: { messageId == $0.messageId }) {
                message.executeCompletionBlock(withStatus: status)
                self.messagesWithCompletionBlock.removeAll(where: { messageId == $0.messageId })
            }
        }
    }

    // MARK: - CCCertificateDelegate

    public func trustedCerticateAccepted() {
        self.reconnect()
    }

    // MARK: - NSURLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            guard webSocketTask == self.webSocket else { return }

            NCLog.log("WebSocket connected!")
            self.reconnectInterval = self.initialReconnectInterval
            self.sendHelloMessage()
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            guard webSocketTask == self.webSocket else { return }

            NCLog.log("WebSocket didCloseWithCode: \(closeCode) reason: \(reason, default: "Unknown")")
            self.reconnect()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        DispatchQueue.main.async {
            guard task == self.webSocket else { return }

            if let error = error as? URLError, error.code == .serverCertificateUntrusted {
                NCLog.log("WebSocket session didCompleteWithError: \(NCLog.errorCode(error))")

                DispatchQueue.main.async {
                    CCCertificate.sharedManager()
                        .presentViewControllerCertificate(
                            withTitle: error.localizedDescription,
                            viewController: NCUserInterfaceController.sharedInstance().mainViewController,
                            delegate: self)
                }

                return
            }

            if let error {
                NCLog.log("WebSocket session didCompleteWithError: \(NCLog.errorCode(error))")
                self.reconnect()
            }
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The pinning check
        if CCCertificate.sharedManager().checkTrustedChallenge(challenge) {
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func receiveMessage() {
        guard let webSocket else { return }

        let receivingWebSocket = webSocket

        webSocket.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let string):
                    self.handleReceivedMessage(message: string.data(using: .utf8)!)
                case .data(let data):
                    self.handleReceivedMessage(message: data)
                @unknown default:
                    break
                }

                self.receiveMessage()
            case .failure(let error):
                DispatchQueue.main.async {
                    // Only try to reconnect if the webSocket is still the one we tried to receive a message on
                    guard receivingWebSocket == self.webSocket else { return }

                    if let error = error as? URLError, error.code == .serverCertificateUntrusted {
                        // The error is handled in `didCompleteWithError` already, don't try to reconnect from here
                        return
                    }

                    NCLog.log("WebSocket receiveMessageWithCompletionHandler error \(NCLog.errorCode(error))")
                    self.reconnect()
                }
            }
        }
    }

    private func handleReceivedMessage(message: Data) {
        guard let messageDict = self.getWebSocketMessageFromJSONData(jsonData: message),
              let messageType = messageDict["type"] as? String
        else { return }

        if messageType == "hello" {
            self.helloResponseReceived(messageDict: messageDict)
        } else if messageType == "error" {
            self.errorResponseReceived(messageDict: messageDict)
        } else if messageType == "room" {
            self.roomMessageReceived(messageDict: messageDict)
        } else if messageType == "event", let wrappedMessage = messageDict["event"] as? [AnyHashable: Any] {
            self.eventMessageReceived(eventDict: wrappedMessage)
        } else if messageType == "message", let wrappedMessage = messageDict["message"] as? [AnyHashable: Any] {
            self.messageReceived(messageDict: wrappedMessage)
        } else if messageType == "control", let wrappedMessage = messageDict["control"] as? [AnyHashable: Any] {
            self.messageReceived(messageDict: wrappedMessage)
        }

        // Completion block for messageId should have been handled already at this point
        if let messageId = messageDict["id"] as? String {
            self.executeCompletionBlock(forMessageId: messageId, withStatus: .applicationError)
        }
    }

    // MARK: - Utils

    func getParticipant(fromSessionId sessionId: String) -> SignalingParticipant? {
        return self.participantsMap[sessionId]
    }

    func getWebSocketMessageFromJSONData(jsonData: Data) -> [AnyHashable: Any]? {
        let messageDict = try? JSONSerialization.jsonObject(with: jsonData) as? [AnyHashable: Any]
        return messageDict
    }

}
