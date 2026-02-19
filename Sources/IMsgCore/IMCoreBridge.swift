import Foundation

/// Tapback reaction types for iMessage
///
/// These values correspond to Apple's IMCore framework's `associatedMessageType` field.
/// - 2000-2005: Add tapback reactions (love, thumbsup, thumbsdown, haha, emphasis, question)
/// - 3000-3005: Remove tapback reactions (add 1000 to the base type)
///
/// Source: BlueBubbles IMCore documentation
/// https://docs.bluebubbles.app/private-api/imcore-documentation
public enum TapbackType: Int, Sendable {
  case love = 2000
  case thumbsUp = 2001
  case thumbsDown = 2002
  case haha = 2003
  case emphasis = 2004
  case question = 2005

  case removeLove = 3000
  case removeThumbsUp = 3001
  case removeThumbsDown = 3002
  case removeHaha = 3003
  case removeEmphasis = 3004
  case removeQuestion = 3005

  public var displayName: String {
    switch self {
    case .love, .removeLove: return "love"
    case .thumbsUp, .removeThumbsUp: return "thumbsup"
    case .thumbsDown, .removeThumbsDown: return "thumbsdown"
    case .haha, .removeHaha: return "haha"
    case .emphasis, .removeEmphasis: return "emphasis"
    case .question, .removeQuestion: return "question"
    }
  }

  public static func from(string: String, remove: Bool = false) -> TapbackType? {
    let offset = remove ? 1000 : 0
    switch string.lowercased() {
    case "love", "heart": return TapbackType(rawValue: 2000 + offset)
    case "thumbsup", "like": return TapbackType(rawValue: 2001 + offset)
    case "thumbsdown", "dislike": return TapbackType(rawValue: 2002 + offset)
    case "haha", "laugh": return TapbackType(rawValue: 2003 + offset)
    case "emphasis", "exclaim", "!!": return TapbackType(rawValue: 2004 + offset)
    case "question", "?": return TapbackType(rawValue: 2005 + offset)
    default: return nil
    }
  }
}

public enum IMCoreBridgeError: Error, CustomStringConvertible {
  case frameworkNotAvailable
  case dylibNotFound
  case connectionFailed(String)
  case chatNotFound(String)
  case messageNotFound(String)
  case operationFailed(String)

  public var description: String {
    switch self {
    case .frameworkNotAvailable:
      return "IMCore framework not available. Advanced features require SIP disabled."
    case .dylibNotFound:
      return
        "imsg-plus-helper.dylib not found. Build with: make build-dylib"
    case .connectionFailed(let error):
      return "Connection to Messages.app failed: \(error)"
    case .chatNotFound(let id):
      return "Chat not found: \(id)"
    case .messageNotFound(let guid):
      return "Message not found: \(guid)"
    case .operationFailed(let reason):
      return "Operation failed: \(reason)"
    }
  }
}

public struct TypingChangeEvent: Sendable, Equatable {
  public let chatGUID: String
  public let chatID: String
  public let handle: String
  public let isTyping: Bool
  public let timestamp: String

  public init(
    chatGUID: String,
    chatID: String,
    handle: String,
    isTyping: Bool,
    timestamp: String
  ) {
    self.chatGUID = chatGUID
    self.chatID = chatID
    self.handle = handle
    self.isTyping = isTyping
    self.timestamp = timestamp
  }

  init?(dictionary: [String: Any]) {
    guard
      let chatGUID = dictionary["chat_guid"] as? String,
      let chatID = dictionary["chat_id"] as? String,
      let handle = dictionary["handle"] as? String,
      let isTyping = dictionary["is_typing"] as? Bool,
      let timestamp = dictionary["timestamp"] as? String
    else {
      return nil
    }
    self.init(
      chatGUID: chatGUID,
      chatID: chatID,
      handle: handle,
      isTyping: isTyping,
      timestamp: timestamp
    )
  }
}

/// Bridge to IMCore via DYLD injection into Messages.app
///
/// This bridge communicates with an injected dylib inside Messages.app
/// via Unix socket IPC. The dylib has full access to IMCore because
/// it runs within the Messages.app context with proper entitlements.
public final class IMCoreBridge: @unchecked Sendable {
  public static let shared = IMCoreBridge()

  private let launcher = MessagesLauncher.shared

