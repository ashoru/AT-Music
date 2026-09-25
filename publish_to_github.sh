#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

REMOTE_ARG="${1:-}"
DEFAULT_REMOTE="${AT_MUSIC_GITHUB_REMOTE:-https://github.com/ashoru/AT-Music.git}"

if ! command -v git >/dev/null 2>&1; then
  echo "错误：没有安装 git。"
  exit 1
fi

VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')"

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  echo "错误：无法从 project.yml 读取版本号。"
  exit 1
fi

if [ ! -d .git ]; then
  git init -b main
fi

git branch -M main

if ! git config user.name >/dev/null; then
  git config user.name "AT Music Publisher"
fi
if ! git config user.email >/dev/null; then
  git config user.email "at-music@users.noreply.github.com"
fi

if git remote get-url origin >/dev/null 2>&1; then
  if [ -n "$REMOTE_ARG" ] && [ "$(git remote get-url origin)" != "$REMOTE_ARG" ]; then
    git remote set-url origin "$REMOTE_ARG"
  fi
else
  git remote add origin "${REMOTE_ARG:-$DEFAULT_REMOTE}"
fi

echo "准备发布 AT Music $VERSION (build $BUILD)"
echo "远端：$(git remote get-url origin)"

git add -A

if git diff --cached --quiet; then
  echo "没有新的代码变更，直接确认远端同步状态。"
else
  git commit -m "release: AT Music $VERSION build $BUILD"
fi

git push -u origin main

echo
echo "已推送。GitHub Actions 会自动构建："
echo "  AT-Music-$VERSION-build$BUILD-unsigned.ipa"
echo "并在 Actions Artifact 与 GitHub Releases 中提供下载。"
