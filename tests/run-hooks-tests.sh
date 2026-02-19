#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK_STOP="${ROOT_DIR}/hooks/slack-times-response.sh"
HOOK_PROMPT="${ROOT_DIR}/hooks/slack-times-prompt.sh"
HOOK_ANSWER="${ROOT_DIR}/hooks/slack-times-answer.sh"
FIXTURES_DIR="${ROOT_DIR}/tests/fixtures"
DEBUG_LOG="/tmp/slack-times-debug.log"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  local name="$1"
  echo "[PASS] ${name}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local name="$1"
  local message="$2"
  echo "[FAIL] ${name}: ${message}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "${name}"
  else
    fail "${name}" "missing: ${needle}"
  fi
}

assert_not_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${name}" "unexpected: ${needle}"
  else
    pass "${name}"
  fi
}

assert_no_emoji_shortcode() {
  local name="$1"
  local value="$2"
  if printf "%s" "$value" | grep -Eq ':[a-z0-9_+-]+:'; then
    fail "${name}" "unexpected emoji shortcode"
  else
    pass "${name}"
  fi
}

assert_zero() {
  local name="$1"
  local value="$2"
  if [ "$value" -eq 0 ]; then
    pass "${name}"
  else
    fail "${name}" "expected 0, got ${value}"
  fi
}

assert_nonzero() {
  local name="$1"
  local value="$2"
  if [ "$value" -ne 0 ]; then
    pass "${name}"
  else
    fail "${name}" "expected non-zero, got ${value}"
  fi
}

assert_file_absent() {
  local name="$1"
  local path="$2"
  if [ -e "$path" ]; then
    fail "${name}" "unexpected file: ${path}"
  else
    pass "${name}"
  fi
}

debug_line_count() {
  if [ -f "$DEBUG_LOG" ]; then
    wc -l < "$DEBUG_LOG"
  else
    echo 0
  fi
}

debug_slice() {
  local start_line="$1"
  if [ -f "$DEBUG_LOG" ]; then
    tail -n "+$((start_line + 1))" "$DEBUG_LOG"
  else
    echo ""
  fi
}

file_mode() {
  local path="$1"
  if stat -f %Lp "$path" >/dev/null 2>&1; then
    stat -f %Lp "$path"
    return 0
  fi
  if stat -c %a "$path" >/dev/null 2>&1; then
    stat -c %a "$path"
    return 0
  fi
  echo "unknown"
}

file_mtime() {
  local path="$1"
  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
    return 0
  fi
  if stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
    return 0
  fi
  echo 0
}

write_mock_curl() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"
  cat > "${mock_bin}/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

payload=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data|--data-binary|--data-raw)
      payload="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "${MOCK_CURL_CAPTURE:-}" ]; then
  printf "%s" "$payload" > "$MOCK_CURL_CAPTURE"
fi

case "${MOCK_CURL_MODE:-ok}" in
  ok)
    echo '{"ok":true,"channel":"C_TEST","ts":"1710000000.000001"}'
    ;;
  invalid_auth)
    echo '{"ok":false,"error":"invalid_auth"}'
    ;;
  curl_fail)
    exit 28
    ;;
  *)
    echo '{"ok":false,"error":"unknown_mock_mode"}'
    ;;
esac
EOF
  chmod +x "${mock_bin}/curl"
}

prepare_git_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.name "hooks-test"
  git -C "$repo_dir" config user.email "hooks-test@example.com"
}

run_stop_hook() {
  local repo_dir="$1"
  local transcript_path="$2"
  local session_id="$3"
  local curl_mode="$4"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  echo -n "1700000000.000001" > "${test_home}/.claude/.slack-thread-${session_id}"
  printf "%s" "$repo_dir" > "${test_home}/.claude/.slack-thread-${session_id}.cwd"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg path "$transcript_path" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, transcript_path:$path, cwd:$cwd, stop_hook_active:false}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="$curl_mode" \
  CC_SLACK_BOT_TOKEN="xoxb-test" \
  CC_SLACK_CHANNEL="C_TEST" \
  CC_SLACK_HOOK_DEBUG="1" \
  CC_CC_SLACK_HOOK_DEBUG_LOG="$DEBUG_LOG" \
    bash "$HOOK_STOP" <<< "$input" >/dev/null 2>&1 || status=$?

  echo "$status"
}

