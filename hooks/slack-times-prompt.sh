#!/bin/bash
set -uo pipefail

# ── デバッグログ ──
DEBUG_LOG="/tmp/slack-times-debug.log"
debug() { echo "[$(date '+%H:%M:%S')] [start] $*" >> "$DEBUG_LOG"; }
debug "=== Start hook started ==="

# ── 1. stdin から JSON を読み取り ──
INPUT=$(cat)
debug "INPUT keys: $(echo "$INPUT" | jq -r 'keys | join(", ")' 2>/dev/null)"

# ── 2. 前提チェック ──
if [ -z "${SLACK_USER_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL:-}" ]; then
  debug "EXIT: no SLACK_USER_TOKEN or SLACK_CHANNEL"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  exit 0
fi

# ── 3. 入力値の取得 ──
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

debug "SESSION_ID=$SESSION_ID"
debug "PROMPT=${PROMPT:0:100}"
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

# ── 6. スレッド管理 ──
THREAD_FILE="$HOME/.claude/.slack-thread-${SESSION_ID}"
THREAD_TS=""
if [ -f "$THREAD_FILE" ]; then
  THREAD_TS=$(cat "$THREAD_FILE")
fi

# ── 7. メッセージ構築 ──
if [ -n "$THREAD_TS" ]; then
  # 2回目以降: スレッドに返信
  TEXT=$(printf ":speech_balloon: *リクエスト:*\n%s" "$PROMPT_TRUNCATED")
else
  # 初回: 作業開始メッセージ
  TEXT=$(printf ":robot_face: *【Claude Code作業開始】*\n:file_folder: \`%s\`\n\n%s" "$PROJECT_INFO" "$PROMPT_TRUNCATED")
fi

# ── 8. Slack API に直接 POST ──
BLOCKS=$(jq -n --arg text "$TEXT" '[{"type":"section","text":{"type":"mrkdwn","text":$text}}]')

BODY=$(jq -n \
  --arg channel "$SLACK_CHANNEL" \
  --arg text "$TEXT" \
  --argjson blocks "$BLOCKS" \
  '{"channel":$channel,"text":$text,"blocks":$blocks}')

# スレッドがある場合は thread_ts を追加
if [ -n "$THREAD_TS" ]; then
  BODY=$(echo "$BODY" | jq --arg ts "$THREAD_TS" '. + {"thread_ts":$ts}')
fi

debug "Sending to Slack API (as user)"

RESPONSE=$(curl -s -X POST \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
  --data "$BODY" \
  --connect-timeout 10 \
  --max-time 20 \
  "https://slack.com/api/chat.postMessage" 2>/dev/null || true)

debug "RESPONSE: ${RESPONSE:0:200}"

# ── 9. 初回: レスポンスの ts → thread_ts ファイルに保存 ──
if [ -z "$THREAD_TS" ]; then
  NEW_TS=$(echo "$RESPONSE" | jq -r '.ts // ""' 2>/dev/null)
  if [ -n "$NEW_TS" ] && [ "$NEW_TS" != "null" ]; then
    echo -n "$NEW_TS" > "$THREAD_FILE"
    debug "Saved thread_ts=$NEW_TS to $THREAD_FILE"
  fi
fi

debug "=== Start hook finished ==="

exit 0
