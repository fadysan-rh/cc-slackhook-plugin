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
- タイムアウトは `CC_SLACK_THREAD_TIMEOUT` で変更可能

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
    "CC_SLACK_USER_TOKEN": "xoxp-...",   // Prompt/Answer 通知（ユーザーとして投稿）
    "CC_SLACK_BOT_TOKEN": "xoxb-...",    // Summary 通知（Botとして投稿）
    "CC_SLACK_CHANNEL": "C0XXXXXXX",     // 通知先チャンネルID
    "CC_SLACK_LOCALE": "ja",             // 通知文言の言語: ja / en（既定: ja）
    "CC_SLACK_HOOK_DEBUG": "0",          // 任意: 1 でデバッグログ有効化
    "CC_CC_SLACK_HOOK_DEBUG_LOG": ""        // 任意: デバッグログ保存先
  }
}
```

| Variable | Required | Description |
|----------|:--------:|-------------|
| `CC_SLACK_USER_TOKEN` | Yes | プロンプト/回答通知用トークン（ユーザーとして投稿） |
| `CC_SLACK_BOT_TOKEN` | Yes | 作業完了サマリー通知用トークン（Botとして投稿） |
| `CC_SLACK_CHANNEL` | Yes | 通知先 Slack チャンネル ID |
| `CC_SLACK_THREAD_TIMEOUT` | No | 新規スレッド開始までの秒数（既定: `1800`） |
| `CC_SLACK_LOCALE` | No | 通知文言の言語。`ja` または `en`（既定: `ja`） |
| `CC_SLACK_HOOK_DEBUG` | No | `1` で Hook のデバッグログを有効化（既定: 無効） |
| `CC_CC_SLACK_HOOK_DEBUG_LOG` | No | デバッグログの出力先（既定: `$HOME/.claude/slack-times-debug.log`） |

## Slack App Setup

1. [Slack API](https://api.slack.com/apps) で新しい App を作成します。
2. **OAuth & Permissions** で以下のスコープを追加します。

   | Token | Scope |
   |-------|-------|
   | Bot Token | `chat:write` |
   | User Token | `chat:write` |

3. App をワークスペースにインストールし、トークンを取得します。
4. 通知先チャンネルに App を招待します（`/invite @your-app`）。

## Contributing

アーキテクチャ、開発方法、リリース手順は [CONTRIBUTING.md](../../CONTRIBUTING.md) を参照してください。

## License

[MIT](../../LICENSE)
