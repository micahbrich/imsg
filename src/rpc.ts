import { createHash } from "node:crypto"
import { existsSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { resolve } from "node:path"
import { createInterface } from "node:readline"
import type { Bridge } from "./bridge.js"
import type { DB } from "./db.js"
import { parseFilter } from "./filter.js"
import { openIdempotency } from "./idempotency.js"
import { serializeMessage, serializeUndelivered } from "./json.js"
import {
  applyTargetSpec,
  normalize,
  react,
  send,
  typingHandle,
  type ReactOptions,
  type SendOptions,
  type TapbackType,
} from "./send.js"
import type { Chat, Service } from "./types.js"
import { parseService } from "./types.js"
import { watch } from "./watch.js"

interface RPCOptions {
  verbose?: boolean
  autoRead?: boolean
  autoTyping?: boolean
  idempotencyPath?: string
  idempotencyTtlSecs?: number
  confirmTimeoutMs?: number
  confirmPollMs?: number
}

const CACHE_TTL = 5 * 60 * 1000
const DEFAULT_AUTO_IDEMPOTENCY_TTL_SECS = 300
const DEFAULT_EXPLICIT_IDEMPOTENCY_TTL_SECS = 120
const DEFAULT_CONFIRM_TIMEOUT_MS = 5000
const DEFAULT_CONFIRM_POLL_MS = 100
const EXPLICIT_TYPING_GRACE_MS = 8000
const OUTCOME_UNKNOWN_CODE = -32001
const OUTCOME_FAILED_CODE = -32002

interface CacheEntry<T> {
  value: T
  expiresAt: number
}

function ttlCache<K, V>() {
  const store = new Map<K, CacheEntry<V>>()
  return {
    get(key: K): V | undefined {
      const entry = store.get(key)
      if (!entry) return undefined
      if (Date.now() > entry.expiresAt) {
        store.delete(key)
        return undefined
      }
      return entry.value
    },
    set(key: K, value: V): void {
      store.set(key, { value, expiresAt: Date.now() + CACHE_TTL })
    },
  }
}

export async function serve(db: DB, bridge: Bridge, opts: RPCOptions = {}): Promise<void> {
  const autoRead = opts.autoRead ?? bridge.available
  const autoTyping = opts.autoTyping ?? true
  const verbose = opts.verbose ?? false
  const explicitIdempotencyTtlSecs = opts.idempotencyTtlSecs ?? DEFAULT_EXPLICIT_IDEMPOTENCY_TTL_SECS
  const confirmTimeoutMs = opts.confirmTimeoutMs ?? DEFAULT_CONFIRM_TIMEOUT_MS
  const confirmPollMs = opts.confirmPollMs ?? DEFAULT_CONFIRM_POLL_MS
  const idempotency = openIdempotency(opts.idempotencyPath)
  const explicitTypingSeenAt = new Map<string, number>()

  const chatCache = ttlCache<number, Chat | null>()
  const participantCache = ttlCache<number, string[]>()

  function cachedChat(id: number): Chat | null {
    let c = chatCache.get(id)
    if (c === undefined) {
      c = db.chat(id)
      chatCache.set(id, c)
    }
    return c
  }

  function cachedParticipants(id: number): string[] {
    let p = participantCache.get(id)
    if (p === undefined) {
      p = db.participants(id)
      participantCache.set(id, p)
    }
    return p
  }

  function toWireMessage(msg: ReturnType<DB["messages"]>[number], attachments: ReturnType<DB["attachments"]> = []) {
    const chat = cachedChat(msg.chatId)
    return {
      ...serializeMessage(msg, attachments),
      chat_identifier: chat?.identifier ?? "",
      chat_guid: chat?.guid ?? "",
      chat_name: chat?.name ?? "",
      participants: cachedParticipants(msg.chatId),
      is_group: chat?.isGroup ?? false,
    }
  }

  function toWireChat(chat: Chat) {
    return {
      id: chat.id,
      identifier: chat.identifier,
      guid: chat.guid,
      name: chat.name,
      service: chat.service,
      last_message_at: chat.lastMessageAt?.toISOString() ?? null,
      participants: cachedParticipants(chat.id),
      is_group: chat.isGroup,
    }
  }

  function autoMarkRead(msg: ReturnType<DB["messages"]>[number]) {
    if (!autoRead || msg.isFromMe) return
    const handle = cachedChat(msg.chatId)?.identifier ?? msg.sender
    if (!handle) return
    setTimeout(() => {
      bridge.markRead(handle).catch((err) => log(`[auto-read] error: ${err.message}`))
    }, 1000)
  }

  let nextSubId = 1
  const subs = new Map<number, AbortController>()

  function abortAllSubscriptions() {
    for (const ac of subs.values()) ac.abort()
    subs.clear()
  }

  function startSubscription(
    subId: number,
    ac: AbortController,
    watchOpts: Parameters<typeof watch>[1],
    includeAttachments: boolean,
    excludeFromMe: boolean,
    staleSecs = 30,
    staleCheckMs = 15_000
  ) {
    const RETRY_MS = 2000
    let lastRowId = watchOpts?.sinceRowId

    const notifiedStale = new Set<number>()
    const staleInterval = setInterval(() => {
      if (ac.signal.aborted) return
      try {
        const stale = db.undeliveredMessages(staleSecs)
        for (const msg of stale) {
          if (notifiedStale.has(msg.id)) continue
          notifiedStale.add(msg.id)
          notify("stale_send", { subscription: subId, message: serializeUndelivered(msg) })
        }
      } catch (err: any) {
        log(`[sub ${subId}] stale check error: ${err.message}`)
      }
    }, staleCheckMs)
    ac.signal.addEventListener("abort", () => clearInterval(staleInterval))

    const heartbeatInterval = setInterval(() => {
      if (ac.signal.aborted) return
      notify("heartbeat", { subscription: subId })
    }, 15 * 60 * 1000)
    ac.signal.addEventListener("abort", () => clearInterval(heartbeatInterval))

    ;(async () => {
      while (!ac.signal.aborted) {
        try {
          for await (const msg of watch(db, { ...watchOpts, sinceRowId: lastRowId, excludeFromMe })) {
            if (ac.signal.aborted) return
            lastRowId = msg.id
            notify("message", {
              subscription: subId,
              message: toWireMessage(msg, includeAttachments ? db.attachments(msg.id) : []),
            })
            autoMarkRead(msg)
          }
          return
        } catch (err: any) {
          if (ac.signal.aborted) return
          log(`[sub ${subId}] watch error: ${err.message}, restarting in ${RETRY_MS}ms`)
          notify("error", { subscription: subId, error: { message: err.message }, recovering: true })
          await sleep(RETRY_MS)
        }
      }
    })().catch((err) => {
      if (!ac.signal.aborted) notify("error", { subscription: subId, error: { message: err.message } })
    })
  }

  function respond(id: unknown, result: unknown) {
    if (id != null) emit({ jsonrpc: "2.0", id, result })
  }

  function error(id: unknown, code: number, message: string, data?: unknown) {
    emit({ jsonrpc: "2.0", id: id ?? null, error: { code, message, ...(data !== undefined ? { data } : {}) } })
  }

  function notify(method: string, params: unknown) {
    emit({ jsonrpc: "2.0", method, params })
  }

  function emit(obj: unknown) {
    process.stdout.write(JSON.stringify(obj) + "\n")
  }

  function log(msg: string) {
    if (verbose) process.stderr.write(msg + "\n")
  }

  type Params = Record<string, any>

  const methods: Record<string, (p: Params) => unknown> = {
    "chats.list"(p) {
      return { chats: db.chats(Math.max(int(p.limit) ?? 20, 1)).map(toWireChat) }
    },

    "messages.history"(p) {
      const chatId = need(int(p.chat_id), "chat_id")
      const atts = bool(p.attachments) ?? false
      return {
        messages: db
          .messages(chatId, { limit: Math.max(int(p.limit) ?? 50, 1), filter: parseFilter(p) })
          .map((m) => toWireMessage(m, atts ? db.attachments(m.id) : [])),
      }
    },

    "watch.subscribe"(p) {
      const subId = nextSubId++
      const ac = new AbortController()
      subs.set(subId, ac)
      startSubscription(
        subId,
        ac,
        {
          chatId: int(p.chat_id) ?? undefined,
          sinceRowId: int(p.since_rowid) ?? undefined,
          filter: parseFilter(p),
        },
        bool(p.attachments) ?? false,
        bool(p.exclude_from_me) ?? true,
        int(p.stale_threshold) ?? 30,
        int(p._stale_check_ms) ?? 15_000
      )
      return { subscription: subId }
    },

    "watch.unsubscribe"(p) {
      const subId = need(int(p.subscription), "subscription")
      subs.get(subId)?.abort()
      subs.delete(subId)
      return { ok: true }
    },

    async send(p) {
      if (p.queue !== undefined) throw new InvalidParams("queue param is no longer supported")

      const input = parseSendInput(p)
      const explicitIdempotencyKey = clean(str(p.idempotency_key))
      const idempotencyKey = explicitIdempotencyKey ?? autoIdempotencyKey(input, p)
      const claimTtlSecs = explicitIdempotencyKey
        ? explicitIdempotencyTtlSecs
        : DEFAULT_AUTO_IDEMPOTENCY_TTL_SECS
      const resultTtlSecs = claimTtlSecs
      const claim = idempotency.claim(idempotencyKey, claimTtlSecs)

      if (!claim.claimed) {
        return {
          ok: true,
          outcome: "duplicate",
          duplicate: true,
          in_flight: claim.record.status === "in_flight",
          previous_status: claim.record.status,
          reason: duplicateStatusReason(claim.record.status),
          idempotency_key: idempotencyKey,
          ...(claim.record.messageId != null ? { message_id: claim.record.messageId, id: claim.record.messageId } : {}),
          ...(claim.record.guid ? { guid: claim.record.guid } : {}),
        }
      }

      const typingTarget = typingHandle(input, db)
      const useFallbackTyping = Boolean(
        autoTyping &&
          typingTarget &&
          (!explicitTypingSeenAt.has(typingTarget) ||
            Date.now() - (explicitTypingSeenAt.get(typingTarget) ?? 0) > EXPLICIT_TYPING_GRACE_MS)
      )
      if (useFallbackTyping && typingTarget) {
        bridge.setTyping(typingTarget, true).catch((err) => log(`[typing] fallback on error: ${err.message}`))
      }

      try {
        const sentCursor = db.maxRowId()
        await send(input, db)

        // AppleScript accepted the send — Messages.app has the message.
        // Try a short chat.db confirmation pass to enrich the response with
        // message_id/guid. If chat.db hasn't written it yet (common on loaded
        // systems), return accepted (non-error) so OpenClaw does NOT retry.
        const sentRef = await confirmSentMessage(db, sentCursor, input, confirmTimeoutMs, confirmPollMs)
        if (!sentRef) {
          idempotency.finalize(idempotencyKey, "accepted", resultTtlSecs, {})
          return {
            ok: true,
            outcome: "accepted",
            unconfirmed: true,
            duplicate: false,
            idempotency_key: idempotencyKey,
          }
        }

        idempotency.finalize(idempotencyKey, "sent", resultTtlSecs, {
          messageId: sentRef.id,
          guid: sentRef.guid,
        })

        return {
          ok: true,
          outcome: "sent",
          duplicate: false,
          idempotency_key: idempotencyKey,
          message_id: sentRef.id,
          id: sentRef.id,
          guid: sentRef.guid,
        }
      } catch (err: any) {
        if (err instanceof RpcMethodError) throw err

        const message = err?.message ?? String(err)
        const outcome = classifySendFailure(message)
        if (outcome === "failed") {
          idempotency.finalize(idempotencyKey, "failed", resultTtlSecs, { error: message })
          throw new RpcMethodError(OUTCOME_FAILED_CODE, "Send failed", {
            outcome: "failed",
            idempotency_key: idempotencyKey,
            duplicate: false,
            error: message,
          })
        }

        // AppleScript timed out or gave an ambiguous error — message may have
        // already been delivered. Return accepted (non-error) so OpenClaw does
        // NOT retry and risk a duplicate send.
        idempotency.finalize(idempotencyKey, "accepted", resultTtlSecs, { error: message })
        return {
          ok: true,
          outcome: "accepted",
          unconfirmed: true,
          duplicate: false,
          idempotency_key: idempotencyKey,
        }
      } finally {
        if (useFallbackTyping && typingTarget) {
          bridge.setTyping(typingTarget, false).catch((err) => log(`[typing] fallback off error: ${err.message}`))
        }
      }
    },

    async "messages.react"(p) {
      const to = need(str(p.to) ?? str(p.target), "to")
      const guid = need(str(p.guid), "guid")
      const type = need(str(p.type), "type") as TapbackType
      const validTypes = ["love", "like", "dislike", "laugh", "emphasis", "question"]
      if (!validTypes.includes(type)) throw new InvalidParams(`type must be one of: ${validTypes.join(", ")}`)

      let service: ReactOptions["service"] = "imessage"
      try {
        const parsed = parseService(str(p.service) ?? undefined)
        service = parsed === "auto" ? "imessage" : parsed
      } catch (err: any) {
        throw new InvalidParams(err.message)
      }

      await react({ to, guid, type, service, region: str(p.region) ?? undefined })
      return { ok: true }
    },

    async "typing.set"(p) {
      const handle = need(str(p.handle) ?? str(p.to), "handle")
      const state = need(str(p.state), "state")
      if (state !== "on" && state !== "off") throw new InvalidParams("state must be 'on' or 'off'")

      const service = str(p.service)
      const normalized = typingHandle({
        to: handle,
        service: service ? (service as Service) : undefined,
        region: str(p.region) ?? undefined,
      }) ?? handle

      await bridge.setTyping(normalized, state === "on")
      explicitTypingSeenAt.set(normalized, Date.now())
      return { ok: true }
    },

    async "messages.markRead"(p) {
      const handle = need(str(p.handle) ?? str(p.to), "handle")
      const service = str(p.service)
      const normalized = typingHandle({
        to: handle,
        service: service ? (service as Service) : undefined,
        region: str(p.region) ?? undefined,
      }) ?? handle
      await bridge.markRead(normalized)
      return { ok: true }
    },
  }

  const rl = createInterface({ input: process.stdin, terminal: false })

  process.stdin.on("end", () => {
    abortAllSubscriptions()
  })

  for await (const line of rl) {
    if (!line.trim()) continue

    let req: Params
    try {
      req = JSON.parse(line)
    } catch {
      error(null, -32700, "Parse error")
      continue
    }

    if (!req?.method || typeof req.method !== "string") {
      error(req?.id, -32600, "Invalid Request")
      continue
    }

    const handler = methods[req.method]
    if (!handler) {
      error(req.id, -32601, "Method not found", req.method)
      continue
    }

    try {
      respond(req.id, await handler(req.params ?? {}))
    } catch (err: any) {
      if (err instanceof RpcMethodError) {
        error(req.id, err.code, err.message, err.data)
        continue
      }
      const code = err instanceof InvalidParams ? -32602 : -32603
      error(req.id, code, err instanceof InvalidParams ? "Invalid params" : "Internal error", err.message)
    }
  }

  abortAllSubscriptions()
  idempotency.close()
}

function parseSendInput(p: Record<string, unknown>): SendOptions {
  let service: Service
  try {
    service = parseService(str(p.service) ?? undefined)
  } catch (err: any) {
    throw new InvalidParams(err.message)
  }

  return {
    to: str(p.to) ?? str(p.target) ?? undefined,
    chatId: int(p.chat_id) ?? undefined,
    chatIdentifier: str(p.chat_identifier) ?? undefined,
    chatGuid: str(p.chat_guid) ?? undefined,
    text: str(p.text) ?? undefined,
    file: str(p.file) ?? undefined,
    service,
    region: str(p.region) ?? undefined,
  }
}

function autoIdempotencyKey(input: SendOptions, rawParams: Record<string, unknown>): string {
  const resolved = applyTargetSpec(input)
  const region = resolved.region ?? "US"
  const target = resolved.to
    ? normalizeTargetForKey(resolved.to, region)
    : resolved.chatId != null
      ? `chat_id:${resolved.chatId}`
      : resolved.chatGuid
        ? `chat_guid:${resolved.chatGuid.trim()}`
        : resolved.chatIdentifier
          ? `chat_identifier:${resolved.chatIdentifier.trim()}`
          : ""

  const payload = {
    target,
    text: (resolved.text ?? "").trim(),
    service: resolved.service ?? "auto",
    region,
    file: fileIdentity(resolved.file),
    reply_to: clean(str(rawParams.reply_to)),
    reply_to_id: clean(str(rawParams.reply_to_id)),
    reply_to_guid: clean(str(rawParams.reply_to_guid)),
  }

  const digest = createHash("sha256").update(JSON.stringify(payload)).digest("hex")
  return `auto:${digest}`
}

function normalizeTargetForKey(target: string, region: string): string {
  const trimmed = target.trim()
  if (trimmed.includes("@")) return trimmed.toLowerCase()
  return normalize(trimmed, region).replace(/\s+/g, "")
}

function fileIdentity(file: string | undefined) {
  if (!file) return null
  const absolutePath = resolve(file.replace(/^~/, homedir()))
  if (!existsSync(absolutePath)) {
    return { path: absolutePath, size: null, mtime: null }
  }
  const stats = statSync(absolutePath)
  return {
    path: absolutePath,
    size: stats.size,
    mtime: Math.floor(stats.mtimeMs),
  }
}


function duplicateStatusReason(status: string): string {
  switch (status) {
    case "in_flight":
      return "in_flight"
    case "sent":
      return "recent_sent"
    default:
      return status
  }
}

async function confirmSentMessage(
  db: DB,
  afterRowId: number,
  input: SendOptions,
  timeoutMs: number,
  pollMs: number
): Promise<{ id: number; guid: string } | null> {
  const resolved = applyTargetSpec(input)
  const text = (resolved.text ?? "").trim() || undefined
  const requireAttachment = Boolean(resolved.file)
  const service = resolved.service ?? "auto"
  const chatId = resolved.chatId
  const deadline = Date.now() + timeoutMs

  while (Date.now() <= deadline) {
    const found = db.findSentMessageMatch(afterRowId, { text, requireAttachment, service, chatId })
    if (found) return found
    await sleep(pollMs)
  }

  return null
}

function classifySendFailure(message: string): "failed" | "unknown_outcome" {
  const normalized = message.toLowerCase()

  const definitivePreSendMarkers = [
    "--text or --file is required",
    "use --to or --chat-",
    "--to or --chat-id is required",
    "missing chat identifier or guid",
    "unknown chat id",
    "attachment not found:",
    "invalid target:",
    "invalid chat target:",
    "conflicting service:",
    "messages.app cannot find the specified recipient",
    "messages.app does not understand the command",
  ]
  if (definitivePreSendMarkers.some((m) => normalized.includes(m))) {
    return "failed"
  }

  if (normalized.includes("timed out") || normalized.includes("timeout")) {
    return "unknown_outcome"
  }

  return "unknown_outcome"
}

function clean(value: string | null): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

class RpcMethodError extends Error {
  readonly code: number
  readonly data: unknown

  constructor(code: number, message: string, data: unknown) {
    super(message)
    this.code = code
    this.data = data
  }
}

export class InvalidParams extends Error {}

export function need<T>(value: T | null | undefined, name: string): NonNullable<T> {
  if (value == null) throw new InvalidParams(`${name} is required`)
  return value!
}

export function str(v: unknown): string | null {
  if (typeof v === "string") return v
  if (typeof v === "number") return String(v)
  return null
}

export function int(v: unknown): number | null {
  if (typeof v === "number") return Math.floor(v)
  if (typeof v === "string") {
    const n = parseInt(v, 10)
    return isNaN(n) ? null : n
  }
  return null
}

export function bool(v: unknown): boolean | null {
  if (typeof v === "boolean") return v
  if (v === "true") return true
  if (v === "false") return false
  return null
}
