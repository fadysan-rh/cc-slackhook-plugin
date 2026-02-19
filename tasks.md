# i18n Issue Breakdown (Slack Hooks)

## Assumptions

- 対象は `hooks/*.sh` の Slack 通知文言の国際化。
- 言語設定は `CC_SLACK_LOCALE`（`ja` / `en`）で切り替える。
- 未設定または不正値は `ja` にフォールバックする。
- 既存の通知構造（thread管理・メッセージ構成）は維持し、文言のみ切り替える。

## Workstreams

- 設定: `CC_SLACK_LOCALE` 解決ロジック
- 文言カタログ: ja/en キー管理
- Hook 実装: prompt / answer / stop への適用
- テスト: locale 別回帰テスト
- ドキュメント: README 更新
- リリース: 互換性確認

## Task Breakdown

| ID | Status | Task | Type | Depends On | Est. | Definition of Done |
|---|---|---|---|---|---|---|
| T1 | done | i18n対象文言の棚卸しとキー設計確定 | investigation | - | XS | 3 hook分の文言キー一覧が確定し、漏れがない |
| T2 | done | `CC_SLACK_LOCALE` 解決関数を追加（`ja`/`en`/fallback） | build | T1 | S | 各hookで同一ロジック利用、不正値で`ja`になる |
| T3 | done | ja/en 文言カタログ追加（全キー実装） | build | T1 | S | `ja`,`en`で同一キーセットを持ち、欠損がない |
| T4 | done | `hooks/slack-times-prompt.sh` をキー参照化 | build | T2,T3 | S | 「作業開始」「リクエスト」文言が locale で切替 |
| T5 | done | `hooks/slack-times-answer.sh` をキー参照化 | build | T2,T3 | XS | 「回答」文言が locale で切替 |
| T6 | done | `hooks/slack-times-response.sh` をキー参照化 | build | T2,T3 | M | kill通知・見出し・詳細なし文言が locale で切替 |
| T7 | done | locale 未設定/不正値の挙動テスト追加 | test | T4,T5,T6 | S | fallback 動作を自動テストで検証 |
| T8 | done | locale=`en` / `ja` の文言回帰テスト追加 | test | T4,T5,T6 | M | 主要文言が両言語で期待値一致 |
| T9 | done | README に `CC_SLACK_LOCALE` 仕様追記 | docs | T2,T3 | XS | 設定例・デフォルト・fallback が明記される |
| T10 | done | 後方互換確認（既存ユーザー影響） | release | T7,T8,T9 | XS | `CC_SLACK_LOCALE` 未設定で従来同等（ja）を確認 |
| T11 | done | 実Slack送信で最終確認 | release | T10 | S | `ja` / `en` で実表示確認が取れる |
| T12 | done | セッション開始メッセージ先頭を `Prompt` / `プロンプト` に変更し、絵文字を除去。`repo/dir:` 行を追加 | build | T4 | XS | セッション開始通知が locale に応じた先頭ラベルとなり、絵文字なしで `repo/dir:` を表示する |
| T13 | done | 通知文言とREADMEサンプルから絵文字を完全除去 | build/docs/test | T12 | XS | prompt/answer/stop の文言と README の表示例に絵文字が残っていない。回帰テストで emoji shortcode なしを確認 |

## Milestones

- M1 基盤: `T1 -> T2 -> T3`
- M2 Hook適用: `T4`, `T5`, `T6`（並列可）
- M3 品質: `T7`, `T8`, `T9`
- M4 出荷: `T10 -> T11`

## Critical Path

`T1 -> T2 -> T3 -> T6 -> T8 -> T10 -> T11`

## First PR Scope

- `T1 + T2 + T3 + T4 + T7(最低限) + T9`
- 狙い: Prompt hook で i18n の縦スライスを先に成立させる。
- 完了条件:
  - `CC_SLACK_LOCALE=en` で Prompt通知が英語化
  - 未設定/不正値で日本語フォールバック
  - README へ設定追記済み

## Progress Notes

- 完了: `T1`, `T2`, `T3`, `T4`, `T5`, `T6`, `T7`, `T8`, `T9`, `T10`, `T11`
- 完了: `T12`, `T13`
- テスト: `tests/run-hooks-tests.sh` -> `Passed: 56 / Failed: 0`
- 実送信確認セッション:
  - `i18n-manual-ja-1771469977`
  - `i18n-manual-en-1771469980`
