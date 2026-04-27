import Database from "better-sqlite3"
import { execFileSync } from "node:child_process"
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import type { Chat, Message, Attachment, Filter, UndeliveredMessage } from "./types.js"

const APPLE_EPOCH = 978307200
const NANOS_PER_SEC = 1e9
const DEFAULT_PATH = join(homedir(), "Library/Messages/chat.db")

export function nanosToDate(nanos: number | null): Date {
  if (!nanos) return new Date(APPLE_EPOCH * 1000)
  return new Date((nanos / NANOS_PER_SEC + APPLE_EPOCH) * 1000)
}

export function dateToNanos(date: Date): number {
  return (date.getTime() / 1000 - APPLE_EPOCH) * NANOS_PER_SEC
}

export type DB = ReturnType<typeof open>

export interface SentMessageMatchCriteria {
  text?: string
  service?: string
  requireAttachment?: boolean
  chatId?: number
}

export function open(path = DEFAULT_PATH) {
  if (!existsSync(path)) {
    throw new Error(
      `Cannot open ${path}\n\n` +
        "Grant Full Disk Access to your terminal:\n" +
        "  System Settings → Privacy & Security → Full Disk Access\n"
    )
  }

  const db = new Database(path, { readonly: true, fileMustExist: true })
  db.pragma("busy_timeout = 5000")

  const schema = detectColumns(db)
  const msgColumns = `
            m.ROWID as id, m.handle_id as handleId, h.id as sender,
            IFNULL(m.text, '') as text, m.date as dateNanos, m.is_from_me as isFromMe,
            m.service, ${schema.audioMessage} as isAudio,
            ${schema.destinationCallerId} as destCaller,
            ${schema.guid} as guid, ${schema.associatedGuid} as assocGuid,
            ${schema.associatedType} as assocType,
            (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) as attachCount,
            ${schema.body} as body`

  // --- Row parsing ---

  function parseRow(row: any, chatId: number): Message {
    let sender: string = row.sender ?? ""
    if (!sender && row.destCaller) sender = row.destCaller

    let text: string = row.text
    if (!text && row.body) text = parseAttributedBody(row.body)
    if (row.isAudio && schema.hasAudioTranscription) {
      const t = audioTranscription(row.id)
      if (t) text = t
    }

    return {
      id: row.id,
      chatId,
      guid: row.guid ?? "",
      replyToGuid: extractReplyGuid(row.assocGuid, row.assocType),
      sender,
      text,
      date: nanosToDate(row.dateNanos),
      isFromMe: !!row.isFromMe,
      service: row.service ?? "",
      attachments: row.attachCount ?? 0,
    }
  }

  function audioTranscription(messageId: number): string | null {
    const row: any = db
      .prepare(
        `SELECT a.user_info FROM message_attachment_join maj
         JOIN attachment a ON a.ROWID = maj.attachment_id
         WHERE maj.message_id = ? LIMIT 1`
      )
      .get(messageId)
    if (!row?.user_info) return null
    try {
      const json = execFileSync("plutil", ["-convert", "json", "-o", "-", "-"], {
        input: row.user_info,
        encoding: "utf8",
      })
      return JSON.parse(json)["audio-transcription"] || null
    } catch (err: any) {
      process.stderr.write(`[audio-transcription] error for message ${messageId}: ${err.message}\n`)
      return null
    }
  }

  // --- Filter application (DRY for messages/messagesAfter) ---

  function applyFilter(
    filter: Filter | undefined,
    bindings: any[],
  ): string {
    if (!filter) return ""
    let where = ""
    if (filter.after) {
      where += " AND m.date >= ?"
      bindings.push(dateToNanos(filter.after))
    }
    if (filter.before) {
      where += " AND m.date < ?"
      bindings.push(dateToNanos(filter.before))
    }
    if (filter.participants?.length) {
      const ph = filter.participants.map(() => "?").join(",")
      where += ` AND COALESCE(NULLIF(h.id,''), ${schema.destCallerFilter}) COLLATE NOCASE IN (${ph})`
      bindings.push(...filter.participants)
    }
    return where
  }

  // --- Chat helpers ---

  function isGroup(identifier: string, guid: string): boolean {
    return identifier.includes(";+;") || guid.includes(";+;")
  }

  // --- Public API ---

  return {
    path,
    chats,
    chat,
    participants,
    messages,
    messagesAfter,
    attachments,
    maxRowId,
    undeliveredMessages,
    findSentMessage,
    findSentMessageMatch,
    close: (): void => { db.close() },
  }

  function undeliveredMessages(staleSecs = 30, windowMins = 10): UndeliveredMessage[] {
    if (!schema.hasDeliveryColumns) return []
    const now = new Date()
    const recentCutoff = new Date(now.getTime() - windowMins * 60 * 1000)
    const staleCutoff = new Date(now.getTime() - staleSecs * 1000)
    return db
      .prepare(
        `SELECT m.ROWID as id, m.guid, m.date as dateNanos,
                cmj.chat_id as chatId, IFNULL(m.text,'') as text
         FROM message m
         LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
         WHERE m.is_from_me = 1
           AND m.is_sent = 1
           AND m.is_delivered = 0
           AND m.date > ?
           AND m.date < ?
           AND m.error = 0
         ORDER BY m.ROWID ASC`
      )
      .all(dateToNanos(recentCutoff), dateToNanos(staleCutoff))
      .map((row: any) => ({
        id: row.id,
        guid: row.guid ?? "",
        chatId: row.chatId ?? 0,
        text: (row.text as string).slice(0, 100),
        date: nanosToDate(row.dateNanos),
      }))
  }

  function findSentMessage(afterRowId: number): { id: number; guid: string } | null {
    const row: any = db
      .prepare(
        `SELECT m.ROWID as id, ${schema.guid} as guid
         FROM message m
         WHERE m.ROWID > ? AND m.is_from_me = 1
         ORDER BY m.ROWID DESC LIMIT 1`
      )
      .get(afterRowId)
    if (!row) return null
    return { id: row.id, guid: row.guid ?? "" }
  }

  function findSentMessageMatch(
    afterRowId: number,
    criteria: SentMessageMatchCriteria = {}
  ): { id: number; guid: string } | null {
    const rows: any[] = db
      .prepare(
        `SELECT m.ROWID as id,
                ${schema.guid} as guid,
                IFNULL(m.text, '') as text,
                ${schema.body} as body,
                IFNULL(m.service, '') as service,
                cmj.chat_id as chatId,
                (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) as attachCount
         FROM message m
         LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
         WHERE m.ROWID > ? AND m.is_from_me = 1
         ORDER BY m.ROWID ASC
         LIMIT 50`
      )
      .all(afterRowId)

    const expectedText = criteria.text?.trim()
    const expectedService = criteria.service?.toLowerCase().trim()
    const expectedChatId = criteria.chatId
    const requireAttachment = criteria.requireAttachment ?? false

    for (const row of rows) {
      // On modern macOS, message.text can be NULL with text stored in attributedBody
      const rowText = String(row.text ?? "").trim() || parseAttributedBody(row.body ?? null).trim()
      if (expectedText && rowText !== expectedText) continue
      if (expectedChatId != null && Number(row.chatId ?? 0) !== expectedChatId) continue
      if (requireAttachment && Number(row.attachCount ?? 0) < 1) continue
      if (expectedService && expectedService !== "auto") {
        const actual = String(row.service ?? "").toLowerCase()
        if (expectedService === "sms" && !actual.includes("sms")) continue
        if (expectedService === "imessage" && actual.includes("sms")) continue
      }
      return { id: row.id, guid: row.guid ?? "" }
    }

    return null
  }

  function chats(limit = 20): Chat[] {
    return db
      .prepare(
        `SELECT c.ROWID as id,
            IFNULL(c.guid, '') as guid,
            IFNULL(c.display_name, c.chat_identifier) as name,
            c.chat_identifier as identifier,
            c.service_name as service,
            MAX(m.date) as lastDate
         FROM chat c
         JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
         JOIN message m ON m.ROWID = cmj.message_id
         GROUP BY c.ROWID
         ORDER BY lastDate DESC
         LIMIT ?`
      )
      .all(limit)
      .map((row: any) => ({
        id: row.id,
        guid: row.guid,
        identifier: row.identifier,
        name: row.name,
        service: row.service,
        isGroup: isGroup(row.identifier, row.guid),
        lastMessageAt: nanosToDate(row.lastDate),
      }))
  }

  function chat(chatId: number): Chat | null {
    const row: any = db
      .prepare(
        `SELECT c.ROWID as id,
            IFNULL(c.chat_identifier, '') as identifier,
            IFNULL(c.guid, '') as guid,
            IFNULL(c.display_name, c.chat_identifier) as name,
            IFNULL(c.service_name, '') as service
         FROM chat c WHERE c.ROWID = ? LIMIT 1`
      )
      .get(chatId)
    if (!row) return null
    return {
      id: row.id,
      identifier: row.identifier,
      guid: row.guid,
      name: row.name,
      service: row.service,
      isGroup: isGroup(row.identifier, row.guid),
    }
  }

  function participants(chatId: number): string[] {
    const handles = db
      .prepare(
        `SELECT h.id as handle
         FROM chat_handle_join chj
         JOIN handle h ON h.ROWID = chj.handle_id
         WHERE chj.chat_id = ?
         ORDER BY h.id ASC`
      )
      .all(chatId)
      .map((row: any) => row.handle as string)
      .filter(Boolean)
    return [...new Set(handles)]
  }

  function messages(chatId: number, opts: { limit?: number; filter?: Filter } = {}): Message[] {
    const limit = opts.limit ?? 50
    const bindings: any[] = [chatId]
    const filterWhere = applyFilter(opts.filter, bindings)
    bindings.push(limit)

    return db
      .prepare(
        `SELECT ${msgColumns}
         FROM message m
         JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
         LEFT JOIN handle h ON m.handle_id = h.ROWID
         WHERE cmj.chat_id = ?${schema.noReactions}${filterWhere}
         ORDER BY m.date DESC LIMIT ?`
      )
      .all(...bindings)
      .map((row: any) => parseRow(row, chatId))
  }

  function messagesAfter(afterRowId: number, opts: { chatId?: number; limit?: number; filter?: Filter; excludeFromMe?: boolean } = {}): Message[] {
    const limit = opts.limit ?? 100
    const bindings: any[] = [afterRowId]
    let chatWhere = ""
    if (opts.chatId != null) {
      chatWhere = " AND cmj.chat_id = ?"
      bindings.push(opts.chatId)
    }
    if (opts.excludeFromMe) {
      chatWhere += " AND m.is_from_me = 0"
    }
    chatWhere += applyFilter(opts.filter, bindings)
    bindings.push(limit)

    return db
      .prepare(
        `SELECT ${msgColumns}, cmj.chat_id as chatId
         FROM message m
         LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
         LEFT JOIN handle h ON m.handle_id = h.ROWID
         WHERE m.ROWID > ?${schema.noReactions}${chatWhere}
         ORDER BY m.date ASC, m.ROWID ASC LIMIT ?`
      )
      .all(...bindings)
      .map((row: any) => parseRow(row, row.chatId ?? opts.chatId ?? 0))
  }

  function attachments(messageId: number): Attachment[] {
    return db
      .prepare(
        `SELECT a.filename, a.transfer_name as transferName, a.uti,
            a.mime_type as mimeType, a.total_bytes as totalBytes, a.is_sticker as isSticker
         FROM message_attachment_join maj
         JOIN attachment a ON a.ROWID = maj.attachment_id
         WHERE maj.message_id = ?`
      )
      .all(messageId)
      .map((row: any) => {
        const path = row.filename ? row.filename.replace(/^~/, homedir()) : ""
        return {
          filename: row.filename ?? "",
          transferName: row.transferName ?? "",
          uti: row.uti ?? "",
          mimeType: row.mimeType ?? "",
          totalBytes: Number(row.totalBytes ?? 0),
          isSticker: !!row.isSticker,
          path,
          missing: !path || !existsSync(path),
        }
      })
  }

  function maxRowId(): number {
    const row: any = db.prepare("SELECT MAX(ROWID) as id FROM message").get()
    return Number(row?.id ?? 0)
  }
}