run_prompt_hook() {
  local repo_dir="$1"
  local session_id="$2"
  local prompt_text="$3"
  local locale="${4:-}"
  local curl_mode="${5:-ok}"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/prompt-body.json"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg prompt "$prompt_text" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, prompt:$prompt, cwd:$cwd}')

  local status=0
  if [ -n "$locale" ]; then
    HOME="$test_home" \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE="$curl_mode" \
    MOCK_CURL_CAPTURE="$capture_file" \
    CC_SLACK_USER_TOKEN="xoxp-test" \
    CC_SLACK_CHANNEL="C_TEST" \
    CC_SLACK_LOCALE="$locale" \
      bash "$HOOK_PROMPT" <<< "$input" >/dev/null 2>&1 || status=$?
  else
    HOME="$test_home" \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE="$curl_mode" \
    MOCK_CURL_CAPTURE="$capture_file" \
    CC_SLACK_USER_TOKEN="xoxp-test" \
    CC_SLACK_CHANNEL="C_TEST" \
      bash "$HOOK_PROMPT" <<< "$input" >/dev/null 2>&1 || status=$?
  fi

  local text=""
  if [ -s "$capture_file" ]; then
    text=$(jq -r '.text // ""' "$capture_file" 2>/dev/null || true)
  fi

  jq -nc --argjson status "$status" --arg text "$text" '{"status":$status,"text":$text}'
}

run_answer_hook() {
  local repo_dir="$1"
  local session_id="$2"
  local tool_response="$3"
  local locale="${4:-}"
  local curl_mode="${5:-ok}"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/answer-body.json"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  echo -n "1700000000.000001" > "${test_home}/.claude/.slack-thread-${session_id}"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg tr "$tool_response" \
    '{session_id:$sid, tool_response:$tr}')

  local status=0
  if [ -n "$locale" ]; then
    HOME="$test_home" \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE="$curl_mode" \
    MOCK_CURL_CAPTURE="$capture_file" \
    CC_SLACK_USER_TOKEN="xoxp-test" \
    CC_SLACK_CHANNEL="C_TEST" \
    CC_SLACK_LOCALE="$locale" \
      bash "$HOOK_ANSWER" <<< "$input" >/dev/null 2>&1 || status=$?
  else
    HOME="$test_home" \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE="$curl_mode" \
    MOCK_CURL_CAPTURE="$capture_file" \
    CC_SLACK_USER_TOKEN="xoxp-test" \
    CC_SLACK_CHANNEL="C_TEST" \
      bash "$HOOK_ANSWER" <<< "$input" >/dev/null 2>&1 || status=$?
  fi

  local text=""
  if [ -s "$capture_file" ]; then
    text=$(jq -r '.text // ""' "$capture_file" 2>/dev/null || true)
  fi

  jq -nc --argjson status "$status" --arg text "$text" '{"status":$status,"text":$text}'
}

run_stop_hook_capture() {
  local repo_dir="$1"
  local transcript_path="$2"
  local session_id="$3"
  local locale="${4:-}"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/stop-body.json"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  echo -n "1700000000.000001" > "${test_home}/.claude/.slack-thread-${session_id}"
  printf "%s" "$repo_dir" > "${test_home}/.claude/.slack-thread-${session_id}.cwd"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg path "$transcript_path" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, transcript_path:$path, cwd:$cwd, stop_hook_active:false}')

  local status=0
  if [ -n "$locale" ]; then
    HOME="$test_home" \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE="ok" \
    MOCK_CURL_CAPTURE="$capture_file" \
    CC_SLACK_BOT_TOKEN="xoxb-test" \
    CC_SLACK_CHANNEL="C_TEST" \
    CC_SLACK_LOCALE="$locale" \
    CC_SLACK_HOOK_DEBUG="1" \
    CC_CC_SLACK_HOOK_DEBUG_LOG="$DEBUG_LOG" \
      bash "$HOOK_STOP" <<< "$input" >/dev/null 2>&1 || status=$?
  else
    HOME="$test_home" \
    PATH="${mock_bin}:${PATH}" \
    MOCK_CURL_MODE="ok" \
    MOCK_CURL_CAPTURE="$capture_file" \
    CC_SLACK_BOT_TOKEN="xoxb-test" \
    CC_SLACK_CHANNEL="C_TEST" \
    CC_SLACK_HOOK_DEBUG="1" \
    CC_CC_SLACK_HOOK_DEBUG_LOG="$DEBUG_LOG" \
      bash "$HOOK_STOP" <<< "$input" >/dev/null 2>&1 || status=$?
  fi

  local text=""
  if [ -s "$capture_file" ]; then
    text=$(jq -r '.text // ""' "$capture_file" 2>/dev/null || true)
  fi

  jq -nc --argjson status "$status" --arg text "$text" '{"status":$status,"text":$text}'
}

