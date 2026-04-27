import { watch as fsWatch } from "node:fs"
import type { DB } from "./db.js"
import type { Message, Filter } from "./types.js"

export interface WatchOptions {
  chatId?: number
  sinceRowId?: number
  debounce?: number
  filter?: Filter
  excludeFromMe?: boolean
}

export async function* watch(db: DB, opts: WatchOptions = {}): AsyncGenerator<Message> {
  let cursor = opts.sinceRowId ?? db.maxRowId()
  const interval = opts.debounce ?? 250
  const filter = opts.filter

  // Poll for new messages (filters are pushed into the SQL query)
  function poll(): Message[] {
    const msgs = db.messagesAfter(cursor, { chatId: opts.chatId, limit: 100, filter, excludeFromMe: opts.excludeFromMe })
    for (const msg of msgs) {
      if (msg.id > cursor) cursor = msg.id
    }
    return msgs
  }

  // Watch the db files for changes, resolve a promise on each change
  let notify: (() => void) | null = null
  const watchers: ReturnType<typeof fsWatch>[] = []

  for (const suffix of ["", "-wal", "-shm"]) {
    try {
      const w = fsWatch(db.path + suffix, () => notify?.())
      watchers.push(w)
    } catch {
      // File may not exist yet — that's fine
    }
  }

  try {
    // Yield forever until cancelled
    while (true) {
      // Register notify BEFORE polling so no fs events are lost
      // between poll() completing and the callback being set up
      const change = new Promise<void>((resolve) => {
        notify = resolve
        // Fallback poll in case fs events are missed
        setTimeout(resolve, 2000)
      })

      const msgs = poll()
      for (const msg of msgs) yield msg

      // Wait for next fs change
      await change

      // Debounce
      if (interval > 0) {
        await new Promise<void>((r) => setTimeout(r, interval))
      }
    }
  } finally {
    for (const w of watchers) w.close()
  }
}
