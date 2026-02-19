#!/usr/bin/env bash
set -euo pipefail

IMSG_BIN="${IMSG_BIN:-/usr/local/bin/imsg-plus}"
DEFAULT_CHAT_ID="${IMSG_DEFAULT_CHAT_ID:-1}"
DEFAULT_HANDLE="${IMSG_DEFAULT_HANDLE:-+18185713263}"
MESSAGE_DB_PATH="${IMSG_DB_PATH:-$HOME/Library/Messages/chat.db}"

usage() {
  cat <<'EOF'
Usage:
  imsg-tapback.sh --type <reaction-or-emoji> [options]

Options:
  --type <value>          Required. Reaction alias or literal emoji.
  --chat-id <id>          Chat ID for GUID lookup (default: 1).
  --handle <value>        Handle for react command (default: +18185713263).
  --index <n>             0-based message index from newest (default: 0).
  --id <message_id>       React using iMessage DB row ID (resolves guid internally).
  --guid <value>          React to an explicit message GUID (skip lookup).
  --remove                Remove reaction instead of adding it.
  --json                  Forward JSON output mode to imsg-plus react.
  --dry-run               Resolve and print command without sending.
  -h, --help              Show this help.

Examples:
  imsg-tapback.sh --type love
  imsg-tapback.sh --type "🔥" --index 2
  imsg-tapback.sh --chat-id 5 --type thumbsup --remove
  imsg-tapback.sh --type love --id 7267
  imsg-tapback.sh --guid "ABC-123" --type "😂"
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

chat_id="$DEFAULT_CHAT_ID"
handle="$DEFAULT_HANDLE"
message_index=0
reaction_type=""
message_guid=""
message_id=""
remove_flag=0
json_flag=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat-id)
      chat_id="${2:-}"
      shift 2
      ;;
    --handle)
      handle="${2:-}"
      shift 2
      ;;
    --index)
      message_index="${2:-}"
      shift 2
      ;;
    --id)
      message_id="${2:-}"
      shift 2
      ;;
    --guid)
      message_guid="${2:-}"
      shift 2
      ;;
    --type)
      reaction_type="${2:-}"
      shift 2
      ;;
    --remove)
      remove_flag=1
      shift
      ;;
    --json)
      json_flag=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$reaction_type" ]]; then
  echo "--type is required" >&2
  usage >&2
  exit 1
fi

if [[ -n "$message_guid" && -n "$message_id" ]]; then
  echo "Specify only one of --guid or --id" >&2
  exit 1
fi

if [[ -z "$message_guid" && -n "$message_id" ]]; then
  if [[ ! "$message_id" =~ ^[0-9]+$ ]]; then
    echo "--id must be a non-negative integer" >&2
    exit 1
  fi

  require_cmd sqlite3
  message_guid="$(sqlite3 "$MESSAGE_DB_PATH" \
    "SELECT guid FROM message WHERE ROWID = $message_id LIMIT 1;")"

  if [[ -z "$message_guid" ]]; then
    echo "Could not resolve message GUID for id=$message_id" >&2
    exit 1
  fi
fi

if [[ -z "$message_guid" ]]; then
  if [[ ! "$message_index" =~ ^[0-9]+$ ]]; then
    echo "--index must be a non-negative integer" >&2
    exit 1
  fi
  if [[ ! "$chat_id" =~ ^[0-9]+$ ]]; then
    echo "--chat-id must be a positive integer" >&2
    exit 1
  fi

  require_cmd "$IMSG_BIN"
  require_cmd jq

  lookup_limit=$((message_index + 1))
  message_guid="$("$IMSG_BIN" history --chat-id "$chat_id" --limit "$lookup_limit" --json \
    | jq -sr --argjson idx "$message_index" '
      map(
        if type == "array" then .[]
        elif type == "object" then .
        else empty
        end
      )
      | map(select((.guid? // "") | tostring | length > 0))
      | .[$idx].guid // empty
    ')"

  if [[ -z "$message_guid" ]]; then
    echo "Could not resolve message GUID for chat-id=$chat_id index=$message_index" >&2
    exit 1
  fi
fi

cmd=("$IMSG_BIN" react --handle "$handle" --guid "$message_guid" --type "$reaction_type")
if [[ $remove_flag -eq 1 ]]; then
  cmd+=(--remove)
fi
if [[ $json_flag -eq 1 ]]; then
  cmd+=(--json)
fi

if [[ $dry_run -eq 1 ]]; then
  printf 'Resolved GUID: %s\n' "$message_guid"
  printf 'Command:'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  exit 0
fi

"${cmd[@]}"