test_prompt_locale_en() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_prompt_hook "$repo_dir" "test-prompt-en" "hello i18n" "en")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "prompt_locale_en_exit" "$status"
  assert_contains "prompt_locale_en_started_label" "$text" "*Claude Code Session Started*"
  assert_contains "prompt_locale_en_header" "$text" "*Prompt*"
  assert_contains "prompt_locale_en_repo_dir" "$text" "*repo/dir:*"
  assert_no_emoji_shortcode "prompt_locale_en_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_prompt_locale_invalid_fallback() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_prompt_hook "$repo_dir" "test-prompt-invalid" "hello i18n" "fr")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "prompt_locale_invalid_exit" "$status"
  assert_contains "prompt_locale_invalid_started_label" "$text" "*Claude Code Session Started*"
  assert_contains "prompt_locale_invalid_fallback_prompt" "$text" "*Prompt*"
  assert_contains "prompt_locale_invalid_repo_dir" "$text" "*repo/dir:*"
  assert_no_emoji_shortcode "prompt_locale_invalid_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_prompt_locale_unset_fallback() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_prompt_hook "$repo_dir" "test-prompt-unset" "hello i18n")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "prompt_locale_unset_exit" "$status"
  assert_contains "prompt_locale_unset_started_label" "$text" "*Claude Code Session Started*"
  assert_contains "prompt_locale_unset_fallback_prompt" "$text" "*Prompt*"
  assert_contains "prompt_locale_unset_repo_dir" "$text" "*repo/dir:*"
  assert_no_emoji_shortcode "prompt_locale_unset_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_prompt_thread_reply_no_emoji() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local first
  first=$(run_prompt_hook "$repo_dir" "test-prompt-thread" "first prompt" "en")
  local first_status
  first_status=$(echo "$first" | jq -r '.status')
  assert_zero "prompt_thread_first_exit" "$first_status"

  local second
  second=$(run_prompt_hook "$repo_dir" "test-prompt-thread" "follow up prompt" "en")
  local second_status
  second_status=$(echo "$second" | jq -r '.status')
  local second_text
  second_text=$(echo "$second" | jq -r '.text')

  assert_zero "prompt_thread_second_exit" "$second_status"
  assert_contains "prompt_thread_reply_label" "$second_text" "Request"
  assert_not_contains "prompt_thread_reply_no_repo_dir_line" "$second_text" "repo/dir:"
  assert_no_emoji_shortcode "prompt_thread_reply_no_emoji_shortcode" "$second_text"

  rm -rf "$tmp_dir"
}

test_prompt_invalid_session_id() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/prompt-body.json"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  local input
  input=$(jq -nc \
    --arg sid "../evil" \
    --arg prompt "hello" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, prompt:$prompt, cwd:$cwd}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  MOCK_CURL_CAPTURE="$capture_file" \
  CC_SLACK_USER_TOKEN="xoxp-test" \
  CC_SLACK_CHANNEL="C_TEST" \
    bash "$HOOK_PROMPT" <<< "$input" >/dev/null 2>&1 || status=$?

  assert_zero "prompt_invalid_session_id_exit" "$status"
  assert_file_absent "prompt_invalid_session_id_no_post" "$capture_file"
  assert_file_absent "prompt_invalid_session_id_no_escape_file" "${test_home}/evil"
  assert_file_absent "prompt_invalid_session_id_no_escape_file_cwd" "${test_home}/evil.cwd"

  rm -rf "$tmp_dir"
}

test_prompt_escape_mrkdwn_mentions() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_prompt_hook "$repo_dir" "test-prompt-escape" "<!channel> & <tag>" "en")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "prompt_escape_mrkdwn_exit" "$status"
  assert_contains "prompt_escape_mrkdwn_escaped" "$text" "&lt;!channel&gt; &amp; &lt;tag&gt;"
  assert_not_contains "prompt_escape_mrkdwn_no_raw_mention" "$text" "<!channel>"

  rm -rf "$tmp_dir"
}

test_prompt_debug_disabled_by_default() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_prompt_hook "$repo_dir" "test-prompt-debug-default" "hello" "en")
  local status
  status=$(echo "$result" | jq -r '.status')

  assert_zero "prompt_debug_default_exit" "$status"
  assert_file_absent "prompt_debug_default_no_log_file" "${repo_dir}/.home/.claude/slack-times-debug.log"

  rm -rf "$tmp_dir"
}

