#!/bin/zsh
# 构建 roothide 正式包，成功后通过 ssh 15 安装并重启 SpringBoard。
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SSH_TARGET=15
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10)
STAMP_FILE="$(mktemp)"
REMOTE_DEB=""

cleanup() {
  rm -f "$STAMP_FILE"
  if [[ -n "$REMOTE_DEB" ]]; then
    ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "rm -f '$REMOTE_DEB'" </dev/null || true
  fi
}
trap cleanup EXIT

rm -rf .theos packages

# 复用统一构建流程：3 = roothide，1 = 正式包。
"${ROOT_DIR}/build.sh" <<'BUILD_OPTIONS'
3
1
BUILD_OPTIONS

# 只选择本次构建产生的 roothide 包，避免安装残留旧包。
packages=()
for deb in "${ROOT_DIR}"/packages/*_iphoneos-arm64e.deb(N); do
  [[ "$deb" -nt "$STAMP_FILE" ]] && packages+=("$deb")
done
if (( ${#packages[@]} != 1 )); then
  print -u2 "未找到唯一的本次 roothide 构建产物，停止安装。"
  exit 1
fi
DEB="${packages[1]}"

print "\n==> 上传并安装到 ssh ${SSH_TARGET}: ${DEB:t}"
remote_path="$(ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" \
  'set -e; test "$(id -u)" = 0; test "$(dpkg --print-architecture)" = iphoneos-arm64e; mktemp /tmp/ios-mcp.XXXXXX')"
if [[ ! "$remote_path" =~ '^/tmp/ios-mcp\.[[:alnum:]]+$' ]]; then
  print -u2 "设备返回了无效的临时文件路径，停止安装。"
  exit 1
fi
REMOTE_DEB="$remote_path"
ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "cat > '$REMOTE_DEB'" < "$DEB"
ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "dpkg -i '$REMOTE_DEB'" </dev/null
ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "rm -f '$REMOTE_DEB'" </dev/null
REMOTE_DEB=""
print "==> 安装成功，重启 SpringBoard..."
ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" 'killall SpringBoard' </dev/null
print "编译并安装完成。"


cp "$DEB" "$HOME/Documents/GitHub/myTweaks/roothide"