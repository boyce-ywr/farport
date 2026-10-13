#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897
export GIT_HTTP_LOW_SPEED_LIMIT=1024 GIT_HTTP_LOW_SPEED_TIME=30
gh auth status >/dev/null 2>&1 || { echo "请先运行 gh auth login --hostname github.com --git-protocol https --web 并完成浏览器授权。" >&2; exit 1; }
owner=$(gh api user --jq .login)
repository="$owner/farport"
git diff --quiet && git diff --cached --quiet || { echo "工作区有未提交修改，停止发布。" >&2; exit 1; }
git rev-parse --verify HEAD >/dev/null
response=$(mktemp)
trap 'rm -f "$response"' EXIT
if gh api "repos/$repository" >"$response" 2>&1; then
  privacy=$(gh repo view "$repository" --json isPrivate --jq .isPrivate)
  [ "$privacy" = "true" ] || { echo "已有同名仓库不是私有仓库，拒绝上传。" >&2; exit 1; }
else
  if ! rg -q 'HTTP 404' "$response"; then cat "$response" >&2; exit 1; fi
  gh repo create "$repository" --private --description '栖远 Farport：macOS SSH、tmux 与多主机文件工作台'
fi
[ "$(gh repo view "$repository" --json isPrivate --jq .isPrivate)" = "true" ] || exit 1
remote="https://github.com/$repository.git"
if git remote get-url origin >/dev/null 2>&1; then
  [ "$(git remote get-url origin)" = "$remote" ] || { echo "origin 与当前账号仓库不一致，停止推送。" >&2; exit 1; }
else
  git remote add origin "$remote"
fi
git -c http.proxy=http://127.0.0.1:7897 -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin HEAD:main
local_commit=$(git rev-parse HEAD)
remote_commit=$(gh api "repos/$repository/commits/main" --jq .sha)
[ "$local_commit" = "$remote_commit" ] || { echo "远端提交验证失败。" >&2; exit 1; }
gh repo view "$repository" --json nameWithOwner,isPrivate,defaultBranchRef
printf '\n私有仓库提交已验证：%s\n' "$local_commit"
