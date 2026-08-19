# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

Copilot / Claude Code / Codex の残り使用量と CPU・メモリを表示する macOS 常駐アプリ。⌃⌥U でトグルするフローティングパネル（NSPanel）と通知センターウィジェット（WidgetKit）の 2 面構成。

## コマンド

```sh
# ビルド + /Applications へインストール + 再起動（通常はこれだけ）
scripts/install.sh

# ビルドのみ（Debug）
xcodebuild -project usage-hud.xcodeproj -scheme usage-hud -configuration Debug -destination 'platform=macOS' build

# 署名・sandbox・認証まわりの決めごとチェック（CI と同じもの。macOS 不要）
scripts/check-invariants.sh
```

テストは無い。CI（`.github/workflows/ci.yml`）は PR で universal Release ビルドと上のチェックを回すだけなので、
振る舞いの検証は実行して確認する:

- `~/Library/Application Support/usage-hud/usage.json` に 3 サービスの gauges がエラーなしで入ること
- `pluginkit -m | grep usage` でウィジェット登録
- `codesign -dv /Applications/usage-hud.app` → `Signature=adhoc`

## アーキテクチャ

ターゲットは 2 つ + 共有フォルダ（Xcode の synchronized folder なので、ファイルはフォルダに置くだけでターゲットに入る。pbxproj は直接編集して管理している）:

- `usage-hud/` — 本体アプリ。sandbox OFF・LSUIElement（Dock/メニューバー非表示）。**データ取得はすべて本体が担い**、`SharedStore` で JSON を書き、`WidgetCenter.reloadAllTimelines()` を叩く
- `usage-hud-widget/` — ウィジェット。sandbox ON（**extension は sandbox 必須**。OFF にすると pluginkit に登録されず、エラーログも出ない）。共有 JSON を読んで表示するだけ
- `shared/` — 両ターゲットに属する。`UsageSnapshot`（データモデル）と `SharedStore`（JSON の読み書き）

データの流れ: `Fetchers.swift`（3 サービス並列取得）→ `UsageStore`（@MainActor、タイマー管理: パネル表示中 120s / 非表示 1800s / システム指標 2s）→ `SharedStore.save()` → ウィジェットの `TimelineProvider` が読む。

### 表示項目の選択（`DisplayItem`）

表示項目は `shared/DisplayItem.swift` の enum で、選択は `DisplayPreferences`（本体の UserDefaults）に持つ。無効な項目は**表示しないだけでなく取得もしない**のが要件:

- サービス: `UsageStore.fetchService` が無効なら fetch を呼ばない（CLI 起動も HTTP も発生しない）。サービスが 0 個なら定期取得タイマー自体を張らない
- システム指標: `SystemSampler.sample(enabled:)` が有効な指標のカーネル統計だけを引く。0 個なら 2 秒タイマーを張らない。バッテリー/ディスクは動きが遅いのでサンプラ内で 30 秒キャッシュする
- ウィジェットとは App Group を共有できないため、選択内容も `UsageSnapshot.enabledItems` に入れて共有 JSON 経由で渡す

### データ源はすべて非公式 API（壊れたら都度直す前提）

| サービス | 経路 | 注意 |
|---|---|---|
| Claude | Keychain「Claude Code-credentials」→ `api.anthropic.com/api/oauth/usage`（`anthropic-beta: oauth-2025-04-20`） | **token refresh は実装しない**。refresh token は rotation されるため、ここで refresh すると Claude Code 本体の認証を壊す。401 時は stale 表示 |
| Codex | `codex app-server` を spawn して JSON-RPC | **initialize の応答を待ってから次を送る**。まとめて stdin に書くと 2 通目が黙って無視される（`ProcessSession.waitForLine`） |
| Copilot | `gh auth token` → `api.github.com/copilot_internal/user` の `quota_snapshots` | ユーザーは enterprise シートのため公式 billing API には個人データが出ない。この内部 API が唯一の経路 |

## 変えると壊れる設計判断

- **署名は ad-hoc 固定**（`CODE_SIGN_IDENTITY = "-"`、チーム設定なし）。どのマシンでも Apple ID・証明書なしでビルドできることが要件。DEVELOPMENT_TEAM を足さない
- **App Group は使わない**。App Group ID はチーム ID prefix が必須で ad-hoc と両立しない。共有キャッシュは実ホームの `Library/Application Support/usage-hud/usage.json` に置き、sandbox 内のウィジェットは temporary-exception entitlement（読み取り専用）+ `getpwuid` の実ホーム解決でアクセスする
- **Keychain は `security find-generic-password` コマンド経由で読む**（`SecItemCopyMatching` にしない）。API 直だと ACL がアプリの署名 identity に紐づき、ad-hoc ではリビルドごとに許可ダイアログが出る。コマンド経由ならダイアログ自体が出ない
- 外部 CLI（`codex` / `gh` / `security`）は `ProcessSession` 経由で起動する。GUI アプリの PATH に Homebrew や `~/.local/bin` が無いため、PATH 前置をここで一元管理している
- ビルド設定 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（本体のみ）。ブロッキング処理（プロセス起動・Keychain）は `runOffMain` + `nonisolated` で main を外すこと。実際に SecItemCopyMatching で UI ごと固まった経緯がある
