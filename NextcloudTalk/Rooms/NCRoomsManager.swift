//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public typealias RoomToken = String

@objcMembers
public class NCRoomController {
    public var userSessionId: String
    public var inCall: Bool
    public var inChat: Bool

    init(userSessionId: String, inCall: Bool, inChat: Bool) {
        self.userSessionId = userSessionId
        self.inCall = inCall
        self.inChat = inChat

        AllocationTracker.shared.addAllocation()
    }

    deinit {
        AllocationTracker.shared.removeAllocation()
    }
}

@objcMembers
class NCRoomsManager: NSObject, CallViewControllerDelegate {

    public static let shared = NCRoomsManager()

    private static let statusCodeNoSessionId = 996
    private static let statusCodeFailedToJoinExternal = 997
    private static let statusCodeShouldIgnoreAttemptButJoinedSuccessfully = 998
    private static let statusCodeIgnoreJoinAttempt = 999

    // Re-joining a room for a call is not possible, because the room is not active anymore (it was left meanwhile)
    static let statusCodeRoomNotActive = 995

    private static let answeredCallReadyTimeoutSeconds: TimeInterval = 30

    // Who needs the joined room: the chat, the call, or both. The room is left only when nobody needs it any more
    private struct JoinIntent {
        let accountId: String
        var call: Bool
        var chat: Bool

        mutating func merge(_ other: JoinIntent) {
            call = call || other.call
            chat = chat || other.chat
        }

        mutating func release(call releasedCall: Bool) {
            if releasedCall {
                call = false
            } else {
                chat = false
            }
        }

        var isInUse: Bool {
            return call || chat
        }
    }

    // A join of a room whose exit is still running. It starts as soon as the exit has finished
    private struct PendingJoin {
        let token: String
        var intent: JoinIntent
    }

    // A running re-join of a room. A later attempt for the same room replaces it, see `rejoinRoomForCall`
    private struct Rejoin {
        let attemptId: UUID
        var task: URLSessionTask?
    }

    private struct PendingAnsweredCall {
        let token: String
        let accountId: String
        let hasVideo: Bool
    }

    public var chatViewController: ChatViewController?
    public var callViewController: CallViewController?

    internal var activeRooms = [RoomToken: NCRoomController]()
    internal var joiningAttempts: Int = 0

    // The requests to the server, replaceable in tests
    internal var exitRoomRequest: (String, TalkAccount, @escaping (OcsError?) -> Void) -> URLSessionTask? = { token, account, completionBlock in
        NCAPIController.sharedInstance().exitRoom(token, forAccount: account, completionBlock: completionBlock)
    }

    internal var joinRoomRequest: (String, TalkAccount, @escaping (String?, NCRoom?, OcsError?, Int, String?) -> Void) -> URLSessionTask? = { token, account, completionBlock in
        NCAPIController.sharedInstance().joinRoom(token, forAccount: account, completionBlock: completionBlock)
    }

    // Replaces the lookup of the external signaling controller after a join, tests have no signaling server
    internal var externalSignalingRequest: ((TalkAccount, String, @escaping (NCExternalSignalingController?, SignalingSettings?, Error?) -> Void) -> Void)?

    // How long a join waits for the answer of the external signaling server, replaceable in tests
    internal var externalSignalingJoinTimeout: TimeInterval = 20

    private var joiningRoomToken: String?
    private var joiningIntent: JoinIntent?
    private var leavingRoomTokens = Set<String>()
    private var joiningSessionId: String?
    private var joinRoomTask: URLSessionTask?
    // A re-join of a call has its own state: it runs next to the join of another room
    private var rejoins = [String: Rejoin]()
    // Rooms whose exit must be repeated once the running one has finished, see `endSessionOfLeftRoom`
    private var roomsToExitAgain = Set<String>()
    private var pendingJoin: PendingJoin?
    private var upgradeCallToken: String?
    private var upgradeCallAccountId: String?
    private var pendingToStartCallToken: String?
    private var pendingToStartCallAccountId: String?
    private var pendingToStartCallHasVideo: Bool = false
    private var pendingAnsweredCall: PendingAnsweredCall?
    private var pendingAnsweredCallTimeout: DispatchWorkItem?
    private var highlightMessageDict: [AnyHashable: Any]?
    private var showThreadPushNotification: NCPushNotification?
    private var pendingPrivateReplyInternalId: String?

    // Write ordering for rooms: A response must not overwrite a room with data that is older than what is stored.
    // Request starts and local writes are stamped from one monotonic counter (seconds would not order two requests
    // started within the same second). The state lives in memory only: a response from an earlier process cannot arrive.
    private enum RoomFieldGroup {
        case lastRead
        case commonRead
        case unreadState
        case lastMessage
    }

    private let writeOrderLock = NSLock()
    private var writeOrderClock = 0
    private var appliedRequestStarts = [String: Int]()
    private var localWriteStamps = [String: [RoomFieldGroup: Int]]()