test_prompt_debug_log_permission_when_enabled() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local debug_log="${repo_dir}/hook-debug.log"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  local input
  input=$(jq -nc \
    --arg sid "test-prompt-debug-perm" \
    --arg prompt "hello" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, prompt:$prompt, cwd:$cwd}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  CC_SLACK_USER_TOKEN="xoxp-test" \
  CC_SLACK_CHANNEL="C_TEST" \
  CC_SLACK_HOOK_DEBUG="1" \
  CC_CC_SLACK_HOOK_DEBUG_LOG="$debug_log" \
    bash "$HOOK_PROMPT" <<< "$input" >/dev/null 2>&1 || status=$?

  assert_zero "prompt_debug_enabled_exit" "$status"
  if [ -f "$debug_log" ]; then
    pass "prompt_debug_enabled_log_file_created"
  else
    fail "prompt_debug_enabled_log_file_created" "missing: ${debug_log}"
  fi

  local mode
  mode=$(file_mode "$debug_log")
  if [ "$mode" = "600" ]; then
    pass "prompt_debug_enabled_log_mode_600"
  else
    fail "prompt_debug_enabled_log_mode_600" "expected 600, got ${mode}"
  fi

  rm -rf "$tmp_dir"
}

test_prompt_invalid_auth_does_not_persist_thread() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local session_id="test-prompt-invalid-auth"
  local thread_file="${repo_dir}/.home/.claude/.slack-thread-${session_id}"
  local result
  result=$(run_prompt_hook "$repo_dir" "$session_id" "hello" "en" "invalid_auth")
  local status
  status=$(echo "$result" | jq -r '.status')

  assert_zero "prompt_invalid_auth_exit" "$status"
  assert_file_absent "prompt_invalid_auth_no_thread_file" "$thread_file"

  rm -rf "$tmp_dir"
}

test_prompt_debug_log_symlink_not_followed() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/prompt-body.json"
  local victim_file="${repo_dir}/victim.log"
  local debug_link="${repo_dir}/debug-link.log"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  printf "SAFE" > "$victim_file"
  chmod 644 "$victim_file"
  ln -s "$victim_file" "$debug_link"
  local before_mode
  before_mode=$(file_mode "$victim_file")

  local input
  input=$(jq -nc \
    --arg sid "test-prompt-debug-symlink" \
    --arg prompt "hello" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, prompt:$prompt, cwd:$cwd}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  MOCK_CURL_CAPTURE="$capture_file" \
  CC_SLACK_USER_TOKEN="xoxp-test" \
  CC_SLACK_CHANNEL="C_TEST" \
  CC_SLACK_HOOK_DEBUG="1" \
  CC_CC_SLACK_HOOK_DEBUG_LOG="$debug_link" \
    bash "$HOOK_PROMPT" <<< "$input" >/dev/null 2>&1 || status=$?

  local victim_after
  victim_after=$(cat "$victim_file")
  local after_mode
  after_mode=$(file_mode "$victim_file")

  assert_zero "prompt_debug_symlink_exit" "$status"
  assert_not_contains "prompt_debug_symlink_victim_not_modified" "$victim_after" "[start]"
  if [ "$before_mode" = "$after_mode" ]; then
    pass "prompt_debug_symlink_mode_unchanged"
  else
    fail "prompt_debug_symlink_mode_unchanged" "mode changed: ${before_mode} -> ${after_mode}"
  fi

  rm -rf "$tmp_dir"
}

test_prompt_symlink_thread_cwd_not_followed() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/prompt-body.json"
  local session_id="test-prompt-symlink-cwd"
  local victim_file="${repo_dir}/victim.txt"
  local thread_cwd_file="${test_home}/.claude/.slack-thread-${session_id}.cwd"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  printf "ORIGINAL" > "$victim_file"
  ln -s "$victim_file" "$thread_cwd_file"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg prompt "symlink safety" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, prompt:$prompt, cwd:$cwd}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  MOCK_CURL_CAPTURE="$capture_file" \
  CC_SLACK_USER_TOKEN="xoxp-test" \
  CC_SLACK_CHANNEL="C_TEST" \
    bash "$HOOK_PROMPT" <<< "$input" >/dev/null 2>&1 || status=$?

  local victim_after
  victim_after=$(cat "$victim_file")

  assert_zero "prompt_symlink_thread_cwd_exit" "$status"
  assert_contains "prompt_symlink_thread_cwd_victim_unchanged" "$victim_after" "ORIGINAL"
  if [ -L "$thread_cwd_file" ]; then
    fail "prompt_symlink_thread_cwd_symlink_replaced" "thread cwd file remained symlink"
  else
    pass "prompt_symlink_thread_cwd_symlink_replaced"
  fi

  rm -rf "$tmp_dir"
}

