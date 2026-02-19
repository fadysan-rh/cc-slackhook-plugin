# Contributing to cc-slackhook

Thank you for your interest in contributing!

## Architecture

```
hooks/
├── hooks.json                 # Hook definitions (event -> script)
├── slack-times-prompt.sh      # UserPromptSubmit -> Slack post
├── slack-times-answer.sh      # PostToolUse(AskUserQuestion) -> thread reply
├── slack-times-response.sh    # Stop -> thread summary
└── i18n.sh                    # Locale helper (ja / en)
```

Posting behavior:
- Prompt / Answer: posted with `CC_SLACK_USER_TOKEN` as the user
- Summary: posted with `CC_SLACK_BOT_TOKEN` as the bot

## Development

```bash
# Run hook regression tests
tests/run-hooks-tests.sh
```

Debug logs are disabled by default.
Set `CC_SLACK_HOOK_DEBUG=1` to enable logging.
Default log path is `$HOME/.claude/slack-times-debug.log` (mode `600`).

## Release

```bash
# Validate plugin and marketplace manifests
claude plugin validate .claude-plugin/plugin.json
claude plugin validate .claude-plugin/marketplace.json

# Run tests
tests/run-hooks-tests.sh

# Publish a release tag
git tag v1.x.x
git push origin v1.x.x
```

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
