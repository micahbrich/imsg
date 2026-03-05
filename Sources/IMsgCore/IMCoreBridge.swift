import Foundation

/// Tapback reaction types for iMessage
///
/// These values correspond to Apple's IMCore framework's `associatedMessageType` field.
/// - 2000-2005: Add standard tapback reactions (love, thumbsup, thumbsdown, haha, emphasis, question)
/// - 2006: Add custom emoji reaction
/// - 3000-3006: Remove tapback reactions (add 1000 to the base type)
///
/// Source: BlueBubbles IMCore documentation
/// https://docs.bluebubbles.app/private-api/imcore-documentation
public enum TapbackType: Sendable, Equatable {
  case love
  case thumbsUp
  case thumbsDown
  case haha
  case emphasis
  case question
  case customEmoji(String)

  case removeLove
  case removeThumbsUp
  case removeThumbsDown
  case removeHaha
  case removeEmphasis
  case removeQuestion
  case removeCustomEmoji(String)

  public var rawValue: Int {
    switch self {
    case .love: return 2000
    case .thumbsUp: return 2001
    case .thumbsDown: return 2002
    case .haha: return 2003
    case .emphasis: return 2004
    case .question: return 2005
    case .customEmoji: return 2006
    case .removeLove: return 3000
    case .removeThumbsUp: return 3001
    case .removeThumbsDown: return 3002
    case .removeHaha: return 3003
    case .removeEmphasis: return 3004
    case .removeQuestion: return 3005
    case .removeCustomEmoji: return 3006
    }
  }

  public var displayName: String {
    switch self {
    case .love, .removeLove: return "love"
    case .thumbsUp, .removeThumbsUp: return "thumbsup"
    case .thumbsDown, .removeThumbsDown: return "thumbsdown"
    case .haha, .removeHaha: return "haha"
    case .emphasis, .removeEmphasis: return "emphasis"
    case .question, .removeQuestion: return "question"
    case .customEmoji(let emoji), .removeCustomEmoji(let emoji): return emoji
    }
  }

  /// Emoji representation of this tapback
  public var emoji: String {
    switch self {
    case .love, .removeLove: return "❤️"
    case .thumbsUp, .removeThumbsUp: return "👍"
    case .thumbsDown, .removeThumbsDown: return "👎"
    case .haha, .removeHaha: return "😂"
    case .emphasis, .removeEmphasis: return "‼️"
    case .question, .removeQuestion: return "❓"
    case .customEmoji(let emoji), .removeCustomEmoji(let emoji): return emoji
    }
  }

  /// Whether this is a custom emoji tapback (not one of the 6 standard types)
  public var isCustom: Bool {
    switch self {
    case .customEmoji, .removeCustomEmoji: return true
    default: return false
    }
  }

  /// The custom emoji string, or nil for standard tapbacks
  public var customEmojiString: String? {
    switch self {
    case .customEmoji(let emoji), .removeCustomEmoji(let emoji): return emoji
    default: return nil
    }
  }

  /// Whether this is a removal tapback
  public var isRemoval: Bool {
    return rawValue >= 3000
  }

  public static func from(string: String, remove: Bool = false) -> TapbackType? {
    // Check standard type names first (case-insensitive)
    let lower = string.lowercased()
    switch lower {
    case "love", "heart":
      return remove ? .removeLove : .love
    case "thumbsup", "like":
      return remove ? .removeThumbsUp : .thumbsUp
    case "thumbsdown", "dislike":
      return remove ? .removeThumbsDown : .thumbsDown
    case "haha", "laugh":
      return remove ? .removeHaha : .haha
    case "emphasis", "exclaim", "!!":
      return remove ? .removeEmphasis : .emphasis
    case "question", "?":
      return remove ? .removeQuestion : .question
    default:
      break
    }

    // Check standard emoji characters → map to standard types
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed {
    case "❤️", "❤":
      return remove ? .removeLove : .love
    case "👍":
      return remove ? .removeThumbsUp : .thumbsUp
    case "👎":
      return remove ? .removeThumbsDown : .thumbsDown
    case "😂":
      return remove ? .removeHaha : .haha
    case "‼️", "‼":
      return remove ? .removeEmphasis : .emphasis
    case "❓":
      return remove ? .removeQuestion : .question
    default:
      break
    }

    // Fall through to custom emoji check
    if containsEmoji(trimmed) {
      return remove ? .removeCustomEmoji(trimmed) : .customEmoji(trimmed)
    }

    return nil
  }

  private static func containsEmoji(_ value: String) -> Bool {
    for scalar in value.unicodeScalars {
      if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji {
        return true
      }
    }
    return false
  }
}

/// iMessage send effects (bubble and screen animations)
///
/// These values correspond to Apple's `expressive_send_style_id` column in the Messages database.
/// Bubble effects animate the individual message bubble; screen effects fill the entire screen.
public enum MessageEffect: String, Sendable, Equatable, CaseIterable {
  // Bubble effects
  case gentle, slam, loud, invisibleInk
  // Screen effects
  case confetti, balloons, fireworks, heart, lasers, echo, spotlight, sparkles, shootingStar

