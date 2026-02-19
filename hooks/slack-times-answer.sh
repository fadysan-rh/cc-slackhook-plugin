#!/bin/bash
set -uo pipefail

# ── デバッグログ ──
DEBUG_ENABLED="${CC_SLACK_HOOK_DEBUG:-0}"
DEBUG_LOG="${CC_CC_SLACK_HOOK_DEBUG_LOG:-$HOME/.claude/slack-times-debug.log}"

init_debug_log() {
  if [ "$DEBUG_ENABLED" != "1" ]; then
    return 0
  fi
  if ! is_safe_debug_log_path "$DEBUG_LOG"; then
    DEBUG_ENABLED=0
    return 0
  fi
  local log_dir
  log_dir=$(dirname "$DEBUG_LOG")
  (umask 077 && mkdir -p "$log_dir") 2>/dev/null || {
    DEBUG_ENABLED=0
    return 0
  }
  if ! is_safe_debug_log_path "$DEBUG_LOG"; then
    DEBUG_ENABLED=0
    return 0
  fi
  (umask 077 && touch "$DEBUG_LOG") 2>/dev/null || {
    DEBUG_ENABLED=0
    return 0
  }
  chmod 600 "$DEBUG_LOG" 2>/dev/null || true
}

debug() {
  if [ "$DEBUG_ENABLED" != "1" ]; then
    return 0
  fi
  if ! is_safe_debug_log_path "$DEBUG_LOG"; then
    DEBUG_ENABLED=0
    return 0
  fi
  printf "[%s] [answer] %s\n" "$(date '+%H:%M:%S')" "$*" >> "$DEBUG_LOG" 2>/dev/null || true
}

is_valid_session_id() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  [ "${#sid}" -le 128 ] || return 1
  [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]]
}