test_answer_locale_en() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_answer_hook "$repo_dir" "test-answer-en" "yes" "en")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "answer_locale_en_exit" "$status"
  assert_contains "answer_locale_en_label" "$text" "Answer"
  assert_no_emoji_shortcode "answer_locale_en_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_answer_locale_ja() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_answer_hook "$repo_dir" "test-answer-ja" "yes" "ja")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "answer_locale_ja_exit" "$status"
  assert_contains "answer_locale_ja_label" "$text" "回答"
  assert_no_emoji_shortcode "answer_locale_ja_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_answer_locale_invalid_fallback() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_answer_hook "$repo_dir" "test-answer-invalid" "yes" "fr")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "answer_locale_invalid_exit" "$status"
  assert_contains "answer_locale_invalid_fallback_ja" "$text" "回答"
  assert_no_emoji_shortcode "answer_locale_invalid_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_answer_locale_unset_fallback() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_answer_hook "$repo_dir" "test-answer-unset" "yes")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "answer_locale_unset_exit" "$status"
  assert_contains "answer_locale_unset_fallback_ja" "$text" "回答"
  assert_no_emoji_shortcode "answer_locale_unset_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_answer_escape_mrkdwn_mentions() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local result
  result=$(run_answer_hook "$repo_dir" "test-answer-escape" "<!here> & <x>" "en")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "answer_escape_mrkdwn_exit" "$status"
  assert_contains "answer_escape_mrkdwn_escaped" "$text" "&lt;!here&gt; &amp; &lt;x&gt;"
  assert_not_contains "answer_escape_mrkdwn_no_raw_mention" "$text" "<!here>"

  rm -rf "$tmp_dir"
}

test_answer_invalid_auth_does_not_refresh_thread() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local session_id="test-answer-invalid-auth"
  local thread_file="${test_home}/.claude/.slack-thread-${session_id}"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"
  printf "1700000000.000001" > "$thread_file"

  local before_mtime
  before_mtime=$(file_mtime "$thread_file")
  sleep 1

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg tr "yes" \
    '{session_id:$sid, tool_response:$tr}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="invalid_auth" \
  CC_SLACK_USER_TOKEN="xoxp-test" \
  CC_SLACK_CHANNEL="C_TEST" \
    bash "$HOOK_ANSWER" <<< "$input" >/dev/null 2>&1 || status=$?

  local after_mtime
  after_mtime=$(file_mtime "$thread_file")

  assert_zero "answer_invalid_auth_exit" "$status"
  if [ "$before_mtime" = "$after_mtime" ]; then
    pass "answer_invalid_auth_no_thread_refresh"
  else
    fail "answer_invalid_auth_no_thread_refresh" "thread file mtime changed"
  fi

  rm -rf "$tmp_dir"
}

test_answer_debug_log_symlink_not_followed() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/answer-body.json"
  local session_id="test-answer-debug-symlink"
  local thread_file="${test_home}/.claude/.slack-thread-${session_id}"
  local victim_file="${repo_dir}/victim.log"
  local debug_link="${repo_dir}/debug-link.log"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"
  printf "1700000000.000001" > "$thread_file"
  printf "SAFE" > "$victim_file"
  chmod 644 "$victim_file"
  ln -s "$victim_file" "$debug_link"
  local before_mode
  before_mode=$(file_mode "$victim_file")

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg tr "yes" \
    '{session_id:$sid, tool_response:$tr}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  MOCK_CURL_CAPTURE="$capture_file" \
  CC_SLACK_USER_TOKEN="xoxp-test" \
  CC_SLACK_CHANNEL="C_TEST" \
  CC_SLACK_HOOK_DEBUG="1" \
  CC_CC_SLACK_HOOK_DEBUG_LOG="$debug_link" \
    bash "$HOOK_ANSWER" <<< "$input" >/dev/null 2>&1 || status=$?

  local victim_after
  victim_after=$(cat "$victim_file")
  local after_mode
  after_mode=$(file_mode "$victim_file")

  assert_zero "answer_debug_symlink_exit" "$status"
  assert_not_contains "answer_debug_symlink_victim_not_modified" "$victim_after" "[answer]"
  if [ "$before_mode" = "$after_mode" ]; then
    pass "answer_debug_symlink_mode_unchanged"
  else
    fail "answer_debug_symlink_mode_unchanged" "mode changed: ${before_mode} -> ${after_mode}"
  fi

  rm -rf "$tmp_dir"
}

