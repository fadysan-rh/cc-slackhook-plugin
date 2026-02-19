#!/bin/bash

# Resolve locale from environment input.
# Supported: ja / en. Fallback: ja.
resolve_locale() {
  local raw="${1:-ja}"
  raw=$(printf "%s" "$raw" | tr "[:upper:]" "[:lower:]")

  case "$raw" in
    en|en-us|en_us|english)
      echo "en"
      ;;
    ja|ja-jp|ja_jp|japanese)
      echo "ja"
      ;;
    *)
      echo "ja"
      ;;
  esac
}

i18n_text() {
  local locale="$1"
  local key="$2"

  case "${locale}:${key}" in
    # Prompt hook
    ja:prompt_request_label) echo "リクエスト" ;;
    en:prompt_request_label) echo "Request" ;;
    ja:prompt_start_header) echo "プロンプト" ;;
    en:prompt_start_header) echo "Prompt" ;;
    ja:prompt_repo_dir_label) echo "repo/dir" ;;
    en:prompt_repo_dir_label) echo "repo/dir" ;;

    # Answer hook
    ja:answer_label) echo "回答" ;;
    en:answer_label) echo "Answer" ;;

    # Stop hook
    ja:stop_kill_message) echo "作業中断 (kill)" ;;
    en:stop_kill_message) echo "Work interrupted (kill)" ;;
    ja:stop_work_summary_label) echo "作業内容" ;;
    en:stop_work_summary_label) echo "Work Summary" ;;
    ja:stop_changed_files_label) echo "変更ファイル" ;;
    en:stop_changed_files_label) echo "Changed Files" ;;
    ja:stop_answer_label) echo "回答" ;;
    en:stop_answer_label) echo "Answer" ;;
    ja:stop_git_label) echo "Git" ;;
    en:stop_git_label) echo "Git" ;;
    ja:stop_no_details) echo "(詳細なし)" ;;
    en:stop_no_details) echo "(No details)" ;;

    # Unknown key: keep visible for debugging.
    *)
      echo "$key"
      ;;
  esac
}
