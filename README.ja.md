# usage-hud

[English](README.md)

[![CI](https://github.com/Matuyuhi/usage-hud/actions/workflows/ci.yml/badge.svg)](https://github.com/Matuyuhi/usage-hud/actions/workflows/ci.yml)

Copilot / Claude Code / Codex の残り使用量と、CPU・メモリ使用率を一枚で見る macOS 常駐アプリ。
メニューバーにアイコンを増やさず、`⌃⌥U` で好きなときに呼び出せます。

<img src="docs/panel.png" alt="usage-hud panel" width="346">

## インストール

```sh
brew install --cask matuyuhi/tools/usage-hud
```

ソースから入れる場合:

```sh
git clone https://github.com/Matuyuhi/usage-hud.git
cd usage-hud && scripts/install.sh
```

## 使い方

- `⌃⌥U` でパネルを開閉（パネル外クリックでも閉じます）
- 各サービス名をクリックすると詳細（実クレジット数・リセット日時など）を展開
- 歯車メニューから「ログイン時に起動」を設定
- 通知センターのウィジェットは「編集 → ウィジェットを追加 → Usage HUD」で追加

## 必要なもの

使用量は各ツールのログイン情報から読み取ります。表示したいものだけログインしていれば十分です。

| 表示 | 必要なもの |
|---|---|
| Claude Code | Claude Code でログイン済みであること |
| Codex | `codex` CLI でログイン済みであること |
| Copilot | `gh auth login` 済みであること |

いずれも読み取りのみで、認証情報の書き換えや更新は行いません。

## 表示言語

UI はシステムの言語設定に従い、英語と日本語を収録しています。
どちらかに固定する場合は「システム設定 > 一般 > 言語と地域 > アプリケーション」で指定してください。

## 注意

各サービスの使用量 API は公開仕様ではないため、提供側の変更で取得できなくなることがあります。
取得に失敗したサービスは、直前の値とエラー内容を並べて表示します。

## 開発

```sh
scripts/install.sh            # Release ビルドして /Applications に入れる
scripts/check-invariants.sh   # CI が見る署名・sandbox・認証まわりの決めごとチェック
```

PR ではこの 2 つが回る（macOS での universal Release ビルドと、上の invariant チェック）。
リリースは `VERSION` が信号なので、「Bump version」ワークフローを回して、開いた PR をマージすると
リリース公開と Homebrew cask 更新まで進む。

## ライセンス

MIT
