import Foundation
import SQLite

extension MessageStore {
  public func messages(chatID: Int64, limit: Int) throws -> [Message] {
    return try messages(chatID: chatID, limit: limit, filter: nil)
  }

  public func messages(chatID: Int64, limit: Int, filter: MessageFilter?) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn = hasThreadOriginator ? "m.thread_originator_guid" : "NULL"
    let threadOriginatorPartColumn = hasThreadOriginator ? "m.thread_originator_part" : "NULL"
    let dateEditedColumn = hasDateEdited ? "m.date_edited" : "NULL"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid,
             \(threadOriginatorPartColumn) AS thread_originator_part,
             \(dateEditedColumn) AS date_edited
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE cmj.chat_id = ?\(reactionFilter)
      """
    var bindings: [Binding?] = [chatID]

    if let filter {
      if let startDate = filter.startDate {
        sql += " AND m.date >= ?"
        bindings.append(MessageStore.appleEpoch(startDate))
      }
      if let endDate = filter.endDate {
        sql += " AND m.date < ?"
        bindings.append(MessageStore.appleEpoch(endDate))
      }
      if !filter.participants.isEmpty {
        let placeholders = Array(repeating: "?", count: filter.participants.count).joined(
          separator: ",")
        // Match current in-memory behavior: Message.sender is either handle.id or destination_caller_id.
        sql +=
          " AND COALESCE(NULLIF(h.id,''), \(destinationCallerColumn)) COLLATE NOCASE IN (\(placeholders))"
        for participant in filter.participants {
          bindings.append(participant)
        }
      }
    }

    sql += " ORDER BY m.date DESC LIMIT ?"
    bindings.append(limit)

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let rowID = int64Value(row[0]) ?? 0
        let handleID = int64Value(row[1])
        var sender = stringValue(row[2])
        let text = stringValue(row[3])
        let date = appleDate(from: int64Value(row[4]))
        let isFromMe = boolValue(row[5])
        let service = stringValue(row[6])
        let isAudioMessage = boolValue(row[7])
        let destinationCallerID = stringValue(row[8])
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        let guid = stringValue(row[9])
        let associatedGuid = stringValue(row[10])
        let associatedType = intValue(row[11])
        let attachments = intValue(row[12]) ?? 0
        let body = dataValue(row[13])
        let threadOriginatorGUID = stringValue(row[14])
        let threadOriginatorPart = stringValue(row[15])
        let dateEditedRaw = int64Value(row[16])
        var resolvedText = text
        var markdownText: String?
        if text.isEmpty {
          let parsed = AttributedBodyParser.parse(body)
          resolvedText = parsed.plainText
          markdownText = parsed.markdown != parsed.plainText ? parsed.markdown : nil
        }
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
          resolvedText = transcription
          markdownText = nil
        }
        let resolvedReplyToGUID: String? =
          !threadOriginatorGUID.isEmpty
          ? threadOriginatorGUID
          : replyToGUID(associatedGuid: associatedGuid, associatedType: associatedType)
        let isEdited = (dateEditedRaw ?? 0) > 0
        let dateEdited: Date? = isEdited ? appleDate(from: dateEditedRaw) : nil
        messages.append(
          Message(
            rowID: rowID,
            chatID: chatID,
            sender: sender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachments,
            guid: guid,
            replyToGUID: resolvedReplyToGUID,
            markdownText: markdownText,
            isEdited: isEdited,
            dateEdited: dateEdited,
            threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID,
            threadOriginatorPart: threadOriginatorPart.isEmpty ? nil : threadOriginatorPart
          ))
      }
      return messages
    }
  }

  public func messagesAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn = hasThreadOriginator ? "m.thread_originator_guid" : "NULL"
    let threadOriginatorPartColumn = hasThreadOriginator ? "m.thread_originator_part" : "NULL"
    let dateEditedColumn = hasDateEdited ? "m.date_edited" : "NULL"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid,
             \(threadOriginatorPartColumn) AS thread_originator_part,
             \(dateEditedColumn) AS date_edited
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID > ?\(reactionFilter)
      """
    var bindings: [Binding?] = [afterRowID]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let rowID = int64Value(row[0]) ?? 0
        let resolvedChatID = int64Value(row[1]) ?? chatID ?? 0
        let handleID = int64Value(row[2])
        var sender = stringValue(row[3])
        let text = stringValue(row[4])
        let date = appleDate(from: int64Value(row[5]))
        let isFromMe = boolValue(row[6])
        let service = stringValue(row[7])
        let isAudioMessage = boolValue(row[8])
        let destinationCallerID = stringValue(row[9])
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        let guid = stringValue(row[10])
        let associatedGuid = stringValue(row[11])
        let associatedType = intValue(row[12])
        let attachments = intValue(row[13]) ?? 0
        let body = dataValue(row[14])
        let threadOriginatorGUID = stringValue(row[15])
        let threadOriginatorPart = stringValue(row[16])
        let dateEditedRaw = int64Value(row[17])
        var resolvedText = text
        var markdownText: String?
        if text.isEmpty {
          let parsed = AttributedBodyParser.parse(body)
          resolvedText = parsed.plainText
          markdownText = parsed.markdown != parsed.plainText ? parsed.markdown : nil
        }
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
          resolvedText = transcription
          markdownText = nil
        }
        let resolvedReplyToGUID: String? =
          !threadOriginatorGUID.isEmpty
          ? threadOriginatorGUID
          : replyToGUID(associatedGuid: associatedGuid, associatedType: associatedType)
        let isEdited = (dateEditedRaw ?? 0) > 0
        let dateEdited: Date? = isEdited ? appleDate(from: dateEditedRaw) : nil
        messages.append(
          Message(
            rowID: rowID,
            chatID: resolvedChatID,
            sender: sender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachments,
            guid: guid,
            replyToGUID: resolvedReplyToGUID,
            markdownText: markdownText,
            isEdited: isEdited,
            dateEdited: dateEdited,
            threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID,
            threadOriginatorPart: threadOriginatorPart.isEmpty ? nil : threadOriginatorPart
          ))
      }
      return messages
    }
  }
}
