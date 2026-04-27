import { describe, it, expect } from "vitest"
import Database from "better-sqlite3"
import { nanosToDate, dateToNanos, parseAttributedBody, extractReplyGuid, open } from "../db.js"
import { unlinkSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"

const APPLE_EPOCH = 978307200

describe("nanosToDate / dateToNanos", () => {
  it("round-trips a known date", () => {
    const date = new Date("2024-06-15T12:00:00.000Z")
    const nanos = dateToNanos(date)
    const back = nanosToDate(nanos)
    expect(back.toISOString()).toBe(date.toISOString())
  })

  it("returns Apple epoch for null/zero nanos", () => {
    expect(nanosToDate(null).getTime()).toBe(APPLE_EPOCH * 1000)
    expect(nanosToDate(0).getTime()).toBe(APPLE_EPOCH * 1000)
  })

  it("handles recent dates correctly", () => {
    const date = new Date("2025-01-01T00:00:00.000Z")
    const nanos = dateToNanos(date)
    expect(nanos).toBeGreaterThan(0)
    expect(nanosToDate(nanos).toISOString()).toBe("2025-01-01T00:00:00.000Z")
  })
})

describe("parseAttributedBody", () => {
  it("returns empty string for null/empty", () => {
    expect(parseAttributedBody(null)).toBe("")
    expect(parseAttributedBody(Buffer.alloc(0))).toBe("")
  })

  it("extracts text between TypedStream markers", () => {
    // Build a buffer with 0x01 0x2b ... text ... 0x86 0x84
    const text = "Hello, world!"
    const marker = Buffer.from([0x01, 0x2b])
    const terminator = Buffer.from([0x86, 0x84])
    const textBuf = Buffer.from(text, "utf8")
    const blob = Buffer.concat([marker, textBuf, terminator])
    expect(parseAttributedBody(blob)).toBe(text)
  })

  it("picks the longest segment when multiple exist", () => {
    const marker = Buffer.from([0x01, 0x2b])
    const terminator = Buffer.from([0x86, 0x84])
    const short = Buffer.from("Hi", "utf8")
    const long = Buffer.from("This is the longer text", "utf8")
    const blob = Buffer.concat([marker, short, terminator, Buffer.from([0x00]), marker, long, terminator])
    expect(parseAttributedBody(blob)).toBe("This is the longer text")
  })

  it("falls back to full buffer toString when no markers found", () => {
    const blob = Buffer.from("plain text content")
    expect(parseAttributedBody(blob)).toBe("plain text content")
  })

  it("handles length-prefixed segments", () => {
    const marker = Buffer.from([0x01, 0x2b])
    const terminator = Buffer.from([0x86, 0x84])
    const text = "Test"
    const textBuf = Buffer.from(text, "utf8")
    // Length prefix: first byte = length of remaining segment
    const prefixed = Buffer.concat([Buffer.from([textBuf.length]), textBuf])
    const blob = Buffer.concat([marker, prefixed, terminator])
    expect(parseAttributedBody(blob)).toBe("Test")
  })
})

describe("extractReplyGuid", () => {
  it("returns null for null guid", () => {
    expect(extractReplyGuid(null, null)).toBeNull()
  })

  it("extracts guid after last slash", () => {
    expect(extractReplyGuid("p:0/ABCD-1234", null)).toBe("ABCD-1234")
  })

  it("returns guid as-is when no slash", () => {
    expect(extractReplyGuid("ABCD-1234", null)).toBe("ABCD-1234")
  })

  it("returns null for reaction types (2000-3006)", () => {
    expect(extractReplyGuid("p:0/ABCD-1234", 2000)).toBeNull()
    expect(extractReplyGuid("p:0/ABCD-1234", 2500)).toBeNull()
    expect(extractReplyGuid("p:0/ABCD-1234", 3006)).toBeNull()
  })

  it("returns guid for types outside reaction range", () => {
    expect(extractReplyGuid("p:0/ABCD-1234", 1999)).toBe("ABCD-1234")
    expect(extractReplyGuid("p:0/ABCD-1234", 3007)).toBe("ABCD-1234")
  })

  it("returns full guid when slash is at end", () => {
    // When slash is the last char, there's nothing after it to extract,
    // so the code returns the full guid (slash >= guid.length - 1)
    expect(extractReplyGuid("p:0/", null)).toBe("p:0/")
  })
})

function createDeliveryTestDB(): string {
  const tmpPath = join(tmpdir(), `imsg-delivery-${Date.now()}.db`)
  const db = new Database(tmpPath)
  db.exec(`
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, guid TEXT,
      display_name TEXT, service_name TEXT
    );
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, date INTEGER,
      is_from_me INTEGER, service TEXT, guid TEXT,
      associated_message_guid TEXT, associated_message_type INTEGER,
      attributedBody BLOB, destination_caller_id TEXT, is_audio_message INTEGER,
      is_delivered INTEGER, date_delivered INTEGER, is_sent INTEGER, error INTEGER
    );
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
    CREATE TABLE attachment (
      ROWID INTEGER PRIMARY KEY, filename TEXT, transfer_name TEXT, uti TEXT,
      mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER, user_info BLOB
    );
  `)
  db.exec(`INSERT INTO handle VALUES (1, '+15551234567');`)
  db.exec(`INSERT INTO chat VALUES (1, '+15551234567', 'iMessage;-;+15551234567', 'Alice', 'iMessage');`)
  return tmpPath
}

describe("undeliveredMessages", () => {
  it("returns sent-but-undelivered messages older than threshold", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    const now = new Date()
    // Message sent 60 seconds ago, not delivered
    const sixtySecsAgo = new Date(now.getTime() - 60_000)
    const nanos = dateToNanos(sixtySecsAgo)
    rawDb.exec(`
      INSERT INTO message VALUES (10, 1, 'Stale message', ${nanos}, 1, 'iMessage', 'guid-stale', NULL, NULL, NULL, NULL, 0, 0, 0, 1, 0);
      INSERT INTO chat_message_join VALUES (1, 10);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      const stale = imsg.undeliveredMessages(30, 10)
      expect(stale.length).toBe(1)
      expect(stale[0].id).toBe(10)
      expect(stale[0].guid).toBe("guid-stale")
      expect(stale[0].chatId).toBe(1)
      expect(stale[0].text).toBe("Stale message")
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })

  it("returns [] when messages are delivered", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    const sixtySecsAgo = new Date(Date.now() - 60_000)
    const nanos = dateToNanos(sixtySecsAgo)
    rawDb.exec(`
      INSERT INTO message VALUES (10, 1, 'Delivered', ${nanos}, 1, 'iMessage', 'guid-del', NULL, NULL, NULL, NULL, 0, 1, ${nanos}, 1, 0);
      INSERT INTO chat_message_join VALUES (1, 10);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      expect(imsg.undeliveredMessages(30, 10)).toEqual([])
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })

  it("returns [] when message has error", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    const sixtySecsAgo = new Date(Date.now() - 60_000)
    const nanos = dateToNanos(sixtySecsAgo)
    rawDb.exec(`
      INSERT INTO message VALUES (10, 1, 'Error msg', ${nanos}, 1, 'iMessage', 'guid-err', NULL, NULL, NULL, NULL, 0, 0, 0, 1, 5);
      INSERT INTO chat_message_join VALUES (1, 10);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      expect(imsg.undeliveredMessages(30, 10)).toEqual([])
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })

  it("returns [] when message is too recent (within threshold)", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    // Sent only 5 seconds ago — within the 30s threshold
    const fiveSecsAgo = new Date(Date.now() - 5_000)
    const nanos = dateToNanos(fiveSecsAgo)
    rawDb.exec(`
      INSERT INTO message VALUES (10, 1, 'Recent', ${nanos}, 1, 'iMessage', 'guid-recent', NULL, NULL, NULL, NULL, 0, 0, 0, 1, 0);
      INSERT INTO chat_message_join VALUES (1, 10);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      expect(imsg.undeliveredMessages(30, 10)).toEqual([])
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })

  it("returns [] when delivery columns do not exist", () => {
    // Use the old-style DB without delivery columns
    const tmpPath = join(tmpdir(), `imsg-old-${Date.now()}.db`)
    const rawDb = new Database(tmpPath)
    rawDb.exec(`
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, guid TEXT, display_name TEXT, service_name TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, date INTEGER, is_from_me INTEGER, service TEXT, guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER, attributedBody BLOB, destination_caller_id TEXT, is_audio_message INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
      CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER, user_info BLOB);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      expect(imsg.undeliveredMessages()).toEqual([])
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })
})

describe("findSentMessage", () => {
  it("finds the most recent is_from_me message after a given ROWID", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    const nanos = dateToNanos(new Date())
    rawDb.exec(`
      INSERT INTO message VALUES (10, 1, 'From them', ${nanos}, 0, 'iMessage', 'guid-10', NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0);
      INSERT INTO message VALUES (11, 1, 'From me', ${nanos}, 1, 'iMessage', 'guid-11', NULL, NULL, NULL, NULL, 0, 0, 0, 1, 0);
      INSERT INTO chat_message_join VALUES (1, 10);
      INSERT INTO chat_message_join VALUES (1, 11);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      const msg = imsg.findSentMessage(5)
      expect(msg).toEqual({ id: 11, guid: "guid-11" })
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })

  it("returns null when no message exists after the given ROWID", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      expect(imsg.findSentMessage(999)).toBeNull()
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })
})

describe("findSentMessageMatch", () => {
  it("matches when message.text is populated", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    const nanos = dateToNanos(new Date())
    rawDb.exec(`
      INSERT INTO message VALUES (20, 1, 'Hello there', ${nanos}, 1, 'iMessage', 'guid-20', NULL, NULL, NULL, NULL, 0, 0, 0, 1, 0);
      INSERT INTO chat_message_join VALUES (1, 20);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      const match = imsg.findSentMessageMatch(5, { text: "Hello there" })
      expect(match).toEqual({ id: 20, guid: "guid-20" })
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })

  it("matches via attributedBody when message.text is NULL", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    const nanos = dateToNanos(new Date())

    // Build an attributedBody blob that encodes the text 'Hello attr'
    const text = "Hello attr"
    const marker = Buffer.from([0x01, 0x2b])
    const terminator = Buffer.from([0x86, 0x84])
    const textBuf = Buffer.from(text, "utf8")
    const attrBody = Buffer.concat([marker, textBuf, terminator])

    rawDb.exec(`
      INSERT INTO message VALUES (21, 1, NULL, ${nanos}, 1, 'iMessage', 'guid-21', NULL, NULL, ?, NULL, 0, 0, 0, 1, 0);
      INSERT INTO chat_message_join VALUES (1, 21);
    `)
    // Use a prepared statement to insert the blob
    rawDb.prepare("UPDATE message SET attributedBody = ? WHERE ROWID = 21").run(attrBody)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      // Should match even though message.text is NULL
      const match = imsg.findSentMessageMatch(5, { text: "Hello attr" })
      expect(match).toEqual({ id: 21, guid: "guid-21" })
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })

  it("returns null when text does not match", () => {
    const tmpPath = createDeliveryTestDB()
    const rawDb = new Database(tmpPath)
    const nanos = dateToNanos(new Date())
    rawDb.exec(`
      INSERT INTO message VALUES (22, 1, 'Different text', ${nanos}, 1, 'iMessage', 'guid-22', NULL, NULL, NULL, NULL, 0, 0, 0, 1, 0);
      INSERT INTO chat_message_join VALUES (1, 22);
    `)
    rawDb.close()

    const imsg = open(tmpPath)
    try {
      expect(imsg.findSentMessageMatch(5, { text: "Hello there" })).toBeNull()
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })
})

describe("open (file-based)", () => {
  function createTestDB(): string {
    const tmpPath = join(tmpdir(), `imsg-open-${Date.now()}.db`)
    const db = new Database(tmpPath)
    db.exec(`
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT
      );
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        attributedBody BLOB,
        destination_caller_id TEXT,
        is_audio_message INTEGER
      );
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER,
        user_info BLOB
      );
    `)
    db.exec(`
      INSERT INTO handle VALUES (1, '+15551234567');
      INSERT INTO chat VALUES (1, '+15551234567', 'iMessage;-;+15551234567', 'Alice', 'iMessage');
      INSERT INTO chat VALUES (2, 'chat123;+;group', 'iMessage;+;chat123', 'Group Chat', 'iMessage');
      INSERT INTO message VALUES (1, 1, 'Hello', 700000000000000000, 0, 'iMessage', 'guid-1', NULL, NULL, NULL, NULL, 0);
      INSERT INTO message VALUES (2, 1, 'Hey group', 700000000000000001, 0, 'iMessage', 'guid-2', NULL, NULL, NULL, NULL, 0);
      INSERT INTO chat_message_join VALUES (1, 1);
      INSERT INTO chat_message_join VALUES (2, 2);
    `)
    db.close()
    return tmpPath
  }

  it("queries chats with isGroup computed", () => {
    const tmpPath = createTestDB()
    const imsg = open(tmpPath)
    try {
      const chats = imsg.chats(10)
      expect(chats.length).toBe(2)

      const directChat = chats.find((c) => c.id === 1)!
      expect(directChat.isGroup).toBe(false)

      const groupChat = chats.find((c) => c.id === 2)!
      expect(groupChat.isGroup).toBe(true)
      expect(groupChat.guid).toBeTruthy()
    } finally {
      imsg.close()
      unlinkSync(tmpPath)
    }
  })
})
