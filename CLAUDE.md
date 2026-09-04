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

# バージョンを上げる（VERSION と xcodeproj を両方。通常は Bump version ワークフロー経由）
scripts/bump-version.sh patch|minor|major

# スナップショットテスト（パネル / ウィジェットの見た目の回帰テスト。en_US と ja_JP で 2 回走る）
scripts/snapshot-test.sh                    # usage-hud-tests/__Snapshots__ と比べる
scripts/snapshot-test.sh --record           # 見た目を意図して変えたら撮り直す
scripts/snapshot-test.sh --record-missing   # ケースを足したら、無いものだけ撮る
```

バージョンの正は `VERSION`。xcodeproj の `MARKETING_VERSION` はそれと一致させ、`CURRENT_PROJECT_VERSION`
（ビルド番号）は bump のたびに +1 する。CI / release は `xcodebuild` の引数で `MARKETING_VERSION` を
上書きするので、ずれると困るのは `scripts/install.sh` で入れたローカルビルドだけ。
だから手で pbxproj を編集せず `scripts/bump-version.sh` を通し、一致は `check-invariants.sh` が見張る。

テストはスナップショットテストのみ（`usage-hud-tests/`）。CI（`.github/workflows/ci.yml`）は PR で
universal Release ビルド・上のチェック・スナップショットテストを回す。データ取得の振る舞いは実行して確認する:

- `~/Library/Application Support/usage-hud/usage.json` に 3 サービスの gauges がエラーなしで入ること
- `pluginkit -m | grep usage` でウィジェット登録
- `codesign -dv /Applications/usage-hud.app` → `Signature=adhoc`

### スナップショットテスト（`usage-hud-tests/`）

本体をホストにした XCTest バンドル。`PanelView` と `UsageWidgetView` を `NSHostingView` + `cacheDisplay` で
2x のビットマップに描き、`usage-hud-tests/__Snapshots__/<name>.<locale>.<appearance>.png` と比べる
（1 チャンネル 8/255 までの差は許容、違う画素が 50 を超えたら不一致。割合にしないのは縦長の画像で数値 1 つの変化が埋もれるため）。参照画像はリポジトリに入れるので、
見た目が変わる PR は Files changed で before / after が見える。描画結果は毎回 CI の `snapshots` artifact に上がり、
不一致があれば `scripts/snapshot-report.sh` が expected / actual / diff を PR のコメントに画像で出す
（コメントに画像を添付する API は無いので、`snapshot-previews` ブランチに置いて raw URL で参照する。このブランチは履歴を持たず、
開いている PR の最新分だけを 1 commit に force push する。fork からの PR は権限が無いので artifact のみ）。

- **参照画像は CI のランナーで撮ったものを正とする**。フォント描画の微差で手元とずれるため、
  撮り直しは Actions の Record snapshots ワークフロー（`snapshots.yml`、対象ブランチで手動実行 → ブランチにコミット）を使う。
  GITHUB_TOKEN の push は他のワークフローを起動しないので、コミット後の CI は再実行するか次の push で回す
- 表示言語は起動時に決まるので `-testLanguage` / `-testRegion` で en_US と ja_JP を別プロセスで回す。
  日時表示のため scheme の Test で `TZ=UTC` を固定し、データは `SampleData` の固定値を使う
- 描画に必要な入口: `UsageStore(preview:system:processes:enabled:)`（取得もタイマーも動かさない）、
  `PanelView(store:expanded:flatBackground:requestResize:)`（素材はウィンドウの裏側が無いと描けないので
  不透明背景に差し替える）、`UsageWidgetView(snapshot:family:)`（環境の `widgetFamily` は書き込めないので引数で受ける。
  ウィジェットの描画本体を `shared/` に置いているのはこのため。extension はテストのホストになれない）
- XCTest のホストとして起動されたときは `AppDelegate` が何も始めない（`XCTestSessionIdentifier` を見る）

## アーキテクチャ

ターゲットは 2 つ + 共有フォルダ（Xcode の synchronized folder なので、ファイルはフォルダに置くだけでターゲットに入る。pbxproj は直接編集して管理している）:

- `usage-hud/` — 本体アプリ。sandbox OFF・LSUIElement（Dock/メニューバー非表示）。**データ取得はすべて本体が担い**、`SharedStore` で JSON を書き、`WidgetCenter.reloadAllTimelines()` を叩く
- `usage-hud-widget/` — ウィジェット。sandbox ON（**extension は sandbox 必須**。OFF にすると pluginkit に登録されず、エラーログも出ない）。共有 JSON を読んで表示するだけ
- `shared/` — 両ターゲットに属する。`UsageSnapshot`（データモデル）、`SharedStore`（JSON の読み書き）、
  `UsageWidgetView`（ウィジェットの描画本体。本体側のスナップショットテストから描くためここにある）
- `usage-hud-tests/` — スナップショットテスト（上記）。本体をホストにするので `@testable import usage_hud` で本体の型を使う

データの流れ: `Fetchers.swift`（3 サービス並列取得）→ `UsageStore`（@MainActor、タイマー管理: パネル表示中 120s / 非表示 1800s / システム指標 2s）→ `SharedStore.save()` → ウィジェットの `TimelineProvider` が読む。

### 表示項目の選択（`DisplayItem`）

表示項目は `shared/DisplayItem.swift` の enum で、選択は `DisplayPreferences`（本体の UserDefaults）に持つ。無効な項目は**表示しないだけでなく取得もしない**のが要件:

- サービス: `UsageStore.fetchService` が無効なら fetch を呼ばない（CLI 起動も HTTP も発生しない）。サービスが 0 個なら定期取得タイマー自体を張らない
- システム指標: `SystemSampler.sample(enabled:)` が有効な指標のカーネル統計だけを引く。0 個なら 2 秒タイマーを張らない。バッテリー/ディスクは動きが遅いのでサンプラ内で 30 秒キャッシュする
- ウィジェットとは App Group を共有できないため、選択内容も `UsageSnapshot.enabledItems` に入れて共有 JSON 経由で渡す
- 上位プロセス（`ProcessSampler`）は CPU / メモリの詳細表示。全プロセスを列挙する `ps` を回すので、
  **System セクションを展開している間だけ**取る（`UsageStore.setSystemDetailExpanded`）。5 秒より短い間隔では起動しない。
  ウィジェットには出さないので共有 JSON には入れず、`UsageStore.processes` として本体だけが持つ。
  CPU / メモリのどちらかだけ有効な場合は、その列だけを `ps` に要求して片方の並びしか作らない

#### プロセス名はアプリ名に直してからまとめる（`AppNames`）

`ps` が返すのは実行ファイルなので、そのままだと Android Studio が `studio`、Electron 製アプリが
`Slack Helper (Renderer)` のように出る。実行ファイルのパスに含まれる**一番外側の** `.app` まで遡り、
そのバンドルの `CFBundleDisplayName` → `CFBundleName`（無ければバンドル名）を表示名にする。
一番外側を採るのは、ヘルパー（`Foo.app/Contents/Frameworks/Foo Helper.app/…`）や XPC サービスを
親アプリに寄せるため。同じバンドルに属するプロセスは 1 行にまとめて合計し、件数を `×3` で添える
（別々に出すと上位 5 件が同じアプリで埋まり、アプリ全体の使用量も読めない）。
`.app` の外にいる `WindowServer` などは、アクティビティモニタと同じく実行ファイル名のまま。
バンドル名の読み出しは 5 秒ごとのディスク I/O になるのでプロセス内にキャッシュする

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
- 外部 CLI（`codex` / `gh` / `security` / `ps`）は `ProcessSession` 経由で起動する。GUI アプリの PATH に Homebrew や `~/.local/bin` が無いため、PATH 前置をここで一元管理している。
  **前置は `prependCustomPaths: true` の opt-in**（既定は `/usr/bin:/bin:/usr/sbin:/sbin` 固定）。ユーザーが書き込めるディレクトリを前置すると
  偽の実行ファイルに乗っ取られる（CWE-426）ので、true にしてよいのは Homebrew 等に入る `codex` / `gh` だけ。`security` / `ps` のような system コマンドは既定のまま使う
- **プロセス一覧は libproc ではなく `ps`**。`libproc.h` は SDK の module map に無く Swift から直接呼べないうえ、`proc_pidinfo` は他ユーザ（root デーモン）のプロセスが EPERM になる。`ps -A -w -w -o pcpu= -o rss= -o comm=`（列は有効な指標のぶんだけ）なら全プロセスが取れ、`%CPU` も OS 側の減衰平均をそのまま使える
- ビルド設定 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（本体のみ）。ブロッキング処理（プロセス起動・Keychain）は `runOffMain` + `nonisolated` で main を外すこと。実際に SecItemCopyMatching で UI ごと固まった経緯がある
- **パネルは `FloatingPanel`（`canBecomeKey = true`）+ `hidesOnDeactivate = false`**。borderless の窓は key になれず、中の SwiftUI `Menu` が tracking を維持できない。NSPanel 既定の `hidesOnDeactivate` はメニュー操作でアプリのアクティブ状態が動いた拍子にパネルごと消す。両方合わさって設定メニューが点滅し操作できなくなった経緯がある
- **メニューが開いている間はパネルを動かさない**。`NSMenu.didBegin/didEndTrackingNotification` を見て `UsageStore.setUpdatesPaused()` で定期更新を止め、`fitPanelToContent()` は閉じるまで保留する（開いた NSMenu は開いた時点のパネルに紐づくため、リサイズ・移動・再描画のたびに閉じる）。パネル外クリックで閉じる監視も tracking 中は無視する
