# imsg-plus

Send and read iMessage/SMS from the terminal. Typing indicators, read receipts, tapback reactions, a FIFO send queue, and a JSON-RPC server — all from the command line.

Originally created by [Peter Steinberger](https://github.com/steipete/imsg). This is a ground-up rewrite (Go → Swift → **TypeScript**) focused on stability, testability, and long-term maintainability.

## How it works

imsg-plus reads messages directly from the macOS Messages database (`chat.db`) and sends via AppleScript. Advanced features like typing indicators and read receipts use an Objective-C dylib injected into Messages.app to access Apple's private IMCore framework.

**No server, no daemon, no account credentials.** Everything runs locally on your Mac.

## Requirements

- macOS 14+ with Messages.app signed in
- Node.js 20+
- **Full Disk Access** for your terminal (to read `~/Library/Messages/chat.db`)
- **Automation permission** for imsg-plus to control Messages.app (see [Permissions](#permissions))
- For SMS relay: enable "Text Message Forwarding" on your iPhone → this Mac
- For advanced features (typing, read receipts): SIP disabled (see [Advanced features setup](#advanced-features-setup))

## Install

```bash
npm install
make install
```

This compiles TypeScript, builds the Objective-C dylib, symlinks the binary to `/usr/local/bin/imsg-plus`, and copies the dylib to `/usr/local/lib/`.

To uninstall:

```bash
make uninstall
```

## Commands

### chats — List conversations

```bash
imsg-plus chats [--limit 20] [--json]
```

### history — View message history

```bash
imsg-plus history --chat-id <id> [--limit 50] [--json] [--attachments] \
  [--participants +15551234567,...] [--start 2025-01-01T00:00:00Z] [--end 2025-02-01T00:00:00Z]
```

### watch — Stream new messages in real time

```bash
imsg-plus watch [--chat-id <id>] [--since-rowid <n>] [--debounce 250] [--json] [--attachments] \
  [--participants ...] [--start ...] [--end ...]
```

Uses filesystem events on `chat.db` with a polling fallback. Messages are yielded as they arrive.

### send — Send a message

```bash
imsg-plus send --to <phone-or-email> [--text "hello"] [--file /path/to/image.jpg] \
  [--service imessage|sms|auto] [--region US]
```

Send to a group chat by targeting an existing conversation:

```bash
imsg-plus send --chat-id <id> --text "hello group"
imsg-plus send --chat-identifier "chat123456" --text "hello"
imsg-plus send --chat-guid "iMessage;+;chat123456" --text "hello"
```

Phone numbers are normalized to E.164 automatically (`--region` defaults to US).

### react — Send a tapback reaction

```bash
imsg-plus react --to <phone-or-email> --guid <message-guid> --type love|like|dislike|laugh|emphasis|question \
  [--service imessage|sms] [--region US]
```

### typing — Control typing indicator

Requires [advanced features](#advanced-features-setup).

```bash
imsg-plus typing --handle <phone-or-email> --state on|off
```

### read — Mark messages as read

Requires [advanced features](#advanced-features-setup).

```bash
imsg-plus read --handle <phone-or-email>
```

### status — Check feature availability

```bash
imsg-plus status [--json]
```

Reports whether basic features (send/receive) and advanced features (typing/read receipts) are available.

### launch — Start Messages.app with dylib injection

```bash
imsg-plus launch [--dylib <path>] [--quiet]
imsg-plus launch --kill-only
```

Kills any running Messages instance, injects the dylib, and launches a fresh one.

### enqueue — Queue a message for reliable delivery

```bash
imsg-plus enqueue --to <phone> --text "hello" [--retries 3]
```

Same arguments as `send`. Messages are persisted to a local SQLite queue (`~/.imsg-plus/queue.db`) and delivered by the worker. Supports idempotency keys for deduplication.

### worker — Process the message queue

```bash
imsg-plus worker [--poll 1000] [--json]
```

Runs a background loop that dequeues and sends messages. Handles retries automatically (default 3 attempts). Gracefully shuts down on SIGINT/SIGTERM.

### queue — Inspect the job queue

```bash
imsg-plus queue              # list all jobs
imsg-plus queue counts       # show pending/processing/sent/failed counts
imsg-plus queue purge        # delete completed and failed jobs
```

### cleanup — Remove old staged attachments

```bash
imsg-plus cleanup
```

Removes temporary attachment files older than 1 hour from `~/Library/Messages/Attachments/imsg/`.

### Global options

| Flag | Description |
|---|---|
| `--json` | Output as JSON lines (one object per line) |
| `--db <path>` | Path to chat.db (default: `~/Library/Messages/chat.db`) |
| `--verbose` | Verbose logging |
| `--quiet` | Suppress non-essential output |
| `--version` | Print version |

## JSON-RPC server

```bash
imsg-plus rpc [--no-auto-read] [--no-auto-typing] [--verbose]
```

Starts a JSON-RPC 2.0 server over stdin/stdout. Designed for programmatic integration — no TCP port, no daemon. A parent process spawns `imsg-plus rpc` and communicates via line-delimited JSON.

### Methods

| Method | Description |
|---|---|
| `chats.list` | List recent conversations |
| `messages.history` | Fetch message history for a chat |
| `messages.markRead` | Mark messages as read (requires bridge) |
| `messages.react` | Send a tapback reaction |
| `send` | Queue a message for delivery |
| `queue.status` | Get job queue counts |
| `typing.set` | Control typing indicator (requires bridge) |
| `watch.subscribe` | Subscribe to new messages (returns subscription ID) |
| `watch.unsubscribe` | Cancel a subscription |

### `chats.list`

```json
{"jsonrpc":"2.0","id":1,"method":"chats.list","params":{"limit":10}}
```

Returns `{ "chats": [...] }` — each chat includes `id`, `name`, `identifier`, `guid`, `service`, `is_group`, `last_message_at`, and `participants`.

### `messages.history`

```json
{"jsonrpc":"2.0","id":2,"method":"messages.history","params":{"chat_id":1,"limit":50,"attachments":true}}
```

Optional filters: `participants` (array), `start`/`end` (ISO 8601).

### `watch.subscribe` / `watch.unsubscribe`

```json
{"jsonrpc":"2.0","id":3,"method":"watch.subscribe","params":{"chat_id":1}}
```

Returns `{ "subscription": <id> }`. New messages arrive as notifications:

```json
{"jsonrpc":"2.0","method":"message","params":{"subscription":1,"message":{...}}}
```

Subscriptions auto-restart on transient database errors and send a heartbeat every 15 minutes.

### `send`

```json
{"jsonrpc":"2.0","id":4,"method":"send","params":{"to":"+14155551212","text":"hello"}}
```

Messages go through the FIFO queue for reliable delivery. Supports `idempotency_key` for deduplication. You can target by `to` (direct) or `chat_id`/`chat_identifier`/`chat_guid` (group).

### `typing.set` / `messages.markRead`

```json
{"jsonrpc":"2.0","id":5,"method":"typing.set","params":{"handle":"+14155551212","state":true}}
{"jsonrpc":"2.0","id":6,"method":"messages.markRead","params":{"handle":"+14155551212"}}
```

### Auto-behaviors

When the bridge (dylib) is available, the RPC server enables two optional behaviors:

- **Auto-read** — Incoming messages automatically get read receipts (~1s delay). Disable with `--no-auto-read`.
- **Auto-typing** — Outgoing sends show a typing indicator first (~1s before sending). Disable with `--no-auto-typing`.

Both silently skip if the bridge is unavailable.

### Error codes

Standard JSON-RPC 2.0 error codes: `-32700` (parse error), `-32600` (invalid request), `-32601` (method not found), `-32602` (invalid params), `-32603` (internal error).

## JSON output

All JSON output uses snake_case keys.

**Chat object:** `id`, `name`, `identifier`, `guid`, `service`, `is_group`, `last_message_at`, `participants`

**Message object:** `id`, `chat_id`, `guid`, `reply_to_guid`, `sender`, `is_from_me`, `text`, `created_at`, `attachments` (array), `reactions` (array), `chat_identifier`, `chat_guid`, `chat_name`, `participants`, `is_group`

**Attachment object:** `filename`, `transfer_name`, `uti`, `mime_type`, `total_bytes`, `is_sticker`, `original_path`, `missing`

## Group chats

Group chats are identified by `;+;` or `;-;` in the chat identifier (e.g., `iMessage;+;chat1234567890`).

To send to a group, use one of:
- `--chat-id <rowid>` — stable within one database (preferred)
- `--chat-identifier <handle>` — portable across machines
- `--chat-guid <guid>` — portable across machines

Inbound messages in JSON/RPC output include `chat_id`, `chat_identifier`, `chat_guid`, `chat_name`, `participants`, and `is_group` for routing.

## Advanced features setup

Typing indicators and read receipts require injecting an Objective-C dylib into Messages.app to access Apple's private IMCore framework.

### 1. Disable SIP

Reboot into Recovery Mode, open Terminal, and run:

```bash
csrutil disable
```

Reboot normally. (Re-enable later with `csrutil enable` from Recovery Mode.)

### 2. Build and install

```bash
make install
```

### 3. Launch Messages with injection

```bash
imsg-plus launch
```

This kills any running Messages instance, sets `DYLD_INSERT_LIBRARIES`, and starts a fresh one.

### 4. Verify

```bash
imsg-plus status
# Should show: Advanced features — Available
```

### How the bridge works

The dylib (`imsg-plus-helper.dylib`) is loaded into the Messages.app process via `DYLD_INSERT_LIBRARIES`. It accesses IMCore classes (`IMChatRegistry`, `IMChat`) through the Objective-C runtime.

Communication between the CLI and the dylib uses file-based IPC:
- **Command file:** `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-command.json`
- **Response file:** `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-response.json`
- **Lock file:** `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-ready`

Requests have a 10-second timeout. If the dylib is unresponsive, Messages.app is automatically relaunched.

### Troubleshooting advanced features

**"Advanced features: Not available"**
- Run `imsg-plus launch` to restart Messages with injection
- Verify IPC files exist: `ls ~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-*`
- Check SIP is disabled: `csrutil status`

**Typing indicator doesn't appear**
- The typing bubble shows on the *recipient's* device, not yours

**Conflicts with BlueBubbles or other injectors**
- Only one dylib can inject into Messages.app at a time — disable others first

**Security note:** These features use Apple's private frameworks and require SIP disabled, which reduces system security. Intended for personal use. Re-enable SIP when not needed.

## Permissions

### Full Disk Access

Required to read `~/Library/Messages/chat.db`.

System Settings → Privacy & Security → Full Disk Access → add your terminal app.

**Symptoms when missing:** "unable to open database file" or empty output.

### Automation permission

Required for AppleScript to control Messages.app (used by `send` and `react`).

**Symptoms when missing:** `send` commands hang forever with no error. Messages appear in the database but recipients never receive them.

**To grant:** From a **GUI Terminal session** (not SSH), run:

```bash
imsg-plus send --to <your-phone> --text "permission test"
```

macOS will prompt "imsg-plus wants to control Messages.app" — click Allow.

Or manually: System Settings → Privacy & Security → Automation → imsg-plus → enable Messages.

### Why rebuilds break permissions

imsg-plus is ad-hoc signed. macOS ties Automation permissions to the binary's code signature. Every rebuild changes the signature, so macOS silently revokes permission. **After every rebuild, re-grant Automation permission** from a GUI Terminal session.

To make permissions persist across rebuilds, sign with an Apple Developer ID:

```bash
codesign --force --sign "Developer ID Application: Your Name (TEAMID)" /usr/local/bin/imsg-plus
```

This requires an [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year).

## Clawdbot integration

imsg-plus serves as the iMessage backend for [Clawdbot](https://github.com/clawdbot/clawdbot). Clawdbot spawns `imsg-plus rpc` and communicates over stdin/stdout.

```json
{
  "channels": {
    "imessage": {
      "cliPath": "imsg-plus"
    }
  }
}
```

With the dylib active, Clawdbot automatically gets typing indicators before replies and read receipts on incoming messages.

```bash
imsg-plus launch    # start Messages with injection
clawdbot start      # then start Clawdbot
```

## LaunchAgent

Auto-launch Messages with dylib injection on login:

```xml
<!-- ~/Library/LaunchAgents/com.imsg-plus.messages-helper.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.imsg-plus.messages-helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/imsg-plus</string>
        <string>launch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/imsg-plus-launch.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/imsg-plus-launch.log</string>
</dict>
</plist>
```

```bash
cp com.imsg-plus.messages-helper.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.imsg-plus.messages-helper.plist
```

## Architecture

```
src/
  index.ts      CLI entry point and command dispatcher
  db.ts         Read-only SQLite access to ~/Library/Messages/chat.db
  send.ts       Message sending and reactions via AppleScript
  watch.ts      Real-time message streaming (fs events + polling)
  bridge.ts     IPC bridge to injected dylib (typing, read receipts)
  queue.ts      SQLite-backed FIFO job queue (~/.imsg-plus/queue.db)
  worker.ts     Background job processor with retry logic
  rpc.ts        JSON-RPC 2.0 server over stdin/stdout
  filter.ts     Query filter parsing (participants, dates)
  json.ts       Snake_case JSON serialization
  types.ts      TypeScript interfaces (Chat, Message, Attachment, etc.)
```

### Data flow

```
CLI / RPC Client
       │
       ▼
  index.ts / rpc.ts  ─── command dispatch
       │
  ┌────┼─────┬──────────┬──────────┐
  │    │     │          │          │
  ▼    ▼     ▼          ▼          ▼
db.ts send.ts watch.ts queue.ts bridge.ts
  │      │       │        │         │
  │      ▼       │        ▼         ▼
  │  AppleScript │    worker.ts   dylib
  │              │                (IMCore)
  ▼              ▼
chat.db       chat.db
(read-only)   (fs events)
```

## Development

```bash
npm install                     # install dependencies
make dev ARGS="chats --limit 5" # run in dev mode (tsx, no build step)
make build                      # compile TypeScript + dylib
npm test                        # run tests (vitest)
npx tsc --noEmit                # type-check only
```

### Testing

Tests use [vitest](https://vitest.dev) with an in-memory SQLite database and `memfs` for filesystem mocking. No live Messages database needed.

```bash
npm test                        # run all tests
npx vitest run src/__tests__/rpc.test.ts  # run a specific test file
```

### Releasing

1. Update version in `package.json` and `CHANGELOG.md`
2. Ensure tests pass: `npm test`
3. Tag and push: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`
4. Create GitHub release with `gh release create`

## License

MIT — see [LICENSE](LICENSE).

Originally created by [Peter Steinberger](https://github.com/steipete/imsg). v2 rewrite by [Micah Rich](https://github.com/micahbrich).
