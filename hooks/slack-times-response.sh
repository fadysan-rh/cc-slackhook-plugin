#!/bin/bash
set -uo pipefail

# ── デバッグログ ──
DEBUG_ENABLED="${SLACK_HOOK_DEBUG:-0}"
DEBUG_LOG="${SLACK_HOOK_DEBUG_LOG:-$HOME/.claude/slack-times-debug.log}"

init_debug_log() {
  if [ "$DEBUG_ENABLED" != "1" ]; then
    return 0
  fi
  local log_dir
  log_dir=$(dirname "$DEBUG_LOG")
  (umask 077 && mkdir -p "$log_dir" && touch "$DEBUG_LOG") 2>/dev/null || return 0
  chmod 600 "$DEBUG_LOG" 2>/dev/null || true
}

debug() {
  if [ "$DEBUG_ENABLED" != "1" ]; then
    return 0
  fi
  echo "[$(date '+%H:%M:%S')] [stop] $*" >> "$DEBUG_LOG"
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

normalize_path() {
  local path="$1"
  local dir
  local base
  local dir_real

  dir=$(dirname "$path")
  base=$(basename "$path")

  if ! dir_real=$(cd -P "$dir" 2>/dev/null && pwd -P); then
    return 1
  fi
  printf "%s/%s" "$dir_real" "$base"
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

is_safe_transcript_path() {
  local path="$1"
  local cwd="$2"
  local normalized_path
  local normalized_cwd
  local normalized_home_claude

  [ -n "$path" ] || return 1
  case "$path" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *.jsonl) ;;
    *) return 1 ;;
  esac

  # Existing symlink files can redirect outside allowed roots.
  if [ -L "$path" ]; then
    return 1
  fi

  # Only regular files (or non-existing future files) are accepted.
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    return 1
  fi

  normalized_path=$(normalize_path "$path") || return 1
  normalized_home_claude=$(normalize_path "$HOME/.claude/placeholder") || return 1
  normalized_home_claude=$(dirname "$normalized_home_claude")

  if [[ "$normalized_path" == "$normalized_home_claude/"* ]]; then
    return 0
  fi

  if [ -n "$cwd" ]; then
    normalized_cwd=$(normalize_path "$cwd/placeholder") || return 1
    normalized_cwd=$(dirname "$normalized_cwd")
    if [[ "$normalized_path" == "$normalized_cwd/"* ]]; then
      return 0
    fi
  fi

  return 1
}

init_debug_log
debug "=== Stop hook started ==="

# ── i18n ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./i18n.sh
. "${SCRIPT_DIR}/i18n.sh"
LOCALE=$(resolve_locale "${SLACK_LOCALE:-}")
debug "LOCALE=$LOCALE"

# ── 1. stdin から JSON を読み取り ──
INPUT=$(cat)
debug "INPUT keys: $(echo "$INPUT" | jq -r 'keys | join(", ")' 2>/dev/null)"

# ── 2. ループ防止 ──
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# ── 3. 前提チェック ──
if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL:-}" ]; then
  exit 0
fi

if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── 4. 入力値の取得 ──
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

if ! is_valid_session_id "$SESSION_ID"; then
  debug "EXIT: invalid session_id"
  exit 0
fi

if [ -n "$TRANSCRIPT_PATH" ] && ! is_safe_transcript_path "$TRANSCRIPT_PATH" "$CWD"; then
  debug "EXIT: unsafe transcript_path"
  exit 0
fi

debug "SESSION_ID=$SESSION_ID"
debug "TRANSCRIPT_PATH=$TRANSCRIPT_PATH"
debug "CWD=$CWD"

# ── スレッド ts の読み取り ──
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

# ── Slack API 投稿関数 ──
CLAUDE_ICON_URL="https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Claude_AI_logo.svg/1024px-Claude_AI_logo.svg.png"

