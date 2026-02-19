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
  printf "[%s] [start] %s\n" "$(date '+%H:%M:%S')" "$*" >> "$DEBUG_LOG" 2>/dev/null || true
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
    --max-time 20 \
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
debug "=== Start hook started ==="

# ── i18n ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./i18n.sh
. "${SCRIPT_DIR}/i18n.sh"
LOCALE=$(resolve_locale "${CC_SLACK_LOCALE:-}")
debug "LOCALE=$LOCALE"

# ── 共通: ファイル更新時刻取得（macOS/Linux両対応） ──
file_mtime() {
  local file="$1"
  if stat -f %m "$file" >/dev/null 2>&1; then
    stat -f %m "$file"
    return 0
  fi
  if stat -c %Y "$file" >/dev/null 2>&1; then
    stat -c %Y "$file"
    return 0
  fi
  echo 0
}

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
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

if ! is_valid_session_id "$SESSION_ID"; then
  debug "EXIT: invalid session_id"
  exit 0
fi

debug "SESSION_ID=$SESSION_ID"
debug "PROMPT_LEN=${#PROMPT}"
debug "CWD=$CWD"

if [ -z "$PROMPT" ]; then
  debug "EXIT: no prompt"
  exit 0
fi

# ── 4. プロジェクト情報（Git: org:repo/branch、非Git: ~/path）──
PROJECT_INFO=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  if git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
    REPO_NAME=$(basename "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)")
    BRANCH_NAME=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
    REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
    ORG=""
    if [ -n "$REMOTE_URL" ]; then
      ORG=$(echo "$REMOTE_URL" | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#; s#\.git$##')
    fi
    if [ -n "$ORG" ]; then
      PROJECT_INFO="${ORG}:${REPO_NAME}/${BRANCH_NAME}"
    else
      PROJECT_INFO="${REPO_NAME}/${BRANCH_NAME}"
    fi
  else
    PROJECT_INFO=$(echo "$CWD" | sed "s|^$HOME|~|")
  fi
else
  PROJECT_INFO="${CWD:-unknown}"
fi

debug "PROJECT_INFO=$PROJECT_INFO"

# ── 5. プロンプトを切り詰め ──
PROMPT_TRUNCATED="${PROMPT:0:500}"
PROMPT_ESCAPED=$(escape_mrkdwn "$PROMPT_TRUNCATED")
PROJECT_INFO_ESCAPED=$(escape_mrkdwn "$PROJECT_INFO")

# ── 6. スレッド管理 ──
THREAD_FILE="$HOME/.claude/.slack-thread-${SESSION_ID}"
THREAD_CWD_FILE="${THREAD_FILE}.cwd"
THREAD_TIMEOUT=${CC_SLACK_THREAD_TIMEOUT:-1800}  # デフォルト30分
THREAD_TS=""

if ! sanitize_state_file_path "$THREAD_FILE" "thread_ts"; then
  exit 0
fi
if ! sanitize_state_file_path "$THREAD_CWD_FILE" "thread_cwd"; then
  exit 0
fi

if [ -f "$THREAD_FILE" ]; then
  THREAD_TS=$(cat "$THREAD_FILE" 2>/dev/null || true)

  # スレッド区切り判定: 時間経過 or CWD変更
  NEED_NEW_THREAD=false

  # 時間チェック: thread_fileの更新時刻からN秒以上経過
  if [ -n "$THREAD_TS" ]; then
    FILE_MOD=$(file_mtime "$THREAD_FILE")
    NOW=$(date +%s)
    ELAPSED=$((NOW - FILE_MOD))
    if [ "$ELAPSED" -ge "$THREAD_TIMEOUT" ]; then
      debug "Thread timeout: ${ELAPSED}s >= ${THREAD_TIMEOUT}s"
      NEED_NEW_THREAD=true
    fi
  fi

  # CWDチェック: 前回と異なるディレクトリ
  if [ "$NEED_NEW_THREAD" = "false" ] && [ -f "$THREAD_CWD_FILE" ]; then
    PREV_CWD=$(cat "$THREAD_CWD_FILE")
    if [ "$PREV_CWD" != "$CWD" ]; then
      debug "CWD changed: $PREV_CWD -> $CWD"
      NEED_NEW_THREAD=true
    fi
  fi

  if [ "$NEED_NEW_THREAD" = "true" ]; then
    THREAD_TS=""
    rm -f "$THREAD_FILE" "$THREAD_CWD_FILE"
  fi
fi

# CWDを記録
if ! write_state_file_atomic "$THREAD_CWD_FILE" "$CWD"; then
  debug "EXIT: failed to write thread cwd file"
  exit 0
fi

# ── 7. メッセージ構築 ──
REQUEST_LABEL=$(i18n_text "$LOCALE" "prompt_request_label")
SESSION_STARTED_LABEL=$(i18n_text "$LOCALE" "prompt_session_started_label")
START_HEADER=$(i18n_text "$LOCALE" "prompt_start_header")
REPO_DIR_LABEL=$(i18n_text "$LOCALE" "prompt_repo_dir_label")

if [ -n "$THREAD_TS" ]; then
  # 2回目以降: スレッドに返信
  TEXT=$(printf "*%s:*\n%s" "$REQUEST_LABEL" "$PROMPT_ESCAPED")
else
  # 初回: 作業開始メッセージ
  TEXT=$(printf "*%s*\n*%s:* %s\n\n*%s*\n%s" "$SESSION_STARTED_LABEL" "$REPO_DIR_LABEL" "$PROJECT_INFO_ESCAPED" "$START_HEADER" "$PROMPT_ESCAPED")
fi

# ── 8. Slack API に直接 POST ──
BLOCKS=$(jq -n --arg text "$TEXT" '[{"type":"section","text":{"type":"mrkdwn","text":$text}}]')

BODY=$(jq -n \
  --arg channel "$CC_SLACK_CHANNEL" \
  --arg text "$TEXT" \
  --argjson blocks "$BLOCKS" \
  '{"channel":$channel,"text":$text,"blocks":$blocks}')

# スレッドがある場合は thread_ts を追加
if [ -n "$THREAD_TS" ]; then
  BODY=$(echo "$BODY" | jq --arg ts "$THREAD_TS" '. + {"thread_ts":$ts}')
fi

debug "Sending to Slack API (as user)"

if ! RESPONSE=$(post_to_slack "$BODY"); then
  debug "EXIT: failed to post prompt notification"
  exit 0
fi

debug "RESPONSE: ${RESPONSE:0:200}"

# ── 9. スレッド管理の更新 ──
if [ -z "$THREAD_TS" ]; then
  # 初回: レスポンスの ts → thread_ts ファイルに保存
  NEW_TS=$(echo "$RESPONSE" | jq -r '.ts // ""' 2>/dev/null)
  if [ -n "$NEW_TS" ] && [ "$NEW_TS" != "null" ]; then
    if write_state_file_atomic "$THREAD_FILE" "$NEW_TS"; then
      debug "Saved thread_ts=$NEW_TS to $THREAD_FILE"
    else
      debug "WARN: failed to save thread_ts"
    fi
  fi
else
  # 2回目以降: 最終利用時刻を更新（タイムアウト判定用）
  if ! write_state_file_atomic "$THREAD_FILE" "$THREAD_TS"; then
    debug "WARN: failed to refresh thread_ts file"
  fi
fi

debug "=== Start hook finished ==="

exit 0
