# cc-slackhook

A Claude Code plugin that automatically notifies a Slack channel about session activity.

## Features

- **Prompt notification** (UserPromptSubmit hook): Posts to Slack each time a user sends a prompt
- **Work summary** (Stop hook): Posts a thread reply with work summary, changed files, and Git operations when Claude finishes responding
- **Thread management**: Messages within the same session are automatically grouped into a single Slack thread
- **Project info**: Displays Git repository as `org:repo/branch` or local path as `~/path`

## Install

```bash
claude --plugin-dir /path/to/cc-slackhook-plugin
```

## Configuration

Add the following environment variables to your `settings.json`:

```json
{
  "env": {
    "SLACK_USER_TOKEN": "xoxp-...",
    "SLACK_BOT_TOKEN": "xoxb-...",
    "SLACK_CHANNEL": "C0XXXXXXX"
  }
}
```

| Variable | Required | Purpose |
|----------|----------|---------|
| `SLACK_USER_TOKEN` | Yes | Prompt notifications (posts as user) |
| `SLACK_BOT_TOKEN` | Yes | Work summary notifications (posts as bot) |
| `SLACK_CHANNEL` | Yes | Target Slack channel ID |

## Slack App Setup

1. Create a new app at [Slack API](https://api.slack.com/apps)
2. Add the following OAuth scopes:
   - **Bot Token Scopes**: `chat:write`
   - **User Token Scopes**: `chat:write`
3. Install the app to your workspace and copy the tokens
4. Invite the app to your target channel

## How It Works

```
User sends a prompt
  ↓ UserPromptSubmit hook
  → Slack: Session start message (org:repo/branch + prompt content)

Claude finishes responding
  ↓ Stop hook
  → Slack: Thread reply (work summary + changed files + Git operations)

User sends another prompt in the same session
  ↓ UserPromptSubmit hook
  → Slack: Thread reply (prompt content)
```

## License

MIT
