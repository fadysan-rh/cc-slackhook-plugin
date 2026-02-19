#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK_STOP="${ROOT_DIR}/hooks/slack-times-response.sh"
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

write_mock_curl() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"
  cat > "${mock_bin}/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
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
  SLACK_BOT_TOKEN="xoxb-test" \
  SLACK_CHANNEL="C_TEST" \
    bash "$HOOK_STOP" <<< "$input" >/dev/null 2>&1 || status=$?

  echo "$status"
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
  assert_contains "stop_normal_summary" "$logs" "WORK_SUMMARY=normal summary"
  assert_contains "stop_normal_changed_file" "$logs" "CHANGED_FILES=M notes.txt (+1 -1)"
  assert_contains "stop_normal_posted" "$logs" "RESPONSE: {\"ok\":true"

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
  assert_contains "stop_dr_only_changed_file" "$logs" "CHANGED_FILES=D old.txt"

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
  assert_contains "stop_long_turn_summary" "$logs" "WORK_SUMMARY=long window summary"

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

main() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "[FAIL] setup: jq is required"
    exit 1
  fi

  test_stop_normal
  test_stop_dr_only
  test_stop_long_turn_window
  test_stop_invalid_auth

  echo "----"
  echo "Passed: ${PASS_COUNT}"
  echo "Failed: ${FAIL_COUNT}"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
