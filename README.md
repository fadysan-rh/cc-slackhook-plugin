# cc-slackhook

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code Plugin](https://img.shields.io/badge/Claude_Code-Plugin-blueviolet)](https://docs.anthropic.com/en/docs/claude-code)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](hooks/)

> Real-time Slack notifications for Claude Code session activity.
> Prompt submissions, AskUserQuestion answers, and stop summaries are grouped into one thread.

Language: English | [Japanese](docs/ja/README.md)

---

## Overview

When teams use Claude Code, it can be hard to see what is currently in progress.
**cc-slackhook** makes that visible in Slack.

```
You: "Implement authentication"
  ↓
Slack:
       *Claude Code Session Started*
       *repo/dir:* org:repo/main

       *Prompt*
       Implement authentication
         ├── Request: "JWT or session?"
         ├── Answer: "JWT"
         └── Work complete
              Changed Files:
              • M src/auth/jwt.ts (+48 -0)
              • M src/middleware.ts (+12 -3)
              Git:
              • `a1b2c3d` feat: add JWT authentication
```

## Features

| Hook | Trigger | What it does |
|------|---------|-------------|
| **Prompt** | `UserPromptSubmit` | Posts to Slack on user prompt submission. First post starts a new thread; later prompts continue in the thread. |
| **Answer** | `PostToolUse` | Posts `AskUserQuestion` answers as thread replies. |
| **Summary** | `Stop` | Posts work summary, changed files (with diff stats), and Git operation results. |

### Smart Threading

- One Slack thread per active session
- Starts a new thread after 30 minutes of idle time or when the working directory changes
- Timeout is configurable via `CC_SLACK_THREAD_TIMEOUT`

## Install

For end users:

```bash
claude plugin marketplace add fadysan-rh/cc-slackhook-plugin
claude plugin install cc-slackhook@cc-slackhook-marketplace --scope user
```

For local development only:

```bash
claude --plugin-dir /path/to/cc-slackhook-plugin
```

## Configuration

Add these environment variables to `~/.claude/settings.json`:

```jsonc
{
  "env": {
    "CC_SLACK_USER_TOKEN": "xoxp-...",   // Prompt/Answer posts (as user)
    "CC_SLACK_BOT_TOKEN": "xoxb-...",    // Summary posts (as bot)
    "CC_SLACK_CHANNEL": "C0XXXXXXX",     // Target channel ID
    "CC_SLACK_LOCALE": "ja",             // Message locale: ja / en (default: ja)
    "CC_SLACK_HOOK_DEBUG": "0",          // Optional: set 1 to enable debug logs
    "CC_CC_SLACK_HOOK_DEBUG_LOG": ""        // Optional: custom debug log path
  }
}
```

| Variable | Required | Description |
|----------|:--------:|-------------|
| `CC_SLACK_USER_TOKEN` | Yes | Token for prompt/answer notifications (posted as the user) |
| `CC_SLACK_BOT_TOKEN` | Yes | Token for stop summary notifications (posted as the bot) |
| `CC_SLACK_CHANNEL` | Yes | Target Slack channel ID |
| `CC_SLACK_THREAD_TIMEOUT` | No | Seconds before starting a new thread (default: `1800`) |
| `CC_SLACK_LOCALE` | No | Notification locale: `ja` or `en` (default: `ja`) |
| `CC_SLACK_HOOK_DEBUG` | No | Set `1` to enable hook debug logs (default: disabled) |
| `CC_CC_SLACK_HOOK_DEBUG_LOG` | No | Debug log path (default: `$HOME/.claude/slack-times-debug.log`) |

## Slack App Setup

1. Create a new app in [Slack API](https://api.slack.com/apps).
2. In **OAuth & Permissions**, add these scopes.

   | Token | Scope |
   |-------|-------|
   | Bot Token | `chat:write` |
   | User Token | `chat:write` |

3. Install the app in your workspace and copy the tokens.
4. Invite the app to the target channel (`/invite @your-app`).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for architecture, development, and release information.

## License

[MIT](LICENSE)