// --- Column detection ---

function detectColumns(db: Database.Database) {
  const msg = columnNames(db, "message")
  const att = columnNames(db, "attachment")
  const hasReactions = msg.has("guid") && msg.has("associated_message_guid") && msg.has("associated_message_type")
  const hasDestCaller = msg.has("destination_caller_id")

  const hasDeliveryColumns = msg.has("is_delivered") && msg.has("is_sent") && msg.has("error")

  return {
    body: msg.has("attributedbody") ? "m.attributedBody" : "NULL",
    guid: hasReactions ? "m.guid" : "NULL",
    associatedGuid: hasReactions ? "m.associated_message_guid" : "NULL",
    associatedType: hasReactions ? "m.associated_message_type" : "NULL",
    destinationCallerId: hasDestCaller ? "m.destination_caller_id" : "NULL",
    audioMessage: msg.has("is_audio_message") ? "m.is_audio_message" : "0",
    noReactions: hasReactions
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : "",
    destCallerFilter: hasDestCaller ? "m.destination_caller_id" : "''",
    hasAudioTranscription: msg.has("is_audio_message") && att.has("user_info"),
    hasDeliveryColumns,
  }
}

function columnNames(db: Database.Database, table: string): Set<string> {
  const rows: any[] = db.prepare(`PRAGMA table_info(${table})`).all()
  return new Set(rows.map((row) => (row.name as string).toLowerCase()))
}

