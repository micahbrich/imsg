import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { join } from "node:path"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { openIdempotency, type IdempotencyDB } from "../idempotency.js"

let db: IdempotencyDB
let tmpDir: string

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "imsg-idempotency-test-"))
  db = openIdempotency(join(tmpDir, "idempotency.db"))
})

afterEach(() => {
  db.close()
  rmSync(tmpDir, { recursive: true, force: true })
})

describe("openIdempotency", () => {
  it("claims new keys", () => {
    const claim = db.claim("k1", 120)
    expect(claim.claimed).toBe(true)
    expect(claim.record.status).toBe("in_flight")
  })

  it("deduplicates existing live keys", () => {
    const first = db.claim("k1", 120)
    const second = db.claim("k1", 120)
    expect(first.claimed).toBe(true)
    expect(second.claimed).toBe(false)
    expect(second.record.status).toBe("in_flight")
  })

  it("finalizes outcomes with metadata", () => {
    db.claim("k1", 120)
    const done = db.finalize("k1", "sent", 120, { messageId: 42, guid: "guid-42" })
    expect(done.status).toBe("sent")
    expect(done.messageId).toBe(42)
    expect(done.guid).toBe("guid-42")
  })

  it("allows re-claim after ttl expiry", async () => {
    const first = db.claim("k1", 1)
    expect(first.claimed).toBe(true)
    await new Promise((r) => setTimeout(r, 1100))
    const second = db.claim("k1", 1)
    expect(second.claimed).toBe(true)
  })
})
