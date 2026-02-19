#!/bin/bash
set -uo pipefail

# ── デバッグログ ──
DEBUG_LOG="/tmp/slack-times-debug.log"
debug() { echo "[$(date '+%H:%M:%S')] [stop] $*" >> "$DEBUG_LOG"; }
debug "=== Stop hook started ==="

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

debug "SESSION_ID=$SESSION_ID"
debug "TRANSCRIPT_PATH=$TRANSCRIPT_PATH"
debug "CWD=$CWD"

# ── スレッド ts の読み取り ──
THREAD_FILE="$HOME/.claude/.slack-thread-${SESSION_ID}"
THREAD_TS=""
if [ -f "$THREAD_FILE" ]; then
  THREAD_TS=$(cat "$THREAD_FILE")
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

  curl -s -X POST \
    -H 'Content-Type: application/json; charset=utf-8' \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    --data "$body" \
    --connect-timeout 10 \
    --max-time 20 \
    "https://slack.com/api/chat.postMessage" 2>/dev/null || true
}

# ── トランスクリプトが無い場合 (kill等) は中断通知のみ ──
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  debug "No transcript — sending kill notification"
  post_to_slack ":octagonal_sign: 作業中断 (kill)"
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

# ── 5. 最新ターンの範囲を特定（最後のユーザープロンプト以降）──
sleep 1

TURN_LINES_FILE=$(mktemp)
trap "rm -f '$TURN_LINES_FILE'" EXIT

# ユーザープロンプト行を特定（tool_resultはtool_use_idを含むので除外）
LAST_PROMPT_LINE=$(grep -n '"type":"user"' "$TRANSCRIPT_PATH" 2>/dev/null | grep -v 'tool_use_id' | tail -1 | cut -d: -f1 || true)

if [ -n "$LAST_PROMPT_LINE" ]; then
  tail -n +"$LAST_PROMPT_LINE" "$TRANSCRIPT_PATH" > "$TURN_LINES_FILE"
else
  tail -50 "$TRANSCRIPT_PATH" > "$TURN_LINES_FILE"
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

  # git差分からD/Rファイルを追加（トランスクリプトに現れないもの）
  if [ -n "$GIT_CHANGES" ]; then
    DR_FILES=$(echo "$GIT_CHANGES" | while IFS=$'\t' read -r status path extra; do
      case "$status" in
        D) echo "D ${path}" ;;
        R*) echo "R ${path} → ${extra}" ;;
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

debug "WORK_SUMMARY=${WORK_SUMMARY:0:100}"
debug "CHANGED_FILES=$CHANGED_FILES"
debug "GIT_INFO=$GIT_INFO"

# ── 6. メッセージ組み立て ──
PARTS=""

if [ -n "$CHANGED_FILES" ]; then
  if [ -n "$WORK_SUMMARY" ]; then
    PARTS="*作業内容:*\n${WORK_SUMMARY}"
  fi
  FILE_LIST=$(echo "$CHANGED_FILES" | while IFS= read -r f; do echo "• \`${f}\`"; done)
  if [ -n "$PARTS" ]; then
    PARTS="${PARTS}\n\n*変更ファイル:*\n${FILE_LIST}"
  else
    PARTS="*変更ファイル:*\n${FILE_LIST}"
  fi
elif [ -n "$WORK_SUMMARY" ]; then
  PARTS="*回答:*\n${WORK_SUMMARY}"
else
  PARTS="(詳細なし)"
fi

if [ -n "$GIT_INFO" ]; then
  PARTS="${PARTS}\n\n*Git:*\n${GIT_INFO}"
fi

# 3000文字に切り詰め
MESSAGE=$(echo -e "$PARTS" | head -c 3000)

debug "Sending to Slack API (as bot)"

RESPONSE=$(post_to_slack "$MESSAGE")

debug "RESPONSE: ${RESPONSE:0:200}"
debug "=== Stop hook finished ==="

exit 0