  public var expressiveSendStyleId: String {
    switch self {
    case .gentle: return "com.apple.MobileSMS.expressivesend.gentle"
    case .slam: return "com.apple.MobileSMS.expressivesend.impact"
    case .loud: return "com.apple.MobileSMS.expressivesend.loud"
    case .invisibleInk: return "com.apple.MobileSMS.expressivesend.invisibleink"
    case .confetti: return "com.apple.messages.effect.CKConfettiEffect"
    case .balloons: return "com.apple.messages.effect.CKHappyBirthdayEffect"
    case .fireworks: return "com.apple.messages.effect.CKFireworksEffect"
    case .heart: return "com.apple.messages.effect.CKHeartEffect"
    case .lasers: return "com.apple.messages.effect.CKLasersEffect"
    case .echo: return "com.apple.messages.effect.CKEchoEffect"
    case .spotlight: return "com.apple.messages.effect.CKSpotlightEffect"
    case .sparkles: return "com.apple.messages.effect.CKSparklesEffect"
    case .shootingStar: return "com.apple.messages.effect.CKShootingStarEffect"
    }
  }

  public var displayName: String {
    switch self {
    case .gentle: return "gentle"
    case .slam: return "slam"
    case .loud: return "loud"
    case .invisibleInk: return "invisibleink"
    case .confetti: return "confetti"
    case .balloons: return "balloons"
    case .fireworks: return "fireworks"
    case .heart: return "heart"
    case .lasers: return "lasers"
    case .echo: return "echo"
    case .spotlight: return "spotlight"
    case .sparkles: return "sparkles"
    case .shootingStar: return "shootingstar"
    }
  }

  public static func from(string: String) -> MessageEffect? {
    let lower = string.lowercased()
    switch lower {
    case "gentle": return .gentle
    case "slam": return .slam
    case "loud": return .loud
    case "invisibleink": return .invisibleInk
    case "confetti": return .confetti
    case "balloons": return .balloons
    case "fireworks": return .fireworks
    case "heart": return .heart
    case "lasers": return .lasers
    case "echo": return .echo
    case "spotlight": return .spotlight
    case "sparkles": return .sparkles
    case "shootingstar": return .shootingStar
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
    var params: [String: Any] = [
      "handle": handle,
      "guid": messageGUID,
      "type": type.rawValue,
    ]
    if let emoji = type.customEmojiString {
      params["emoji"] = emoji
    }

    _ = try await sendCommand(action: "react", params: params)
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

  /// Create a new chat with the given addresses
  public func createChat(
    addresses: [String],
    name: String? = nil,
    message: String? = nil,
    service: String = "imessage"
  ) async throws -> [String: Any] {
    var params: [String: Any] = [
      "addresses": addresses,
      "service": service,
    ]
    if let name, !name.isEmpty {
      params["name"] = name
    }
    if let message, !message.isEmpty {
      params["text"] = message
    }
    return try await sendCommand(action: "create_chat", params: params)
  }

  /// Rename an existing chat
  public func renameChat(handle: String, name: String) async throws {
    let params: [String: Any] = [
      "handle": handle,
      "name": name,
    ]
    _ = try await sendCommand(action: "rename_chat", params: params)
  }

  /// Remove participants from a group chat
  public func removeParticipant(
    handle: String, addresses: [String]
  ) async throws {
    let params: [String: Any] = [
      "handle": handle,
      "addresses": addresses,
    ]
    _ = try await sendCommand(action: "remove_participant", params: params)
  }

  /// Send a rich text message (with attributed text and optional effect)
  public func sendRichMessage(
    handle: String, attributedText: Data, effect: MessageEffect? = nil,
    replyToGUID: String? = nil
  ) async throws {
    var params: [String: Any] = [
      "handle": handle,
      "attributed_text": attributedText.base64EncodedString(),
    ]
    if let effect {
      params["effect_id"] = effect.expressiveSendStyleId
    }
    if let replyToGUID {
      params["reply_to_guid"] = replyToGUID
    }
    _ = try await sendCommand(action: "send_message", params: params)
  }

  /// Send a plain text message with an effect via IMCore bridge
  @discardableResult
  public func sendMessage(
    handle: String, text: String, effect: MessageEffect? = nil,
    replyToGUID: String? = nil
  ) async throws -> [String: Any] {
    var params: [String: Any] = ["handle": handle, "text": text]
    if let effect {
      params["effect_id"] = effect.expressiveSendStyleId
    }
    if let replyToGUID {
      params["reply_to_guid"] = replyToGUID
    }
    return try await sendCommand(action: "send_message", params: params)
  }

  /// Edit a previously sent message
  public func editMessage(
    handle: String, messageGUID: String, newText: String,
    attributedText: Data? = nil
  ) async throws {
    var params: [String: Any] = [
      "handle": handle,
      "guid": messageGUID,
      "text": newText,
    ]
    if let attributedText {
      params["attributed_text"] = attributedText.base64EncodedString()
    }
    _ = try await sendCommand(action: "edit_message", params: params)
  }

  /// Unsend (retract) a previously sent message
  public func unsendMessage(
    handle: String, messageGUID: String, partIndex: Int = 0
  ) async throws {
    let params: [String: Any] = [
      "handle": handle,
      "guid": messageGUID,
      "part_index": partIndex,
    ]
    _ = try await sendCommand(action: "unsend_message", params: params)
  }
}