    override init() {
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(joinChatWithLocalNotification(notification:)), name: NSNotification.Name.NCLocalNotificationJoinChat, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinChat(notification:)), name: NSNotification.Name.NCPushNotificationJoinChat, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinAudioCallAccepted(notification:)), name: NSNotification.Name.NCPushNotificationJoinAudioCallAccepted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinVideoCallAccepted(notification:)), name: NSNotification.Name.NCPushNotificationJoinVideoCallAccepted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(selectedUserForChat(notification:)), name: NSNotification.Name.NCSelectedUserForChat, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(roomCreated(notification:)), name: NSNotification.Name.NCRoomCreated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(acceptCallForRoom(notification:)), name: NSNotification.Name.CallKitManagerDidAnswerCall, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(startCallForRoom(notification:)), name: NSNotification.Name.CallKitManagerDidStartCall, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkForCallUpgrades(notification:)), name: NSNotification.Name.CallKitManagerDidEndCall, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinOrCreateChat(notification:)), name: NSNotification.Name.NCChatViewControllerReplyPrivatelyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinChatOfForwardedMessage(notification:)), name: NSNotification.Name.NCChatViewControllerForwardNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinOrCreateChat(notification:)), name: NSNotification.Name.NCChatViewControllerTalkToUserNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinOrCreateChatWithURL(notification:)), name: NSNotification.Name.NCURLWantsToOpenConversation, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(joinChatHighlightingMessage(notification:)), name: NSNotification.Name.NCPresentChatHighlightingMessage, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(connectionStateHasChanged(notification:)), name: NSNotification.Name.NCConnectionStateHasChangedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appStateHasChanged(notification:)), name: NSNotification.Name.NCAppStateHasChangedNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Room

    @objc(updateRoomsAndChatsUpdatingUserStatus: onlyLastModified: withCompletionBlock:)
    public func updateRoomsAndChats(updatingUserStatus updateStatus: Bool, onlyLastModified: Bool, withCompletionBlock completion: ((_ error: Error?) -> Void)?) {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        if onlyLastModified, Int(activeAccount.lastReceivedModifiedSince) == 0 {
            completion?(nil)
            return
        }

        self.updateRooms(updatingUserStatus: updateStatus, onlyLastModified: onlyLastModified) { roomsWithNewMessages, account, error in
            guard error == nil else {
                completion?(error)
                return
            }

            print("Finished rooms update with \(roomsWithNewMessages?.count ?? 0) rooms with new messages")

            // When in low power mode, we only update the conversation list and don't load new messages for each room
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled, NCDatabaseManager.sharedInstance().serverHasTalkCapability(.chatKeepNotifications, forAccountId: account.accountId) else {
                completion?(nil)
                return
            }

            guard let roomsWithNewMessages else {
                completion?(nil)
                return
            }

            let chatUpdateGroup = DispatchGroup()

            for room in roomsWithNewMessages {
                chatUpdateGroup.enter()

                print("Updating room \(room.internalId)")
                var chatController: NCChatController

                if let activeController = self.chatViewController?.chatController, activeController.room.internalId == room.internalId {
                    chatController = activeController
                } else {
                    chatController = NCChatController(for: room)
                }

                chatController.updateHistoryInBackground { _ in
                    print("Finished updating \(room.internalId)")
                    chatUpdateGroup.leave()
                }
            }

            chatUpdateGroup.notify(queue: .main) {
                // Notify backgroundFetch that we're finished
                completion?(nil)
            }
        }
    }

    /// Must be called before the request is started, not when the response arrives
    internal func nextWriteStamp() -> Int {
        writeOrderLock.lock()
        defer { writeOrderLock.unlock() }

        writeOrderClock += 1
        return writeOrderClock
    }

    /// Returns nil if a request that started later was already stored for this room. Otherwise it records this
    /// request and returns the field groups that were written locally after the request started.
    private func claimRoomWrite(internalId: String, requestStart: Int) -> Set<RoomFieldGroup>? {
        writeOrderLock.lock()
        defer { writeOrderLock.unlock() }

        if let appliedStart = appliedRequestStarts[internalId], appliedStart > requestStart {
            return nil
        }

        appliedRequestStarts[internalId] = requestStart

        let stamps = localWriteStamps[internalId] ?? [:]
        return Set(stamps.filter { $0.value > requestStart }.keys)
    }

    private func markLocalWrite(_ groups: Set<RoomFieldGroup>, internalId: String) {
        guard !groups.isEmpty else { return }

        writeOrderLock.lock()
        defer { writeOrderLock.unlock() }

        writeOrderClock += 1

        for group in groups {
            localWriteStamps[internalId, default: [:]][group] = writeOrderClock
        }
    }

    private func appliedRequestStartsSnapshot() -> [String: Int] {
        writeOrderLock.lock()
        defer { writeOrderLock.unlock() }

        return appliedRequestStarts
    }

    /// Used when a write transaction was rolled back. Claims are only made inside write transactions, so none can
    /// have been added by someone else since the snapshot was taken.
    private func restoreAppliedRequestStarts(_ snapshot: [String: Int]) {
        writeOrderLock.lock()
        defer { writeOrderLock.unlock() }

        appliedRequestStarts = snapshot
    }

    /// Rooms stored by a request that started after `requestStart`. A room list from before that must not delete them.
    private func internalIdsStored(after requestStart: Int) -> [String] {
        writeOrderLock.lock()
        defer { writeOrderLock.unlock() }

        return appliedRequestStarts.filter { $0.value > requestStart }.map { $0.key }
    }

    // TODO: Can be removed when ObjC is gone
    @objc(updateRoomsUpdatingUserStatus: onlyLastModified:)
    public func updateRooms(updatingUserStatus updateStatus: Bool, onlyLastModified: Bool) {
        self.updateRooms(updatingUserStatus: updateStatus, onlyLastModified: onlyLastModified, withCompletion: nil)
    }

    @objc(updateRoomsUpdatingUserStatus: onlyLastModified: withCompletionBlock:)
    public func updateRooms(updatingUserStatus updateStatus: Bool, onlyLastModified: Bool, withCompletion completion: ((_ roomsWithNewMessage: [NCRoom]?, _ account: TalkAccount, _ error: Error?) -> Void)? = nil) {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        let lastReceivedModified = Int(activeAccount.lastReceivedModifiedSince) ?? 0
        let modifiedSince = onlyLastModified ? lastReceivedModified : 0
        let requestStart = self.nextWriteStamp()

        NCAPIController.sharedInstance().getRooms(forAccount: activeAccount, updateStatus: updateStatus, modifiedSince: modifiedSince) { rooms, error in
            if let error {
                NCLog.log("Could not update rooms. Error: \(NCLog.errorCode(error))")

                NotificationCenter.default.post(name: .NCRoomsManagerDidUpdateRooms, object: self, userInfo: ["error": error])
                completion?([], activeAccount, error)

                return
            }

            guard let rooms else {
                NotificationCenter.default.post(name: .NCRoomsManagerDidUpdateRooms, object: self)
                completion?([], activeAccount, nil)
                return
            }

            var roomsWithNewMessages = [NCRoom]()

            let bgTask = BGTaskHelper.startBackgroundTask { _ in
                NCLog.log("ExpirationHandler called NCUpdateRoomsTransaction, number of rooms \(rooms.count)")
            }

            defer {
                bgTask.stopBackgroundTask()

                NotificationCenter.default.post(name: .NCRoomsManagerDidUpdateRooms, object: self)
                completion?(roomsWithNewMessages, activeAccount, nil)
            }

            roomsWithNewMessages = self.storeRooms(rooms, forAccount: activeAccount, requestStart: requestStart, onlyLastModified: onlyLastModified, isExpired: { bgTask.isExpired })
        }
    }

    /// Stores a rooms response. Returns the rooms with new messages, or an empty list if the write was cancelled.
    internal func storeRooms(_ rooms: [[String: Any]], forAccount activeAccount: TalkAccount, requestStart: Int, onlyLastModified: Bool, isExpired: () -> Bool) -> [NCRoom] {
        let realm = RLMRealm.default()
        var roomsWithNewMessages = [NCRoom]()

        var startsSnapshot: [String: Int]?

        let committed: Void? = try? realm.transaction {
            // A rolled back transaction must not leave claims behind: they would reject older responses for rooms that were not stored
            let snapshot = self.appliedRequestStartsSnapshot()
            startsSnapshot = snapshot
            let updateTimestamp = Int(Date().timeIntervalSince1970)

            // Add or update rooms
            for roomDict in rooms {
                if isExpired() {
                    roomsWithNewMessages.removeAll()
                    realm.cancelWriteTransaction()
                    self.restoreAppliedRequestStarts(snapshot)
                    return
                }

                let roomContainsNewMessages = self.updateRoom(withDict: roomDict, withAccount: activeAccount, withTimestamp: updateTimestamp, withRealm: realm, withRequestStart: requestStart)

                if roomContainsNewMessages, let room = NCRoom(dictionary: roomDict, andAccountId: activeAccount.accountId) {
                    roomsWithNewMessages.append(room)
                }
            }

            // Only delete rooms if it was a complete rooms update (not using modifiedSince)
            if !onlyLastModified {
                // Delete old rooms, but not the ones that were stored by a request that started after this list
                let newerRoomIds = self.internalIdsStored(after: requestStart)
                let roomsQuery = NSPredicate(format: "accountId = %@ AND lastUpdate != %ld AND NOT (internalId IN %@)", activeAccount.accountId, updateTimestamp, newerRoomIds as NSArray)
                let managedRoomsToBeDeleted = NCRoom.objects(with: roomsQuery)

                // Delete messages, chat blocks and threads from old rooms
                for case let managedRoom as NCRoom in managedRoomsToBeDeleted {
                    if isExpired() {
                        roomsWithNewMessages.removeAll()
                        realm.cancelWriteTransaction()
                        self.restoreAppliedRequestStarts(snapshot)
                        return
                    }

                    let messagesAndBlocksQuery = NSPredicate(format: "accountId = %@ AND token = %@", activeAccount.accountId, managedRoom.token)
                    realm.deleteObjects(NCChatMessage.objects(with: messagesAndBlocksQuery))
                    realm.deleteObjects(NCChatBlock.objects(with: messagesAndBlocksQuery))

                    let threadsQuery = NSPredicate(format: "accountId = %@ AND roomToken = %@", activeAccount.accountId, managedRoom.token)
                    realm.deleteObjects(NCThread.objects(with: threadsQuery))

                    if managedRoom.isFederated {
                        let federatedCapabilities = NSPredicate(format: "accountId = %@ AND remoteServer = %@ AND roomToken = %@", activeAccount.accountId, managedRoom.remoteServer, managedRoom.token)
                        realm.deleteObjects(FederatedCapabilities.objects(with: federatedCapabilities))
                    }
                }

                realm.deleteObjects(managedRoomsToBeDeleted)
            }
        }

        if committed == nil {
            // The commit failed
            roomsWithNewMessages.removeAll()

            if let startsSnapshot {
                self.restoreAppliedRequestStarts(startsSnapshot)
            }
        }

        return roomsWithNewMessages
    }

    public func updateRoom(_ token: String, forAccount account: TalkAccount, withCompletionBlock completion: ((_ roomDict: [String: AnyObject]?, _ error: OcsError?) -> Void)? = nil) {
        let requestStart = self.nextWriteStamp()

        NCAPIController.sharedInstance().getRoom(forAccount: account, withToken: token) { roomDict, error in
            if let error {
                NCLog.log("Could not update room. Error: \(NCLog.errorCode(error))")

                NotificationCenter.default.post(name: .NCRoomsManagerDidUpdateRoom, object: self, userInfo: ["error": error])
                completion?([:], error)

                return
            }

            guard let roomDict else {
                NotificationCenter.default.post(name: .NCRoomsManagerDidUpdateRoom, object: self)
                completion?([:], nil)

                return
            }

            RLMRealm.writeTransaction { realm in
                self.updateRoom(withDict: roomDict, withAccount: account, withTimestamp: Int(Date().timeIntervalSince1970), withRealm: realm, withRequestStart: requestStart)
            }

            var userDict = [String: Any]()

            // TODO: Can be returend from updateRoom(withDict)?
            if let updateRoom = NCDatabaseManager.sharedInstance().room(withToken: token, forAccountId: account.accountId) {
                userDict["room"] = updateRoom
            }

            NotificationCenter.default.post(name: .NCRoomsManagerDidUpdateRoom, object: self, userInfo: userDict)
            completion?(roomDict, error)
        }
    }

    /// Keeps the fields of the stored room that were written locally after the request of `room` started
    private func keepFields(of managedRoom: NCRoom, in room: NCRoom, writtenLocally groups: Set<RoomFieldGroup>) {
        // Keep the fields that were written locally after the request started
        if groups.contains(.lastRead) {
            room.lastReadMessage = managedRoom.lastReadMessage
        }

        if groups.contains(.commonRead) {
            room.lastCommonReadMessage = max(room.lastCommonReadMessage, managedRoom.lastCommonReadMessage)
        }

        if groups.contains(.unreadState) {
            room.unreadMessages = managedRoom.unreadMessages
            room.unreadMention = managedRoom.unreadMention
            room.unreadMentionDirect = managedRoom.unreadMentionDirect
        }

        // The response can already contain a newer message than the stored one, so only keep the stored one if it is not older
        if groups.contains(.lastMessage), managedRoom.lastActivity >= room.lastActivity {
            room.lastMessageId = managedRoom.lastMessageId
            room.lastActivity = managedRoom.lastActivity
        }
    }

    @discardableResult
    public func updateRoom(withDict roomDict: [String: Any], withAccount account: TalkAccount, withTimestamp timestamp: Int, withRealm realm: RLMRealm, withRequestStart requestStart: Int? = nil) -> Bool {
        var roomContainsNewMessages = false

        guard let room = NCRoom(dictionary: roomDict, andAccountId: account.accountId)
        else { return false }

        // A response from a request that started before the stored data was written must not overwrite it
        guard let newerLocalWrites = self.claimRoomWrite(internalId: room.internalId, requestStart: requestStart ?? self.nextWriteStamp())
        else { return false }

        room.lastUpdate = timestamp

        var lastMessage: NCChatMessage?
        let lastMessageDict = roomDict["lastMessage"] as? [AnyHashable: Any]

        if !room.isFederated, let lastMessageDict {
            // TODO: Move handling to NCRoom roomWithDictionary?
            lastMessage = NCChatMessage(dictionary: lastMessageDict, andAccountId: account.accountId)
            room.lastMessageId = lastMessage?.internalId
        }

        if let managedRoom = NCRoom.objects(where: "internalId = %@", room.internalId).firstObject() as? NCRoom {
            self.keepFields(of: managedRoom, in: room, writtenLocally: newerLocalWrites)

            if room.lastActivity > managedRoom.lastActivity {
                roomContainsNewMessages = true
            }

            NCRoom.update(managedRoom, with: room)
        } else {
            realm.add(room)
        }

        if let lastMessage, let lastMessageDict, let internalId = lastMessage.internalId {
            if let managedLastMessage = NCChatMessage.objects(where: "internalId = %@", internalId).firstObject() as? NCChatMessage {
                NCChatMessage.update(managedLastMessage, with: lastMessage, isRoomLastMessage: true)
            } else {
                // Pass an unmanaged copy, since "room" might have been added to realm (and became managed) at this point
                let chatController = NCChatController(for: NCRoom(value: room))
                chatController?.storeMessages([lastMessageDict], with: realm)
            }
        }

        return roomContainsNewMessages
    }

    private func updateRoom(_ room: NCRoom, markingGroups groups: Set<RoomFieldGroup> = [], withBlock block: @escaping (_ managedRoom: NCRoom) -> Void) {
        RLMRealm.writeTransaction { _ in
            if let managedRoom = NCRoom.objects(where: "internalId = %@", room.internalId).firstObject() as? NCRoom {
                self.markLocalWrite(groups, internalId: room.internalId)
                block(managedRoom)
            }
        }
    }

    public func updatePendingMessage(_ message: String, forRoom room: NCRoom) {
        self.updateRoom(room) { managedRoom in
            managedRoom.pendingMessage = message
        }
    }

    public func updateLastReadMessage(_ lastReadMessage: Int, forRoom room: NCRoom) {
        self.updateRoom(room, markingGroups: [.lastRead]) { managedRoom in
            managedRoom.lastReadMessage = lastReadMessage
        }
    }

    public func updateLastCommonReadMessage(_ messageId: Int, forRoom room: NCRoom) {
        self.updateRoom(room, markingGroups: [.commonRead]) { managedRoom in
            if messageId > managedRoom.lastCommonReadMessage {
                managedRoom.lastCommonReadMessage = messageId
            }
        }
    }

    public func setNoUnreadMessages(forRoom room: NCRoom, withLastMessage lastMessage: NCChatMessage?) {
        // The last message is only written (and so only protected) if there is one that may be used
        var groups: Set<RoomFieldGroup> = [.unreadState]
        if lastMessage != nil, !room.isSensitive {
            groups.insert(.lastMessage)
        }

        self.updateRoom(room, markingGroups: groups) { managedRoom in
            managedRoom.unreadMention = false
            managedRoom.unreadMentionDirect = false
            managedRoom.unreadMessages = 0

            if let lastMessage, !room.isSensitive {
                managedRoom.lastMessageId = lastMessage.internalId
                managedRoom.lastActivity = lastMessage.timestamp
            }
        }
    }

    public func deleteRoom(withConfirmation room: NCRoom, withStartedBlock startedBlock: (() -> Void)? = nil, withFinishedBlock finishedBlock: ((_ success: Bool) -> Void)? = nil) {
        self.deleteRoom(withConfirmation: room, withTitle: NSLocalizedString("Delete conversation", comment: ""), withMessage: room.deletionMessage, withKeepOption: false, withStartedBlock: startedBlock, withFinishedBlock: finishedBlock)
    }

    public func deleteEventRoomWithConfirmationAfterCall(_ room: NCRoom) {
        var title = NSLocalizedString("Delete conversation", comment: "")
        var message = NSLocalizedString("The call for this event ended. Do you want to delete this conversation for everyone?", comment: "")

        // A retention message is only returned when auto-deletion is enabled on the server
        let eventRetentionMessage = room.eventRetentionMessage
        let isRetentionEnabled = eventRetentionMessage != nil

        if let eventRetentionMessage {
            title = NSLocalizedString("Do you want to delete this conversation?", comment: "")
            message = eventRetentionMessage
        }

        self.deleteRoom(withConfirmation: room, withTitle: title, withMessage: message, withKeepOption: isRetentionEnabled, withStartedBlock: nil, withFinishedBlock: nil)
    }

    public func deleteClassifiedRoomWithConfirmationAfterCall(_ room: NCRoom) {
        var title = NSLocalizedString("Delete conversation", comment: "")
        var message = NSLocalizedString("The call in this classified conversation ended. Do you want to delete this conversation for everyone?", comment: "")

        // A retention message is only returned when auto-deletion is enabled on the server
        let classifiedRetentionMessage = room.classifiedRetentionMessage
        let isRetentionEnabled = classifiedRetentionMessage != nil

        if let classifiedRetentionMessage {
            title = NSLocalizedString("Do you want to delete this conversation?", comment: "")
            message = classifiedRetentionMessage
        }

        self.deleteRoom(withConfirmation: room, withTitle: title, withMessage: message, withKeepOption: isRetentionEnabled, withStartedBlock: nil, withFinishedBlock: nil)
    }

    // swiftlint:disable:next function_parameter_count
    private func deleteRoom(withConfirmation room: NCRoom, withTitle title: String, withMessage message: String, withKeepOption keepOption: Bool, withStartedBlock startedBlock: (() -> Void)?, withFinishedBlock finishedBlock: ((_ success: Bool) -> Void)?) {
        guard let account = room.account else { return }

        let confirmDialog = UIAlertController(title: title, message: message, preferredStyle: .alert)

        if keepOption {
            let keepAction = UIAlertAction(title: NSLocalizedString("Keep", comment: ""), style: .default) { _ in
                startedBlock?()

                NCAPIController.sharedInstance().unbindRoomFromObject(room.token, forAccount: account) { error in
                    if let error {
                        print("Error unbinding room from object: \(error.localizedDescription)")
                    }

                    finishedBlock?(error == nil)
                }
            }

            confirmDialog.addAction(keepAction)
        }

        // Delete option
        let deleteTitle = keepOption ?
        NSLocalizedString("Delete now", comment: "Delete a conversation right now without waiting for auto-deletion") :
        NSLocalizedString("Delete", comment: "")

        let confirmAction = UIAlertAction(title: deleteTitle, style: .destructive) { _ in
            NCUserInterfaceController.sharedInstance().presentConversationsList()

            startedBlock?()

            NCAPIController.sharedInstance().deleteRoom(room.token, forAccount: account) { error in
                if let error {
                    print("Error deleting room: \(error.localizedDescription)")
                }

                self.updateRooms(updatingUserStatus: true, onlyLastModified: false)

                finishedBlock?(error == nil)
            }
        }

        confirmDialog.addAction(confirmAction)

        // Cancel option
        let cancelTitle = keepOption ? NSLocalizedString("Dismiss", comment: "") : NSLocalizedString("Cancel", comment: "")

        let cancelAction = UIAlertAction(title: cancelTitle, style: .cancel)
        confirmDialog.addAction(cancelAction)

        NCUserInterfaceController.sharedInstance().presentAlertViewController(confirmDialog)
    }

    // MARK: - Chat

    public func startChat(inRoom room: NCRoom) {
        guard self.callViewController == nil else {
            NCLog.log("Not starting chat due to in a call.")
            return
        }

        guard let roomToken = room.token else {
            print("Trying to start a chat in a room, without a token")
            return
        }

        guard let account = room.account else {
            NCLog.log("Trying to startChatInRoom without account")
            return
        }

        if room.isVoiceRoom {
            NCUserInterfaceController.sharedInstance().presentVoiceRoomJoinAlert(for: room)
            return
        }

        if self.activeRooms[roomToken] != nil {
            // Workaround until external signaling supports multi-room
            if let extSignalingController = NCSettingsController.sharedInstance().externalSignalingController(forAccountId: account.accountId) {
                let currentRoom = extSignalingController.currentRoom

                if currentRoom != roomToken {
                    // Since we are going to join another conversation, we don't need to leaveRoom() in extSignalingController.
                    // That's why we set currentRoom = nil, so when leaveRoom() is called in extSignalingController the currentRoom
                    // is no longer the room we want to leave (so no message is sent to the external signaling server).
                    extSignalingController.currentRoom = nil
                }
            }
        }

        if chatViewController == nil || chatViewController?.room.token != roomToken {
            print("Creating new chat view controller.")
            self.chatViewController = ChatViewController(forRoom: room, withAccount: account)

            // Highlight message
            if let highlightToken = self.highlightMessageDict?["token"] as? String, highlightToken == roomToken {
                if let messageId = self.highlightMessageDict?[intForKey: "messageId"] {
                    self.chatViewController?.highlightMessageId = messageId
                    self.highlightMessageDict = nil
                }
            }

            // Open thread view on appear
            if let showThreadPushNotification, showThreadPushNotification.roomToken == roomToken {
                self.chatViewController?.presentThreadOnAppear = showThreadPushNotification.threadId
                self.showThreadPushNotification = nil
            }

            // Quote the original message when the chat was opened via "Reply privately"
            if let pendingPrivateReplyInternalId, room.type == .oneToOne {
                self.chatViewController?.presentPrivateReplyOnAppear = pendingPrivateReplyInternalId
            }
            self.pendingPrivateReplyInternalId = nil

            if let chatViewController = self.chatViewController {
                NCUserInterfaceController.sharedInstance().present(chatViewController)
            }
        } else {
            print("Not creating new chat room: chatViewController for room \(roomToken) does already exist.")

            // Open thread view on appear
            if let showThreadPushNotification, showThreadPushNotification.roomToken == roomToken {
                self.chatViewController?.presentThreadView(for: showThreadPushNotification.threadId)
                self.showThreadPushNotification = nil

                // Still make sure the current room is highlighted
                NCUserInterfaceController.sharedInstance().roomsTableViewController.selectedRoomToken = roomToken
            }

            // Quote the original message when the chat was opened via "Reply privately"
            if let pendingPrivateReplyInternalId, room.type == .oneToOne {
                self.chatViewController?.presentPrivateReply(withInternalId: pendingPrivateReplyInternalId)
            }
            self.pendingPrivateReplyInternalId = nil
        }
    }

    public func startChat(withRoomToken token: String) {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()

        if let room = NCDatabaseManager.sharedInstance().room(withToken: token, forAccountId: activeAccount.accountId) {
            self.startChat(inRoom: room)
        } else {
            // TODO: Show spinner
            NCAPIController.sharedInstance().getRoom(forAccount: activeAccount, withToken: token) { roomDict, error in
                guard error == nil else { return }

                if let room = NCRoom(dictionary: roomDict, andAccountId: activeAccount.accountId) {
                    self.startChat(inRoom: room)
                }
            }
        }
    }

    public func leaveChat(inRoom token: String, forAccount account: TalkAccount) {
        self.activeRooms[token]?.inChat = false
        self.endUse(ofRoom: token, call: false)
        self.leaveRoom(token, forAccount: account, keepingJoinForOtherUse: true)
    }

    /// The chat or the call stops using a room. A join which waits or runs also for the other use goes on without it
    private func endUse(ofRoom token: String, call: Bool) {
        if var pendingJoin = self.pendingJoin, pendingJoin.token == token {
            pendingJoin.intent.release(call: call)
            self.pendingJoin = pendingJoin
        }

        if self.isJoiningRoom(withToken: token), var joiningIntent = self.joiningIntent {
            joiningIntent.release(call: call)
            self.joiningIntent = joiningIntent
        }
    }

    // MARK: - Call

    // swiftlint:disable:next function_parameter_count
    public func startCall(withVideo video: Bool, inRoom room: NCRoom, withVideoEnabled videoEnabled: Bool, asInitiator initiator: Bool, silently: Bool, withRecordingConsent recordingConsent: Bool, withVoiceChatMode voiceChatMode: Bool, answeredIncomingCall: Bool = false) {
        guard self.callViewController == nil else {
            NCLog.log("Not starting call due to in another call.")
            return
        }

        guard let account = room.account else {
            NCLog.log("Trying to start call in room \(room.token ?? "(Unknown)") without account")
            return
        }

        let callViewController = CallViewController(for: room, withAccount: account, audioOnly: !video)
        self.callViewController = callViewController

        callViewController.videoDisabledAtStart = !videoEnabled
        callViewController.receivesVideoInVoiceCall = answeredIncomingCall
        callViewController.voiceChatModeAtStart = voiceChatMode
        callViewController.initiator = initiator
        callViewController.silentCall = silently
        callViewController.recordingConsent = recordingConsent
        callViewController.modalTransitionStyle = .crossDissolve
        callViewController.delegate = self

        let chatViewControllerRoomToken = self.chatViewController?.room.token
        let joiningRoomToken = room.token

        // Workaround until external signaling supports multi-room
        if let extSignalingController = NCSettingsController.sharedInstance().externalSignalingController(forAccountId: account.accountId) {
            let extSignalingRoomToken = extSignalingController.currentRoom

            if extSignalingRoomToken != joiningRoomToken {
                // Since we are going to join another conversation, we don't need to leaveRoom() in extSignalingController.
                // That's why we set currentRoom = nil, so when leaveRoom() is called in extSignalingController the currentRoom
                // is no longer the room we want to leave (so no message is sent to the external signaling server).
                extSignalingController.currentRoom = nil
            }

            // Make sure the external signaling contoller is connected.
            // Could be that the call has been received while the app was inactive or in the background,
            // so the external signaling controller might be disconnected at this point.
            if extSignalingController.disconnected {
                extSignalingController.forceConnect()
            }
        }

        if let chatViewController {
            if chatViewControllerRoomToken == joiningRoomToken {
                // We're in the chat of the room we want to start a call, so stop chat for now
                chatViewController.stopChat()
            } else {
                // We're in a different chat, so make sure we leave the chat and go back to the conversation list
                chatViewController.leaveChat()
                NCUserInterfaceController.sharedInstance().presentConversationsList()
            }
        }

        NCUserInterfaceController.sharedInstance().present(callViewController) {
            self.joinRoom(room.token, forAccountId: account.accountId, forCall: true)
        }
    }

    public func joinCall(withCallToken token: String, withAccountId accountId: String, withVideo video: Bool, asInitiator initiator: Bool, silently: Bool, recordingConsent: Bool) {
        guard let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: accountId) else { return }

        NCAPIController.sharedInstance().getRoom(forAccount: account, withToken: token) { roomDict, error in
            guard error == nil else { return }

            if let room = NCRoom(dictionary: roomDict, andAccountId: account.accountId) {
                CallKitManager.sharedInstance().startCall(room.token, withVideoEnabled: video, andDisplayName: room.displayName, asInitiator: initiator, silently: silently, recordingConsent: recordingConsent, withAccountId: account.accountId)
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    public func startCall(withToken token: String, withAccountId accountId: String, withVideo video: Bool, enabledAtStart videoEnabled: Bool, asInitiator initiator: Bool, silently: Bool, recordingConsent: Bool, withVoiceChatMode voiceChatMode: Bool) {
        guard let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: accountId) else { return }

        NCAPIController.sharedInstance().getRoom(forAccount: account, withToken: token) { roomDict, error in
            guard error == nil else { return }

            if let room = NCRoom(dictionary: roomDict, andAccountId: account.accountId) {
                self.startCall(withVideo: video, inRoom: room, withVideoEnabled: videoEnabled, asInitiator: initiator, silently: silently, withRecordingConsent: recordingConsent, withVoiceChatMode: voiceChatMode)
            }
        }
    }

    public func isCallOngoing(withCallToken token: String) -> Bool {
        guard let callViewController = self.callViewController else { return false }

        return callViewController.room.token == token
    }

    public var areThereActiveCalls: Bool {
        return self.activeRooms.values.contains(where: { $0.inCall })
    }

    public func checkForPendingToStartCalls() {
        if let pendingToStartCallToken = self.pendingToStartCallToken, let pendingToStartCallAccountId = self.pendingToStartCallAccountId {
            // Pending calls can only happen when answering a new call. That's why we start with video disabled at start and in voice chat mode.
            // We also can start call silently because we are joining an already started call so no need to notify.
            self.answerCall(withToken: pendingToStartCallToken, withAccountId: pendingToStartCallAccountId, withVideo: pendingToStartCallHasVideo)
            self.pendingToStartCallToken = nil
        }
    }

    public func upgradeCallToVideoCall(forRoom room: NCRoom) {
        guard let roomToken = room.token else { return }

        if let roomController = activeRooms[roomToken] {
            roomController.inCall = false
        }

        self.upgradeCallToken = roomToken
        self.upgradeCallAccountId = room.accountId
        CallKitManager.sharedInstance().endCall(roomToken, withStatusCode: 0)
    }

    // MARK: - Switch to

    public func prepareSwitchToAnotherRoom(fromRoom token: String, withCompletionBlock completionBlock: @escaping (_ error: Error?) -> Void) {
        if self.chatViewController?.room.token == token {
            self.chatViewController?.leaveChat()
            NCUserInterfaceController.sharedInstance().popToConversationsList()
        }

        // Remove room controller and exit rooms
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()

        if self.activeRooms[token] != nil {
            self.activeRooms.removeValue(forKey: token)
            self.exitRoomTracked(token, forAccount: activeAccount) { error in
                completionBlock(error)
            }
        } else {
            NCLog.log("Couldn't find a room controller from the room we are switching from")
            completionBlock(nil)
        }
    }

    // MARK: CallViewControllerDelegate

    func callViewControllerWantsToBeDismissed(_ viewController: CallViewController) {
        guard self.callViewController == viewController else { return }

        if !viewController.isBeingDismissed {
            viewController.dismiss(animated: true)
        }
    }

    func callViewControllerWantsVideoCallUpgrade(_ viewController: CallViewController) {
        guard self.callViewController == viewController else { return }

        if let room = self.callViewController?.room {
            self.callViewController = nil
            self.upgradeCallToVideoCall(forRoom: room)
        }
    }

    func callViewController(_ viewController: CallViewController, wantsToSwitchFromRoom from: String, toRoom to: String) {
        guard self.callViewController == viewController else { return }

        CallKitManager.sharedInstance().switchCall(from: from, toCall: to)
    }

    func callViewControllerDidFinish(_ viewController: CallViewController) {
        guard self.callViewController == viewController,
              let roomToken = viewController.room.token
        else { return }

        let room = viewController.room
        let account = viewController.account

        self.callViewController = nil
        self.activeRooms[roomToken]?.inCall = false
        self.endUse(ofRoom: roomToken, call: true)
        self.leaveRoom(roomToken, forAccount: account, keepingJoinForOtherUse: true)

        CallKitManager.sharedInstance().endCall(roomToken, withStatusCode: 0)

        if let chatViewController, chatViewController.room.token == roomToken {
            chatViewController.resumeChat()
        }

        // Keep connection alive temporarily when a call was finished while the app in the background
        if UIApplication.shared.applicationState == .background {
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
            appDelegate?.keepExternalSignalingConnectionAliveTemporarily()
        }

        // If this is an event room and we are a moderator, we allow direct deletion
        if room.canModerate, room.isEvent {
            self.deleteEventRoomWithConfirmationAfterCall(room)
        } else if room.canModerate, room.isPendingClassifiedDeletion {
            // Classified conversations are auto-deleted after a call unless kept, so offer the choice right away
            self.deleteClassifiedRoomWithConfirmationAfterCall(room)
        }
    }

    // MARK: - Notifications

    func checkForCallUpgrades(notification: Notification) {
        // The user ended the CallKit call while we were still waiting to show it
        if let pending = self.pendingAnsweredCall, pending.token == notification.userInfo?[stringForKey: "roomToken"] {
            self.pendingAnsweredCall = nil
            self.pendingAnsweredCallTimeout?.cancel()
        }

        if self.pendingToStartCallToken == notification.userInfo?[stringForKey: "roomToken"] {
            self.pendingToStartCallToken = nil
            self.pendingToStartCallAccountId = nil
        }

        guard let upgradeCallToken, let upgradeCallAccountId else { return }
        let token = upgradeCallToken
        let accountId = upgradeCallAccountId

        self.upgradeCallToken = nil
        self.upgradeCallAccountId = nil

        // Add some delay so CallKit doesn't fail requesting new call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.joinCall(withCallToken: token, withAccountId: accountId, withVideo: true, asInitiator: false, silently: true, recordingConsent: true)
        }
    }

    func checkForAccountChange(_ accountId: String?) {
        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()

        guard let accountId, accountId != activeAccount.accountId else { return }

        // Leave chat before changing accounts
        self.chatViewController?.leaveChat()

        // Set notification account active
        NCSettingsController.sharedInstance().setActiveAccountWithAccountId(accountId)
    }

    func acceptCallForRoom(notification: Notification) {
        guard let roomToken = notification.userInfo?[stringForKey: "roomToken"],
              let waitForcallEnd = notification.userInfo?[boolForKey: "waitForCallEnd"],
              let hasVideo = notification.userInfo?[boolForKey: "hasVideo"],
              let accountId = notification.userInfo?[stringForKey: "accountId"]
        else { return }

        let activeCalls = self.areThereActiveCalls

        if !waitForcallEnd || (!activeCalls && leavingRoomTokens.isEmpty) {
            self.answerCall(withToken: roomToken, withAccountId: accountId, withVideo: hasVideo)
        } else {
            self.pendingToStartCallToken = roomToken
            self.pendingToStartCallHasVideo = hasVideo
            self.pendingToStartCallAccountId = accountId
        }
    }

    private func answerCall(withToken token: String, withAccountId accountId: String, withVideo video: Bool) {
        guard CallKitManager.sharedInstance().hasCall(forToken: token) else {
            NCLog.log("Not showing the call screen for room \(token), the CallKit call is gone")
            return
        }

        let shownCallToken = self.callViewController?.room.token

        switch AnsweredCallPolicy.action(appState: NCConnectionController.shared.appState, shownCallToken: shownCallToken, answeredToken: token) {
        case .keep:
            // The call screen of this room is already shown, the CallKit call belongs to it
            return
        case .fail:
            self.failAnsweredCall(withToken: token, reason: "another call is shown")
        case .wait:
            // The app was probably started by the VoIP push and is not ready yet, so wait for it like the other CallKit entry points
            NCLog.log("Answered call for token \(token) is waiting for the app to become ready")
            self.pendingAnsweredCall = PendingAnsweredCall(token: token, accountId: accountId, hasVideo: video)
            self.pendingAnsweredCallTimeout?.cancel()

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.pendingAnsweredCall else { return }
                self.pendingAnsweredCall = nil
                self.failAnsweredCall(withToken: pending.token, reason: "app is not ready")
            }

            self.pendingAnsweredCallTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.answeredCallReadyTimeoutSeconds, execute: timeout)
        case .start:
            self.startAnsweredCall(withToken: token, withAccountId: accountId, withVideo: video)
        }
    }

    private func startAnsweredCall(withToken token: String, withAccountId accountId: String, withVideo video: Bool) {
        guard let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: accountId) else {
            self.failAnsweredCall(withToken: token, reason: "account not found")
            return
        }

        NCAPIController.sharedInstance().getRoom(forAccount: account, withToken: token) { roomDict, error in
            guard error == nil, let room = NCRoom(dictionary: roomDict, andAccountId: account.accountId) else {
                self.failAnsweredCall(withToken: token, reason: "room could not be retrieved")
                return
            }

            guard CallKitManager.sharedInstance().hasCall(forToken: token) else {
                NCLog.log("Not showing the call screen for room \(token), the CallKit call is gone")
                return
            }

            // A call screen might have been presented while the room was requested
            switch AnsweredCallPolicy.action(appState: .ready, shownCallToken: self.callViewController?.room.token, answeredToken: token) {
            case .fail:
                self.failAnsweredCall(withToken: token, reason: "another call is shown")
                return
            case .keep, .wait:
                return
            case .start:
                break
            }

            // The answer may come before CallKit knows the kind of the call (or its request failed), but this response is fresh
            let callFlag = (roomDict?["callFlag"] as? Int).map { CallFlag(rawValue: $0) }
            let hasCallFlags = NCDatabaseManager.sharedInstance().serverHasTalkCapability(.callFlags, forAccountId: accountId)
            let callType = CallVideoPolicy.callType(callFlag: callFlag, hasCallFlagsCapability: hasCallFlags)
            let startsAsVideoCall = CallVideoPolicy.startsAsVideoCall(callKitHasVideo: video, serverCallType: callType)

            // Calls that have been answered start with video disabled by default, in voice chat mode and silently (without notification).
            // They receive video also when they are voice calls, because their kind can be unknown or outdated when they are answered.
            self.startCall(withVideo: startsAsVideoCall, inRoom: room, withVideoEnabled: false, asInitiator: false, silently: true, withRecordingConsent: false, withVoiceChatMode: true, answeredIncomingCall: true)
        }
    }

    private func failAnsweredCall(withToken token: String, reason: String) {
        NCLog.log("Failed to show the call screen for the answered call in room \(token): \(reason)")
        CallKitManager.sharedInstance().endAnsweredCall(withToken: token)
    }

    func appStateHasChanged(notification: Notification) {
        // Read the state from the notification, accessing NCConnectionController.shared here would be recursive while it is initializing
        guard let pending = self.pendingAnsweredCall,
              let rawAppState = (notification.userInfo?["appState"] as? NSNumber)?.intValue,
              AppState(rawValue: rawAppState) == .ready
        else { return }

        self.pendingAnsweredCall = nil
        self.pendingAnsweredCallTimeout?.cancel()
        self.answerCall(withToken: pending.token, withAccountId: pending.accountId, withVideo: pending.hasVideo)
    }

    func startCallForRoom(notification: Notification) {
        guard let roomToken = notification.userInfo?[stringForKey: "roomToken"],
              let isVideoEnabled = notification.userInfo?[boolForKey: "isVideoEnabled"],
              let initiator = notification.userInfo?[boolForKey: "initiator"],
              let silentCall = notification.userInfo?[boolForKey: "silentCall"],
              let recordingConsent = notification.userInfo?[boolForKey: "recordingConsent"],
              let accountId = notification.userInfo?[stringForKey: "accountId"]
        else { return }

        self.startCall(withToken: roomToken, withAccountId: accountId, withVideo: isVideoEnabled, enabledAtStart: true, asInitiator: initiator, silently: silentCall, recordingConsent: recordingConsent, withVoiceChatMode: false)
    }

    func joinAudioCallAccepted(notification: Notification) {
        guard let pushNotification = notification.userInfo?["pushNotification"] as? NCPushNotification
        else { return }

        self.checkForAccountChange(pushNotification.accountId)
        self.joinCall(withCallToken: pushNotification.roomToken, withAccountId: pushNotification.accountId, withVideo: false, asInitiator: false, silently: true, recordingConsent: false)
    }

    func joinVideoCallAccepted(notification: Notification) {
        guard let pushNotification = notification.userInfo?["pushNotification"] as? NCPushNotification
        else { return }

        self.checkForAccountChange(pushNotification.accountId)
        self.joinCall(withCallToken: pushNotification.roomToken, withAccountId: pushNotification.accountId, withVideo: true, asInitiator: false, silently: true, recordingConsent: false)
    }

    func joinChat(notification: Notification) {
        guard let pushNotification = notification.userInfo?["pushNotification"] as? NCPushNotification
        else { return }

        self.checkForAccountChange(pushNotification.accountId)

        if pushNotification.threadId > 0 {
            self.showThreadPushNotification = pushNotification
        }

        self.startChat(withRoomToken: pushNotification.roomToken)
    }

    func joinOrCreateChat(withUser userId: String, usingAccountId accountId: String) {
        let accountRooms = NCDatabaseManager.sharedInstance().roomsForAccountId(accountId, withRealm: nil)

        if let room = accountRooms.first(where: { $0.type == .oneToOne && $0.name == userId }) {
            // Room already exists -> join the room
            self.startChat(inRoom: room)
            return
        }

        // Did not find a one-to-one room for this user -> create a new one
        guard let activeAccount = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: accountId) else { return }

        NCAPIController.sharedInstance().createRoom(forAccount: activeAccount, withInvite: userId, ofType: .oneToOne, andName: nil) { room, error in
            guard error == nil, let room else {
                print("Failed creating room with \(userId)")
                return
            }

            self.startChat(withRoomToken: room.token)
        }
    }

    func joinOrCreateChat(notification: Notification) {
        guard let actorId = notification.userInfo?[stringForKey: "actorId"],
              let accountId = notification.userInfo?[stringForKey: "accountId"]
        else { return }

        // Set for a "Reply privately" action, so the opened one-to-one chat quotes the original message
        self.pendingPrivateReplyInternalId = notification.userInfo?[stringForKey: "parentInternalId"]

        self.joinOrCreateChat(withUser: actorId, usingAccountId: accountId)
    }

    func joinOrCreateChatWithURL(notification: Notification) {
        guard let accountId = notification.userInfo?[stringForKey: "accountId"]
        else { return }

        let withUser = notification.userInfo?[stringForKey: "withUser"]
        let roomToken = notification.userInfo?[stringForKey: "withRoomToken"]

        self.checkForAccountChange(accountId)

        if let withUser {
            self.joinOrCreateChat(withUser: withUser, usingAccountId: accountId)
        } else if let roomToken {
            self.startChat(withRoomToken: roomToken)
        }
    }

    func joinChatOfForwardedMessage(notification: Notification) {
        guard let accountId = notification.userInfo?[stringForKey: "accountId"],
              let roomToken = notification.userInfo?[stringForKey: "token"]
        else { return }

        self.checkForAccountChange(accountId)
        self.startChat(withRoomToken: roomToken)
    }

    func joinChatWithLocalNotification(notification: Notification) {
        guard let accountId = notification.userInfo?[stringForKey: "accountId"],
              let roomToken = notification.userInfo?[stringForKey: "roomToken"]
        else { return }

        self.checkForAccountChange(accountId)
        self.startChat(withRoomToken: roomToken)

        // In case this notification occurred because of a failed chat-sending event, make sure the text is not lost
        // Note: This will override any stored pending message
        if let responseUserText = notification.userInfo?[stringForKey: "responseUserText"], let chatViewController {
            chatViewController.setChatMessage(responseUserText)
        }
    }

    func joinChatHighlightingMessage(notification: Notification) {
        guard let roomToken = notification.userInfo?[stringForKey: "token"]
        else { return }

        self.highlightMessageDict = notification.userInfo
        self.startChat(withRoomToken: roomToken)
    }

    func selectedUserForChat(notification: Notification) {
        guard let roomToken = notification.userInfo?[stringForKey: "token"]
        else { return }

        self.startChat(withRoomToken: roomToken)
    }

    func roomCreated(notification: Notification) {
        guard let roomToken = notification.userInfo?[stringForKey: "token"]
        else { return }

        self.startChat(withRoomToken: roomToken)
    }

    func connectionStateHasChanged(notification: Notification) {
        guard let rawConnectionState = notification.userInfo?["connectionState"] as? Int,
              let connectionState = ConnectionState(rawValue: rawConnectionState)
        else { return }

        // Try to send offline message when the connection state changes to connected again
        if connectionState == .connected {
            self.resendOfflineMessagesWithCompletionBlock(nil)
        }
    }

    // MARK: - Join/Leave room

    public func joinRoom(_ token: String, forAccountId accountId: String, forCall call: Bool) {
        NCLog.log("Joining room \(token) for call \(call)")

        let intent = JoinIntent(accountId: accountId, call: call, chat: !call)

        // A second join of the same room must not replace the first one, the room is needed for both. So the join
        // which waits for an exit or runs already gets the flag of the second one and a single session serves both
        if var pendingJoin = self.pendingJoin, pendingJoin.token == token, pendingJoin.intent.accountId == accountId {
            NCLog.log("Room \(token) is already waiting to be joined, adding the new use to it")

            pendingJoin.intent.merge(intent)
            self.pendingJoin = pendingJoin
            return
        }

        if self.isJoiningRoom(withToken: token), var joiningIntent = self.joiningIntent, joiningIntent.accountId == accountId {
            NCLog.log("Room \(token) is already being joined, adding the new use to it")

            joiningIntent.merge(intent)
            self.joiningIntent = joiningIntent
            return
        }

        // Clean up joining room flag and attempts. A newer join replaces a join which waits for an exit
        if let pendingJoin = self.pendingJoin {
            NCLog.log("Dropping the join of room \(pendingJoin.token), which waited for an exit")
            self.pendingJoin = nil
        }

        self.joiningRoomToken = nil
        self.joiningIntent = nil
        self.joiningSessionId = nil
        self.joiningAttempts = 0
        self.joinRoomTask?.cancel()

        // The exit request can't be revoked: if it was already sent, the server handles it after our join and would
        // end the new session. So wait until the exit has finished and join then
        if self.isLeavingRoom(withToken: token) {
            NCLog.log("Room \(token) is still being left, joining after the exit finished")

            self.pendingJoin = PendingJoin(token: token, intent: intent)
            return
        }

        self.joinRoomHelper(token, forAccountId: accountId, intent: intent)
    }

    private func joinRoomHelper(_ token: String, forAccountId accountId: String, intent: JoinIntent) {
        var userInfo: [AnyHashable: Any] = [:]
        userInfo["token"] = token
        userInfo["accountId"] = accountId

        if let roomController = self.activeRooms[token] {
            NCLog.log("JoinRoomHelper: Found active room controller")

            if intent.call {
                roomController.inCall = true
            }

            if intent.chat {
                roomController.inChat = true
            }

            userInfo["roomController"] = roomController
            NotificationCenter.default.post(name: .NCRoomsManagerDidJoinRoom, object: self, userInfo: userInfo)

            return
        }

        guard let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: accountId) else {
            NCLog.log("Trying to join room without existing account")
            return
        }

        self.joiningRoomToken = token
        self.joiningIntent = intent

        self.joinRoomHelper(token, withAccount: account, forCall: intent.call) { sessionId, room, error, statusCode, statusReason in
            if statusCode == NCRoomsManager.statusCodeIgnoreJoinAttempt {
                // Not joining the room any more. Ignore response
                return
            } else if statusCode == NCRoomsManager.statusCodeShouldIgnoreAttemptButJoinedSuccessfully {
                // We joined the Nextcloud server successfully, but locally we are not trying to join that room anymore.
                // We need to make sure that we leave the room on the server again to not leave an active session.
                // Do a direct API call here, as the join method will check for an active NCRoomController, which we don't have

                if !self.isLeavingRoom(withToken: token) {
                    self.exitRoomTracked(token, forAccount: account) { _ in }
                }

                return
            }

            if error == nil, let sessionId {
                // Uses of the room which were added while the join was running are part of the intent
                let usage = self.currentJoinIntent(forAccountId: accountId) ?? intent
                let controller = NCRoomController(userSessionId: sessionId, inCall: usage.call, inChat: usage.chat)
                userInfo["roomController"] = controller

                if let room {
                    userInfo["room"] = room
                }

                // Set room as active
                self.activeRooms[token] = controller
            } else {
                // Some request are not recoverable by a retry - don't even try it
                let nonRecoverableErrorCodes = [403, 429, 503]
                if self.joiningAttempts < 3 && !nonRecoverableErrorCodes.contains(statusCode) {
                    NCLog.log("Error joining room, retrying. \(self.joiningAttempts)")
                    self.joiningAttempts += 1
                    self.joinRoomHelper(token, forAccountId: accountId, intent: self.currentJoinIntent(forAccountId: accountId) ?? intent)
                    return
                }

                // Add error to user info
                userInfo["error"] = error
                userInfo["statusCode"] = statusCode
                userInfo["errorReason"] = self.getJoinRoomErrorReason(statusCode, andReason: statusReason)

                if statusCode == 403, statusReason == "ban" {
                    userInfo["isBanned"] = true
                }

                NCLog.log("Could not join room. Status code: \(statusCode). Error: \(error.map { NCLog.errorCode($0) } ?? "none")")
            }

            self.joiningRoomToken = nil
            self.joiningIntent = nil
            self.joiningSessionId = nil
            NotificationCenter.default.post(name: .NCRoomsManagerDidJoinRoom, object: self, userInfo: userInfo)
        }
    }

    // The intent of the running join, if it belongs to the account (the same room token can exist on two accounts)
    private func currentJoinIntent(forAccountId accountId: String) -> JoinIntent? {
        guard let joiningIntent = self.joiningIntent, joiningIntent.accountId == accountId else { return nil }

        return joiningIntent
    }

    private func isJoiningRoom(withToken token: String) -> Bool {
        guard let joiningRoomToken = self.joiningRoomToken else { return false }

        return joiningRoomToken == token
    }

    /// A request which has no error, or was cancelled, can have been handled by the server: the session which it created
    /// is not known. A request which failed was not handled (assumed: a timeout can also hit a request which arrived)
    private func mayHaveCreatedSession(_ error: OcsError?) -> Bool {
        guard let error else { return true }

        return error.underlyingError.code == NSURLErrorCancelled
    }

    private func isLeavingRoom(withToken token: String) -> Bool {
        return self.leavingRoomTokens.contains(token)
    }

    /// Exits a room on the server and remembers it until the server answered, so a join of the room can wait for it.
    /// The completion block runs first, a join which was waiting for this exit starts afterwards.
    private func exitRoomTracked(_ token: String, forAccount account: TalkAccount, completionBlock: @escaping (_ error: OcsError?) -> Void) {
        self.leavingRoomTokens.insert(token)

        let task = self.exitRoomRequest(token, account) { error in
            self.leavingRoomTokens.remove(token)

            // A request of a re-join which was still on its way can have been handled after this exit. Exit again
            // (before the answer is reported, so nothing starts while this exit runs)
            if self.roomsToExitAgain.remove(token) != nil, self.isRoomLeftAndUnused(token) {
                NCLog.log("Exiting room \(token) again, a request of a re-join was handled after the first exit")
                self.exitRoomTracked(token, forAccount: account) { _ in }
            }

            completionBlock(error)

            if self.leavingRoomTokens.isEmpty {
                // A call can wait for every exit, not only for the ones of leaveRoom
                self.checkForPendingToStartCalls()
            }

            self.startPendingJoin(forToken: token)
        }

        if task == nil {
            // No request was made, so there is no response to wait for
            self.leavingRoomTokens.remove(token)
        }
    }

    private func startPendingJoin(forToken token: String) {
        guard let pendingJoin = self.pendingJoin, pendingJoin.token == token, !self.isLeavingRoom(withToken: token) else { return }

        self.pendingJoin = nil
        self.joinRoomHelper(pendingJoin.token, forAccountId: pendingJoin.intent.accountId, intent: pendingJoin.intent)
    }

    /// Nobody holds the room: no room controller, no join which runs or waits for an exit
    private func isRoomLeftAndUnused(_ token: String) -> Bool {
        return self.activeRooms[token] == nil && !self.isJoiningRoom(withToken: token) && self.pendingJoin?.token != token
    }

    private func isJoiningRoom(withSessionId sessionId: String) -> Bool {
        guard let joiningSessionId = self.joiningSessionId else { return false }

        return joiningSessionId == sessionId
    }

    private func joinRoomHelper(_ token: String, withAccount account: TalkAccount, forCall call: Bool, completionBlock: @escaping (_ sessionId: String?, _ room: NCRoom?, _ error: Error?, _ statusCode: Int, _ statusReason: String?) -> Void) {
        self.joinRoomTask = self.joinRoomRequest(token, account, { sessionId, room, error, statusCode, statusReason in
            if !self.isJoiningRoom(withToken: token) {
                // Treat a cancelled request as success, as we can't determine if the request was processed on the server or not
                if !self.mayHaveCreatedSession(error) {
                    NCLog.log("Not joining the room any more. Ignore attempt as the join request failed anyway.")
                    completionBlock(nil, nil, nil, NCRoomsManager.statusCodeIgnoreJoinAttempt, nil)
                } else {
                    NCLog.log("Not joining the room any more, but our join request was successful.")
                    completionBlock(nil, nil, nil, NCRoomsManager.statusCodeShouldIgnoreAttemptButJoinedSuccessfully, nil)
                }

                return
            }

            // Failed to join room in NC
            if let error {
                completionBlock(nil, nil, error, statusCode, statusReason)
                return
            }

            // While we received a successful http status code, we did not receive a sessionId -> treat it as an error
            guard let sessionId else {
                let error = NSError(domain: NSCocoaErrorDomain, code: NCRoomsManager.statusCodeNoSessionId)
                completionBlock(nil, nil, error, NCRoomsManager.statusCodeNoSessionId, nil)
                return
            }

            NCLog.log("Joined room \(token) in NC successfully")

            // Remember the latest sessionId we're using to join a room, to be able to check when joining the external signaling server
            self.joiningSessionId = sessionId

            self.getExternalSignalingHelper(for: account, forRoom: token) { extSignalingController, signalingSettings, error in
                guard error == nil else {
                    // There was an error to ensure we have the correct signaling settings for joining a federated conversation
                    completionBlock(nil, nil, nil, NCRoomsManager.statusCodeFailedToJoinExternal, nil)
                    return
                }

                guard let extSignalingController else {
                    // Joined room in NC successfully and no external signaling server configured.
                    completionBlock(sessionId, room, nil, 0, nil)
                    return
                }

                NCLog.log("Trying to join room \(token) in external signaling server...")

                let federation = signalingSettings?.getFederationJoinDictionary()

                self.joinExternalSignaling(extSignalingController, token: token, sessionId: sessionId, federation: federation) { error in
                    // If the sessionId is not the same anymore we tried to join with, we either already left again before
                    // joining the external signaling server succeeded, or we already have another join in process
                    if !self.isJoiningRoom(withToken: token) {
                        NCLog.log("Not joining the room any more. Ignore external signaling completion block, but we joined the Nextcloud instance before.")
                        completionBlock(nil, nil, nil, NCRoomsManager.statusCodeShouldIgnoreAttemptButJoinedSuccessfully, nil)
                        return
                    }

                    if !self.isJoiningRoom(withSessionId: sessionId) {
                        NCLog.log("Joining the same room with a different sessionId. Ignore external signaling completion block.")
                        completionBlock(nil, nil, nil, NCRoomsManager.statusCodeIgnoreJoinAttempt, nil)
                        return
                    }

                    if error == nil {
                        NCLog.log("Joined room \(token) in external signaling server successfully.")
                        completionBlock(sessionId, room, nil, 0, nil)
                    } else {
                        NCLog.log("Failed joining room \(token) in external signaling server.")
                        completionBlock(nil, nil, error, statusCode, statusReason)
                    }
                }
            }
        })
    }

    /// Joins the room at the external signaling server and waits for the answer for a limited time. The answer can get
    /// lost (the room message waits in the queue of a connection which has no hello, and a newer room message drops it
    /// without a result), and a join which waits for ever keeps the room for the call for ever.
    private func joinExternalSignaling(_ controller: NCExternalSignalingController, token: String, sessionId: String, federation: [AnyHashable: Any]?, completion: @escaping (NSError?) -> Void) {
        var answered = false

        let answer: (NSError?) -> Void = { error in
            guard !answered else { return }

            answered = true
            completion(error)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + self.externalSignalingJoinTimeout) {
            guard !answered else { return }

            NCLog.log("No answer of the external signaling server to the join of room \(token) in time")
            answer(NSError(domain: NSCocoaErrorDomain, code: NCRoomsManager.statusCodeFailedToJoinExternal))
        }

        controller.joinRoom(withRoomId: token, withSessionId: sessionId, withFederation: federation, withCompletionBlock: answer)
    }

    private func getExternalSignalingHelper(for account: TalkAccount, forRoom token: String, withCompletion completion: @escaping (NCExternalSignalingController?, SignalingSettings?, Error?) -> Void) {
        if let externalSignalingRequest {
            externalSignalingRequest(account, token, completion)
            return
        }

        let room = NCDatabaseManager.sharedInstance().room(withToken: token, forAccountId: account.accountId)

        guard room?.supportsFederatedCalling ?? false else {
            // No federated room -> just ensure that we have a signaling configuration and a potential external signaling controller
            NCSettingsController.sharedInstance().ensureSignalingConfiguration(forAccountId: account.accountId, with: nil) { extSignalingController in
                completion(extSignalingController, nil, nil)
            }

            return
        }

        // This is a federated conversation (with federated calling supported), so we require signaling settings for joining
        // the external signaling controller
        NCAPIController.sharedInstance().getSignalingSettings(for: account, forRoom: token) { signalingSettings, _ in
            guard let signalingSettings else {
                // We need to fail if we are unable to get signaling settings for a federation conversation
                completion(nil, nil, NSError(domain: NSCocoaErrorDomain, code: 0))
                return
            }

            NCSettingsController.sharedInstance().ensureSignalingConfiguration(forAccountId: account.accountId, with: signalingSettings) { extSignalingController in
                completion(extSignalingController, signalingSettings, nil)
            }
        }
    }

    public func rejoinRoomForCall(_ token: String, forAccount account: TalkAccount, completionBlock: @escaping (_ sessionId: String?, _ room: NCRoom?, _ error: Error?, _ statusCode: Int, _ statusReason: String?) -> Void) {
        NCLog.log("Rejoining room \(token)")

        guard let roomController = self.activeRooms[token] else {
            // Report it, otherwise the caller waits for the answer forever (the call stays "reconnecting")
            NCLog.log("Could not re-join room \(token), the room is not active anymore")
            completionBlock(nil, nil, NSError(domain: NSCocoaErrorDomain, code: 0), NCRoomsManager.statusCodeRoomNotActive, nil)
            return
        }

        // A second re-join of the same room replaces the first one. Its request is cancelled (the caller gets the
        // cancellation as the result), so two requests do not create two room sessions of which one stays behind.
        // Every room has its own re-join, a re-join of another room does not hide this one
        if let running = self.rejoins[token] {
            NCLog.log("Re-joining room \(token) while a re-join of it is running, cancelling the earlier one")
            running.task?.cancel()
        }

        let attemptId = UUID()
        self.rejoins[token] = Rejoin(attemptId: attemptId, task: nil)

        let task = self.joinRoomRequest(token, account, { sessionId, room, error, statusCode, statusReason in
            // The result of a cancelled earlier attempt must not clear what the later attempt has set
            defer {
                if self.rejoins[token]?.attemptId == attemptId {
                    self.rejoins.removeValue(forKey: token)
                }
            }

            // The room was left (or joined again) while the request was on its way. The call is over, so the result
            // is not for the call
            guard self.activeRooms[token] === roomController else {
                self.endSessionOfLeftRoom(token, forAccount: account, error: error)

                if let error {
                    completionBlock(nil, nil, error, statusCode, statusReason)
                } else {
                    completionBlock(nil, nil, NSError(domain: NSCocoaErrorDomain, code: 0), NCRoomsManager.statusCodeRoomNotActive, nil)
                }

                return
            }

            if error == nil, let sessionId {
                roomController.userSessionId = sessionId
                roomController.inCall = true

                self.getExternalSignalingHelper(for: account, forRoom: token) { extSignalingController, signalingSettings, error in
                    guard error == nil else {
                        // There was an error to ensure we have the correct signaling settings for joining a federated conversation
                        completionBlock(nil, nil, nil, NCRoomsManager.statusCodeFailedToJoinExternal, nil)
                        return
                    }

                    guard let extSignalingController else {
                        // Joined room in NC successfully and no external signaling server configured.
                        completionBlock(sessionId, room, nil, 0, nil)
                        return
                    }

                    let federation = signalingSettings?.getFederationJoinDictionary()

                    self.joinExternalSignaling(extSignalingController, token: token, sessionId: sessionId, federation: federation) { error in
                        // The room was left while the signaling server was asked. The exit of that leave ends the session
                        guard self.activeRooms[token] === roomController else {
                            NCLog.log("Room \(token) was left while re-joining it at the signaling server")
                            completionBlock(nil, nil, NSError(domain: NSCocoaErrorDomain, code: 0), NCRoomsManager.statusCodeRoomNotActive, nil)
                            return
                        }

                        if error == nil {
                            NCLog.log("Re-Joined room \(token) in external signaling server successfully.")
                            completionBlock(sessionId, room, nil, 0, nil)
                        } else {
                            NCLog.log("Failed re-joining room \(token) in external signaling server.")
                            completionBlock(nil, nil, error, statusCode, statusReason)
                        }
                    }
                }
            } else {
                NCLog.log("Could not re-join room \(token). Status code: \(statusCode). Error: \(error.map { NCLog.errorCode($0) } ?? "none")")
                completionBlock(nil, nil, error, statusCode, statusReason)
            }
        })

        // The answer can come before the task is stored, then the attempt is finished already
        if self.rejoins[token]?.attemptId == attemptId {
            self.rejoins[token]?.task = task
        }
    }

    /// The request of a re-join of a room which was left in the meantime can have created a session. The leave
    /// cancelled the request, but a cancel does not revoke it, so the server can handle it after the exit of the leave
    /// and end up with a session which nobody uses. Exit once more, after the running exit if there is one.
    /// A room which is joined (or waits for an exit to be joined) again needs no exit: the join replaces the session.
    private func endSessionOfLeftRoom(_ token: String, forAccount account: TalkAccount, error: OcsError?) {
        guard self.mayHaveCreatedSession(error), self.isRoomLeftAndUnused(token) else { return }

        if self.isLeavingRoom(withToken: token) {
            NCLog.log("Re-join of room \(token) ended after the room was left, exiting again after the running exit")
            self.roomsToExitAgain.insert(token)
        } else {
            NCLog.log("Re-join of room \(token) ended after the room was left, exiting the session which it can have created")
            self.exitRoomTracked(token, forAccount: account) { _ in }
        }
    }

    public func leaveRoom(_ token: String, forAccount account: TalkAccount) {
        self.leaveRoom(token, forAccount: account, keepingJoinForOtherUse: false)
    }

    private func leaveRoom(_ token: String, forAccount account: TalkAccount, keepingJoinForOtherUse: Bool) {
        // Leaving a room we wait to join -> the join is not needed any more, unless the other use still needs it
        if let pendingJoin = self.pendingJoin, pendingJoin.token == token, !(keepingJoinForOtherUse && pendingJoin.intent.isInUse) {
            NCLog.log("Leaving room \(token), but the join still waits for an exit -> drop it")

            self.pendingJoin = nil
        }

        // Check if leaving the room we are joining
        if self.isJoiningRoom(withToken: token), !(keepingJoinForOtherUse && self.joiningIntent?.isInUse == true) {
            NCLog.log("Leaving room \(token), but still joining -> cancel")

            self.joiningRoomToken = nil
            self.joiningIntent = nil
            self.joiningSessionId = nil
            self.joinRoomTask?.cancel()
        }

        // A re-join belongs to a running call, it goes on as long as the call or the chat uses the room
        let roomIsInUse = self.activeRooms[token].map { $0.inCall || $0.inChat } ?? false

        if let rejoin = self.rejoins[token], !roomIsInUse {
            NCLog.log("Leaving room \(token), but still re-joining -> cancel")

            rejoin.task?.cancel()
        }

        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()

        // Remove room controller and exit room
        if let roomController = self.activeRooms[token], !roomController.inCall, !roomController.inChat {

            self.activeRooms.removeValue(forKey: token)

            self.exitRoomTracked(token, forAccount: activeAccount) { error in
                var userInfo = [:]
                userInfo["token"] = token

                if let extSignalingController = NCSettingsController.sharedInstance().externalSignalingController(forAccountId: activeAccount.accountId) {
                    extSignalingController.leaveRoom(withRoomId: token)
                }

                if let error {
                    userInfo["error"] = error
                    NCLog.log("Could not exit room. Error: \(NCLog.errorCode(error))")
                }

                // Leaving the old room is not needed to join the answered call, so don't leave it hanging in CallKit on errors
                self.checkForPendingToStartCalls()

                NotificationCenter.default.post(name: .NCRoomsManagerDidLeaveRoom, object: self, userInfo: userInfo)
            }
        } else {
            self.checkForPendingToStartCalls()
        }
    }

    private func getJoinRoomErrorReason(_ statusCode: Int, andReason statusReason: String?) -> String {
        var errorReason = ""

        switch statusCode {
        case 0:
            errorReason = NSLocalizedString("No response from server", comment: "")
        case 403:
            if statusReason == "ban" {
                errorReason = NSLocalizedString("No permission to join this conversation", comment: "")
            } else {
                errorReason = NSLocalizedString("The password is wrong", comment: "")
            }
        case 404:
            errorReason = NSLocalizedString("Conversation not found", comment: "")
        case 409:
            // Currently not triggered, needs to be enabled in API with sending force=false
            errorReason = NSLocalizedString("Duplicate session", comment: "")
        case 422:
            errorReason = NSLocalizedString("Remote server is unreachable", comment: "")
        case 503:
            errorReason = NSLocalizedString("Server is currently in maintenance mode", comment: "")
        default:
            errorReason = NSLocalizedString("Unknown error occurred", comment: "")
        }

        return errorReason
    }

    // MARK: - Room

    public func resendOfflineMessagesWithCompletionBlock(_ block: (() -> Void)?) {
        // Try to send offline messages for all rooms
        self.resendOfflineMessages(forToken: nil, withCompletionBlock: block)
    }

    public func resendOfflineMessages(forToken token: String?, withCompletionBlock completionBlock: (() -> Void)?) {
        var query: NSPredicate

        if let token {
            query = NSPredicate(format: "isOfflineMessage = true AND token = %@", token)
        } else {
            query = NSPredicate(format: "isOfflineMessage = true")
        }

        let managedTemporaryMessages = NCChatMessage.objects(with: query)
        let twelveHoursAgoTimestamp = Int(Date().timeIntervalSince1970 - (60 * 60 * 12))

        for case let offlineMessage as NCChatMessage in managedTemporaryMessages {
            // If we were unable to send a message after 12 hours, mark as failed
            if offlineMessage.timestamp < twelveHoursAgoTimestamp {
                RLMRealm.writeTransaction { _ in
                    offlineMessage.isOfflineMessage = false
                    offlineMessage.sendingFailed = true
                }

                var userInfo: [AnyHashable: Any] = [:]
                userInfo["message"] = offlineMessage
                userInfo["isOfflineMessage"] = false

                if offlineMessage.referenceId != nil {
                    userInfo["referenceId"] = offlineMessage.referenceId
                }

                // Inform the chatViewController about this change
                NotificationCenter.default.post(name: .NCChatControllerDidSendChatMessage, object: self, userInfo: userInfo)
            } else {
                if let accountId = offlineMessage.accountId,
                   let room = NCDatabaseManager.sharedInstance().room(withToken: offlineMessage.token, forAccountId: accountId) {
                    if offlineMessage.threadId > 0 && offlineMessage.isThread {
                        guard let chatController = NCChatController(forThreadId: offlineMessage.threadId, in: room) else { continue }
                        chatController.send(offlineMessage)
                    } else {
                        guard let chatController = NCChatController(for: room) else { continue }
                        chatController.send(offlineMessage)
                    }
                }
            }
        }

        completionBlock?()
    }

}
