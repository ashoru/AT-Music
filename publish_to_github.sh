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

# ---------------------------------------------------------------------------
# 只发布下列白名单路径。仓库曾经因为 `git add -A` 把签名证书和解压密码推上公开
# 仓库，因此这里不再允许无差别暂存。
# ---------------------------------------------------------------------------
SAFE_PATHS=(
  ATMusic
  ATMusicWatch
  docs
  tests
  .github
  project.yml
  README.md
  CHANGELOG.md
  FEATURES.md
  LICENSE
  说明.md
  generate_unsigned_ipa.sh
  export_at_music_ipa.sh
  package_at_music_ipa.sh
  copy_unsigned_ipa_to_icloud.sh
  update_from_github.sh
  install_at_music.sh
  install_at_music_ipad.sh
  make_at_music_ipa.py
  publish_to_github.sh
  一键安装AT Music.command
)

EXISTING_PATHS=()
for path in "${SAFE_PATHS[@]}"; do
  if [ -e "$path" ]; then
    EXISTING_PATHS+=("$path")
  fi
done

if [ ${#EXISTING_PATHS[@]} -eq 0 ]; then
  echo "错误：没有可发布的路径。"
  exit 1
fi

# ---------------------------------------------------------------------------
# 机密文件拦截：证书、密钥、描述文件、密码/交接文档一律拒绝提交。
# ---------------------------------------------------------------------------
SENSITIVE_REGEX='(\.p12$|\.p8$|\.pem$|\.cer$|\.key$|\.mobileprovision$|\.certSigningRequest$|\.keystore$|\.zip$|\.rar$|\.7z$|证书|密码|密钥|secret|credential|HANDOVER)'

BLOCKED=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  file="${entry#???}"
  file="${file%% -> *}"
  if [[ "$file" =~ $SENSITIVE_REGEX ]]; then
    BLOCKED+=("$file")
  fi
done < <(git status --porcelain --untracked-files=all "${EXISTING_PATHS[@]}")

if [ ${#BLOCKED[@]} -gt 0 ]; then
  echo "错误：以下文件疑似包含机密信息，已拒绝提交："
  printf '  %s\n' "${BLOCKED[@]}"
  echo
  echo "请把它们加入 .gitignore，或移动到仓库之外。"
  echo "确认安全时可用 AT_MUSIC_ALLOW_SENSITIVE=1 覆盖（不推荐）。"
  if [ "${AT_MUSIC_ALLOW_SENSITIVE:-0}" != "1" ]; then
    exit 1
  fi
fi

git add -A -- "${EXISTING_PATHS[@]}"

if git diff --cached --quiet; then
  echo "没有新的代码变更，直接确认远端同步状态。"
else
  echo
  echo "将提交以下变更："
  git --no-pager diff --cached --stat
  echo
  if [ "${AT_MUSIC_ASSUME_YES:-0}" != "1" ]; then
    read -r -p "确认提交并推送到 $(git remote get-url origin)？(y/N) " answer
    case "$answer" in
      y|Y) ;;
      *) echo "已取消，未做任何提交。"; exit 0 ;;
    esac
  fi
  git commit -m "release: AT Music $VERSION build $BUILD"
fi

git push -u origin main

echo
echo "已推送。GitHub Actions 会自动构建："
echo "  AT-Music-$VERSION-build$BUILD-unsigned.ipa"
echo "Release 默认只在手动触发 workflow 时发布，可在 Actions 页面手动运行并选择发布。"
