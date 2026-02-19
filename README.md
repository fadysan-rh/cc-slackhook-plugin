# cc-slackhook

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code Plugin](https://img.shields.io/badge/Claude_Code-Plugin-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](hooks/)

> Claude Code の作業状況を Slack にリアルタイム通知するプラグイン。
> プロンプト送信・質問への回答・作業完了サマリーをスレッドにまとめて可視化します。

---

## Overview

チームで Claude Code を使っていると「今なにやってるの？」が見えにくい。
**cc-slackhook** はその問題を解決します。

```
You: "認証機能を実装して"
  ↓
Slack: プロンプト
       repo/dir: org:repo/main
       認証機能を実装して
         ├── リクエスト: "JWT と Session どちらがいい？"
         ├── 回答: "JWT で"
         └── 作業完了
              変更ファイル:
              • M src/auth/jwt.ts (+48 -0)
              • M src/middleware.ts (+12 -3)
              Git:
              • `a1b2c3d` feat: add JWT authentication
```

## Features

| Hook | Trigger | What it does |
|------|---------|-------------|
| **Prompt** | `UserPromptSubmit` | プロンプト送信時にSlack投稿。初回は新スレッド、以降はスレッド返信 |
| **Answer** | `PostToolUse` | `AskUserQuestion` への回答をスレッドに返信 |
| **Summary** | `Stop` | 作業サマリー・変更ファイル(diff統計付き)・Git操作をスレッドに返信 |

### Smart Threading

- 同一セッションの通知は **1つのSlackスレッド** にまとまる
- **30分間アイドル** または **作業ディレクトリ変更** で新スレッドを自動作成
- タイムアウトは `SLACK_THREAD_TIMEOUT` で調整可能

## Install

```bash
claude plugin add /path/to/cc-slackhook-plugin
```

## Configuration

`~/.claude/settings.json` に環境変数を追加:

```jsonc
{
  "env": {
    "SLACK_USER_TOKEN": "xoxp-...",   // Prompt/Answer通知 (ユーザーとして投稿)
    "SLACK_BOT_TOKEN": "xoxb-...",    // Summary通知 (Botとして投稿)
    "SLACK_CHANNEL": "C0XXXXXXX",     // 通知先チャンネルID
    "SLACK_LOCALE": "ja"              // 通知文言の言語: ja / en（未設定時はja）
  }
}
```

| Variable | Required | Description |
|----------|:--------:|-------------|
| `SLACK_USER_TOKEN` | Yes | プロンプト・回答通知用 (ユーザーとして投稿) |
| `SLACK_BOT_TOKEN` | Yes | 作業サマリー通知用 (Botとして投稿) |
| `SLACK_CHANNEL` | Yes | 通知先SlackチャンネルID |
| `SLACK_THREAD_TIMEOUT` | No | 新スレッドまでの秒数 (default: `1800` = 30min) |
| `SLACK_LOCALE` | No | 通知文言の言語。`ja` or `en` (default: `ja`) |

## Slack App Setup

1. [Slack API](https://api.slack.com/apps) で新しいAppを作成
2. **OAuth & Permissions** で以下のスコープを追加:

   | Token | Scope |
   |-------|-------|
   | Bot Token | `chat:write` |
   | User Token | `chat:write` |

3. Appをワークスペースにインストールしてトークンをコピー
4. 通知先チャンネルにAppを招待 (`/invite @your-app`)

## Architecture

```
hooks/
├── hooks.json                 # Hook定義 (イベント → スクリプトのマッピング)
├── slack-times-prompt.sh      # UserPromptSubmit → Slack投稿
├── slack-times-answer.sh      # PostToolUse(AskUserQuestion) → スレッド返信
└── slack-times-response.sh    # Stop → 作業サマリーをスレッド返信
```

**投稿の使い分け:**
- Prompt / Answer → `SLACK_USER_TOKEN` でユーザーとして投稿 (自分のアイコンで表示)
- Summary → `SLACK_BOT_TOKEN` で Bot として投稿 (Claude アイコンで表示)

## Development

```bash
# Hook のリグレッションテストを実行
tests/run-hooks-tests.sh
```

デバッグログは `/tmp/slack-times-debug.log` に出力されます。

## License

[MIT](LICENSE)
