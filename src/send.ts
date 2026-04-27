import { execFile } from "node:child_process"
import { copyFileSync, existsSync, mkdirSync, readdirSync, renameSync, statSync, rmSync } from "node:fs"
import { homedir } from "node:os"
import { basename, join, resolve } from "node:path"
import { randomUUID } from "node:crypto"
import { parsePhoneNumber } from "libphonenumber-js"
import type { DB } from "./db.js"
import type { Service } from "./types.js"

export interface SendOptions {
  to?: string
  chatId?: number
  chatIdentifier?: string
  chatGuid?: string
  text?: string
  file?: string
  service?: Service
  region?: string
}

export async function send(opts: SendOptions, db?: DB): Promise<void> {
  if (!opts.text && !opts.file) throw new Error("--text or --file is required")

  const { recipient, chatTarget, service } = pickRecipient(opts, db)
  const attachment = opts.file ? stage(opts.file) : ""

  // Clean up old staged attachments in the background (don't block the send)
  cleanStagedAttachments().catch(() => {})

  await osascript(SEND_SCRIPT, [
    recipient,
    (opts.text ?? "").trim(),
    service,
    attachment,
    attachment ? "1" : "0",
    chatTarget,
    chatTarget ? "1" : "0",
  ])
}

// --- Attachment cleanup ---

const STAGED_DIR = join(homedir(), "Library/Messages/Attachments/imsg")

export async function cleanStagedAttachments(maxAgeMs = 3600000): Promise<number> {
  if (!existsSync(STAGED_DIR)) return 0

  const now = Date.now()
  let removed = 0

  for (const entry of readdirSync(STAGED_DIR)) {
    const dirPath = join(STAGED_DIR, entry)
    try {
      const age = now - statSync(dirPath).mtimeMs
      if (age > maxAgeMs) {
        rmSync(dirPath, { recursive: true, force: true })
        removed++
      }
    } catch (err: any) {
      process.stderr.write(`[cleanup] failed to remove ${dirPath}: ${err.message}\n`)
    }
  }

  return removed
}

// --- Reactions ---

export type TapbackType = "love" | "like" | "dislike" | "laugh" | "emphasis" | "question"

const TAPBACK_MAP: Record<TapbackType, number> = {
  love: 2000,
  like: 2001,
  dislike: 2002,
  laugh: 2003,
  emphasis: 2004,
  question: 2005,
}

export interface ReactOptions {
  to: string
  guid: string
  type: TapbackType
  service?: "imessage" | "sms"
  region?: string
}

export async function react(opts: ReactOptions): Promise<void> {
  if (!TAPBACK_MAP[opts.type]) throw new Error(`Unknown tapback type: ${opts.type}`)

  const service = opts.service ?? "imessage"
  const recipient = normalize(opts.to, opts.region ?? "US")
  const tapbackIndex = TAPBACK_MAP[opts.type]

  await osascript(REACT_SCRIPT, [recipient, opts.guid, String(tapbackIndex), service])
}

const REACT_SCRIPT = `
on run argv
    set theRecipient to item 1 of argv
    set theGuid to item 2 of argv
    set tapbackType to item 3 of argv as integer
    set theService to item 4 of argv

    tell application "Messages"
        if theService is "sms" then
            set targetService to first service whose service type is SMS
        else
            set targetService to first service whose service type is iMessage
        end if
        set targetBuddy to buddy theRecipient of targetService
        send theGuid to targetBuddy with tapback tapbackType
    end tell
end run
`.trim()

// Pure function: options in → exactly one of recipient/chatTarget out

export function pickRecipient(opts: SendOptions, db?: DB) {
  const resolved = applyTargetSpec(opts)
  const service = resolved.service ?? "auto"
  const region = resolved.region ?? "US"
  const directService = service === "auto" ? "imessage" : service
  const hasChat = resolved.chatId != null || resolved.chatIdentifier || resolved.chatGuid

  if (resolved.to && hasChat) throw new Error("Use --to or --chat-*, not both")
  if (!resolved.to && !hasChat) throw new Error("--to or --chat-id is required")

  // Direct send to a phone/email
  if (resolved.to) {
    return { recipient: normalize(resolved.to, region), chatTarget: "", service: directService }
  }

  // Look up chat by numeric ID
  let identifier = resolved.chatIdentifier ?? ""
  let guid = resolved.chatGuid ?? ""
  if (resolved.chatId != null) {
    const info = db?.chat(resolved.chatId)
    if (!info) throw new Error(`Unknown chat id ${resolved.chatId}`)
    identifier = info.identifier
    guid = info.guid
  }

  // If the identifier is really just a phone/email, send directly
  if (identifier && looksLikeHandle(identifier)) {
    return { recipient: normalize(identifier, region), chatTarget: "", service: directService }
  }

  // Chat-based send (group chats, named chats)
  const target = guid || identifier
  if (!target) throw new Error("Missing chat identifier or guid")
  return { recipient: "", chatTarget: target, service }
}

