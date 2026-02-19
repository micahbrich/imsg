import Foundation
import IMsgCore

protocol RPCOutput: Sendable {
  func sendResponse(id: Any, result: Any)
  func sendError(id: Any?, error: RPCError)
  func sendNotification(method: String, params: Any)
}

final class RPCServer {
  private let store: MessageStore
  private let watcher: MessageWatcher
  private let output: RPCOutput
  private let cache: ChatCache
  private let verbose: Bool
  private let sendMessage: (MessageSendOptions) throws -> Void
  private let autoRead: Bool
  private let autoTyping: Bool
  private let bridgeAvailable: Bool
  private var nextSubscriptionID = 1
  private var subscriptions: [Int: Task<Void, Never>] = [:]
  private var typingSubscriptions: [Int: TypingSubscription] = [:]

  init(
    store: MessageStore,
    verbose: Bool,
    autoRead: Bool? = nil,
    autoTyping: Bool? = nil,
    output: RPCOutput = RPCWriter(),
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) }
  ) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.verbose = verbose
    self.output = output
    self.sendMessage = sendMessage
    let available = IMCoreBridge.shared.isAvailable
    self.bridgeAvailable = available
    self.autoRead = autoRead ?? available
    self.autoTyping = autoTyping ?? available
  }

  func run() async throws {
    while let line = readLine() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      await handleLine(trimmed)
    }
    for task in subscriptions.values {
      task.cancel()
    }
    for subscription in typingSubscriptions.values {
      subscription.task.cancel()
      if bridgeAvailable {
        try? await IMCoreBridge.shared.unsubscribeFromTyping(
          subscription: subscription.helperSubscription
        )
      }
    }
    typingSubscriptions.removeAll()
  }

  func handleLineForTesting(_ line: String) async {
    await handleLine(line)
  }

  private func handleLine(_ line: String) async {
    guard let data = line.data(using: .utf8) else {
      output.sendError(id: nil, error: RPCError.parseError("invalid utf8"))
      return
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      output.sendError(id: nil, error: RPCError.parseError(error.localizedDescription))
      return
    }
    guard let request = json as? [String: Any] else {
      output.sendError(id: nil, error: RPCError.invalidRequest("request must be an object"))
      return
    }
    let jsonrpc = request["jsonrpc"] as? String
    if jsonrpc != nil && jsonrpc != "2.0" {
      output.sendError(id: request["id"], error: RPCError.invalidRequest("jsonrpc must be 2.0"))
      return
    }
    guard let method = request["method"] as? String, !method.isEmpty else {
      output.sendError(id: request["id"], error: RPCError.invalidRequest("method is required"))
      return
    }
    let params = request["params"] as? [String: Any] ?? [:]
    let id = request["id"]

    do {
      switch method {
      case "chats.list":
        let limit = intParam(params["limit"]) ?? 20
        let chats = try store.listChats(limit: max(limit, 1))
        let payloads = try chats.map { chat in
          let info = try cache.info(chatID: chat.id)
          let participants = try cache.participants(chatID: chat.id)
          let identifier = info?.identifier ?? chat.identifier
          let guid = info?.guid ?? ""
          let name = (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name
          let service = info?.service ?? chat.service
          return chatPayload(
            id: chat.id,
            identifier: identifier,
            guid: guid,
            name: name,
            service: service,
            lastMessageAt: chat.lastMessageAt,
            participants: participants
          )
        }
        respond(id: id, result: ["chats": payloads])
      case "messages.history":
        guard let chatID = int64Param(params["chat_id"]) else {
          throw RPCError.invalidParams("chat_id is required")
        }
        let limit = intParam(params["limit"]) ?? 50
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let filter = try MessageFilter.fromISO(
          participants: participants,
          startISO: startISO,
          endISO: endISO
        )
        let filtered = try store.messages(chatID: chatID, limit: max(limit, 1), filter: filter)
        let payloads = try filtered.map { message in
          try buildMessagePayload(
            store: store,
            cache: cache,
            message: message,
            includeAttachments: includeAttachments
          )
        }
        respond(id: id, result: ["messages": payloads])
      case "watch.subscribe":
        let chatID = int64Param(params["chat_id"])
        let sinceRowID = int64Param(params["since_rowid"])
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let filter = try MessageFilter.fromISO(
          participants: participants,
          startISO: startISO,
          endISO: endISO
        )
        let config = MessageWatcherConfiguration()
        let subID = nextSubscriptionID
        nextSubscriptionID += 1
        let localStore = store
        let localWatcher = watcher
        let localCache = cache
        let localWriter = output
        let localFilter = filter
        let localChatID = chatID
        let localSinceRowID = sinceRowID
        let localConfig = config
        let localIncludeAttachments = includeAttachments
        let localAutoRead = autoRead
        let localBridgeAvailable = bridgeAvailable
        let localVerbose = verbose
        let task = Task {
          do {
            for try await message in localWatcher.stream(
              chatID: localChatID,
              sinceRowID: localSinceRowID,
              configuration: localConfig
            ) {
              if Task.isCancelled { return }
              if !localFilter.allows(message) { continue }
              let payload = try buildMessagePayload(
                store: localStore,
                cache: localCache,
                message: message,
                includeAttachments: localIncludeAttachments
              )
              localWriter.sendNotification(
                method: "message",
                params: ["subscription": subID, "message": payload]
              )
              // Auto-read receipt for incoming messages
              if localAutoRead && localBridgeAvailable {
                if let isFromMe = payload["is_from_me"] as? Bool, !isFromMe {
                  let handle: String? =
                    stringParam(payload["chat_identifier"])
                    ?? stringParam(payload["sender"])
                  if let handle, !handle.isEmpty {
                    Task {
                      do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        try await IMCoreBridge.shared.markAsRead(handle: handle)
                        if localVerbose {
                          FileHandle.standardError.write(
                            Data("[auto-read] marked read for \(handle)\n".utf8))
                        }
                      } catch {
                        if localVerbose {
                          FileHandle.standardError.write(Data("[auto-read] error: \(error)\n".utf8))
                        }
                      }
                    }
                  }
                }
              }
            }
          } catch {
            localWriter.sendNotification(
              method: "error",
              params: [
                "subscription": subID,
                "error": ["message": String(describing: error)],
              ]
            )
          }
        }
        subscriptions[subID] = task
        respond(id: id, result: ["subscription": subID])
      case "watch.unsubscribe":
        guard let subID = intParam(params["subscription"]) else {
          throw RPCError.invalidParams("subscription is required")
        }
        if let task = subscriptions.removeValue(forKey: subID) {
          task.cancel()
        }
        respond(id: id, result: ["ok": true])
      case "typing.subscribe", "typing_subscribe":
        try await handleTypingSubscribe(params: params, id: id)
      case "typing.unsubscribe", "typing_unsubscribe":
        try await handleTypingUnsubscribe(params: params, id: id)
      case "send":
        try await handleSend(params: params, id: id)
      case "typing.set":
        try await handleTypingSet(params: params, id: id)
      case "messages.markRead":
        try await handleMarkRead(params: params, id: id)
      case "tapback.send":
        try await handleTapbackSend(params: params, id: id)
      default:
        output.sendError(id: id, error: RPCError.methodNotFound(method))
      }
    } catch let err as RPCError {
      output.sendError(id: id, error: err)
    } catch let err as IMsgError {
      switch err {
      case .invalidService, .invalidChatTarget:
        output.sendError(
          id: id,
          error: RPCError.invalidParams(err.errorDescription ?? "invalid params")
        )
      default:
        output.sendError(id: id, error: RPCError.internalError(err.localizedDescription))
      }
    } catch {
      output.sendError(id: id, error: RPCError.internalError(error.localizedDescription))
    }
  }

  private func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  private func handleTypingSubscribe(params: [String: Any], id: Any?) async throws {
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }

    var resolvedChatIdentifier = stringParam(params["chat_identifier"]) ?? ""
    var resolvedChatGUID = stringParam(params["chat_guid"]) ?? ""
    let directHandle = stringParam(params["handle"]) ?? ""

    if let chatID = int64Param(params["chat_id"]) {
      guard let info = try cache.info(chatID: chatID) else {
        throw RPCError.invalidParams("unknown chat_id \(chatID)")
      }
      resolvedChatIdentifier = info.identifier
      resolvedChatGUID = info.guid
    }

    let handle: String? = {
      if !directHandle.isEmpty { return directHandle }
      return resolveTypingHandle(
        recipient: "",
        chatIdentifier: resolvedChatIdentifier,
        chatGUID: resolvedChatGUID
      )
    }()

    let helperSubscription = try await IMCoreBridge.shared.subscribeToTyping(handle: handle)
    let subscriptionID = nextSubscriptionID
    nextSubscriptionID += 1

    let localOutput = output
    let localVerbose = verbose
    let task = Task {
      while !Task.isCancelled {
        do {
          let events = try await IMCoreBridge.shared.pollTyping(subscription: helperSubscription)
          for event in events {
            localOutput.sendNotification(
              method: "typing.changed",
              params: [
                "subscription": subscriptionID,
                "chat_guid": event.chatGUID,
                "chat_id": event.chatID,
                "handle": event.handle,
                "is_typing": event.isTyping,
                "timestamp": event.timestamp,
              ]
            )
          }
          try await Task.sleep(nanoseconds: 350_000_000)
        } catch {
          if Task.isCancelled { break }
          localOutput.sendNotification(
            method: "error",
            params: [
              "subscription": subscriptionID,
              "error": ["message": "typing poll failed: \(error)"],
            ]
          )
          break
        }
      }
      try? await IMCoreBridge.shared.unsubscribeFromTyping(subscription: helperSubscription)
      if localVerbose {
        FileHandle.standardError.write(
          Data("[typing] subscription \(subscriptionID) ended\n".utf8))
      }
    }

    typingSubscriptions[subscriptionID] = TypingSubscription(
      helperSubscription: helperSubscription,
      task: task
    )

    var result: [String: Any] = [
      "subscription": subscriptionID,
      "helper_subscription": helperSubscription,
    ]
    if let handle, !handle.isEmpty {
      result["handle"] = handle
    }
    respond(id: id, result: result)
  }

  private func handleTypingUnsubscribe(params: [String: Any], id: Any?) async throws {
    guard let subscriptionID = intParam(params["subscription"]) else {
      throw RPCError.invalidParams("subscription is required")
    }
    guard let subscription = typingSubscriptions.removeValue(forKey: subscriptionID) else {
      throw RPCError.invalidParams("unknown typing subscription \(subscriptionID)")
    }

    subscription.task.cancel()
    if bridgeAvailable {
      try? await IMCoreBridge.shared.unsubscribeFromTyping(
        subscription: subscription.helperSubscription
      )
    }

    respond(
      id: id,
      result: [
        "ok": true,
        "subscription": subscriptionID,
      ])
  }

  private func handleSend(params: [String: Any], id: Any?) async throws {
    let text = stringParam(params["text"]) ?? ""
    let file = stringParam(params["file"]) ?? ""
    let serviceRaw = stringParam(params["service"]) ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw RPCError.invalidParams("invalid service")
    }
    let region = stringParam(params["region"]) ?? "US"

    let chatID = int64Param(params["chat_id"])
    let chatIdentifier = stringParam(params["chat_identifier"]) ?? ""
    let chatGUID = stringParam(params["chat_guid"]) ?? ""
    let hasChatTarget = chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
    let recipient = stringParam(params["to"]) ?? ""
    if hasChatTarget && !recipient.isEmpty {
      throw RPCError.invalidParams("use to or chat_*; not both")
    }
    if !hasChatTarget && recipient.isEmpty {
      throw RPCError.invalidParams("to is required for direct sends")
    }

    if text.isEmpty && file.isEmpty {
      throw RPCError.invalidParams("text or file is required")
    }

    var resolvedChatIdentifier = chatIdentifier
    var resolvedChatGUID = chatGUID
    if let chatID {
      guard let info = try cache.info(chatID: chatID) else {
        throw RPCError.invalidParams("unknown chat_id \(chatID)")
      }
      resolvedChatIdentifier = info.identifier
      resolvedChatGUID = info.guid
    }
    if hasChatTarget && resolvedChatIdentifier.isEmpty && resolvedChatGUID.isEmpty {
      throw RPCError.invalidParams("missing chat identifier or guid")
    }

    // Auto-typing: simulate typing before sending
    if autoTyping && bridgeAvailable {
      let typingHandle = resolveTypingHandle(
        recipient: recipient,
        chatIdentifier: resolvedChatIdentifier,
        chatGUID: resolvedChatGUID
      )
      if let handle = typingHandle {
        do {
          try await IMCoreBridge.shared.setTyping(for: handle, typing: true)
          if verbose {
            FileHandle.standardError.write(Data("[auto-typing] ON for \(handle)\n".utf8))
          }
          // Delay based on message length: ~1.5s base + up to 2.5s for longer messages, cap at 4s
          let charCount = Double(text.count)
          let baseDelay = 1.5
          let extraDelay = min(charCount / 80.0 * 2.5, 2.5)
          let totalDelay = min(baseDelay + extraDelay, 4.0)
          try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
        } catch {
          if verbose {
            FileHandle.standardError.write(Data("[auto-typing] error: \(error)\n".utf8))
          }
        }
      }
    }

    try sendMessage(
      MessageSendOptions(
        recipient: recipient,
        text: text,
        attachmentPath: file,
        service: service,
        region: region,
        chatIdentifier: resolvedChatIdentifier,
        chatGUID: resolvedChatGUID
      )
    )

    // Turn off typing after send (fire-and-forget)
    if autoTyping && bridgeAvailable {
      let typingHandle = resolveTypingHandle(
        recipient: recipient,
        chatIdentifier: resolvedChatIdentifier,
        chatGUID: resolvedChatGUID
      )
      if let handle = typingHandle {
        let localVerbose = verbose
        Task {
          do {
            try await IMCoreBridge.shared.setTyping(for: handle, typing: false)
            if localVerbose {
              FileHandle.standardError.write(Data("[auto-typing] OFF for \(handle)\n".utf8))
            }
          } catch {
            if localVerbose {
              FileHandle.standardError.write(Data("[auto-typing] off error: \(error)\n".utf8))
            }
          }
        }
      }
    }

    respond(id: id, result: ["ok": true])
  }

  private func handleTypingSet(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard let state = stringParam(params["state"]), state == "on" || state == "off" else {
      throw RPCError.invalidParams("state must be 'on' or 'off'")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    try await IMCoreBridge.shared.setTyping(for: handle, typing: state == "on")
    respond(id: id, result: ["ok": true])
  }

  private func handleMarkRead(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    try await IMCoreBridge.shared.markAsRead(handle: handle)
    respond(id: id, result: ["ok": true])
  }

  private func handleTapbackSend(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard let guid = stringParam(params["guid"]), !guid.isEmpty else {
      throw RPCError.invalidParams("guid is required (message GUID to react to)")
    }
    guard let typeStr = stringParam(params["type"]), !typeStr.isEmpty else {
      throw RPCError.invalidParams(
        "type is required (alias or literal emoji)")
    }
    let remove = boolParam(params["remove"]) ?? false
    guard let reactionType = ReactionType.parse(typeStr) else {
      throw RPCError.invalidParams(
        "invalid reaction type: '\(typeStr)'. Valid: love, thumbsup, thumbsdown, haha, emphasis, question, or literal emoji"
      )
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    let associatedType =
      remove
      ? reactionType.removalAssociatedMessageType : reactionType.associatedMessageType
    let customEmoji: String? = {
      if case .custom(let emoji) = reactionType {
        return emoji
      }
      return nil
    }()
    try await IMCoreBridge.shared.sendReaction(
      to: handle,
      messageGUID: guid,
      associatedMessageType: associatedType,
      emoji: customEmoji
    )
    respond(
      id: id,
      result: [
        "ok": true,
        "handle": handle,
        "guid": guid,
        "type": rpcReactionDisplayName(reactionType),
        "emoji": reactionType.emoji,
        "action": remove ? "removed" : "added",
      ])
  }

  /// Resolve the best handle for typing/read from send params
  private func resolveTypingHandle(recipient: String, chatIdentifier: String, chatGUID: String)
    -> String?
  {
    if !recipient.isEmpty { return recipient }
    if !chatIdentifier.isEmpty { return chatIdentifier }
    if !chatGUID.isEmpty { return chatGUID }
    return nil
  }

}

private func rpcReactionDisplayName(_ reaction: ReactionType) -> String {
  switch reaction {
  case .love: return "love"
  case .like: return "thumbsup"
  case .dislike: return "thumbsdown"
  case .laugh: return "haha"
  case .emphasis: return "emphasis"
  case .question: return "question"
  case .custom(let emoji): return emoji
  }
}

private func buildMessagePayload(
  store: MessageStore,
  cache: ChatCache,
  message: Message,
  includeAttachments: Bool
) throws -> [String: Any] {
  let chatInfo = try cache.info(chatID: message.chatID)
  let participants = try cache.participants(chatID: message.chatID)
  let attachments = includeAttachments ? try store.attachments(for: message.rowID) : []
  let reactions = includeAttachments ? try store.reactions(for: message.rowID) : []
  return messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: participants,
    attachments: attachments,
    reactions: reactions
  )
}