post_to_slack() {
  local text="$1"
  local blocks
  blocks=$(jq -n --arg text "$text" '[{"type":"section","text":{"type":"mrkdwn","text":$text}}]')

  local body
  body=$(jq -n \
    --arg channel "$SLACK_CHANNEL" \
    --arg text "$text" \
    --argjson blocks "$blocks" \
    --arg thread_ts "$THREAD_TS" \
    --arg username "Claude Code" \
    --arg icon_url "$CLAUDE_ICON_URL" \
    '{"channel":$channel,"text":$text,"blocks":$blocks,"thread_ts":$thread_ts,"username":$username,"icon_url":$icon_url}')

  local response
  response=$(curl -sS -X POST \
    -H 'Content-Type: application/json; charset=utf-8' \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
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

  echo "$response"
  return 0
}

# ── トランスクリプトが無い場合 (kill等) は中断通知のみ ──
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  debug "No transcript — sending kill notification"
  KILL_MESSAGE=$(i18n_text "$LOCALE" "stop_kill_message")
  if ! RESPONSE=$(post_to_slack "$KILL_MESSAGE"); then
    debug "EXIT: failed to post kill notification"
    exit 1
  fi
  debug "RESPONSE: ${RESPONSE:0:200}"
  exit 0
fi

# ── Markdown → Slack mrkdwn 変換 ──
slack_format() {
  sed -e 's/\*\*\([^*]*\)\*\*/ \*\1\* /g' \
      -e 's/`\([^`]*\)`/ `\1` /g' \
      -e 's/^- /• /g' \
      -e 's/^## /\*/' \
      -e 's/^# /\*/' \
      -e 's/```[a-z]*/```/g'
}

# ── 5. 最新ターンの範囲を特定（末尾から探索して高速化）──
sleep 1

TURN_LINES_FILE=$(mktemp)
trap "rm -f '$TURN_LINES_FILE'" EXIT

# 末尾から可変ウィンドウで探索（200→400→800）。見つからなければ末尾200行を使用
LAST_PROMPT_LINE=""
TAIL_BUF=""
for TAIL_LINES in 200 400 800; do
  TAIL_BUF=$(tail -n "$TAIL_LINES" "$TRANSCRIPT_PATH" 2>/dev/null || true)
  LAST_PROMPT_LINE=$(echo "$TAIL_BUF" | grep -n '"type":"user"' 2>/dev/null | grep -v 'tool_use_id' | tail -1 | cut -d: -f1 || true)
  if [ -n "$LAST_PROMPT_LINE" ]; then
    debug "Turn window matched within tail -${TAIL_LINES}"
    break
  fi
done

if [ -n "$LAST_PROMPT_LINE" ]; then
  echo "$TAIL_BUF" | tail -n +"$LAST_PROMPT_LINE" > "$TURN_LINES_FILE"
else
  debug "Turn window fallback to tail -200"
  tail -n 200 "$TRANSCRIPT_PATH" > "$TURN_LINES_FILE"
fi

# ── 作業内容: 最後のassistantテキストブロックのみ ──
WORK_SUMMARY=$(jq -r '
  select(.type == "assistant") |
  .message.content[]? |
  select(.type == "text") |
  .text
' "$TURN_LINES_FILE" 2>/dev/null | grep -v '^$' | tail -1 | head -c 500 | slack_format || true)

# ── 変更ファイル一覧 ──
TRANSCRIPT_FILES=$(jq -r '
  select(.type == "assistant") |
  .message.content[]? |
  select(.type == "tool_use") |
  select(.name == "Write" or .name == "Edit") |
  .input.file_path // empty
' "$TURN_LINES_FILE" 2>/dev/null | sort -u || true)

REPO_ROOT=""
if [ -n "$CWD" ] && git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
  REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
fi

# git差分からD/Rを含む全変更を取得
GIT_CHANGES=""
if [ -n "$REPO_ROOT" ]; then
  # 未ステージ + ステージ済み + 直近コミット の順で取得
  GIT_CHANGES=$(git -C "$REPO_ROOT" diff --name-status 2>/dev/null || true)
  if [ -z "$GIT_CHANGES" ]; then
    GIT_CHANGES=$(git -C "$REPO_ROOT" diff --cached --name-status 2>/dev/null || true)
  fi
  if [ -z "$GIT_CHANGES" ]; then
    GIT_CHANGES=$(git -C "$REPO_ROOT" diff --name-status HEAD~1 HEAD 2>/dev/null || true)
  fi
fi

CHANGED_FILES=""
if [ -n "$TRANSCRIPT_FILES" ] && [ -n "$CWD" ]; then
  CHANGED_FILES=$(echo "$TRANSCRIPT_FILES" | while IFS= read -r filepath; do
    [ -z "$filepath" ] && continue
    REL_PATH=$(echo "$filepath" | sed "s|^${CWD}/||")

    # ファイルステータス判定
    STATUS="M"
    if [ -n "$REPO_ROOT" ]; then
      if ! git -C "$REPO_ROOT" ls-files --error-unmatch "$filepath" &>/dev/null; then
        STATUS="U"
      fi
    fi

    # diff統計の取得
    DIFF_STAT=""
    if [ -n "$REPO_ROOT" ]; then
      DIFF_STAT=$(git -C "$REPO_ROOT" diff --numstat -- "$filepath" 2>/dev/null | head -1 || true)
      if [ -z "$DIFF_STAT" ]; then
        DIFF_STAT=$(git -C "$REPO_ROOT" diff --cached --numstat -- "$filepath" 2>/dev/null | head -1 || true)
      fi
      if [ -z "$DIFF_STAT" ]; then
        DIFF_STAT=$(git -C "$REPO_ROOT" diff --numstat HEAD~1 HEAD -- "$filepath" 2>/dev/null | head -1 || true)
      fi
    fi

    if [ -n "$DIFF_STAT" ]; then
      ADDED=$(echo "$DIFF_STAT" | awk '{print $1}')
      DELETED=$(echo "$DIFF_STAT" | awk '{print $2}')
      echo "${STATUS} ${REL_PATH} (+${ADDED} -${DELETED})"
    else
      echo "${STATUS} ${REL_PATH}"
    fi
  done)
fi

# git差分からD/Rファイルを追加（トランスクリプトに現れないもの）
if [ -n "$GIT_CHANGES" ]; then
  DR_FILES=$(echo "$GIT_CHANGES" | while IFS=$'\t' read -r status path extra; do
    case "$status" in
      (D) echo "D ${path}" ;;
      (R*) echo "R ${path} → ${extra}" ;;
    esac
  done)
  if [ -n "$DR_FILES" ]; then
    if [ -n "$CHANGED_FILES" ]; then
      CHANGED_FILES="${CHANGED_FILES}
${DR_FILES}"
    else
      CHANGED_FILES="$DR_FILES"
    fi
  fi
fi

# ── Git情報の抽出 ──
NL=$'\n'
GIT_TOOL_IDS=$(jq -r '
  select(.type == "assistant") |
  .message.content[]? |
  select(.type == "tool_use") |
  select(.name == "Bash") |
  select(.input.command | test("git commit|git push")) |
  .id
' "$TURN_LINES_FILE" 2>/dev/null || true)

GIT_INFO=""
if [ -n "$GIT_TOOL_IDS" ]; then
  for TOOL_ID in $GIT_TOOL_IDS; do
    RESULT=$(jq -r --arg id "$TOOL_ID" '
      select(.type == "user") |
      select((.message.content | type) == "array") |
      .message.content[]? |
      select(.type == "tool_result") |
      select(.tool_use_id == $id) |
      select((.content | type) == "string") |
      .content
    ' "$TURN_LINES_FILE" 2>/dev/null || true)

    if [ -n "$RESULT" ]; then
      COMMIT_LINE=$(echo "$RESULT" | grep -oE '^\[.+\] .+' | head -1 || true)
      PUSH_LINE=$(echo "$RESULT" | grep -E '^\s+\S+\.\.\S+\s+' | head -1 || true)
      if [ -n "$COMMIT_LINE" ]; then
        HASH=$(echo "$COMMIT_LINE" | sed 's/\[[^ ]* \([a-f0-9]*\)\].*/\1/')
        MSG=$(echo "$COMMIT_LINE" | sed 's/\[[^]]*\] //')
        GIT_INFO="${GIT_INFO}• \`${HASH}\` ${MSG}${NL}"
      fi
      if [ -n "$PUSH_LINE" ]; then
        PUSH_DETAIL=$(echo "$PUSH_LINE" | sed 's/^ *//')
        GIT_INFO="${GIT_INFO}• push: ${PUSH_DETAIL}${NL}"
      fi
    fi
  done
fi

CHANGED_FILE_COUNT=$(printf "%s\n" "$CHANGED_FILES" | awk 'NF {count++} END {print count+0}')
GIT_INFO_LINES=$(printf "%s\n" "$GIT_INFO" | awk 'NF {count++} END {print count+0}')
debug "WORK_SUMMARY_LEN=${#WORK_SUMMARY}"
debug "CHANGED_FILE_COUNT=${CHANGED_FILE_COUNT}"
debug "GIT_INFO_LINES=${GIT_INFO_LINES}"

# ── 6. メッセージ組み立て ──
WORK_SUMMARY_LABEL=$(i18n_text "$LOCALE" "stop_work_summary_label")
CHANGED_FILES_LABEL=$(i18n_text "$LOCALE" "stop_changed_files_label")
ANSWER_LABEL=$(i18n_text "$LOCALE" "stop_answer_label")
GIT_LABEL=$(i18n_text "$LOCALE" "stop_git_label")
NO_DETAILS=$(i18n_text "$LOCALE" "stop_no_details")

PARTS=""

if [ -n "$CHANGED_FILES" ]; then
  if [ -n "$WORK_SUMMARY" ]; then
    PARTS="*${WORK_SUMMARY_LABEL}:*\n${WORK_SUMMARY}"
  fi
  FILE_LIST=$(echo "$CHANGED_FILES" | while IFS= read -r f; do echo "• \`${f}\`"; done)
  if [ -n "$PARTS" ]; then
    PARTS="${PARTS}\n\n*${CHANGED_FILES_LABEL}:*\n${FILE_LIST}"
  else
    PARTS="*${CHANGED_FILES_LABEL}:*\n${FILE_LIST}"
  fi
elif [ -n "$WORK_SUMMARY" ]; then
  PARTS="*${ANSWER_LABEL}:*\n${WORK_SUMMARY}"
else
  PARTS="${NO_DETAILS}"
fi

if [ -n "$GIT_INFO" ]; then
  PARTS="${PARTS}\n\n*${GIT_LABEL}:*\n${GIT_INFO}"
fi

# 3000文字に切り詰め
MESSAGE=$(echo -e "$PARTS" | head -c 3000)
MESSAGE=$(escape_mrkdwn "$MESSAGE")

debug "Sending to Slack API (as bot)"

if ! RESPONSE=$(post_to_slack "$MESSAGE"); then
  debug "EXIT: failed to post stop summary"
  exit 1
fi

debug "RESPONSE: ${RESPONSE:0:200}"
debug "=== Stop hook finished ==="

exit 0
