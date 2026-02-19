#!/bin/bash
set -uo pipefail

# ── デバッグログ ──
DEBUG_LOG="/tmp/slack-times-debug.log"
debug() { echo "[$(date '+%H:%M:%S')] [start] $*" >> "$DEBUG_LOG"; }
debug "=== Start hook started ==="

# ── i18n ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./i18n.sh
. "${SCRIPT_DIR}/i18n.sh"
LOCALE=$(resolve_locale "${SLACK_LOCALE:-}")
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
THREAD_CWD_FILE="${THREAD_FILE}.cwd"
THREAD_TIMEOUT=${SLACK_THREAD_TIMEOUT:-1800}  # デフォルト30分
THREAD_TS=""

if [ -f "$THREAD_FILE" ]; then
  THREAD_TS=$(cat "$THREAD_FILE")

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
echo -n "$CWD" > "$THREAD_CWD_FILE"

# ── 7. メッセージ構築 ──
REQUEST_LABEL=$(i18n_text "$LOCALE" "prompt_request_label")
START_HEADER=$(i18n_text "$LOCALE" "prompt_start_header")
REPO_DIR_LABEL=$(i18n_text "$LOCALE" "prompt_repo_dir_label")

if [ -n "$THREAD_TS" ]; then
  # 2回目以降: スレッドに返信
  TEXT=$(printf "*%s:*\n%s" "$REQUEST_LABEL" "$PROMPT_TRUNCATED")
else
  # 初回: 作業開始メッセージ
  TEXT=$(printf "%s\n%s: \`%s\`\n\n%s" "$START_HEADER" "$REPO_DIR_LABEL" "$PROJECT_INFO" "$PROMPT_TRUNCATED")
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

# ── 9. スレッド管理の更新 ──
if [ -z "$THREAD_TS" ]; then
  # 初回: レスポンスの ts → thread_ts ファイルに保存
  NEW_TS=$(echo "$RESPONSE" | jq -r '.ts // ""' 2>/dev/null)
  if [ -n "$NEW_TS" ] && [ "$NEW_TS" != "null" ]; then
    echo -n "$NEW_TS" > "$THREAD_FILE"
    debug "Saved thread_ts=$NEW_TS to $THREAD_FILE"
  fi
else
  # 2回目以降: 最終利用時刻を更新（タイムアウト判定用）
  touch "$THREAD_FILE"
fi

debug "=== Start hook finished ==="

exit 0
