# cc-slackhook

Claude Code のセッション活動を Slack チャンネルに自動通知するプラグイン。

## 機能

- **プロンプト通知** (UserPromptSubmit hook): ユーザーがプロンプトを送信するたびに Slack に通知
- **作業サマリー通知** (Stop hook): Claude の応答完了時に作業内容・変更ファイル・Git操作をまとめて通知
- **スレッド管理**: 同一セッション内のメッセージは自動的に1つの Slack スレッドにまとまる
- **プロジェクト情報**: Git リポジトリの `org:repo/branch` またはローカルパスを表示

## インストール

```bash
claude --plugin-dir /path/to/cc-slackhook-plugin
```

## 設定

`settings.json` の `env` に以下の環境変数を設定してください:

```json
{
  "env": {
    "SLACK_USER_TOKEN": "xoxp-...",
    "SLACK_BOT_TOKEN": "xoxb-...",
    "SLACK_CHANNEL": "C0XXXXXXX"
  }
}
```

| 環境変数 | 必須 | 用途 |
|----------|------|------|
| `SLACK_USER_TOKEN` | Yes | プロンプト通知 (ユーザーとして投稿) |
| `SLACK_BOT_TOKEN` | Yes | 作業サマリー通知 (Bot として投稿) |
| `SLACK_CHANNEL` | Yes | 通知先の Slack チャンネル ID |

## Slack App の準備

1. [Slack API](https://api.slack.com/apps) で新しい App を作成
2. OAuth & Permissions で以下のスコープを追加:
   - **Bot Token Scopes**: `chat:write`
   - **User Token Scopes**: `chat:write`
3. ワークスペースにインストールし、トークンを取得
4. 通知先チャンネルに App を招待

## 通知の流れ

```
ユーザーがプロンプト送信
  ↓ UserPromptSubmit hook
  → Slack: 作業開始メッセージ (org:repo/branch + プロンプト内容)

Claude が応答完了
  ↓ Stop hook
  → Slack: スレッド返信 (作業サマリー + 変更ファイル + Git操作)

同一セッションで再度プロンプト送信
  ↓ UserPromptSubmit hook
  → Slack: スレッド返信 (プロンプト内容)
```

## License

MIT
