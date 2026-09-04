#!/bin/sh
# PR のスナップショット差分画像を置く orphan ブランチ snapshot-previews の更新。
#   scripts/snapshot-previews.sh put <PR番号> <commit短縮SHA> <画像ディレクトリ>   # その PR の分を差し替える
#   scripts/snapshot-previews.sh remove <PR番号>                                  # その PR の分を消す
#
# ブランチは履歴を持たせない: 毎回 親なしの commit を作って force push するので常に 1 commit で、
# 中身は「開いている PR の最新 1 回分」だけ。閉じた PR の分はどちらの操作でも一緒に消す
# （PR が閉じた時点でも snapshot-previews-cleanup.yml が remove を呼ぶ）。
#
# 必要な環境変数: GH_TOKEN（contents: write）、REPO（owner/repo）。origin に push できる checkout で実行する
set -eu
cd "$(dirname "$0")/.."

: "${GH_TOKEN:?}" "${REPO:?}"
PREVIEW_BRANCH=snapshot-previews

op="${1:-}"
pr="${2:-}"
case "$op" in
  put) [ $# -eq 4 ] || { echo "usage: $0 put <pr> <short-sha> <dir>" >&2; exit 2; } ;;
  remove) [ $# -eq 2 ] || { echo "usage: $0 remove <pr>" >&2; exit 2; } ;;
  *) echo "usage: $0 put <pr> <short-sha> <dir> | remove <pr>" >&2; exit 2 ;;
esac

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

rm -rf "$worktree/pr-$pr"
if [ "$op" = put ]; then
  short="$3"
  src="$4"
  for kind in expected actual diff; do
    [ -d "$src/$kind" ] || continue
    mkdir -p "$worktree/pr-$pr/$short/$kind"
    cp "$src/$kind"/*.png "$worktree/pr-$pr/$short/$kind/"
  done
fi

# 閉じた PR の分は消す
for other in "$worktree"/pr-*; do
  [ -d "$other" ] || continue
  number="${other##*/pr-}"
  [ "$number" = "$pr" ] && continue
  state="$(gh pr view "$number" --repo "$REPO" --json state -q .state 2>/dev/null || echo UNKNOWN)"
  [ "$state" = "OPEN" ] || rm -rf "$other"
done

git -C "$worktree" add -A
tree="$(git -C "$worktree" write-tree)"
commit="$(GIT_AUTHOR_NAME='github-actions[bot]' GIT_COMMITTER_NAME='github-actions[bot]' \
  GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
  GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
  git -C "$worktree" commit-tree "$tree" -m "snapshot previews ($op #$pr)")"
git -C "$worktree" push -q --force origin "$commit:refs/heads/$PREVIEW_BRANCH"
git worktree remove --force "$worktree"
echo "snapshot-previews: $op #$pr"