test_answer_symlink_thread_file_not_followed() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/answer-body.json"
  local session_id="test-answer-symlink-thread"
  local victim_file="${repo_dir}/victim.txt"
  local thread_file="${test_home}/.claude/.slack-thread-${session_id}"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  printf "ORIGINAL" > "$victim_file"
  ln -s "$victim_file" "$thread_file"
  printf "%s" "$repo_dir" > "${test_home}/.claude/.slack-thread-${session_id}.cwd"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg tr "yes" \
    '{session_id:$sid, tool_response:$tr}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  MOCK_CURL_CAPTURE="$capture_file" \
  CC_SLACK_USER_TOKEN="xoxp-test" \
  CC_SLACK_CHANNEL="C_TEST" \
    bash "$HOOK_ANSWER" <<< "$input" >/dev/null 2>&1 || status=$?

  local victim_after
  victim_after=$(cat "$victim_file")

  assert_zero "answer_symlink_thread_exit" "$status"
  assert_contains "answer_symlink_thread_victim_unchanged" "$victim_after" "ORIGINAL"
  assert_file_absent "answer_symlink_thread_no_post" "$capture_file"
  assert_file_absent "answer_symlink_thread_removed" "$thread_file"

  rm -rf "$tmp_dir"
}

test_stop_normal() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  echo "before" > "${repo_dir}/notes.txt"
  git -C "$repo_dir" add notes.txt
  git -C "$repo_dir" commit -q -m "init"
  echo "after" > "${repo_dir}/notes.txt"

  local transcript="${repo_dir}/transcript-normal.jsonl"
  sed "s#__REPO__#${repo_dir}#g" "${FIXTURES_DIR}/stop-normal.jsonl" > "$transcript"

  local log_start
  log_start=$(debug_line_count)
  local status
  status=$(run_stop_hook "$repo_dir" "$transcript" "test-normal" "ok")
  local logs
  logs=$(debug_slice "$log_start")

  assert_zero "stop_normal_exit" "$status"
  assert_contains "stop_normal_summary" "$logs" "WORK_SUMMARY_LEN=14"
  assert_contains "stop_normal_changed_file" "$logs" "CHANGED_FILE_COUNT=1"
  assert_contains "stop_normal_posted" "$logs" "RESPONSE: {\"ok\":true"

  rm -rf "$tmp_dir"
}

test_stop_symlink_thread_file_not_followed() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-stop-symlink.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local capture_file="${repo_dir}/stop-body.json"
  local session_id="test-stop-symlink-thread"
  local victim_file="${repo_dir}/victim.txt"
  local thread_file="${test_home}/.claude/.slack-thread-${session_id}"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  printf "ORIGINAL" > "$victim_file"
  ln -s "$victim_file" "$thread_file"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg path "$transcript" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, transcript_path:$path, cwd:$cwd, stop_hook_active:false}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  MOCK_CURL_CAPTURE="$capture_file" \
  CC_SLACK_BOT_TOKEN="xoxb-test" \
  CC_SLACK_CHANNEL="C_TEST" \
  CC_SLACK_HOOK_DEBUG="1" \
  CC_CC_SLACK_HOOK_DEBUG_LOG="$DEBUG_LOG" \
    bash "$HOOK_STOP" <<< "$input" >/dev/null 2>&1 || status=$?

  local victim_after
  victim_after=$(cat "$victim_file")

  assert_zero "stop_symlink_thread_exit" "$status"
  assert_contains "stop_symlink_thread_victim_unchanged" "$victim_after" "ORIGINAL"
  assert_file_absent "stop_symlink_thread_no_post" "$capture_file"
  assert_file_absent "stop_symlink_thread_removed" "$thread_file"

  rm -rf "$tmp_dir"
}

test_stop_debug_log_symlink_not_followed() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-stop-debug-symlink.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local session_id="test-stop-debug-symlink"
  local capture_file="${repo_dir}/stop-body.json"
  local victim_file="${repo_dir}/victim.log"
  local debug_link="${repo_dir}/debug-link.log"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"

  printf "1700000000.000001" > "${test_home}/.claude/.slack-thread-${session_id}"
  printf "%s" "$repo_dir" > "${test_home}/.claude/.slack-thread-${session_id}.cwd"
  printf "SAFE" > "$victim_file"
  chmod 644 "$victim_file"
  ln -s "$victim_file" "$debug_link"
  local before_mode
  before_mode=$(file_mode "$victim_file")

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg path "$transcript" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, transcript_path:$path, cwd:$cwd, stop_hook_active:false}')

  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  MOCK_CURL_CAPTURE="$capture_file" \
  CC_SLACK_BOT_TOKEN="xoxb-test" \
  CC_SLACK_CHANNEL="C_TEST" \
  CC_SLACK_HOOK_DEBUG="1" \
  CC_CC_SLACK_HOOK_DEBUG_LOG="$debug_link" \
    bash "$HOOK_STOP" <<< "$input" >/dev/null 2>&1 || status=$?

  local victim_after
  victim_after=$(cat "$victim_file")
  local after_mode
  after_mode=$(file_mode "$victim_file")

  assert_zero "stop_debug_symlink_exit" "$status"
  assert_not_contains "stop_debug_symlink_victim_not_modified" "$victim_after" "[stop]"
  if [ "$before_mode" = "$after_mode" ]; then
    pass "stop_debug_symlink_mode_unchanged"
  else
    fail "stop_debug_symlink_mode_unchanged" "mode changed: ${before_mode} -> ${after_mode}"
  fi

  rm -rf "$tmp_dir"
}