// --- TypedStream parser (attributedBody column) ---
// Apple's TypedStream format uses 0x01 0x2b as a string marker
// and 0x86 0x84 as a segment terminator. We scan for these
// magic bytes to extract the longest readable text segment.

export function parseAttributedBody(blob: Buffer | null): string {
  if (!blob || !blob.length) return ""
  let best = ""

  for (let i = 0; i < blob.length - 1; i++) {
    if (blob[i] !== 0x01 || blob[i + 1] !== 0x2b) continue
    const from = i + 2
    const end = blob.indexOf(Buffer.from([0x86, 0x84]), from)
    if (end === -1) continue

    let segment = blob.subarray(from, end)
    if (segment.length > 1 && segment[0] === segment.length - 1) {
      segment = segment.subarray(1)
    }
    const candidate = segment.toString("utf8").replace(/[\x00-\x1f]/g, "").trim()
    if (candidate.length > best.length) best = candidate
  }

  return best || blob.toString("utf8").replace(/[\x00-\x1f]/g, "").trim()
}

export function extractReplyGuid(guid: string | null, type: number | null): string | null {
  if (!guid) return null
  const slash = guid.lastIndexOf("/")
  const normalized = slash >= 0 && slash < guid.length - 1 ? guid.slice(slash + 1) : guid
  if (!normalized) return null
  if (type != null && type >= 2000 && type <= 3006) return null
  return normalized
}
