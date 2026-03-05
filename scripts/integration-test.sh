#!/bin/bash
#
# Integration test for thread reply, edit, and unsend features.
# Requires: SIP disabled, dylib injected, Messages.app running.
#
set -euo pipefail

TARGET="+61413661735"
IMSG="imsg-plus"
LOG="/tmp/imsg-integration-test.log"

: > "$LOG"

log() { echo "=== $1 ===" | tee -a "$LOG"; }
record() { echo "$1" | tee -a "$LOG"; }

# Find chat ID for the target number
log "Step 0: Find chat ID for $TARGET"
CHAT_JSON=$($IMSG history --chat-id 0 --limit 1 --json 2>/dev/null || true)

# Get chat list and find the right chat
CHATS_JSON=$($IMSG chats --limit 50 --json 2>/dev/null)
CHAT_ID=$(echo "$CHATS_JSON" | jq -r --arg t "$TARGET" 'select(.identifier == $t or (.participants // [] | index($t) != null)) | .id // empty' | head -1)

if [ -z "$CHAT_ID" ]; then
  # Try finding via identifier containing the number
  CHAT_ID=$(echo "$CHATS_JSON" | jq -r --arg t "$TARGET" 'select(.identifier | test($t)) | .id // empty' | head -1)
fi

if [ -z "$CHAT_ID" ]; then
  record "WARNING: Could not find chat ID for $TARGET, will use --to for sends and search history after"
  CHAT_ID=""
fi
record "Chat ID: ${CHAT_ID:-not found}"

# --- Test 1: Send a base message ---
log "Step 1: Send base message"
SEND1_OUT=$($IMSG send --to "$TARGET" --text "integration-test-base-$(date +%s)" --json 2>&1 || true)
record "Send result: $SEND1_OUT"
sleep 3

# Get the GUID of the message we just sent
log "Step 1b: Get GUID of base message from history"
if [ -n "$CHAT_ID" ]; then
  HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 3 --json 2>/dev/null)
else
  # Find the chat by listing recent chats
  CHATS_JSON=$($IMSG chats --limit 10 --json 2>/dev/null)
  CHAT_ID=$(echo "$CHATS_JSON" | jq -r --arg t "$TARGET" 'select(.identifier | test($t; "i")) | .id // empty' | head -1)
  if [ -z "$CHAT_ID" ]; then
    CHAT_ID=$(echo "$CHATS_JSON" | jq -r 'select(.participants != null) | select(.participants[] | test("61413661735")) | .id' | head -1)
  fi
  record "Resolved Chat ID: ${CHAT_ID:-STILL NOT FOUND}"
  if [ -z "$CHAT_ID" ]; then
    record "FATAL: Cannot find chat for $TARGET. Listing all chats:"
    echo "$CHATS_JSON" | jq '.' | tee -a "$LOG"
    exit 1
  fi
  HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 3 --json 2>/dev/null)
fi

BASE_GUID=$(echo "$HISTORY" | jq -r 'select(.is_from_me == true and (.text | test("integration-test-base"))) | .guid' | head -1)
record "Base message GUID: ${BASE_GUID:-NOT FOUND}"
record "Recent history:"
echo "$HISTORY" | jq '{guid, text, is_from_me, reply_to_guid, is_edited, date_edited, reply_to_part}' | tee -a "$LOG"

if [ -z "$BASE_GUID" ]; then
  record "WARNING: Could not find base message GUID. Using most recent from-me message."
  BASE_GUID=$(echo "$HISTORY" | jq -r 'select(.is_from_me == true) | .guid' | head -1)
  record "Fallback GUID: ${BASE_GUID:-NONE}"
fi

# --- Test 2: Send thread reply ---
log "Step 2: Send thread reply to GUID $BASE_GUID"
if [ -n "$BASE_GUID" ]; then
  REPLY_OUT=$($IMSG send --to "$TARGET" --text "integration-test-reply-$(date +%s)" --reply-to "$BASE_GUID" --json 2>&1 || true)
  record "Reply result: $REPLY_OUT"
  sleep 3