export function applyTargetSpec(opts: SendOptions): SendOptions {
  if (!opts.to) return opts
  if (opts.chatId != null || opts.chatIdentifier || opts.chatGuid) return opts

  const target = opts.to.trim()
  if (!target) return opts

  const prefixedHandle = target.match(/^(imessage|sms):(.+)$/)
  if (prefixedHandle) {
    const prefixedService = prefixedHandle[1] as Service
    const handle = prefixedHandle[2].trim()
    if (!handle) throw new Error(`Invalid target: ${target}`)
    if (opts.service && opts.service !== "auto" && opts.service !== prefixedService) {
      throw new Error(`Conflicting service: ${opts.service} and ${prefixedService}`)
    }
    return { ...opts, to: handle, service: prefixedService }
  }

  if (target.startsWith("chat_id:")) {
    const chatId = Number.parseInt(target.slice("chat_id:".length), 10)
    if (!Number.isFinite(chatId)) throw new Error(`Invalid chat target: ${target}`)
    return { ...opts, to: undefined, chatId }
  }

  if (target.startsWith("chat_guid:")) {
    const chatGuid = target.slice("chat_guid:".length).trim()
    if (!chatGuid) throw new Error(`Invalid chat target: ${target}`)
    return { ...opts, to: undefined, chatGuid }
  }

  if (target.startsWith("chat_identifier:")) {
    const chatIdentifier = target.slice("chat_identifier:".length).trim()
    if (!chatIdentifier) throw new Error(`Invalid chat target: ${target}`)
    return { ...opts, to: undefined, chatIdentifier }
  }

  return { ...opts, to: target }
}

export function typingHandle(opts: SendOptions, db?: DB): string | null {
  const resolved = applyTargetSpec(opts)
  const region = resolved.region ?? "US"

  if (resolved.to) return normalize(resolved.to, region)

  if (resolved.chatIdentifier && looksLikeHandle(resolved.chatIdentifier)) {
    return normalize(resolved.chatIdentifier, region)
  }

  if (resolved.chatId != null) {
    const info = db?.chat(resolved.chatId)
    if (!info || !looksLikeHandle(info.identifier)) return null
    return normalize(info.identifier, region)
  }

  return null
}

export function normalize(input: string, region: string): string {
  try {
    return parsePhoneNumber(input, region as any)?.format("E.164") ?? input
  } catch {
    return input
  }
}

export function looksLikeHandle(value: string): boolean {
  if (value.includes("@")) return true
  return /^[+\d\s()\-]+$/.test(value)
}

function stage(filePath: string): string {
  const src = resolve(filePath.replace(/^~/, homedir()))
  if (!existsSync(src)) throw new Error(`Attachment not found: ${src}`)

  const dir = join(homedir(), "Library/Messages/Attachments/imsg", randomUUID())
  mkdirSync(dir, { recursive: true })
  const tmpDest = join(dir, `.tmp-${basename(src)}`)
  const dest = join(dir, basename(src))

  // Stage atomically: copy to .tmp path first, rename on success
  copyFileSync(src, tmpDest)
  renameSync(tmpDest, dest)
  return dest
}

// Parse AppleScript error numbers from stderr into readable messages
const APPLESCRIPT_ERRORS: Record<number, string> = {
  [-1728]: "Messages.app cannot find the specified recipient",
  [-1712]: "AppleScript timed out waiting for Messages.app",
  [-10004]: "Messages.app is not available or not responding",
  [-1708]: "Messages.app does not understand the command (may need a newer macOS version)",
}

function osascript(script: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = execFile("/usr/bin/osascript", ["-l", "AppleScript", "-", ...args])
    let stderr = ""
    child.stderr?.on("data", (d: Buffer) => (stderr += d))
    child.on("close", (code) => {
      if (code === 0) return resolve()

      const trimmed = stderr.trim()
      const match = trimmed.match(/\((-?\d+)\)/)
      if (match) {
        const errorNum = parseInt(match[1], 10)
        const readable = APPLESCRIPT_ERRORS[errorNum]
        if (readable) return reject(new Error(`${readable} (error ${errorNum})`))
      }
      reject(new Error(trimmed || `osascript exited with code ${code}`))
    })
    child.stdin?.end(script)
  })
}

const SEND_SCRIPT = `
on run argv
    set theRecipient to item 1 of argv
    set theMessage to item 2 of argv
    set theService to item 3 of argv
    set theFilePath to item 4 of argv
    set useAttachment to item 5 of argv
    set chatId to item 6 of argv
    set useChat to item 7 of argv

    tell application "Messages"
        if useChat is "1" then
            set targetChat to chat id chatId
            if theMessage is not "" then
                send theMessage to targetChat
            end if
            if useAttachment is "1" then
                set theFile to POSIX file theFilePath as alias
                send theFile to targetChat
            end if
        else
            if theService is "sms" then
                set targetService to first service whose service type is SMS
            else
                set targetService to first service whose service type is iMessage
            end if
            set targetBuddy to buddy theRecipient of targetService
            if theMessage is not "" then
                send theMessage to targetBuddy
            end if
            if useAttachment is "1" then
                set theFile to POSIX file theFilePath as alias
                send theFile to targetBuddy
            end if
        end if
    end tell
end run
`.trim()
