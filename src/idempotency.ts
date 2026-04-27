import Database from "better-sqlite3"
import { existsSync, mkdirSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

export type SendOutcomeStatus = "in_flight" | "sent" | "accepted" | "unknown_outcome" | "failed"

export interface IdempotencyRecord {
  key: string
  status: SendOutcomeStatus
  expiresAt: number
  updatedAt: number
  messageId: number | null
  guid: string | null
  error: string | null
}

export type IdempotencyDB = ReturnType<typeof openIdempotency>

const DEFAULT_IDEMPOTENCY_PATH = join(homedir(), ".imsg-plus", "idempotency.db")

export function openIdempotency(path = DEFAULT_IDEMPOTENCY_PATH) {
  const dir = dirname(path)
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true })

  const db = new Database(path)
  db.pragma("journal_mode = WAL")
  db.pragma("busy_timeout = 5000")

  db.exec(`
    CREATE TABLE IF NOT EXISTS idempotency (
      key TEXT PRIMARY KEY,
      status TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      message_id INTEGER,
      guid TEXT,
      error TEXT
    )
  `)

  const stmts = {
    select: db.prepare(`SELECT * FROM idempotency WHERE key = ?`),
    purgeExpired: db.prepare(`DELETE FROM idempotency WHERE expires_at <= ?`),
    upsert: db.prepare(`
      INSERT INTO idempotency (key, status, expires_at, updated_at, message_id, guid, error)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        status = excluded.status,
        expires_at = excluded.expires_at,
        updated_at = excluded.updated_at,
        message_id = excluded.message_id,
        guid = excluded.guid,
        error = excluded.error
    `),
  }

  function rowToRecord(row: any): IdempotencyRecord {
    return {
      key: String(row.key),
      status: row.status as SendOutcomeStatus,
      expiresAt: Number(row.expires_at),
      updatedAt: Number(row.updated_at),
      messageId: row.message_id == null ? null : Number(row.message_id),
      guid: row.guid ?? null,
      error: row.error ?? null,
    }
  }

  const claimTxn = db.transaction((key: string, ttlSeconds: number) => {
    const now = Date.now()
    const expiresAt = now + ttlSeconds * 1000
    stmts.purgeExpired.run(now)

    const existing: any = stmts.select.get(key)
    if (existing && Number(existing.expires_at) > now) {
      return { claimed: false, record: rowToRecord(existing) }
    }

    stmts.upsert.run(key, "in_flight", expiresAt, now, null, null, null)
    const row: any = stmts.select.get(key)
    return { claimed: true, record: rowToRecord(row) }
  })

  return {
    claim(key: string, ttlSeconds: number): { claimed: boolean; record: IdempotencyRecord } {
      return claimTxn(key, ttlSeconds)
    },

    finalize(
      key: string,
      status: Exclude<SendOutcomeStatus, "in_flight">,
      ttlSeconds: number,
      opts: { messageId?: number | null; guid?: string | null; error?: string | null } = {}
    ): IdempotencyRecord {
      const now = Date.now()
      const expiresAt = now + ttlSeconds * 1000
      stmts.upsert.run(
        key,
        status,
        expiresAt,
        now,
        opts.messageId ?? null,
        opts.guid ?? null,
        opts.error ?? null
      )
      const row: any = stmts.select.get(key)
      return rowToRecord(row)
    },

    get(key: string): IdempotencyRecord | null {
      const now = Date.now()
      const row: any = stmts.select.get(key)
      if (!row) return null
      if (Number(row.expires_at) <= now) return null
      return rowToRecord(row)
    },

    purgeExpired(): number {
      return stmts.purgeExpired.run(Date.now()).changes
    },

    close(): void {
      db.close()
    },
  }
}
