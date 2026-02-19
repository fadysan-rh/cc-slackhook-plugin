#!/bin/bash
set -uo pipefail

# ── デバッグログ ──
DEBUG_LOG="/tmp/slack-times-debug.log"
debug() { echo "[$(date '+%H:%M:%S')] [answer] $*" >> "$DEBUG_LOG"; }
debug "=== Answer hook started ==="

# ── i18n ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./i18n.sh
. "${SCRIPT_DIR}/i18n.sh"
LOCALE=$(resolve_locale "${SLACK_LOCALE:-}")
debug "LOCALE=$LOCALE"

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
TOOL_RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // ""')

debug "SESSION_ID=$SESSION_ID"
debug "TOOL_RESPONSE=${TOOL_RESPONSE:0:200}"

# ── 4. スレッド ts の読み取り ──
THREAD_FILE="$HOME/.claude/.slack-thread-${SESSION_ID}"
THREAD_TS=""
if [ -f "$THREAD_FILE" ]; then
  THREAD_TS=$(cat "$THREAD_FILE")
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
debug "ANSWER=$ANSWER_TRUNCATED"

# ── 6. Slack にスレッド返信 ──
ANSWER_LABEL=$(i18n_text "$LOCALE" "answer_label")
TEXT=$(printf "*%s:*\n%s" "$ANSWER_LABEL" "$ANSWER_TRUNCATED")

BLOCKS=$(jq -n --arg text "$TEXT" '[{"type":"section","text":{"type":"mrkdwn","text":$text}}]')

BODY=$(jq -n \
  --arg channel "$SLACK_CHANNEL" \
  --arg text "$TEXT" \
  --argjson blocks "$BLOCKS" \
  --arg thread_ts "$THREAD_TS" \
  '{"channel":$channel,"text":$text,"blocks":$blocks,"thread_ts":$thread_ts}')

RESPONSE=$(curl -s -X POST \
  -H 'Content-Type: application/json; charset=utf-8' \
  -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
  --data "$BODY" \
  --connect-timeout 10 \
  --max-time 15 \
  "https://slack.com/api/chat.postMessage" 2>/dev/null || true)

debug "RESPONSE: ${RESPONSE:0:200}"

# スレッドの最終利用時刻を更新
touch "$THREAD_FILE"

debug "=== Answer hook finished ==="

exit 0