test_stop_dr_only() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  echo "to-delete" > "${repo_dir}/old.txt"
  git -C "$repo_dir" add old.txt
  git -C "$repo_dir" commit -q -m "init"
  rm -f "${repo_dir}/old.txt"

  local transcript="${repo_dir}/transcript-dr-only.jsonl"
  cp "${FIXTURES_DIR}/stop-dr-only.jsonl" "$transcript"

  local log_start
  log_start=$(debug_line_count)
  local status
  status=$(run_stop_hook "$repo_dir" "$transcript" "test-dr-only" "ok")
  local logs
  logs=$(debug_slice "$log_start")

  assert_zero "stop_dr_only_exit" "$status"
  assert_contains "stop_dr_only_changed_file" "$logs" "CHANGED_FILE_COUNT=1"

  rm -rf "$tmp_dir"
}

test_stop_long_turn_window() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-long.jsonl"
  {
    echo '{"type":"user","message":{"content":"start long turn"}}'
    local i
    for i in $(seq 1 260); do
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"filler %s"}]}}\n' "$i"
    done
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"long window summary"}]}}'
  } > "$transcript"

  local log_start
  log_start=$(debug_line_count)
  local status
  status=$(run_stop_hook "$repo_dir" "$transcript" "test-long-turn" "ok")
  local logs
  logs=$(debug_slice "$log_start")

  assert_zero "stop_long_turn_exit" "$status"
  assert_contains "stop_long_turn_window" "$logs" "Turn window matched within tail -400"
  assert_contains "stop_long_turn_summary" "$logs" "WORK_SUMMARY_LEN=19"

  rm -rf "$tmp_dir"
}

test_stop_invalid_auth() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-invalid-auth.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local log_start
  log_start=$(debug_line_count)
  local status
  status=$(run_stop_hook "$repo_dir" "$transcript" "test-invalid-auth" "invalid_auth")
  local logs
  logs=$(debug_slice "$log_start")

  assert_nonzero "stop_invalid_auth_exit" "$status"
  assert_contains "stop_invalid_auth_error" "$logs" "ERROR: Slack API failed error=invalid_auth"
  assert_contains "stop_invalid_auth_exit_log" "$logs" "EXIT: failed to post stop summary"

  rm -rf "$tmp_dir"
}

test_stop_reject_unsafe_transcript_path() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local log_start
  log_start=$(debug_line_count)
  local status
  status=$(run_stop_hook "$repo_dir" "/etc/passwd" "test-unsafe-transcript-path" "ok")
  local logs
  logs=$(debug_slice "$log_start")

  assert_zero "stop_unsafe_transcript_exit" "$status"
  assert_contains "stop_unsafe_transcript_rejected" "$logs" "EXIT: unsafe transcript_path"

  rm -rf "$tmp_dir"
}

test_stop_reject_transcript_path_with_dotdot() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local secret_dir="${tmp_dir}/secret"
  mkdir -p "$secret_dir"
  local outside="${secret_dir}/outside.jsonl"
  cat > "$outside" <<'EOF'
{"type":"user","message":{"content":"outside"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"outside summary"}]}}
EOF

  local bypass_path="${repo_dir}/../secret/outside.jsonl"

  local log_start
  log_start=$(debug_line_count)
  local status
  status=$(run_stop_hook "$repo_dir" "$bypass_path" "test-transcript-dotdot" "ok")
  local logs
  logs=$(debug_slice "$log_start")

  assert_zero "stop_dotdot_path_exit" "$status"
  assert_contains "stop_dotdot_path_rejected" "$logs" "EXIT: unsafe transcript_path"

  rm -rf "$tmp_dir"
}

