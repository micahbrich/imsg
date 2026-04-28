# RPC

JSON-RPC 2.0 server over stdin/stdout. No daemon, no TCP port — the caller spawns `imsg-plus rpc` and communicates via stdio.

## Transport

- stdin/stdout, one JSON object per line
- JSON-RPC 2.0 framing (`jsonrpc`, `id`, `method`, `params`)
- Notifications (server → client) omit `id`

## Lifecycle

- Caller spawns `imsg-plus rpc [--no-auto-read] [--no-auto-typing] [--verbose]`
- Process stays alive for watch subscriptions + direct sends
- Closes when stdin closes

## Methods

### `chats.list`

Params:
- `limit` (int, default 20)

Result: `{ "chats": [Chat] }`

### `messages.history`

Params:
- `chat_id` (int, required)
- `limit` (int, default 50)
- `participants` (array, optional)
- `start` / `end` (ISO8601, optional)
- `attachments` (bool, default false)

Result: `{ "messages": [Message] }`

### `watch.subscribe`

Params:
- `chat_id` (int, optional)
- `since_rowid` (int, optional)
- `participants` (array, optional)
- `start` / `end` (ISO8601, optional)
- `attachments` (bool, default false)
- `stale_threshold` (int, seconds, default 30)

Result: `{ "subscription": 1 }`

Notifications:
- `message` — new message received
- `stale_send` — sent message not appearing in chat.db after threshold
- `heartbeat` — keep-alive every 15 minutes

### `watch.unsubscribe`

Params:
- `subscription` (int, required)

Result: `{ "ok": true }`

### `send`

Sends immediately with automatic idempotency and explicit outcomes.

Params (direct):
- `to` (string) — phone number or email
- `text` (string, optional)
- `file` (string, optional)
- `service` ("imessage" | "sms" | "auto", default "auto")
- `region` (string, default "US")
- `idempotency_key` (string, optional — auto-generated when omitted; auto keys dedupe for 10s, explicit keys for 120s)

Params (group/existing chat):
- `chat_id` or `chat_identifier` or `chat_guid` (one required; `chat_id` preferred)
- `text` / `file` / `service` / `region` as above

Result (`sent`):
`{ "ok": true, "outcome": "sent", "duplicate": false, "idempotency_key": "...", "message_id": 123, "id": 123, "guid": "..." }`

Result (`duplicate`):
`{ "ok": true, "outcome": "duplicate", "duplicate": true, "idempotency_key": "...", "in_flight": false, "previous_status": "sent", "reason": "recent_sent" }`

Error outcome (`unknown_outcome`):
JSON-RPC error with `error.data.outcome = "unknown_outcome"`

Error outcome (`failed`):
JSON-RPC error with `error.data.outcome = "failed"`

### `messages.react`

Params:
- `to` (string, required)
- `guid` (string, required — message GUID to react to)
- `type` (string, required — love, like, dislike, laugh, emphasis, question)
- `service` (string, optional)
- `region` (string, optional)

Result: `{ "ok": true }`

### `typing.set`

Requires bridge (dylib injected into Messages.app).

Params:
- `handle` (string, required — phone number or email)
- `state` ("on" | "off", required)

Result: `{ "ok": true }`

### `messages.markRead`

Requires bridge.

Params:
- `handle` (string, required)

Result: `{ "ok": true }`

## Notifications

Server-initiated notifications (no `id` field):

| Method | Params | Trigger |
|---|---|---|
| `message` | `{ subscription, message: Message }` | New message in watched chat |
| `stale_send` | `{ subscription, message }` | Sent message not in chat.db after threshold |
| `heartbeat` | `{ subscription }` | Keep-alive (every 15 min) |

## Objects

### Chat

```json
{
  "id": 1,
  "name": "John",
  "identifier": "+14155551212",
  "guid": "iMessage;-;+14155551212",
  "service": "iMessage",
  "is_group": false,
  "last_message_at": "2026-03-28T12:00:00.000Z",
  "participants": ["+14155551212"]
}
```

### Message

```json
{
  "id": 14245,
  "chat_id": 1,
  "guid": "ABC-123",
  "reply_to_guid": null,
  "sender": "+14155551212",
  "is_from_me": false,
  "text": "Hello",
  "created_at": "2026-03-28T12:00:00.000Z",
  "attachments": [],
  "reactions": [],
  "chat_identifier": "+14155551212",
  "chat_guid": "iMessage;-;+14155551212",
  "chat_name": "John",
  "participants": ["+14155551212"],
  "is_group": false
}
```

## Examples

```json
{"jsonrpc":"2.0","id":1,"method":"chats.list","params":{"limit":5}}
{"jsonrpc":"2.0","id":2,"method":"send","params":{"to":"+14155551212","text":"hello","idempotency_key":"abc-123"}}
{"jsonrpc":"2.0","id":3,"method":"watch.subscribe","params":{"attachments":true}}
{"jsonrpc":"2.0","id":4,"method":"typing.set","params":{"handle":"+14155551212","state":"on"}}
```
