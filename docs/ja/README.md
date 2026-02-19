# cc-slackhook

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../../LICENSE)
[![Claude Code Plugin](https://img.shields.io/badge/Claude_Code-Plugin-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](../../hooks/)

> Claude Code の作業状況を Slack にリアルタイム通知するプラグインです。
> プロンプト送信、AskUserQuestion への回答、作業完了サマリーを 1 つのスレッドに集約します。

言語: [English](../../README.md) | 日本語

---

## Overview

チームで Claude Code を使うと「今どの作業が進んでいるか」が見えにくくなります。
**cc-slackhook** は Slack への通知で可視化します。

```
You: "認証機能を実装して"
  ↓
Slack:
       *Claude Code Session Started*
       *repo/dir:* org:repo/main

       *Prompt*
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
| **Prompt** | `UserPromptSubmit` | ユーザーがプロンプトを送るたびに Slack に投稿します。初回は新規スレッド、以降は同じスレッドに返信します。 |
| **Answer** | `PostToolUse` | `AskUserQuestion` への回答をスレッド返信として投稿します。 |
| **Summary** | `Stop` | 作業サマリー、変更ファイル（diff 統計付き）、Git 操作結果を投稿します。 |

### Smart Threading

- 同一セッションの通知を 1 つの Slack スレッドに集約
- 30 分アイドル、または作業ディレクトリ変更で新規スレッドを開始
- タイムアウトは `SLACK_THREAD_TIMEOUT` で変更可能

## Install

```bash
claude plugin marketplace add fadysan-rh/cc-slackhook-plugin
claude plugin install cc-slackhook@cc-slackhook-marketplace --scope user
```

ローカル開発時のみ:

```bash
claude --plugin-dir /path/to/cc-slackhook-plugin
```

## Configuration

`~/.claude/settings.json` に以下を追加します。

```jsonc
{
  "env": {
    "SLACK_USER_TOKEN": "xoxp-...",   // Prompt/Answer 通知（ユーザーとして投稿）
    "SLACK_BOT_TOKEN": "xoxb-...",    // Summary 通知（Botとして投稿）
    "SLACK_CHANNEL": "C0XXXXXXX",     // 通知先チャンネルID
    "SLACK_LOCALE": "ja"              // 通知文言の言語: ja / en（既定: ja）
  }
}
```

| Variable | Required | Description |
|----------|:--------:|-------------|
| `SLACK_USER_TOKEN` | Yes | プロンプト/回答通知用トークン（ユーザーとして投稿） |
| `SLACK_BOT_TOKEN` | Yes | 作業完了サマリー通知用トークン（Botとして投稿） |
| `SLACK_CHANNEL` | Yes | 通知先 Slack チャンネル ID |
| `SLACK_THREAD_TIMEOUT` | No | 新規スレッド開始までの秒数（既定: `1800`） |
| `SLACK_LOCALE` | No | 通知文言の言語。`ja` または `en`（既定: `ja`） |

## Slack App Setup

1. [Slack API](https://api.slack.com/apps) で新しい App を作成します。
2. **OAuth & Permissions** で以下のスコープを追加します。

   | Token | Scope |
   |-------|-------|
   | Bot Token | `chat:write` |
   | User Token | `chat:write` |

3. App をワークスペースにインストールし、トークンを取得します。
4. 通知先チャンネルに App を招待します（`/invite @your-app`）。

## Architecture

```
hooks/
├── hooks.json                 # Hook定義（event -> script）
├── slack-times-prompt.sh      # UserPromptSubmit -> Slack投稿
├── slack-times-answer.sh      # PostToolUse(AskUserQuestion) -> スレッド返信
└── slack-times-response.sh    # Stop -> 作業サマリー投稿
```

投稿の使い分け:
- Prompt / Answer: `SLACK_USER_TOKEN` でユーザーとして投稿
- Summary: `SLACK_BOT_TOKEN` で Bot として投稿

## Development

```bash
# Hook のリグレッションテストを実行
tests/run-hooks-tests.sh
```

デバッグログは `/tmp/slack-times-debug.log` に出力されます。

## Release

```bash
# plugin / marketplace マニフェストの検証
claude plugin validate .claude-plugin/plugin.json
claude plugin validate .claude-plugin/marketplace.json

# テスト実行
tests/run-hooks-tests.sh

# リリースタグを公開
git tag v1.1.0
git push origin v1.1.0
```

## License

[MIT](../../LICENSE)
