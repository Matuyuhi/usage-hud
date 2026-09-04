#!/bin/sh
# スナップショットテスト(パネル / ウィジェットの見た目の回帰テスト)。CI の Snapshot tests ジョブもこれを呼ぶ。
#   scripts/snapshot-test.sh            # usage-hud-tests/__Snapshots__ の参照画像と比べる
#   scripts/snapshot-test.sh --record   # 参照画像を撮り直す(見た目を意図して変えたとき)
#
# 表示言語はプロセス起動時に決まるので、en_US と ja_JP で 2 回走らせる。
# 描画結果は build-test/snapshots/actual/ に毎回書き、不一致なら diff/ と expected/ も書く
# (SNAPSHOT_OUTPUT_DIR で変えられる)。
set -eu
cd "$(dirname "$0")/.."

RECORD=0
case "${1:-}" in
  --record) RECORD=1 ;;
  "") ;;
  *) echo "usage: $0 [--record]" >&2; exit 2 ;;
esac

OUT="${SNAPSHOT_OUTPUT_DIR:-$PWD/build-test/snapshots}"
rm -rf "$OUT"

status=0
for locale in en_US ja_JP; do
  lang="${locale%%_*}"
  region="${locale##*_}"
  echo "== snapshot tests: $locale (record=$RECORD)"
  rm -rf "build-test/results-$locale.xcresult"
  # 環境変数は TEST_RUNNER_ を前置するとテストホストに渡る
  TEST_RUNNER_SNAPSHOT_RECORD="$RECORD" TEST_RUNNER_SNAPSHOT_OUTPUT_DIR="$OUT" \
  xcodebuild test -project usage-hud.xcodeproj -scheme usage-hud -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build-test \
    -testLanguage "$lang" -testRegion "$region" \
    -resultBundlePath "build-test/results-$locale.xcresult" \
    || status=1
done

if [ "$RECORD" -eq 1 ]; then
  echo "recorded into usage-hud-tests/__Snapshots__:"
  ls usage-hud-tests/__Snapshots__
fi
exit "$status"
