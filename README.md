# imsg-plus

Send and read iMessage / SMS from the terminal. Typing indicators, read receipts, tapback reactions, and a JSON-RPC server for programmatic integration.

## Install

Requires **Node.js 20+** and **macOS 14+** with Messages.app signed in.

```bash
make install
# Builds TypeScript CLI + Objective-C dylib
# Symlinks to /usr/local/bin/imsg-plus
# Copies dylib to /usr/local/lib/
```

### Permissions

- **Full Disk Access** — System Settings → Privacy & Security → Full Disk Access → add your terminal. Required to read `~/Library/Messages/chat.db`.
- **Automation** — On first `send`, macOS prompts to allow imsg-plus to control Messages.app. Must be granted from a GUI terminal session (not SSH). See [Permissions troubleshooting](#permissions-troubleshooting).

## Commands

```
imsg-plus <command> [options]

  chats       List recent conversations
  history     Show messages for a chat
  watch       Stream incoming messages
  send        Send a message (text and/or attachment)
  react       Send a tapback reaction
  cleanup     Remove old staged attachments
  typing      Control typing indicator
  read        Mark messages as read
  status      Check feature availability
  launch      Launch Messages.app with dylib injection
  rpc         Run JSON-RPC server over stdin/stdout

Global options:
  --json       Output as JSON lines
  --db <path>  Path to chat.db (default: ~/Library/Messages/chat.db)
```

### Examples

```bash
# List 5 recent chats
imsg-plus chats --limit 5 --json

# Last 10 messages in chat 1 with attachments
imsg-plus history --chat-id 1 --limit 10 --attachments

# Stream incoming messages
imsg-plus watch --chat-id 1 --attachments --json

# Send a message
imsg-plus send --to "+14155551212" --text "hello" --file ~/pic.jpg

# Typing indicator
imsg-plus typing --handle "+14155551212" --state on

# Read receipt
imsg-plus read --handle "+14155551212"

# Tapback reaction
imsg-plus react --to "+14155551212" --guid "ABC-123" --type love

# Check feature availability
imsg-plus status

# Launch Messages.app with dylib injection
imsg-plus launch
```

## Send Reliability

`send` is direct and uncertainty-first:

- Automatic idempotency is always on (SQLite-backed TTL cache, default 10s for auto-generated keys, 120s for explicit caller-provided keys).
- If delivery cannot be confirmed in `chat.db`, RPC returns `unknown_outcome` instead of retrying.
- Duplicate requests inside the TTL window return `outcome: "duplicate"` plus a machine-readable `reason` field.

## RPC Server

`imsg-plus rpc` starts a JSON-RPC 2.0 server over stdin/stdout. Designed for integration with orchestration systems like [OpenClaw](https://openclaw.ai).

```bash
imsg-plus rpc [--no-auto-read] [--no-auto-typing] [--verbose]
```

### Methods

| Method | Description |
|---|---|
| `chats.list` | List recent conversations |
| `messages.history` | Fetch message history for a chat |
| `messages.markRead` | Mark messages as read |
| `messages.react` | Send a tapback reaction |
| `send` | Send directly with explicit outcome |
| `typing.set` | Show/hide typing indicator |
| `watch.subscribe` | Subscribe to new messages |
| `watch.unsubscribe` | Unsubscribe from messages |

### Notifications

The server emits JSON-RPC notifications (no `id`) for events:

| Notification | Description |
|---|---|
| `message` | New message received |
| `stale_send` | Sent message not appearing in chat.db |
| `heartbeat` | Keep-alive (every 15 min) |

### Auto-behaviors

- **Auto-read** — Incoming messages get read receipts after ~1s. Disable with `--no-auto-read`.
- **Auto-typing fallback** — If the caller does not send explicit `typing.set` signals, RPC wraps direct sends with best-effort typing on/off.

### Send routing

The `send` method supports multiple targeting options:

| Parameter | Description |
|---|---|
| `to` | Phone number or email (direct send) |
| `chat_id` | Numeric chat ID from `chats.list` |
| `chat_identifier` | Chat identifier string |
| `chat_guid` | Full chat GUID |

### Example

```json
{"jsonrpc":"2.0","id":1,"method":"chats.list","params":{"limit":5}}
{"jsonrpc":"2.0","id":2,"method":"send","params":{"to":"+14155551212","text":"hello"}}
{"jsonrpc":"2.0","id":3,"method":"typing.set","params":{"handle":"+14155551212","state":"on"}}
```

## Advanced Features

Typing indicators, read receipts, and tapback reactions require injecting a dylib into Messages.app to access Apple's private IMCore framework.

### Prerequisites

1. **Disable SIP** (System Integrity Protection):
   - Reboot into Recovery Mode (hold power button on Apple Silicon)
   - Open Terminal → run `csrutil disable` → reboot

2. **Full Disk Access** for your terminal

### Setup

```bash
make install       # builds CLI + dylib
imsg-plus launch   # starts Messages.app with injection
imsg-plus status   # should show "Available"
```

### Bridge Architecture

The bridge uses file-based IPC with an Objective-C dylib injected into Messages.app:

- Command file: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-command.json`
- Response file: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-response.json`
- Lock file: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-ready`

Bridge commands have a 5-second timeout — if Messages.app is unresponsive, commands fail gracefully without blocking sends.

## Permissions Troubleshooting

### Full Disk Access

If you see "unable to open database file":
1. System Settings → Privacy & Security → Full Disk Access → add your terminal
2. Ensure `~/Library/Messages/chat.db` exists

### Automation Permission

imsg-plus uses AppleScript to send messages. macOS requires Automation permission.

**Symptoms when missing:**
- `send` commands hang (no error)
- Messages appear in chat.db but never send

**Fix:** From a GUI terminal (not SSH), run:
```bash
imsg-plus send --to <your-phone> --text "test"
```
Click "Allow" when macOS prompts.

### Rebuilds Break Permissions

imsg-plus is ad-hoc signed. When you rebuild, the code signature changes and macOS invalidates the Automation authorization. **After every rebuild, re-grant permission** by running a send command from a GUI terminal.

For persistent permissions, sign with a Developer ID:
```bash
codesign --force --sign "Developer ID Application: Your Name (TEAMID)" /usr/local/bin/imsg-plus
```

## OpenClaw Integration

imsg-plus serves as the iMessage channel for [OpenClaw](https://openclaw.ai).

```json
{
  "channels": {
    "imessage": {
      "cliPath": "/usr/local/bin/imsg-plus",
      "dbPath": "~/Library/Messages/chat.db"
    }
  }
}
```

OpenClaw spawns `imsg-plus rpc` and handles typing indicators via `typingMode: "instant"` (typing starts when the agent begins processing, stops when the reply is sent).

## Development

```bash
make build       # compile TypeScript + build dylib
make dev ARGS=… # run CLI in dev mode (tsx)
make test        # type-check
make clean       # remove build artifacts
```

## Architecture

```
src/
  index.ts    CLI entry point, command routing
  rpc.ts      JSON-RPC server, subscriptions, direct send outcomes
  db.ts       Read-only SQLite access to chat.db
  idempotency.ts SQLite-backed idempotency state machine (TTL + atomic claims)
  send.ts     AppleScript-based message sending
  watch.ts    Event-driven message streaming (fs.watch + fallback poll)
  bridge.ts   File-based IPC with Messages.app dylib (typing, read receipts)
  filter.ts   Message filtering (participants, date range)
  json.ts     Message serialization
  types.ts    Shared type definitions

Sources/IMsgHelper/
  IMsgInjected.m   Objective-C dylib injected into Messages.app
```

## License

MIT