  public var isAvailable: Bool {
    // Check if dylib exists
    let possiblePaths = [
      ".build/release/imsg-plus-helper.dylib",
      ".build/debug/imsg-plus-helper.dylib",
      "/usr/local/lib/imsg-plus-helper.dylib",
    ]

    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        return true
      }
    }
    return false
  }

  private init() {}

  /// Send a command to the injected helper via MessagesLauncher
  private func sendCommand(action: String, params: [String: Any]) async throws -> [String: Any] {
    do {
      let response = try await launcher.sendCommand(action: action, params: params)

      if response["success"] as? Bool == true {
        return response
      } else {
        let error = response["error"] as? String ?? "Unknown error"

        // Map specific errors
        if error.contains("Chat not found") {
          let handle = params["handle"] as? String ?? "unknown"
          throw IMCoreBridgeError.chatNotFound(handle)
        } else if error.contains("Message not found") {
          let guid = params["guid"] as? String ?? "unknown"
          throw IMCoreBridgeError.messageNotFound(guid)
        }

        throw IMCoreBridgeError.operationFailed(error)
      }
    } catch let error as MessagesLauncherError {
      throw IMCoreBridgeError.connectionFailed(error.description)
    }
  }

  /// Set typing indicator for a conversation
  public func setTyping(for handle: String, typing: Bool) async throws {
    let params =
      [
        "handle": handle,
        "typing": typing,
      ] as [String: Any]

    _ = try await sendCommand(action: "typing", params: params)
  }

  /// Mark all messages as read in a conversation
  public func markAsRead(handle: String) async throws {
    let params = ["handle": handle]
    _ = try await sendCommand(action: "read", params: params)
  }

  /// Send a tapback reaction to a message
  public func sendTapback(
    to handle: String,
    messageGUID: String,
    type: TapbackType
  ) async throws {
    try await sendReaction(
      to: handle,
      messageGUID: messageGUID,
      associatedMessageType: type.rawValue,
      emoji: nil
    )
  }

  /// Send a reaction to a message with explicit associated message metadata.
  ///
  /// - Parameters:
  ///   - handle: Chat handle/identifier/guid
  ///   - messageGUID: GUID of the message being reacted to
  ///   - associatedMessageType: IMCore associated message type (2000-2006 add, 3000-3006 remove)
  ///   - emoji: Optional custom emoji when type is 2006/3006
  public func sendReaction(
    to handle: String,
    messageGUID: String,
    associatedMessageType: Int,
    emoji: String?
  ) async throws {
    let params =
      [
        "handle": handle,
        "guid": messageGUID,
        "type": associatedMessageType,
      ] as [String: Any]

    var requestParams = params
    if let emoji, !emoji.isEmpty {
      requestParams["emoji"] = emoji
    }

    _ = try await sendCommand(action: "react", params: requestParams)
  }

  /// Subscribe to peer typing updates. Optional handle scopes the subscription to one chat.
  public func subscribeToTyping(handle: String? = nil) async throws -> Int {
    var params: [String: Any] = [:]
    if let handle, !handle.isEmpty {
      params["handle"] = handle
    }
    let response = try await sendCommand(action: "typing_subscribe", params: params)
    if let subscription = response["subscription"] as? Int {
      return subscription
    }
    if let subscription = response["subscription"] as? NSNumber {
      return subscription.intValue
    }
    throw IMCoreBridgeError.operationFailed("typing_subscribe response missing subscription")
  }

  /// Unsubscribe from peer typing updates.
  public func unsubscribeFromTyping(subscription: Int) async throws {
    _ = try await sendCommand(
      action: "typing_unsubscribe",
      params: ["subscription": subscription]
    )
  }

  /// Poll queued typing events for a subscription.
  public func pollTyping(subscription: Int) async throws -> [TypingChangeEvent] {
    let response = try await sendCommand(
      action: "typing_poll",
      params: ["subscription": subscription]
    )
    guard let rawEvents = response["events"] as? [[String: Any]] else {
      return []
    }
    return rawEvents.compactMap(TypingChangeEvent.init(dictionary:))
  }

  /// List all available chats (for debugging)
  public func listChats() async throws -> [[String: Any]] {
    let response = try await sendCommand(action: "list_chats", params: [:])
    return response["chats"] as? [[String: Any]] ?? []
  }

  /// Check the availability and status of the IMCore bridge
  public func checkAvailability() -> (available: Bool, message: String) {
    // Check if dylib exists
    let possiblePaths = [
      ".build/release/imsg-plus-helper.dylib",
      ".build/debug/imsg-plus-helper.dylib",
      "/usr/local/lib/imsg-plus-helper.dylib",
    ]

    var dylibPath: String?
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        dylibPath = path
        break
      }
    }

    guard dylibPath != nil else {
      return (
        false,
        """
        imsg-plus-helper.dylib not found. To build:
        1. make build-dylib
        2. Restart imsg

        Note: Advanced features require:
        - SIP disabled (for DYLD injection)
        - Full Disk Access granted to Terminal
        """
      )
    }

    // Check if already connected
    if launcher.isInjectedAndReady() {
      return (true, "Connected to Messages.app. IMCore features available.")
    }

    // Try to get status
    do {
      try launcher.ensureRunning()
      return (true, "Messages.app launched with injection. IMCore features available.")
    } catch let error as MessagesLauncherError {
      return (false, error.description)
    } catch {
      return (false, "Failed to connect to Messages.app: \(error.localizedDescription)")
    }
  }

  /// Get detailed status from the injected helper
  public func getStatus() async throws -> [String: Any] {
    return try await sendCommand(action: "status", params: [:])
  }
}