else
  record "SKIPPED: No base GUID to reply to"
fi

# --- Test 3: Send a message then edit it ---
log "Step 3: Send message to edit"
EDIT_TS=$(date +%s)
EDIT_OUT=$($IMSG send --to "$TARGET" --text "integration-test-before-edit-$EDIT_TS" --json 2>&1 || true)
record "Send for edit: $EDIT_OUT"
sleep 3

log "Step 3b: Get GUID of message to edit"
HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 5 --json 2>/dev/null)
EDIT_GUID=$(echo "$HISTORY" | jq -r --arg ts "$EDIT_TS" 'select(.is_from_me == true and (.text | test("before-edit-" + $ts))) | .guid' | head -1)
record "Edit target GUID: ${EDIT_GUID:-NOT FOUND}"

if [ -n "$EDIT_GUID" ]; then
  log "Step 3c: Edit message"
  HANDLE="$TARGET"
  EDIT_RESULT=$($IMSG edit --handle "$HANDLE" --guid "$EDIT_GUID" --text "integration-test-EDITED-$EDIT_TS" --json 2>&1 || true)
  record "Edit result: $EDIT_RESULT"
  sleep 3
else
  record "SKIPPED: No GUID to edit"
fi

# --- Test 4: Send a message then unsend it ---
log "Step 4: Send message to unsend"
UNSEND_TS=$(date +%s)
UNSEND_OUT=$($IMSG send --to "$TARGET" --text "integration-test-will-unsend-$UNSEND_TS" --json 2>&1 || true)
record "Send for unsend: $UNSEND_OUT"
sleep 3

log "Step 4b: Get GUID of message to unsend"
HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 5 --json 2>/dev/null)
UNSEND_GUID=$(echo "$HISTORY" | jq -r --arg ts "$UNSEND_TS" 'select(.is_from_me == true and (.text | test("will-unsend-" + $ts))) | .guid' | head -1)
record "Unsend target GUID: ${UNSEND_GUID:-NOT FOUND}"

if [ -n "$UNSEND_GUID" ]; then
  log "Step 4c: Unsend message"
  UNSEND_RESULT=$($IMSG edit --handle "$TARGET" --guid "$UNSEND_GUID" --unsend --json 2>&1 || true)
  record "Unsend result: $UNSEND_RESULT"
  sleep 3
else
  record "SKIPPED: No GUID to unsend"
fi

# --- Test 5: Dump final history showing enriched fields ---
log "Step 5: Final history dump (checking enriched fields)"
FINAL=$($IMSG history --chat-id "$CHAT_ID" --limit 10 --json 2>/dev/null)
echo "$FINAL" | jq '{guid, text, is_from_me, reply_to_guid, reply_to_part, is_edited, date_edited, created_at}' | tee -a "$LOG"

# --- Test 6: RPC smoke test ---
log "Step 6: RPC smoke tests"

# message.edit without handle (should error)
RPC_EDIT_ERR=$(echo '{"jsonrpc":"2.0","id":1,"method":"message.edit","params":{"guid":"ABC","text":"new"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC edit missing handle: $RPC_EDIT_ERR"

# message.unsend without guid (should error)
RPC_UNSEND_ERR=$(echo '{"jsonrpc":"2.0","id":2,"method":"message.unsend","params":{"handle":"+123"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC unsend missing guid: $RPC_UNSEND_ERR"

# send with reply_to_guid (validation only - bridge may not be available in RPC mode)
RPC_REPLY=$(echo '{"jsonrpc":"2.0","id":3,"method":"send","params":{"to":"'$TARGET'","text":"rpc-reply-test","reply_to_guid":"fake-guid"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC send with reply_to_guid: $RPC_REPLY"

log "DONE - full log at $LOG"
