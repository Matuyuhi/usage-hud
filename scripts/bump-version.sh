#!/bin/sh
# VERSION と xcodeproj のバージョンをまとめて上げる。bump.yml もこれを呼ぶ。
#   scripts/bump-version.sh patch|minor|major   # VERSION から次を計算
#   scripts/bump-version.sh 1.2.3               # 明示指定
#
# xcodeproj も一緒に上げるのが要件。ここを忘れると scripts/install.sh で入れた
# ローカルビルドだけ MARKETING_VERSION が古いまま（CI は xcodebuild の引数で
# 上書きするので気付けない）になる。check-invariants.sh が一致を見張っている。
#
# sed -i は GNU/BSD で非互換なので、一時ファイル + mv で書き換える。
set -eu
cd "$(dirname "$0")/.."

PBX=usage-hud.xcodeproj/project.pbxproj

usage() { echo "usage: $0 patch|minor|major|MAJOR.MINOR.PATCH" >&2; exit 2; }
[ $# -eq 1 ] || usage

CUR="$(tr -d '[:space:]' < VERSION)"
MA="${CUR%%.*}"
MI="${CUR#*.}"; MI="${MI%%.*}"
PA="${CUR##*.}"

case "$1" in
  major) NEW="$((MA + 1)).0.0" ;;
  minor) NEW="${MA}.$((MI + 1)).0" ;;
  patch) NEW="${MA}.${MI}.$((PA + 1))" ;;
  [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
  *) usage ;;
esac

echo "$NEW" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' || { echo "not a semver: $NEW" >&2; exit 1; }

# CURRENT_PROJECT_VERSION（ビルド番号）は 4 configuration で揃っている前提。
# ずれていると「どれが本物か」が決まらないので、直してから上げる
BUILDS="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);.*/\1/p' "$PBX" | sort -u)"
[ "$(echo "$BUILDS" | wc -l)" -eq 1 ] || {
  echo "CURRENT_PROJECT_VERSION differs across build configurations: $(echo "$BUILDS" | tr '\n' ' ')" >&2
  exit 1
}
NEW_BUILD="$((BUILDS + 1))"

echo "$NEW" > VERSION

sed -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${NEW};/" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/" \
    "$PBX" > "$PBX.tmp"
mv "$PBX.tmp" "$PBX"

echo "${CUR} -> ${NEW} (build ${BUILDS} -> ${NEW_BUILD})"
