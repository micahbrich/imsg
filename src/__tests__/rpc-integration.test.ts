import { describe, it, expect, vi, beforeEach } from "vitest"
import { PassThrough } from "node:stream"
import { mkdtempSync, rmSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import type { Chat, Message } from "../types.js"
import { openIdempotency } from "../idempotency.js"

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs")>()
  return {
    ...actual,
    watch: (_path: string, cb?: () => void) => {
      const id = setInterval(() => cb?.(), 50)
      return { close: () => clearInterval(id) }
    },
  }
})

vi.mock("../send.js", () => ({
  send: vi.fn().mockResolvedValue(undefined),
  react: vi.fn().mockResolvedValue(undefined),
  typingHandle: vi.fn().mockReturnValue(null),
  applyTargetSpec: vi.fn((opts: unknown) => opts),
  normalize: vi.fn((value: string) => value),
}))

const { serve } = await import("../rpc.js")
const sendMod = await import("../send.js")
const mockSend = vi.mocked(sendMod.send)

function makeChat(id: number): Chat {
  return {
    id,
    guid: `iMessage;-;chat${id}`,
    identifier: `+1555000${id}`,
    name: `Chat ${id}`,
    service: "iMessage",
    isGroup: false,
    lastMessageAt: new Date("2024-06-01"),
  }
}

function makeMessage(id: number, chatId: number): Message {
  return {
    id,
    chatId,
    guid: `msg-${id}`,
    replyToGuid: null,
    sender: "+15550001",
    text: `Message ${id}`,
    date: new Date("2024-06-01"),
    isFromMe: false,
    service: "iMessage",
    attachments: 0,
  }
}

interface TestHarness {
  stdin: PassThrough
  serverDone: Promise<void>
  sendRequest: (obj: unknown) => void
  readResponse: () => Promise<any>
  readResponseById: (id: number) => Promise<any>
  readAllResponses: (count: number) => Promise<any[]>
}

function createHarness(
  dbOverrides: Record<string, any> = {},
  bridgeOverrides: Record<string, any> = {},
  rpcOverrides: Record<string, any> = {}
): TestHarness {
  const stdin = new PassThrough()
  const stdout = new PassThrough()

  const mockDb = {
    path: "/tmp/fake.db",
    maxRowId: () => 100,
    chats: (limit: number) => [makeChat(1), makeChat(2)].slice(0, limit),
    chat: (id: number) => (id === 1 ? makeChat(1) : null),
    participants: () => ["+15550001", "+15550002"],
    messages: (chatId: number) => [makeMessage(1, chatId), makeMessage(2, chatId)],
    messagesAfter: () => [],
    attachments: () => [],
    undeliveredMessages: () => [],
    findSentMessageMatch: () => null,
    ...dbOverrides,
  }

  const mockBridge = {
    available: false,
    dylibPath: null,
    setTyping: vi.fn().mockResolvedValue(undefined),
    markRead: vi.fn().mockResolvedValue(undefined),
    launch: vi.fn().mockResolvedValue(undefined),
    kill: vi.fn(),
    ...bridgeOverrides,
  }

  const origStdin = process.stdin
  const origStdout = process.stdout
  Object.defineProperty(process, "stdin", { value: stdin, writable: true, configurable: true })
  Object.defineProperty(process, "stdout", { value: stdout, writable: true, configurable: true })

  const tmpDir = mkdtempSync(join(tmpdir(), "imsg-rpc-test-"))
  const idempotencyPath = rpcOverrides.idempotencyPath ?? join(tmpDir, "idempotency.db")

  const serverDone = serve(mockDb as any, mockBridge as any, {
    idempotencyPath,
    confirmTimeoutMs: 200,
    confirmPollMs: 25,
    ...rpcOverrides,
  }).finally(() => {
    Object.defineProperty(process, "stdin", { value: origStdin, writable: true, configurable: true })
    Object.defineProperty(process, "stdout", { value: origStdout, writable: true, configurable: true })
    try {
      rmSync(tmpDir, { recursive: true, force: true })
    } catch {}
  })

  function sendRequest(obj: unknown) {
    stdin.write(JSON.stringify(obj) + "\n")
  }

  const responseQueue: any[] = []
  const waiters: Array<(value: any) => void> = []

  stdout.on("data", (chunk: Buffer) => {
    const lines = chunk.toString().split("\n").filter(Boolean)
    for (const line of lines) {
      try {
        const parsed = JSON.parse(line)
        const waiter = waiters.shift()
        if (waiter) waiter(parsed)
        else responseQueue.push(parsed)
      } catch {}
    }
  })

  function readResponse(): Promise<any> {
    const queued = responseQueue.shift()
    if (queued) return Promise.resolve(queued)
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const idx = waiters.indexOf(resolve)
        if (idx !== -1) waiters.splice(idx, 1)
        reject(new Error("Timeout waiting for response"))
      }, 5000)
      waiters.push((value) => {
        clearTimeout(timeout)
        resolve(value)
      })
    })
  }

  async function readAllResponses(count: number): Promise<any[]> {
    const results: any[] = []
    for (let i = 0; i < count; i++) results.push(await readResponse())
    return results
  }

  async function readResponseById(id: number): Promise<any> {
    while (true) {
      const res = await readResponse()
      if (res.id === id) return res
      responseQueue.push(res)
    }
  }

  return { stdin, serverDone, sendRequest, readResponse, readResponseById, readAllResponses }
}

