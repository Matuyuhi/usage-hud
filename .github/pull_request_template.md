## 概要

<!-- 何を・なぜ。1〜3 行で -->

## 変更点

-

## 動作確認

<!-- テストが無いので、実際に動かして確かめたことを書く -->

- [ ] `scripts/install.sh` が通り、`⌃⌥U` でパネルが出る
- [ ] `~/Library/Application Support/usage-hud/usage.json` に 3 サービスの gauges がエラーなしで入る
- [ ] `pluginkit -m | grep usage` でウィジェットが登録されている（ウィジェット/共有データを触った場合）
- [ ] 見た目を変えた場合はスクリーンショットを貼った

## 確認事項

- [ ] `scripts/check-invariants.sh` が通る（署名 ad-hoc・App Group 無し・Keychain は `security` 経由・token refresh 無し）
- [ ] 非公式 API の取得経路を変えた場合、CLAUDE.md の表を更新した
- [ ] リリースが必要なら、マージ後に「Bump version」ワークフローを回す（この PR では VERSION を触らない）