escape_mrkdwn() {
  printf "%s" "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

is_safe_debug_log_path() {
  local path="$1"
  [ -n "$path" ] || return 1
  case "$path" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  if [ -L "$path" ]; then
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    return 1
  fi
  return 0
}

sanitize_state_file_path() {
  local path="$1"
  local label="$2"

  if [ -L "$path" ]; then
    debug "Reset unsafe symlink state file (${label})"
    rm -f "$path" 2>/dev/null || return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    debug "EXIT: unsafe state file type (${label})"
    return 1
  fi
  return 0
}

write_state_file_atomic() {
  local path="$1"
  local value="$2"
  local dir
  local tmp_file

  dir=$(dirname "$path")
  (umask 077 && mkdir -p "$dir") 2>/dev/null || return 1
  if [ -e "$path" ] && [ ! -f "$path" ] && [ ! -L "$path" ]; then
    return 1
  fi

  tmp_file=$(mktemp "$dir/.slack-state.XXXXXX") || return 1
  if ! printf "%s" "$value" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  chmod 600 "$tmp_file" 2>/dev/null || true
  if ! mv -f "$tmp_file" "$path"; then
    rm -f "$tmp_file"
    return 1
  fi
  chmod 600 "$path" 2>/dev/null || true
  return 0
}

post_to_slack() {
  local body="$1"
  local response
  response=$(curl -sS -X POST \
    -H 'Content-Type: application/json; charset=utf-8' \
    -H "Authorization: Bearer ${CC_SLACK_USER_TOKEN}" \
    --data "$body" \
    --connect-timeout 10 \
    --max-time 15 \
    "https://slack.com/api/chat.postMessage")
  local curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    debug "ERROR: curl failed status=$curl_status"
    return 1
  fi

  local ok
  ok=$(echo "$response" | jq -r '.ok // false' 2>/dev/null || echo "false")
  if [ "$ok" != "true" ]; then
    local error
    error=$(echo "$response" | jq -r '.error // "unknown_error"' 2>/dev/null || echo "invalid_json_response")
    debug "ERROR: Slack API failed error=$error response=${response:0:200}"
    return 1
  fi

  printf "%s" "$response"
  return 0
}

init_debug_log
debug "=== Answer hook started ==="

# ── i18n ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./i18n.sh
. "${SCRIPT_DIR}/i18n.sh"
LOCALE=$(resolve_locale "${CC_SLACK_LOCALE:-}")
debug "LOCALE=$LOCALE"

# ── 1. stdin から JSON を読み取り ──
INPUT=$(cat)
debug "INPUT keys: $(echo "$INPUT" | jq -r 'keys | join(", ")' 2>/dev/null)"

# ── 2. 前提チェック ──
if [ -z "${CC_SLACK_USER_TOKEN:-}" ] || [ -z "${CC_SLACK_CHANNEL:-}" ]; then
  debug "EXIT: no CC_SLACK_USER_TOKEN or CC_SLACK_CHANNEL"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── 3. 入力値の取得 ──
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TOOL_RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // ""')

if ! is_valid_session_id "$SESSION_ID"; then
  debug "EXIT: invalid session_id"
  exit 0
fi

debug "SESSION_ID=$SESSION_ID"
debug "TOOL_RESPONSE_LEN=${#TOOL_RESPONSE}"

# ── 4. スレッド ts の読み取り ──
THREAD_FILE="$HOME/.claude/.slack-thread-${SESSION_ID}"
THREAD_TS=""

if ! sanitize_state_file_path "$THREAD_FILE" "thread_ts"; then
  exit 0
fi

if [ -f "$THREAD_FILE" ]; then
  THREAD_TS=$(cat "$THREAD_FILE" 2>/dev/null || true)
fi

if [ -z "$THREAD_TS" ]; then
  debug "EXIT: no thread_ts found"
  exit 0
fi

# ── 5. 回答テキストの抽出 ──
# tool_responseがJSON文字列の場合とオブジェクトの場合を両方処理
ANSWER=""
if echo "$TOOL_RESPONSE" | jq -e '.' &>/dev/null 2>&1; then
  # JSONオブジェクト: answers/questionsから回答を抽出
  ANSWER=$(echo "$TOOL_RESPONSE" | jq -r '
    if type == "object" then
      (.answers // {}) | to_entries | map(.value) | join(", ")
    elif type == "string" then
      .
    else
      empty
    end
  ' 2>/dev/null || true)
fi

# フォールバック: そのまま文字列として使用
if [ -z "$ANSWER" ]; then
  ANSWER="$TOOL_RESPONSE"
fi

if [ -z "$ANSWER" ] || [ "$ANSWER" = "null" ]; then
  debug "EXIT: no answer extracted"
  exit 0
fi

ANSWER_TRUNCATED="${ANSWER:0:500}"
ANSWER_ESCAPED=$(escape_mrkdwn "$ANSWER_TRUNCATED")
debug "ANSWER_LEN=${#ANSWER_TRUNCATED}"

# ── 6. Slack にスレッド返信 ──
ANSWER_LABEL=$(i18n_text "$LOCALE" "answer_label")
TEXT=$(printf "*%s:*\n%s" "$ANSWER_LABEL" "$ANSWER_ESCAPED")

BLOCKS=$(jq -n --arg text "$TEXT" '[{"type":"section","text":{"type":"mrkdwn","text":$text}}]')

BODY=$(jq -n \
  --arg channel "$CC_SLACK_CHANNEL" \
  --arg text "$TEXT" \
  --argjson blocks "$BLOCKS" \
  --arg thread_ts "$THREAD_TS" \
  '{"channel":$channel,"text":$text,"blocks":$blocks,"thread_ts":$thread_ts}')

if ! RESPONSE=$(post_to_slack "$BODY"); then
  debug "EXIT: failed to post answer notification"
  exit 0
fi

debug "RESPONSE: ${RESPONSE:0:200}"

# スレッドの最終利用時刻を更新
if ! write_state_file_atomic "$THREAD_FILE" "$THREAD_TS"; then
  debug "WARN: failed to refresh thread_ts file"
fi

debug "=== Answer hook finished ==="

exit 0
