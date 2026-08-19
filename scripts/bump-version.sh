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
CONFIGS=4  # app Debug/Release + widget Debug/Release

usage() { echo "usage: $0 patch|minor|major|MAJOR.MINOR.PATCH" >&2; exit 2; }
die() { printf '%s\n' "$1" >&2; exit 1; }

# 4 configuration ぶんの設定値を「値の重複を潰した 1 行」で返す。
# 個数が合わない（キーが増減した）ときはここで止める。数え損ねたまま sed すると
# 一部の configuration だけ古いバージョンで残る
pbx_setting() {
  values="$(sed -n "s/.*$1 = \\([^;]*\\);.*/\\1/p" "$PBX")"
  count="$(echo "$values" | grep -c . || true)"
  [ "$count" -eq "$CONFIGS" ] ||
    die "$1 must appear in all $CONFIGS build configurations of $PBX, found $count"
  echo $(echo "$values" | sort -u)
}

[ $# -eq 1 ] || usage

CUR="$(tr -d '[:space:]' < VERSION)"
# 壊れた VERSION（マージ衝突の残骸など）を算術展開に渡すと読めないエラーになる
echo "$CUR" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' ||
  die "VERSION must be a single 'MAJOR.MINOR.PATCH' line, got: $(cat VERSION)"
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

echo "$NEW" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' || die "not a semver: $NEW"

# 書き換え対象が 4 つ揃っていることを、書き換える前に確かめる
pbx_setting MARKETING_VERSION > /dev/null

# CURRENT_PROJECT_VERSION（ビルド番号）は 4 configuration で揃っている前提。
# ずれていると「どれが本物か」が決まらないので、直してから上げる
BUILD="$(pbx_setting CURRENT_PROJECT_VERSION)"
case "$BUILD" in
  *[!0-9]*) die "CURRENT_PROJECT_VERSION must be one integer across build configurations, found: $BUILD" ;;
esac
NEW_BUILD="$((BUILD + 1))"

echo "$NEW" > VERSION

sed -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${NEW};/" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/" \
    "$PBX" > "$PBX.tmp"
mv "$PBX.tmp" "$PBX"

echo "${CUR} -> ${NEW} (build ${BUILD} -> ${NEW_BUILD})"
