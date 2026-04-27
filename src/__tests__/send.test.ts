import { describe, it, expect } from "vitest"
import { pickRecipient, applyTargetSpec, normalize, looksLikeHandle, typingHandle } from "../send.js"

describe("pickRecipient", () => {
  it("sends directly to a phone number", () => {
    const result = pickRecipient({ to: "+15551234567", text: "hi" })
    expect(result.recipient).toBe("+15551234567")
    expect(result.chatTarget).toBe("")
    expect(result.service).toBe("imessage")
  })

  it("sends directly to an email", () => {
    const result = pickRecipient({ to: "user@example.com", text: "hi" })
    expect(result.recipient).toBe("user@example.com")
    expect(result.chatTarget).toBe("")
  })

  it("throws when both --to and --chat-id are provided", () => {
    expect(() => pickRecipient({ to: "x", chatId: 1, text: "hi" })).toThrow("not both")
  })

  it("throws when neither --to nor --chat-* is provided", () => {
    expect(() => pickRecipient({ text: "hi" })).toThrow("required")
  })

  it("looks up chat by chatId using db", () => {
    const fakeDb = {
      chat: (id: number) =>
        id === 42
          ? { id: 42, identifier: "chat;+;group", guid: "iMessage;+;chat123", name: "Group", service: "iMessage", isGroup: true }
          : null,
    } as any

    const result = pickRecipient({ chatId: 42, text: "hi" }, fakeDb)
    expect(result.chatTarget).toBe("iMessage;+;chat123")
    expect(result.recipient).toBe("")
  })

  it("throws for unknown chat id", () => {
    const fakeDb = { chat: () => null } as any
    expect(() => pickRecipient({ chatId: 999, text: "hi" }, fakeDb)).toThrow("Unknown chat id")
  })

  it("sends directly when identifier looks like a handle", () => {
    const fakeDb = {
      chat: () => ({ id: 1, identifier: "+15559876543", guid: "iMessage;-;+15559876543", name: "", service: "iMessage", isGroup: false }),
    } as any

    const result = pickRecipient({ chatId: 1, text: "hi" }, fakeDb)
    expect(result.recipient).toBe("+15559876543")
    expect(result.chatTarget).toBe("")
  })

  it("uses specified service instead of auto", () => {
    const result = pickRecipient({ to: "+15551234567", text: "hi", service: "sms" })
    expect(result.service).toBe("sms")
  })

  it("uses chatGuid directly", () => {
    const result = pickRecipient({ chatGuid: "iMessage;+;chat999", text: "hi" })
    expect(result.chatTarget).toBe("iMessage;+;chat999")
  })

  it("uses chatIdentifier directly", () => {
    const result = pickRecipient({ chatIdentifier: "chat;+;group123", text: "hi" })
    expect(result.chatTarget).toBe("chat;+;group123")
  })

  it("parses prefixed iMessage handles", () => {
    const result = pickRecipient({ to: "imessage:+15551234567", text: "hi" })
    expect(result.recipient).toBe("+15551234567")
    expect(result.service).toBe("imessage")
  })

  it("parses prefixed SMS handles", () => {
    const result = pickRecipient({ to: "sms:+15551234567", text: "hi" })
    expect(result.recipient).toBe("+15551234567")
    expect(result.service).toBe("sms")
  })

  it("parses explicit chat targets from --to", () => {
    const result = pickRecipient({ to: "chat_guid:iMessage;+;chat999", text: "hi" })
    expect(result.chatTarget).toBe("iMessage;+;chat999")
  })
})

describe("applyTargetSpec", () => {
  it("converts chat_id targets into chatId", () => {
    expect(applyTargetSpec({ to: "chat_id:42" })).toEqual({ to: undefined, chatId: 42 })
  })

  it("keeps plain handles as direct targets", () => {
    expect(applyTargetSpec({ to: "user@example.com" })).toEqual({ to: "user@example.com" })
  })
})

describe("normalize", () => {
  it("formats US phone numbers to E.164", () => {
    expect(normalize("(555) 123-4567", "US")).toBe("+15551234567")
  })

  it("returns emails unchanged", () => {
    expect(normalize("user@example.com", "US")).toBe("user@example.com")
  })

  it("returns already E.164 numbers unchanged", () => {
    expect(normalize("+15551234567", "US")).toBe("+15551234567")
  })

  it("returns invalid input unchanged", () => {
    expect(normalize("not-a-number", "US")).toBe("not-a-number")
  })
})

describe("looksLikeHandle", () => {
  it("returns true for email addresses", () => {
    expect(looksLikeHandle("user@example.com")).toBe(true)
  })

  it("returns true for phone numbers", () => {
    expect(looksLikeHandle("+15551234567")).toBe(true)
    expect(looksLikeHandle("(555) 123-4567")).toBe(true)
    expect(looksLikeHandle("555 123 4567")).toBe(true)
  })

  it("returns false for chat identifiers", () => {
    expect(looksLikeHandle("chat123;+;group")).toBe(false)
    expect(looksLikeHandle("iMessage;+;chat")).toBe(false)
  })

  it("returns false for empty string", () => {
    expect(looksLikeHandle("")).toBe(false)
  })
})

describe("typingHandle", () => {
  it("returns a normalized handle for prefixed targets", () => {
    expect(typingHandle({ to: "sms:(555) 123-4567" })).toBe("+15551234567")
  })

  it("resolves chatId handles through the database", () => {
    const fakeDb = {
      chat: () => ({ id: 1, identifier: "+15559876543", guid: "iMessage;-;+15559876543", name: "", service: "iMessage", isGroup: false }),
    } as any

    expect(typingHandle({ chatId: 1 }, fakeDb)).toBe("+15559876543")
  })
})
