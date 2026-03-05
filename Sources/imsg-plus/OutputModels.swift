import Foundation
import IMsgCore

struct ChatPayload: Codable {
  let id: Int64
  let name: String
  let identifier: String
  let service: String
  let lastMessageAt: String
  let participantNames: [String: String]?

  init(chat: Chat, participantNames: [String: String]? = nil) {
    self.id = chat.id
    self.name = chat.name
    self.identifier = chat.identifier
    self.service = chat.service
    self.lastMessageAt = CLIISO8601.format(chat.lastMessageAt)
    self.participantNames = participantNames
  }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case identifier
    case service
    case lastMessageAt = "last_message_at"
    case participantNames = "participant_names"
  }
}

struct MessagePayload: Codable {
  let id: Int64
  let chatID: Int64
  let guid: String
  let replyToGUID: String?
  let replyToPart: String?
  let sender: String
  let senderName: String?
  let isFromMe: Bool
  let text: String
  let markdownText: String?
  let createdAt: String
  let isEdited: Bool?
  let dateEdited: String?
  let attachments: [AttachmentPayload]
  let reactions: [ReactionPayload]

  init(
    message: Message,
    attachments: [AttachmentMeta],
    reactions: [Reaction] = [],
    senderName: String? = nil,
    markdownText: String? = nil
  ) {
    self.id = message.rowID
    self.chatID = message.chatID
    self.guid = message.guid
    self.replyToGUID = message.replyToGUID
    self.replyToPart = message.threadOriginatorPart
    self.sender = message.sender
    self.senderName = senderName
    self.isFromMe = message.isFromMe
    self.text = message.text
    self.markdownText = markdownText
    self.createdAt = CLIISO8601.format(message.date)
    self.isEdited = message.isEdited ? true : nil
    self.dateEdited = message.dateEdited.map { CLIISO8601.format($0) }
    self.attachments = attachments.map { AttachmentPayload(meta: $0) }
    self.reactions = reactions.map { ReactionPayload(reaction: $0) }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case chatID = "chat_id"
    case guid
    case replyToGUID = "reply_to_guid"
    case replyToPart = "reply_to_part"
    case sender
    case senderName = "sender_name"
    case isFromMe = "is_from_me"
    case text
    case markdownText = "markdown_text"
    case createdAt = "created_at"
    case isEdited = "is_edited"
    case dateEdited = "date_edited"
    case attachments
    case reactions
  }
}

struct ReactionPayload: Codable {
  let id: Int64
  let type: String
  let emoji: String
  let sender: String
  let senderName: String?
  let isFromMe: Bool
  let createdAt: String

  init(reaction: Reaction, senderName: String? = nil) {
    self.id = reaction.rowID
    self.type = reaction.reactionType.name
    self.emoji = reaction.reactionType.emoji
    self.sender = reaction.sender
    self.senderName = senderName
    self.isFromMe = reaction.isFromMe
    self.createdAt = CLIISO8601.format(reaction.date)
  }

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case emoji
    case sender
    case senderName = "sender_name"
    case isFromMe = "is_from_me"
    case createdAt = "created_at"
  }
}

struct AttachmentPayload: Codable {
  let filename: String
  let transferName: String
  let uti: String
  let mimeType: String
  let totalBytes: Int64
  let isSticker: Bool
  let originalPath: String
  let missing: Bool

  init(meta: AttachmentMeta) {
    self.filename = meta.filename
    self.transferName = meta.transferName
    self.uti = meta.uti
    self.mimeType = meta.mimeType
    self.totalBytes = meta.totalBytes
    self.isSticker = meta.isSticker
    self.originalPath = meta.originalPath
    self.missing = meta.missing
  }

  enum CodingKeys: String, CodingKey {
    case filename = "filename"
    case transferName = "transfer_name"
    case uti = "uti"
    case mimeType = "mime_type"
    case totalBytes = "total_bytes"
    case isSticker = "is_sticker"
    case originalPath = "original_path"
    case missing = "missing"
  }
}

enum CLIISO8601 {
  static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
