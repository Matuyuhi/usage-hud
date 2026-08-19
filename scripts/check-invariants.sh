#!/bin/sh
# CLAUDE.md「変えると壊れる設計判断」を機械的に守るためのチェック。
# ローカルでもそのまま実行できる（macOS 不要・Xcode 不要）:
#   scripts/check-invariants.sh
set -eu
cd "$(dirname "$0")/.."

fail=0
ng() { printf 'NG: %s\n' "$1"; fail=1; }
ok() { printf 'ok: %s\n' "$1"; }

PBX=usage-hud.xcodeproj/project.pbxproj
WIDGET_ENT=usage-hud-widget/usage-hud-widget.entitlements

# VERSION は release.yml がタグ名に使う。空白や v 付きが混ざると v<version> が壊れる
if grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' VERSION && [ "$(wc -l < VERSION)" -le 1 ]; then
  ok "VERSION is semver ($(tr -d '[:space:]' < VERSION))"
else
  ng "VERSION must be a single 'MAJOR.MINOR.PATCH' line, got: $(cat VERSION)"
fi

# xcodeproj の MARKETING_VERSION は VERSION と一致させる（scripts/bump-version.sh が両方上げる）。
# CI/release は xcodebuild の引数で上書きするので、ずれても気付けるのはローカルビルドだけ
ver="$(tr -d '[:space:]' < VERSION)"
marketing="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PBX" | sort -u)"
marketing="$(echo $marketing)"  # 値が複数あれば空白区切りの 1 行になる
if [ "$marketing" = "$ver" ]; then
  ok "MARKETING_VERSION matches VERSION ($ver) in all 4 build configurations"
else
  ng "MARKETING_VERSION in $PBX must be $ver in all 4 build configurations, found: $marketing (run scripts/bump-version.sh)"
fi

# ビルド番号は 4 configuration で揃っていること（揃っていないと bump 時にどれが本物か決まらない）
builds="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$PBX" | sort -u)"
builds="$(echo $builds)"
if [ "$(sed -n 's/.*CURRENT_PROJECT_VERSION = [^;]*;.*/x/p' "$PBX" | wc -l)" -eq 4 ] &&
   [ "$(echo "$builds" | wc -w)" -eq 1 ]; then
  ok "CURRENT_PROJECT_VERSION is the same ($builds) in all 4 build configurations"
else
  ng "CURRENT_PROJECT_VERSION must appear in all 4 build configurations with one value, found: $builds"
fi

# 署名は ad-hoc 固定。Apple ID・証明書なしでどのマシンでもビルドできることが要件
if grep -q 'DEVELOPMENT_TEAM' "$PBX"; then
  ng "DEVELOPMENT_TEAM found in $PBX (ad-hoc signing must stay team-less)"
else
  ok "no DEVELOPMENT_TEAM in $PBX"
fi

identities="$(grep -c '"CODE_SIGN_IDENTITY\[sdk=macosx\*\]" = "-";' "$PBX" || true)"
if [ "$identities" -eq 4 ]; then
  ok "CODE_SIGN_IDENTITY is ad-hoc (\"-\") in all 4 build configurations"
else
  ng "expected 4 ad-hoc CODE_SIGN_IDENTITY entries in $PBX, found $identities"
fi

# 本体は sandbox OFF（外部 CLI と Keychain を叩く）、extension は sandbox ON（OFF だと pluginkit に登録されない）
sandbox_off="$(grep -c 'ENABLE_APP_SANDBOX = NO;' "$PBX" || true)"
sandbox_on="$(grep -c 'ENABLE_APP_SANDBOX = YES;' "$PBX" || true)"
if [ "$sandbox_off" -eq 2 ] && [ "$sandbox_on" -eq 2 ]; then
  ok "app sandbox OFF x2 / widget sandbox ON x2"
else
  ng "expected ENABLE_APP_SANDBOX NO x2 (app) and YES x2 (widget), found NO x$sandbox_off YES x$sandbox_on"
fi

# App Group はチーム ID prefix 必須なので ad-hoc と両立しない
if grep -rq 'application-groups' "$PBX" usage-hud usage-hud-widget shared; then
  ng "App Group entitlement found (incompatible with ad-hoc signing; use the shared JSON path instead)"
else
  ok "no App Group entitlement"
fi

# ウィジェットは共有 JSON を home 相対の読み取り例外で参照する
if grep -q 'temporary-exception.files.home-relative-path.read-only' "$WIDGET_ENT" &&
   grep -q '/Library/Application Support/usage-hud/' "$WIDGET_ENT"; then
  ok "widget keeps the read-only home-relative exception for the shared cache"
else
  ng "$WIDGET_ENT lost the read-only exception for ~/Library/Application Support/usage-hud/"
fi

# Keychain は security コマンド経由。SecItemCopyMatching だと ad-hoc 署名でリビルド毎に許可ダイアログが出る
if grep -rq 'SecItemCopyMatching(' usage-hud shared; then
  ng "SecItemCopyMatching( used; read the Keychain through 'security find-generic-password' instead"
else
  ok "Keychain is read through the security command"
fi

if grep -q 'find-generic-password' usage-hud/Fetchers.swift; then
  ok "security find-generic-password call is still in place"
else
  ng "usage-hud/Fetchers.swift no longer calls 'security find-generic-password'"
fi

# refresh token は rotation されるため、ここで refresh すると Claude Code 本体の認証を壊す
if grep -rq 'grant_type\|refresh_token' usage-hud shared; then
  ng "OAuth token refresh looks implemented; Claude Code owns the refresh token rotation"
else
  ok "no OAuth token refresh (401 stays a stale display)"
fi

[ "$fail" -eq 0 ] || { echo; echo "invariant check failed"; exit 1; }
echo
echo "all invariants hold"