private struct TypingSubscription {
  let helperSubscription: Int
  let task: Task<Void, Never>
}

private final class RPCWriter: RPCOutput, @unchecked Sendable {
  private let queue = DispatchQueue(label: "imsg.rpc.writer")

  func sendResponse(id: Any, result: Any) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    send(payload)
  }

  func sendNotification(method: String, params: Any) {
    send(["jsonrpc": "2.0", "method": method, "params": params])
  }

  private func send(_ object: Any) {
    queue.sync {
      do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        if let output = String(data: data, encoding: .utf8) {
          FileHandle.standardOutput.write(Data(output.utf8))
          FileHandle.standardOutput.write(Data("\n".utf8))
        }
      } catch {
        if let fallback =
          "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"write failed\"}}\n"
          .data(using: .utf8)
        {
          FileHandle.standardOutput.write(fallback)
        }
      }
    }
  }
}

struct RPCError: Error {
  let code: Int
  let message: String
  let data: String?

  static func parseError(_ message: String) -> RPCError {
    RPCError(code: -32700, message: "Parse error", data: message)
  }

  static func invalidRequest(_ message: String) -> RPCError {
    RPCError(code: -32600, message: "Invalid Request", data: message)
  }

  static func methodNotFound(_ method: String) -> RPCError {
    RPCError(code: -32601, message: "Method not found", data: method)
  }

  static func invalidParams(_ message: String) -> RPCError {
    RPCError(code: -32602, message: "Invalid params", data: message)
  }

  static func internalError(_ message: String) -> RPCError {
    RPCError(code: -32603, message: "Internal error", data: message)
  }

  func asDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "code": code,
      "message": message,
    ]
    if let data {
      dict["data"] = data
    }
    return dict
  }
}

private final class ChatCache: @unchecked Sendable {
  private let store: MessageStore
  private var infoCache: [Int64: ChatInfo] = [:]
  private var participantsCache: [Int64: [String]] = [:]

  init(store: MessageStore) {
    self.store = store
  }

  func info(chatID: Int64) throws -> ChatInfo? {
    if let cached = infoCache[chatID] { return cached }
    if let info = try store.chatInfo(chatID: chatID) {
      infoCache[chatID] = info
      return info
    }
    return nil
  }

  func participants(chatID: Int64) throws -> [String] {
    if let cached = participantsCache[chatID] { return cached }
    let participants = try store.participants(chatID: chatID)
    participantsCache[chatID] = participants
    return participants
  }
}
