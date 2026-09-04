#!/bin/sh
# README の画像をスナップショットテストの参照画像から作る。
#   scripts/sync-readme-images.sh          # docs/ を参照画像で上書きする
#   scripts/sync-readme-images.sh --check  # docs/ が参照画像と同じか見る（check-invariants.sh が呼ぶ。macOS 不要）
#
# 参照画像は Record snapshots ワークフローが CI のランナーで撮るので、README の画像もそこから作れば
# 実機のスクショを撮り直さなくても本体の見た目に追従する。撮り直しのたびに snapshots.yml がこれを呼んで一緒にコミットする
set -eu
cd "$(dirname "$0")/.."

SNAPSHOTS=usage-hud-tests/__Snapshots__
# docs 側のファイル名 → 参照画像。README.md は英語、README.ja.md は日本語の表示を載せる
pairs="
docs/panel.png=$SNAPSHOTS/panel-default.en_US.dark.png
docs/panel.ja.png=$SNAPSHOTS/panel-default.ja_JP.dark.png
"

check=0
[ "${1:-}" = "--check" ] && check=1

status=0
for pair in $pairs; do
  dest="${pair%%=*}"
  src="${pair#*=}"
  if [ ! -e "$src" ]; then
    echo "missing $src (record snapshots first)" >&2
    status=1
    continue
  fi
  if [ "$check" -eq 1 ]; then
    if cmp -s "$src" "$dest"; then
      echo "ok: $dest matches $src"
    else
      echo "NG: $dest differs from $src (run scripts/sync-readme-images.sh)"
      status=1
    fi
  else
    cp "$src" "$dest"
    echo "$dest <- $src"
  fi
done
exit "$status"