test_stop_reject_without_trusted_thread_cwd() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-no-trusted-cwd.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local test_home="${repo_dir}/.home"
  local mock_bin="${repo_dir}/.mock-bin"
  local session_id="test-stop-no-thread-cwd"
  mkdir -p "${test_home}/.claude"
  write_mock_curl "$mock_bin"
  printf "1700000000.000001" > "${test_home}/.claude/.slack-thread-${session_id}"

  local input
  input=$(jq -nc \
    --arg sid "$session_id" \
    --arg path "$transcript" \
    --arg cwd "$repo_dir" \
    '{session_id:$sid, transcript_path:$path, cwd:$cwd, stop_hook_active:false}')

  local log_start
  log_start=$(debug_line_count)
  local status=0
  HOME="$test_home" \
  PATH="${mock_bin}:${PATH}" \
  MOCK_CURL_MODE="ok" \
  CC_SLACK_BOT_TOKEN="xoxb-test" \
  CC_SLACK_CHANNEL="C_TEST" \
  CC_SLACK_HOOK_DEBUG="1" \
  CC_CC_SLACK_HOOK_DEBUG_LOG="$DEBUG_LOG" \
    bash "$HOOK_STOP" <<< "$input" >/dev/null 2>&1 || status=$?
  local logs
  logs=$(debug_slice "$log_start")

  assert_zero "stop_no_trusted_cwd_exit" "$status"
  assert_contains "stop_no_trusted_cwd_rejected" "$logs" "EXIT: unsafe transcript_path"

  rm -rf "$tmp_dir"
}

test_stop_locale_en() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-stop-en.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local result
  result=$(run_stop_hook_capture "$repo_dir" "$transcript" "test-stop-en" "en")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "stop_locale_en_exit" "$status"
  assert_contains "stop_locale_en_label" "$text" "Answer"
  assert_no_emoji_shortcode "stop_locale_en_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_stop_locale_ja() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-stop-ja.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local result
  result=$(run_stop_hook_capture "$repo_dir" "$transcript" "test-stop-ja" "ja")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "stop_locale_ja_exit" "$status"
  assert_contains "stop_locale_ja_label" "$text" "回答"
  assert_no_emoji_shortcode "stop_locale_ja_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_stop_locale_invalid_fallback() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-stop-invalid.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local result
  result=$(run_stop_hook_capture "$repo_dir" "$transcript" "test-stop-invalid" "fr")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "stop_locale_invalid_exit" "$status"
  assert_contains "stop_locale_invalid_fallback_ja" "$text" "回答"
  assert_no_emoji_shortcode "stop_locale_invalid_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_stop_locale_unset_fallback() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/transcript-stop-unset.jsonl"
  cp "${FIXTURES_DIR}/stop-invalid-auth.jsonl" "$transcript"

  local result
  result=$(run_stop_hook_capture "$repo_dir" "$transcript" "test-stop-unset")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "stop_locale_unset_exit" "$status"
  assert_contains "stop_locale_unset_fallback_ja" "$text" "回答"
  assert_no_emoji_shortcode "stop_locale_unset_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

test_stop_kill_message_en() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local repo_dir="${tmp_dir}/repo"
  prepare_git_repo "$repo_dir"

  local transcript="${repo_dir}/missing-transcript.jsonl"
  local result
  result=$(run_stop_hook_capture "$repo_dir" "$transcript" "test-stop-kill-en" "en")
  local status
  status=$(echo "$result" | jq -r '.status')
  local text
  text=$(echo "$result" | jq -r '.text')

  assert_zero "stop_kill_en_exit" "$status"
  assert_contains "stop_kill_en_message" "$text" "Work interrupted (kill)"
  assert_no_emoji_shortcode "stop_kill_en_no_emoji_shortcode" "$text"

  rm -rf "$tmp_dir"
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "[FAIL] setup: jq is required"
    exit 1
  fi

  test_prompt_locale_en
  test_prompt_locale_invalid_fallback
  test_prompt_locale_unset_fallback
  test_prompt_thread_reply_no_emoji
  test_prompt_invalid_session_id
  test_prompt_escape_mrkdwn_mentions
  test_prompt_debug_disabled_by_default
  test_prompt_debug_log_permission_when_enabled
  test_prompt_invalid_auth_does_not_persist_thread
  test_prompt_debug_log_symlink_not_followed
  test_prompt_symlink_thread_cwd_not_followed
  test_answer_locale_en
  test_answer_locale_ja
  test_answer_locale_invalid_fallback
  test_answer_locale_unset_fallback
  test_answer_escape_mrkdwn_mentions
  test_answer_invalid_auth_does_not_refresh_thread
  test_answer_debug_log_symlink_not_followed
  test_answer_symlink_thread_file_not_followed
  test_stop_locale_en
  test_stop_locale_ja
  test_stop_locale_invalid_fallback
  test_stop_locale_unset_fallback
  test_stop_kill_message_en
  test_stop_symlink_thread_file_not_followed
  test_stop_debug_log_symlink_not_followed
  test_stop_normal
  test_stop_dr_only
  test_stop_long_turn_window
  test_stop_invalid_auth
  test_stop_reject_unsafe_transcript_path
  test_stop_reject_transcript_path_with_dotdot
  test_stop_reject_without_trusted_thread_cwd

  echo "----"
  echo "Passed: ${PASS_COUNT}"
  echo "Failed: ${FAIL_COUNT}"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
