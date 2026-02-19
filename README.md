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
Slack: Prompt
       repo/dir: org:repo/main
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
- Timeout is configurable via `SLACK_THREAD_TIMEOUT`

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
    "SLACK_USER_TOKEN": "xoxp-...",   // Prompt/Answer posts (as user)
    "SLACK_BOT_TOKEN": "xoxb-...",    // Summary posts (as bot)
    "SLACK_CHANNEL": "C0XXXXXXX",     // Target channel ID
    "SLACK_LOCALE": "ja"              // Message locale: ja / en (default: ja)
  }
}
```

| Variable | Required | Description |
|----------|:--------:|-------------|
| `SLACK_USER_TOKEN` | Yes | Token for prompt/answer notifications (posted as the user) |
| `SLACK_BOT_TOKEN` | Yes | Token for stop summary notifications (posted as the bot) |
| `SLACK_CHANNEL` | Yes | Target Slack channel ID |
| `SLACK_THREAD_TIMEOUT` | No | Seconds before starting a new thread (default: `1800`) |
| `SLACK_LOCALE` | No | Notification locale: `ja` or `en` (default: `ja`) |

## Slack App Setup

1. Create a new app in [Slack API](https://api.slack.com/apps).
2. In **OAuth & Permissions**, add these scopes.

   | Token | Scope |
   |-------|-------|
   | Bot Token | `chat:write` |
   | User Token | `chat:write` |

3. Install the app in your workspace and copy the tokens.
4. Invite the app to the target channel (`/invite @your-app`).

## Architecture

```
hooks/
├── hooks.json                 # Hook definitions (event -> script)
├── slack-times-prompt.sh      # UserPromptSubmit -> Slack post
├── slack-times-answer.sh      # PostToolUse(AskUserQuestion) -> thread reply
└── slack-times-response.sh    # Stop -> thread summary
```

Posting behavior:
- Prompt / Answer: posted with `SLACK_USER_TOKEN` as the user
- Summary: posted with `SLACK_BOT_TOKEN` as the bot

## Development

```bash
# Run hook regression tests
tests/run-hooks-tests.sh
```

Debug logs are written to `/tmp/slack-times-debug.log`.

## Release

```bash
# Validate plugin and marketplace manifests
claude plugin validate .claude-plugin/plugin.json
claude plugin validate .claude-plugin/marketplace.json

# Run tests
tests/run-hooks-tests.sh

# Publish a release tag
git tag v1.1.0
git push origin v1.1.0
```

## License

[MIT](LICENSE)
