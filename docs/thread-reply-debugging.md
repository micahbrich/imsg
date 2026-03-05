# Thread Reply Implementation: Debugging Notes

## Problem

Sending messages with `threadIdentifier` set via `IMChat.sendMessage:` did not produce
threaded replies. The `thread_originator_guid` column in the Messages database stayed NULL,
and the message appeared as a standalone message both locally and on the remote device.

## Key Discovery: Two Send Paths

Messages.app has two distinct send paths:

1. **IMCore layer** (`IMChat.sendMessage:`) - Lower-level, used by the daemon
2. **ChatKit layer** (`CKConversation.sendMessage:newComposition:`) - Higher-level, used by the UI

Thread replies sent through the UI go through the ChatKit path, not IMChat directly. The
ChatKit layer communicates thread metadata to the daemon in a way that IMChat.sendMessage:
does not.

## Thread Identifier Format

The `threadIdentifier` property on `IMMessage` uses different formats:

- **Tapback association**: `p:0/<GUID>` (part reference)
- **Thread reply**: `r:0:0:<INDEX>:<GUID>` (reply reference)

The `r:` format maps to database columns:
- `thread_originator_guid` = `<GUID>`
- `thread_originator_part` = `0:0:<INDEX>`

The `<INDEX>` appears to be a ChatKit-internal item index. Using `0` works correctly.

## Working Solution

1. Create `IMMessage` with `threadIdentifier` set to `r:0:0:0:<reply_to_guid>` via the
   `initWithSender:time:text:...:threadIdentifier:` initializer
2. Find the `CKConversation` for the target chat (via `CKConversationList.conversationForExistingChat:`)
3. Send via `CKConversation.sendMessage:newComposition:` with `composition=nil`

## What Didn't Work

- **`IMChat.sendMessage:`** with threadIdentifier set: The daemon ignores the thread metadata
  when sent through this path.
- **`p:0/<GUID>` format**: Even through CKConversation, this format is not recognized as a
  thread reply. The daemon echoes it back on the `IMMessageItem` but doesn't write it to the
  database.
- **Setting `threadOriginator` via KVC**: Loading the originator message via
  `IMChatHistoryController.loadMessageWithGUID:completionBlock:` and setting it on both
  `IMMessage` and `IMMessageItem` via KVC had no effect through `IMChat.sendMessage:`.
- **Direct database writes**: Would only affect local state, not remote delivery.

## Debugging Techniques

### What Was Useful

- **Method swizzling with in-memory logging**: Swizzling `IMChat.sendMessage:`,
  `IMChat._sendMessage:adjustingSender:shouldQueue:`, and
  `CKConversation.sendMessage:newComposition:` to log message properties (threadIdentifier,
  threadOriginator, GUID) and call stacks. Results stored in an `NSMutableArray` and exposed
  via the IPC status response.

- **Runtime method introspection**: Using `class_copyMethodList` to dump available methods on
  `IMMessage`, `CKConversation`, and `IMChat` classes. This revealed the existence of
  `sendMessage:newComposition:` and various thread-related methods.

- **Swizzling incoming item handler**: `IMChat._handleIncomingItem:updateRecipient:suppressNotification:updateReplyCounts:`
  showed that the daemon was echoing back thread info, confirming the data reached the daemon
  but was being ignored (wrong format).

- **Comparing UI vs programmatic sends**: Sending a normal message then replying to it in the
  UI, with swizzles active on both paths, made it clear that the UI uses a completely different
  send path (CKConversation vs IMChat).

### What Wasn't Useful

- **NSLog from injected dylib**: Messages.app's NSLog output does NOT appear in the unified
  system log (`log show`). File-based logging to `/tmp/` also fails due to sandbox restrictions.
  In-memory logging via IPC was the only reliable approach.

- **Iterating one approach at a time**: Trying a single change, rebuilding, relaunching Messages,
  and testing was slow. Testing multiple hypotheses in parallel (multiple formats, multiple send
  paths) would have been faster.

- **Database forensics alone**: Checking DB columns showed *what* was missing but not *why*. The
  breakthrough came from runtime introspection of the live send path.

## Architecture Notes

- `CKConversation` wraps `IMChat` but adds ChatKit-specific behavior
- `CKConversationList.sharedConversationList` provides access to CKConversation instances
- `CKConversation` can be retrieved from an `IMChat` via `conversationForExistingChat:` or
  the `conversation` KVC property on IMChat
- The `newComposition:` parameter can be nil for simple text sends (including thread replies)
- Thread replies do NOT require loading the originator message or setting threadOriginator
  objects when using the CKConversation path
