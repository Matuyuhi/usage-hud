#!/bin/sh
# スナップショットテストの結果を PR のコメントに出す（CI の Snapshot tests ジョブから呼ぶ）。
#
# 不一致があれば expected / actual / diff の画像を orphan ブランチ snapshot-previews の
# pr-<番号>/ に push して、その raw URL を並べた表をコメントにする（PR ごとに 1 つのコメントを更新する）。
# 不一致が無ければ、既にコメントがあるときだけ「差分なし」に更新する。
#
# 画像を GitHub 上でそのまま表示するには、どこかに URL でホストする必要がある。artifact は zip で
# 直接は見えないので、リポジトリ内の専用ブランチに置く（public リポジトリの raw URL は認証なしで見える）。
#
# 必要な環境変数:
#   GH_TOKEN        contents: write と pull-requests: write を持つトークン
#   REPO            owner/repo
#   PR_NUMBER       PR 番号
#   HEAD_SHA        テストした commit
#   SNAPSHOT_OUTPUT_DIR   scripts/snapshot-test.sh の出力先（既定 build-test/snapshots）
set -eu
cd "$(dirname "$0")/.."

: "${GH_TOKEN:?}" "${REPO:?}" "${PR_NUMBER:?}" "${HEAD_SHA:?}"
OUT="${SNAPSHOT_OUTPUT_DIR:-$PWD/build-test/snapshots}"
PREVIEW_BRANCH=snapshot-previews
MARKER="<!-- snapshot-report -->"
REFERENCES=usage-hud-tests/__Snapshots__

# 不一致のケース（expected/ は不一致のときだけ書かれる）と、参照画像が無いケース
changed="$(cd "$OUT/expected" 2>/dev/null && ls *.png 2>/dev/null || true)"
missing=""
for actual in "$OUT"/actual/*.png; do
  [ -e "$actual" ] || continue
  name="$(basename "$actual")"
  [ -e "$REFERENCES/$name" ] || missing="$missing $name"
done

existing_comment_id() {
  gh api "repos/$REPO/issues/$PR_NUMBER/comments" --paginate \
    --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" | head -n 1
}

post_comment() {
  body_file="$1"
  id="$(existing_comment_id)"
  if [ -n "$id" ]; then
    gh api --method PATCH "repos/$REPO/issues/comments/$id" -F "body=@$body_file" > /dev/null
    echo "updated comment $id"
  else
    gh api --method POST "repos/$REPO/issues/$PR_NUMBER/comments" -F "body=@$body_file" > /dev/null
    echo "posted a new comment"
  fi
}

short="$(printf '%s' "$HEAD_SHA" | cut -c1-7)"
body="$(mktemp)"

if [ -z "$changed" ] && [ -z "$missing" ]; then
  # 差分なし。以前に差分を報告していたときだけ上書きして、緑になったことを見せる
  if [ -n "$(existing_comment_id)" ]; then
    printf '%s\n## Snapshot tests\n\n✅ %s に見た目の差分はありません。\n' "$MARKER" "$short" > "$body"
    post_comment "$body"
  else
    echo "no differences and no previous report; nothing to post"
  fi
  exit 0
fi

# 画像を snapshot-previews ブランチの pr-<番号>/ に置く（前回のぶんは置き換える）
dir="pr-$PR_NUMBER"
worktree="$(mktemp -d)/preview"
if git fetch -q origin "$PREVIEW_BRANCH" 2>/dev/null; then
  git worktree add -q --detach "$worktree" FETCH_HEAD
else
  git worktree add -q --detach "$worktree"
  git -C "$worktree" checkout -q --orphan "$PREVIEW_BRANCH"
  git -C "$worktree" rm -rfq . 2>/dev/null || true
  printf '# snapshot previews\n\nCI が PR のスナップショット差分画像を置くブランチ。手で触らない。\n' > "$worktree/README.md"
fi
rm -rf "$worktree/$dir"
for kind in expected actual diff; do
  [ -d "$OUT/$kind" ] || continue
  mkdir -p "$worktree/$dir/$kind"
  cp "$OUT/$kind"/*.png "$worktree/$dir/$kind/"
done
git -C "$worktree" add -A
git -C "$worktree" -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -q -m "snapshots for #$PR_NUMBER at $short" --allow-empty
git -C "$worktree" push -q origin "HEAD:$PREVIEW_BRANCH"
preview_sha="$(git -C "$worktree" rev-parse HEAD)"
git worktree remove --force "$worktree"

raw="https://raw.githubusercontent.com/$REPO/$preview_sha/$dir"
img() { printf '<img src="%s/%s/%s" width="%s">' "$raw" "$1" "$2" "$3"; }
# 幅は表の 3 列に収まる程度。widget-* は横長なので少し狭める
width_for() { case "$1" in widget-*) echo 220 ;; *) echo 260 ;; esac; }

{
  printf '%s\n## Snapshot tests\n\n' "$MARKER"
  if [ -n "$changed" ]; then
    printf '⚠️ %s で参照画像と違うケースがあります（%s 件）。意図した変更なら Actions の **Record snapshots** を実行して参照画像を撮り直してください。\n\n' \
      "$short" "$(echo "$changed" | wc -w | tr -d ' ')"
    printf '<table>\n<tr><th>case</th><th>expected</th><th>actual</th><th>diff</th></tr>\n'
    for name in $changed; do
      w="$(width_for "$name")"
      printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
        "${name%.png}" "$(img expected "$name" "$w")" "$(img actual "$name" "$w")" \
        "$([ -e "$OUT/diff/$name" ] && img diff "$name" "$w" || echo 'サイズが違うため diff なし')"
    done
    printf '</table>\n\n'
  fi
  if [ -n "$missing" ]; then
    printf '🆕 参照画像が無いケースがあります。**Record snapshots** を `missing` で実行すると追加されます。\n\n'
    printf '<table>\n<tr><th>case</th><th>actual</th></tr>\n'
    for name in $missing; do
      printf '<tr><td><code>%s</code></td><td>%s</td></tr>\n' "${name%.png}" "$(img actual "$name" "$(width_for "$name")")"
    done
    printf '</table>\n\n'
  fi
  printf '<sub>diff は違う画素を赤で塗ったもの。画像は <code>%s</code> ブランチの <code>%s/</code> にあり、次の実行で置き換わる。</sub>\n' "$PREVIEW_BRANCH" "$dir"
} > "$body"

post_comment "$body"