beforeEach(() => {
  mockSend.mockReset()
  mockSend.mockResolvedValue(undefined)
})

describe("RPC integration", () => {
  it("chats.list returns expected shape", async () => {
    const h = createHarness()
    h.sendRequest({ jsonrpc: "2.0", id: 1, method: "chats.list", params: { limit: 2 } })
    const res = await h.readResponse()

    expect(res.id).toBe(1)
    expect(res.result.chats).toHaveLength(2)
    expect(res.result.chats[0]).toHaveProperty("participants")
    expect(res.result.chats[0]).toHaveProperty("is_group")

    h.stdin.end()
    await h.serverDone
  })

  it("subscribe -> message -> unsubscribe lifecycle works", async () => {
    let callCount = 0
    const h = createHarness({
      messagesAfter: () => {
        callCount++
        if (callCount === 1) return [makeMessage(101, 1)]
        return []
      },
    })

    h.sendRequest({ jsonrpc: "2.0", id: 3, method: "watch.subscribe", params: {} })
    const subRes = await h.readResponse()
    expect(subRes.result.subscription).toBe(1)

    const notification = await h.readResponse()
    expect(notification.method).toBe("message")
    expect(notification.params.subscription).toBe(1)

    h.sendRequest({ jsonrpc: "2.0", id: 4, method: "watch.unsubscribe", params: { subscription: 1 } })
    const unsubRes = await h.readResponse()
    expect(unsubRes.result.ok).toBe(true)

    h.stdin.end()
    await h.serverDone
  })

  it("send returns sent outcome when post-send confirmation matches", async () => {
    const h = createHarness({
      findSentMessageMatch: () => ({ id: 777, guid: "msg-777" }),
    })

    h.sendRequest({
      jsonrpc: "2.0",
      id: 30,
      method: "send",
      params: { to: "+15550001", text: "Hi" },
    })

    const res = await h.readResponseById(30)
    expect(res.result.ok).toBe(true)
    expect(res.result.outcome).toBe("sent")
    expect(res.result.duplicate).toBe(false)
    expect(res.result.message_id).toBe(777)
    expect(res.result.id).toBe(777)
    expect(res.result.guid).toBe("msg-777")

    h.stdin.end()
    await h.serverDone
  })

  it("send returns accepted+unconfirmed when chat.db confirmation does not arrive in short window", async () => {
    // findSentMessageMatch never returns a match — simulates chat.db write lag
    const h = createHarness({
      findSentMessageMatch: () => null,
    })

    h.sendRequest({
      jsonrpc: "2.0",
      id: 300,
      method: "send",
      params: { to: "+15550001", text: "Hi" },
    })

    const res = await h.readResponseById(300)

    // AppleScript succeeded, so this is NOT an error — return accepted non-error result
    expect(res.result.ok).toBe(true)
    expect(res.result.outcome).toBe("accepted")
    expect(res.result.unconfirmed).toBe(true)
    expect(res.result.duplicate).toBe(false)
    expect(res.result).not.toHaveProperty("message_id")
    expect(res.error).toBeUndefined()

    h.stdin.end()
    await h.serverDone
  })

  it("send deduplicates by idempotency_key", async () => {
    const h = createHarness({
      findSentMessageMatch: () => ({ id: 111, guid: "msg-111" }),
    })

    h.sendRequest({
      jsonrpc: "2.0",
      id: 31,
      method: "send",
      params: { to: "+15550001", text: "Hi", idempotency_key: "test-key-1" },
    })
    const res1 = await h.readResponseById(31)
    expect(res1.result.outcome).toBe("sent")
    expect(res1.result.duplicate).toBe(false)

    h.sendRequest({
      jsonrpc: "2.0",
      id: 32,
      method: "send",
      params: { to: "+15550001", text: "Hi", idempotency_key: "test-key-1" },
    })
    const res2 = await h.readResponseById(32)
    expect(res2.result.outcome).toBe("duplicate")
    expect(res2.result.duplicate).toBe(true)
    expect(res2.result.reason).toBe("recent_sent")
    expect(res2.result.previous_status).toBe("sent")
    expect(res2.result.message_id).toBe(111)

    h.stdin.end()
    await h.serverDone
  })

  it("send duplicate while request is still in flight includes machine-readable reason", async () => {
    const tmpDir = mkdtempSync(join(tmpdir(), "imsg-rpc-preclaim-test-"))
    const idempotencyPath = join(tmpDir, "idempotency.db")
    const idempotency = openIdempotency(idempotencyPath)
    idempotency.claim("test-key-in-flight", 120)
    idempotency.close()

    const h = createHarness(
      {
        findSentMessageMatch: () => ({ id: 112, guid: "msg-112" }),
      },
      {},
      { idempotencyPath }
    )

    h.sendRequest({
      jsonrpc: "2.0",
      id: 38,
      method: "send",
      params: { to: "+15550001", text: "Hi", idempotency_key: "test-key-in-flight" },
    })

    const dup = await h.readResponseById(38)
    expect(dup.result.outcome).toBe("duplicate")
    expect(dup.result.in_flight).toBe(true)
    expect(dup.result.previous_status).toBe("in_flight")
    expect(dup.result.reason).toBe("in_flight")

    h.stdin.end()
    await h.serverDone
    rmSync(tmpDir, { recursive: true, force: true })
  })

  it("automatic idempotency expires after 300 seconds; explicit keys (120s) remain live within that window", async () => {
    vi.useFakeTimers()
    try {
      const h = createHarness({
        findSentMessageMatch: () => ({ id: 113, guid: "msg-113" }),
      })

      h.sendRequest({
        jsonrpc: "2.0",
        id: 39,
        method: "send",
        params: { to: "+15550001", text: "Hi" },
      })
      const auto1 = await h.readResponseById(39)
      expect(auto1.result.outcome).toBe("sent")

      // Advance past the 300s auto-idempotency TTL so the key expires
      await vi.advanceTimersByTimeAsync(301_000)

      h.sendRequest({
        jsonrpc: "2.0",
        id: 40,
        method: "send",
        params: { to: "+15550001", text: "Hi" },
      })
      const auto2 = await h.readResponseById(40)
      expect(auto2.result.outcome).toBe("sent")
      expect(auto2.result.duplicate).toBe(false)

      h.sendRequest({
        jsonrpc: "2.0",
        id: 41,
        method: "send",
        params: { to: "+15550001", text: "Hi", idempotency_key: "test-key-explicit-ttl" },
      })
      const explicit1 = await h.readResponseById(41)
      expect(explicit1.result.outcome).toBe("sent")

      // Only 11 more seconds — explicit key (120s TTL) is still alive
      await vi.advanceTimersByTimeAsync(11_000)

      h.sendRequest({
        jsonrpc: "2.0",
        id: 42,
        method: "send",
        params: { to: "+15550001", text: "Hi", idempotency_key: "test-key-explicit-ttl" },
      })
      const explicit2 = await h.readResponseById(42)
      expect(explicit2.result.outcome).toBe("duplicate")
      expect(explicit2.result.reason).toBe("recent_sent")

      h.stdin.end()
      await h.serverDone
    } finally {
      vi.useRealTimers()
    }
  })

  it("AppleScript timeout after send returns ok accepted result (not an error)", async () => {
    // Timeout means the message may have been delivered — do NOT let OpenClaw retry
    mockSend.mockRejectedValueOnce(new Error("AppleScript timed out waiting for Messages.app"))
    const h = createHarness()

    h.sendRequest({
      jsonrpc: "2.0",
      id: 33,
      method: "send",
      params: { to: "+15550001", text: "Hi" },
    })

    const res = await h.readResponseById(33)
    expect(res.result.ok).toBe(true)
    expect(res.result.outcome).toBe("accepted")
    expect(res.result.unconfirmed).toBe(true)
    expect(res.error).toBeUndefined()

    h.stdin.end()
    await h.serverDone
  })

  it("definitive pre-send errors return failed outcome", async () => {
    mockSend.mockRejectedValueOnce(new Error("Attachment not found: /tmp/missing.png"))
    const h = createHarness()

    h.sendRequest({
      jsonrpc: "2.0",
      id: 34,
      method: "send",
      params: { to: "+15550001", text: "Hi" },
    })

    const res = await h.readResponseById(34)
    expect(res.error.code).toBe(-32002)
    expect(res.error.data.outcome).toBe("failed")

    h.stdin.end()
    await h.serverDone
  })

  it("send rejects legacy queue param", async () => {
    const h = createHarness()
    h.sendRequest({
      jsonrpc: "2.0",
      id: 35,
      method: "send",
      params: { to: "+15550001", text: "Hi", queue: false },
    })
    const res = await h.readResponseById(35)
    expect(res.error.code).toBe(-32602)
    expect(res.error.message).toBe("Invalid params")

    h.stdin.end()
    await h.serverDone
  })

  it("queue.status is removed", async () => {
    const h = createHarness()
    h.sendRequest({ jsonrpc: "2.0", id: 36, method: "queue.status", params: {} })
    const res = await h.readResponseById(36)
    expect(res.error.code).toBe(-32601)
    expect(res.error.message).toBe("Method not found")

    h.stdin.end()
    await h.serverDone
  })

  it("stale_send notification is emitted", async () => {
    const staleMsg = {
      id: 201,
      guid: "guid-stale-201",
      chatId: 1,
      text: "Hey are you there?",
      date: new Date("2024-06-01T12:00:00Z"),
    }
    const h = createHarness({
      undeliveredMessages: () => [staleMsg],
    })

    h.sendRequest({ jsonrpc: "2.0", id: 40, method: "watch.subscribe", params: { _stale_check_ms: 100 } })
    const subRes = await h.readResponse()
    expect(subRes.result.subscription).toBe(1)

    const notification = await h.readResponse()
    expect(notification.method).toBe("stale_send")
    expect(notification.params.message.id).toBe(201)

    h.sendRequest({ jsonrpc: "2.0", id: 41, method: "watch.unsubscribe", params: { subscription: 1 } })
    await h.readResponse()
    h.stdin.end()
    await h.serverDone
  })
})
