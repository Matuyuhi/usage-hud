#!/bin/sh
# スナップショットテストの結果を PR のコメントに出す（CI の Snapshot tests ジョブから呼ぶ）。
#
# 不一致があれば expected / actual / diff の画像を orphan ブランチ snapshot-previews に置き、
# その raw URL を並べた表をコメントにする（PR ごとに 1 つのコメントを更新する）。
# 不一致が無ければ、既にコメントがあるときだけ「差分なし」に更新し、ブランチ上の画像も消す。
#
# 画像を GitHub 上でそのまま表示するには https の URL が要る（コメントへの添付 API は無く、
# data: URI も落とされる）。artifact は zip で直接は見えないので、リポジトリ内の専用ブランチに置く。
# ブランチは履歴を持たせない: 毎回 親なしの commit を作って force push するので常に 1 commit で、
# 中身は「開いている PR の最新 1 回分」だけ。閉じた PR の分はここで消す。
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
short="$(printf '%s' "$HEAD_SHA" | cut -c1-7)"

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
  id="$(existing_comment_id)"
  if [ -n "$id" ]; then
    gh api --method PATCH "repos/$REPO/issues/comments/$id" -F "body=@$1" > /dev/null
    echo "updated comment $id"
  else
    gh api --method POST "repos/$REPO/issues/$PR_NUMBER/comments" -F "body=@$1" > /dev/null
    echo "posted a new comment"
  fi
}

# snapshot-previews を「この PR の今回分 + 開いている他 PR の分」だけの 1 commit に作り直して force push する。
# $1 が空ならこの PR の分を消すだけ
sync_previews() {
  worktree="$(mktemp -d)/preview"
  if git fetch -q origin "$PREVIEW_BRANCH" 2>/dev/null; then
    git worktree add -q --detach "$worktree" FETCH_HEAD
  else
    git worktree add -q --detach "$worktree"
    git -C "$worktree" checkout -q --orphan "$PREVIEW_BRANCH"
    git -C "$worktree" rm -rfq . 2>/dev/null || true
  fi
  printf '# snapshot previews\n\nCI が PR のスナップショット差分画像を置くブランチ。履歴は持たず、開いている PR の最新分だけがある。手で触らない。\n' \
    > "$worktree/README.md"

  rm -rf "$worktree/pr-$PR_NUMBER"
  if [ -n "${1:-}" ]; then
    for kind in expected actual diff; do
      [ -d "$1/$kind" ] || continue
      mkdir -p "$worktree/pr-$PR_NUMBER/$short/$kind"
      cp "$1/$kind"/*.png "$worktree/pr-$PR_NUMBER/$short/$kind/"
    done
  fi
  # 閉じた PR の分は消す
  for other in "$worktree"/pr-*; do
    [ -d "$other" ] || continue
    number="${other##*/pr-}"
    [ "$number" = "$PR_NUMBER" ] && continue
    state="$(gh pr view "$number" --repo "$REPO" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    [ "$state" = "OPEN" ] || rm -rf "$other"
  done

  git -C "$worktree" add -A
  tree="$(git -C "$worktree" write-tree)"
  commit="$(GIT_AUTHOR_NAME='github-actions[bot]' GIT_COMMITTER_NAME='github-actions[bot]' \
    GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
    GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
    git -C "$worktree" commit-tree "$tree" -m "snapshot previews (latest: #$PR_NUMBER at $short)")"
  git -C "$worktree" push -q --force origin "$commit:refs/heads/$PREVIEW_BRANCH"
  git worktree remove --force "$worktree"
}

body="$(mktemp)"

if [ -z "$changed" ] && [ -z "$missing" ]; then
  # 差分なし。以前に差分を報告していたときだけ上書きして、緑になったことを見せる
  if [ -n "$(existing_comment_id)" ]; then
    printf '%s\n## Snapshot tests\n\n✅ %s に見た目の差分はありません。\n' "$MARKER" "$short" > "$body"
    post_comment "$body"
    sync_previews ""
  else
    echo "no differences and no previous report; nothing to post"
  fi
  exit 0
fi

sync_previews "$OUT"

# 同じ URL だと GitHub の画像プロキシがキャッシュするので、commit ごとのディレクトリで URL を変える
raw="https://raw.githubusercontent.com/$REPO/$PREVIEW_BRANCH/pr-$PR_NUMBER/$short"
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
  printf '<sub>diff は違う画素を赤で塗ったもの。画像は <code>%s</code> ブランチにあり、次の実行で置き換わる（PR が閉じると消える）。</sub>\n' "$PREVIEW_BRANCH"
} > "$body"

post_comment "$body"
