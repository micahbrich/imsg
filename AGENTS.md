# Repository Guidelines

## Project Overview

imsg-plus is a macOS CLI for sending and reading iMessage/SMS from the terminal. It was rewritten from Swift to TypeScript in v2.0 for stability and maintainability.

## Project Structure

```
src/
  index.ts      CLI entry point — arg parsing and command dispatch
  db.ts         Read-only SQLite access to ~/Library/Messages/chat.db
  send.ts       Message sending + tapback reactions via AppleScript
  watch.ts      Real-time message streaming (fs.watch + polling fallback)
  bridge.ts     IPC bridge to injected Objective-C dylib (typing, read receipts)
  queue.ts      SQLite-backed FIFO job queue (~/.imsg-plus/queue.db)
  worker.ts     Background job processor with retry logic
  rpc.ts        JSON-RPC 2.0 server over stdin/stdout
  filter.ts     Query filter parsing (participants, date ranges)
  json.ts       Snake_case JSON serialization for CLI/RPC output
  types.ts      Core TypeScript interfaces (Chat, Message, Attachment, Filter, etc.)

Sources/IMsgHelper/
  IMsgInjected.m    Objective-C dylib injected into Messages.app via DYLD_INSERT_LIBRARIES
  main.m            Legacy standalone helper (not used in v2)

src/__tests__/      Vitest test files
```

## Build, Test, and Development Commands

- `npm install` — install dependencies
- `make build` — compile TypeScript + build dylib
- `make build-dylib` — build only the injectable Objective-C dylib (arm64e)
- `make dev ARGS="..."` — run CLI with tsx (no build step needed)
- `npm test` — run vitest test suite
- `npx tsc --noEmit` — type-check without emitting
- `make install` — symlink binary to /usr/local/bin, copy dylib to /usr/local/lib
- `make clean` — remove build artifacts

## Key Dependencies

- `arg` — CLI argument parsing
- `better-sqlite3` — SQLite bindings (read-only access to chat.db, read-write for queue.db)
- `libphonenumber-js` — phone number normalization to E.164
- `vitest` — test framework
- `memfs` — filesystem mocking in tests
- `tsx` — TypeScript execution for development

## Advanced Features Architecture

### Dylib Injection

Advanced features (typing indicators, read receipts) require the private IMCore framework, only available inside Messages.app's process. We inject `imsg-plus-helper.dylib` via `DYLD_INSERT_LIBRARIES`.

**Key files:**
- `Sources/IMsgHelper/IMsgInjected.m` — Objective-C dylib loaded into Messages.app
- `src/bridge.ts` — TypeScript IPC bridge to the dylib

### IPC Mechanism

File-based JSON IPC between the CLI and the injected dylib:
- **Command file**: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-command.json`
- **Response file**: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-response.json`
- **Lock file**: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-ready`

The dylib watches the command file and writes responses. The TypeScript side polls for responses with a 10-second timeout.

### IMCore Framework Access

The dylib uses Objective-C runtime to access IMCore classes:
- `IMChatRegistry` — find chats by handle/identifier
- `IMChat` — chat objects with `setLocalUserIsTyping:`, `markAllMessagesAsRead`

### Implementation Status

- Typing indicators: working via `IMChat.setLocalUserIsTyping:`
- Read receipts: working via `IMChat.markAllMessagesAsRead`
- Tapbacks via dylib: in progress (currently sent via AppleScript)

## Database Access

- `chat.db` is opened **read-only** (`readonly: true`) with a 5-second busy timeout
- `queue.db` is opened read-write in WAL mode for concurrent access
- Schema detection handles different macOS versions (reactions, audio transcriptions, delivery status columns)
- Apple epoch (2001-01-01) + nanosecond precision for timestamps

## Coding Style

- TypeScript strict mode, ES2022 target, Node16 module resolution
- CLI flags: long-form kebab-case (`--chat-id`, `--attachments`)
- JSON output: snake_case keys
- Prefer early returns and small pure functions
- No unnecessary abstractions

## Testing Guidelines

- Tests in `src/__tests__/*.test.ts` using vitest
- Use in-memory SQLite databases and `memfs` for filesystem mocking
- No dependency on a live Messages database
- Add regression tests for parsing, filtering, and attachment handling changes

## Commit & Pull Request Guidelines

- Use short lowercase prefixes: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `ci:`
- Imperative mood (e.g., `fix: handle missing attachments`)
- Keep changesets focused — avoid drive-by refactors
- PRs should include: description, steps to verify, test output

## Security & macOS Permissions

- Full Disk Access required to read `~/Library/Messages/chat.db`
- Automation permission required for AppleScript sends (re-grant after every rebuild)
- SIP must be disabled for dylib injection (advanced features only)
