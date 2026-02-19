# 💬 imsg-plus — Enhanced iMessage CLI with Typing, Reactions & More

An enhanced macOS Messages.app CLI that adds typing indicators, read receipts, tapback reactions, and a JSON-RPC server to the original [imsg](https://github.com/steipete/imsg). Basic features use AppleScript; advanced features use IMCore via an Objective-C helper dylib.

## Features

### Original Features
- List chats, view history, or stream new messages (`watch`).
- Send text and attachments via iMessage or SMS (AppleScript, no private APIs).
- Phone normalization to E.164 for reliable buddy lookup (`--region`, default US).
- Optional attachment metadata output (mime, name, path, missing flag).
- Filters: participants, start/end time, JSON output for tooling.
- Read-only DB access (`mode=ro`), no DB writes.
- Event-driven watch via filesystem events.

### 🆕 New imsg-plus Features
- **Typing indicators** — Show/hide typing bubble with `imsg-plus typing`
- **Read receipts** — Mark messages as read with `imsg-plus read`
- **Tapback reactions** — Send standard reactions or arbitrary emoji (for example 🎉 🤯 🔥) with `imsg-plus react`
- **Status check** — Verify feature availability with `imsg-plus status`
- **Launch command** — Start Messages.app with dylib injection in one step
- **JSON-RPC server** — Programmatic access via `imsg-plus rpc` over stdin/stdout
- **Auto-typing** — Outgoing sends show typing indicator first (1.5–4s based on message length)
- **Auto-read** — Incoming messages automatically get read receipts (~1s delay)
- **Watchdog** — Auto-heal Messages.app sync issues by monitoring imagent logs
- **Objective-C helper** — Bridges Swift to IMCore private framework

## Requirements
- macOS 14+ with Messages.app signed in.
- Full Disk Access for your terminal to read `~/Library/Messages/chat.db`.
- **Automation permission** for imsg-plus to control Messages.app (see [Permissions troubleshooting](#%EF%B8%8F-automation-permission-important) — this is the #1 source of issues).
- For SMS relay, enable "Text Message Forwarding" on your iPhone to this Mac.

## Install

```bash
make install
# Builds the Swift CLI + Objective-C dylib
# Copies binary to /usr/local/bin/imsg-plus
# Copies dylib to /usr/local/lib/imsg-plus-helper.dylib
```

To build just the dylib without installing:
```bash
make build-dylib
```

## Commands

### Original Commands
- `imsg-plus chats [--limit 20] [--json]` — list recent conversations.
- `imsg-plus history --chat-id <id> [--limit 50] [--attachments] [--participants +15551234567,...] [--start 2025-01-01T00:00:00Z] [--end 2025-02-01T00:00:00Z] [--json]`
- `imsg-plus watch [--chat-id <id>] [--since-rowid <n>] [--debounce 250ms] [--attachments] [--participants …] [--start …] [--end …] [--json]`
- `imsg-plus send --to <handle> [--text "hi"] [--file /path/img.jpg] [--service imessage|sms|auto] [--region US]`

### New Commands (imsg-plus)
- `imsg-plus typing --handle <phone/email> --state on|off` — Control typing indicator
- `imsg-plus read --handle <phone/email> [--message-guid <guid>]` — Mark messages as read
- `imsg-plus react --handle <phone/email> --guid <message-guid> --type <reaction-or-emoji> [--remove]` — Send tapback/custom emoji reaction
- `imsg-plus status` — Check if advanced features are available
- `imsg-plus launch` — Launch Messages.app with dylib injection
- `imsg-plus launch --kill-only` — Kill Messages.app without relaunching
- `imsg-plus launch --dylib <path>` — Launch with a custom dylib path
- `imsg-plus rpc` — Start JSON-RPC 2.0 server over stdin/stdout
- `imsg-plus watchdog` — Install/manage the auto-healing watchdog daemon

### Quick samples
```bash
# list 5 chats
imsg-plus chats --limit 5

# list chats as JSON
imsg-plus chats --limit 5 --json

# last 10 messages in chat 1 with attachments
imsg-plus history --chat-id 1 --limit 10 --attachments

# filter by date and emit JSON
imsg-plus history --chat-id 1 --start 2025-01-01T00:00:00Z --json

# live stream a chat
imsg-plus watch --chat-id 1 --attachments --debounce 250ms

# send a picture
imsg-plus send --to "+14155551212" --text "hi" --file ~/Desktop/pic.jpg --service imessage

# show typing indicator
imsg-plus typing --handle "+14155551212" --state on

# mark messages as read
imsg-plus read --handle "+14155551212"

# send a tapback reaction
imsg-plus react --handle "+14155551212" --guid "ABC-123" --type love

# send a custom emoji reaction
imsg-plus react --handle "+14155551212" --guid "ABC-123" --type "🎉"

# check feature availability
imsg-plus status

# launch Messages with dylib injection
imsg-plus launch

# kill Messages without relaunching
imsg-plus launch --kill-only

# install and start the watchdog
imsg-plus watchdog

# check watchdog status
imsg-plus watchdog --status

# view watchdog logs
imsg-plus watchdog --logs

# stop and uninstall watchdog
imsg-plus watchdog --uninstall
```

## RPC Server

`imsg-plus rpc` starts a JSON-RPC 2.0 server over stdin/stdout, designed for programmatic integration (e.g., with [Clawdbot](#clawdbot-integration)).

```bash
imsg-plus rpc [--no-auto-read] [--no-auto-typing]
```

### Methods

| Method | Description |
|---|---|
| `chats.list` | List recent conversations |
| `messages.history` | Fetch message history for a chat |
| `messages.markRead` | Mark messages as read |
| `send` | Send a message |
| `tapback.send` | Send or remove a tapback/custom emoji reaction |
| `typing.set` | Show/hide typing indicator |
| `typing.subscribe` | Subscribe to peer typing updates |
| `typing.unsubscribe` | Unsubscribe from peer typing updates |
| `watch.subscribe` | Subscribe to new messages |
| `watch.unsubscribe` | Unsubscribe from messages |

### Auto-behaviors

Both behaviors require the dylib/bridge to be active. If unavailable, they silently skip.

- **Auto-read** — Incoming messages automatically get read receipts after ~1s delay. Disable with `--no-auto-read`.
- **Auto-typing** — Outgoing sends show a typing indicator first (1.5–4s based on message length) before actually sending. Disable with `--no-auto-typing`.

### Example

```bash
# Start RPC server with defaults (auto-read + auto-typing on)
imsg-plus rpc

# Start with auto-behaviors disabled
imsg-plus rpc --no-auto-read --no-auto-typing
```

```json
{"jsonrpc":"2.0","method":"chats.list","params":{"limit":5},"id":1}
{"jsonrpc":"2.0","method":"send","params":{"to":"+14155551212","text":"hello"},"id":2}
{"jsonrpc":"2.0","method":"tapback.send","params":{"handle":"+14155551212","guid":"ABC-123","type":"love"},"id":3}
{"jsonrpc":"2.0","method":"tapback.send","params":{"handle":"+14155551212","guid":"ABC-123","type":"🎉"},"id":4}
```

### `send` chat routing

The `send` method supports multiple ways to target a chat:

| Parameter | Description |
|---|---|
| `to` | Phone number or email (direct send to a recipient) |
| `chat_id` | Numeric chat ID from `chats.list` |
| `chat_identifier` | Chat identifier string (e.g., `+14155551212`) |
| `chat_guid` | Full chat GUID (e.g., `iMessage;-;+14155551212`) |

Use **either** `to` **or** one of the `chat_*` parameters — not both. The `chat_*` params are useful for replying to existing chats (especially group chats) where you already know the chat ID from a `chats.list` or `watch.subscribe` response.

## Attachment notes
`--attachments` prints per-attachment lines with name, MIME, missing flag, and resolved path (tilde expanded). Only metadata is shown; files aren't copied.

## JSON output
`imsg-plus chats --json` emits one JSON object per chat with fields: `id`, `name`, `identifier`, `service`, `last_message_at`.
`imsg-plus history --json` and `imsg-plus watch --json` emit one JSON object per message with fields: `id`, `chat_id`, `guid`, `reply_to_guid`, `sender`, `is_from_me`, `text`, `created_at`, `attachments` (array of metadata with `filename`, `transfer_name`, `uti`, `mime_type`, `total_bytes`, `is_sticker`, `original_path`, `missing`), `reactions`.
When using `imsg-plus watch --typing --json`, typing updates are emitted as objects with `type: "typing"` and fields `chat_guid`, `chat_id`, `handle`, `is_typing`, `timestamp`.

Note: `reply_to_guid` and `reactions` are read-only metadata.

## Permissions troubleshooting

### Full Disk Access
If you see "unable to open database file" or empty output:
1. Grant Full Disk Access: System Settings → Privacy & Security → Full Disk Access → add your terminal.
2. Ensure Messages.app is signed in and `~/Library/Messages/chat.db` exists.

### ⚠️ Automation Permission (Important!)

imsg-plus uses AppleScript to control Messages.app. macOS requires **Automation permission** for this to work.

**Symptoms when permission is missing:**
- `send` commands hang forever (no error, just blocks)
- Messages appear in chat.db but never actually send
- Works fine from the web UI / database, but recipients never receive them

**How to fix:**

1. **From a GUI Terminal session** (not SSH), run:
   ```bash
   /usr/local/bin/imsg-plus send --to <your-phone> --text "permission test"
   ```
2. macOS will prompt: "imsg-plus wants to control Messages.app"
3. Click **Allow**

Or manually: System Settings → Privacy & Security → Automation → find `imsg-plus` → enable **Messages**

### 🔄 Why Rebuilds Break Permissions

**This is the #1 gotcha with imsg-plus.**

imsg-plus is **ad-hoc signed** (no Apple Developer certificate). macOS ties Automation permissions to the binary's code signature. When you rebuild:

1. The code signature changes
2. macOS invalidates the previous Automation authorization
3. imsg-plus silently loses permission to control Messages.app
4. Since it often runs headlessly (daemon, SSH, cron), macOS can't prompt you — it just denies silently

**After every rebuild, you must re-grant Automation permission** by running a send command from a GUI Terminal session (not SSH).

### Long-term Fix: Developer ID Signing

To make permissions persist across rebuilds, sign the binary with an Apple Developer ID certificate:

```bash
# After building
codesign --force --sign "Developer ID Application: Your Name (TEAMID)" /usr/local/bin/imsg-plus
```

With proper signing, macOS recognizes rebuilds as the "same" app and preserves permissions.

**Note:** This requires an [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year).

## Advanced Features Setup (imsg-plus)

The typing, read receipt, and tapback features require injecting a dylib into Messages.app to access Apple's private IMCore framework.

### Prerequisites

1. **Disable SIP** (System Integrity Protection):
   - Reboot into Recovery Mode (hold Cmd+R during startup, or power button on Apple Silicon)
   - Open Terminal from the Utilities menu
   - Run: `csrutil disable`
   - Reboot normally

2. **Full Disk Access**: Grant your terminal FDA permission in System Settings → Privacy & Security → Full Disk Access

### Setup

```bash
make install          # builds and installs binary + dylib
imsg-plus launch      # starts Messages.app with injection
imsg-plus status      # verify: should show "✅ Available"
```

That's it. The `launch` command replaces the manual `DYLD_INSERT_LIBRARIES` dance — it kills any running Messages instance, injects the dylib, and launches a fresh one.

### Troubleshooting

**"Advanced features: ❌ Not available"**
- Run `imsg-plus launch` to restart Messages with injection
- Check IPC files exist: `ls ~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-*`

**Typing indicator doesn't appear**
- Typing bubbles show on the *recipient's* device, not yours
- Test with another device or ask the recipient to confirm

**Conflicts with BlueBubbles**
- Only one dylib can inject into Messages.app at a time
- Disable BlueBubbles before using imsg-plus advanced features

**Security Warning**
- These features use Apple's private IMCore framework
- Requires SIP disabled, which reduces system security
- The Automation permission (System Settings → Privacy & Security → Automation) is required for AppleScript-based sending. Without it, send commands hang silently — no error, just blocks forever waiting for an auth dialog.
- Intended for personal use and testing only
- Re-enable SIP when not needed: `csrutil enable` (from Recovery Mode)

## Clawdbot Integration

imsg-plus can serve as the iMessage backend for [Clawdbot](https://github.com/clawdbot/clawdbot).

```json
// clawdbot.json
{
  "channels": {
    "imessage": {
      "cliPath": "imsg-plus"
    }
  }
}
```

Clawdbot uses RPC mode (`imsg-plus rpc`) for all communication. With the dylib active, Clawdbot automatically gets:
- **Typing indicators** before replies (simulates natural typing delay)
- **Read receipts** on incoming messages

**Recommended setup:**
```bash
imsg-plus launch       # start Messages with injection
clawdbot start         # then start Clawdbot
```

Or install the [LaunchAgent](#launchagent) for auto-start on login.

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

## Watchdog

The watchdog monitors macOS `imagent` logs for sync failures and automatically restarts Messages.app with dylib injection when issues are detected. This is useful for long-running setups (like Clawdbot) where Messages.app can occasionally lose its connection to iCloud.

### What it monitors

The watchdog watches for `imagent` XPC/sandbox errors in the system logs — these indicate Messages.app has lost sync with iCloud and needs a restart to recover.

### Usage

```bash
# Install and start the watchdog (one command does it all)
imsg-plus watchdog

# Check if it's running
imsg-plus watchdog --status

# View real-time logs
imsg-plus watchdog --logs

# Stop and uninstall
imsg-plus watchdog --uninstall

# Run in foreground (used internally by LaunchAgent)
imsg-plus watchdog --run
```

### How it works

1. Running `imsg-plus watchdog` installs a LaunchAgent (`com.imsg-plus.watchdog.plist`)
2. The LaunchAgent runs `imsg-plus watchdog --run` as a background daemon
3. The daemon monitors `/var/log/system.log` for imagent errors
4. When errors are detected, it runs `imsg-plus launch` to restart Messages.app with proper dylib injection
5. The watchdog survives reboots and auto-starts on login

### Recommended setup

For reliable iMessage automation:

```bash
imsg-plus watchdog     # install watchdog (runs forever, survives reboots)
imsg-plus status       # verify everything is working
```

The watchdog replaces the need for the manual LaunchAgent setup above — it handles both the initial launch and ongoing health monitoring.

## Testing
```bash
make test
```

Note: `make test` applies a small patch to SQLite.swift to silence a SwiftPM warning about `PrivacyInfo.xcprivacy`.

## Linting & formatting
```bash
make lint
make format
```

## Core library
The reusable Swift core lives in `Sources/IMsgCore` and is consumed by the CLI target. Apps can depend on the `IMsgCore` library target directly.
