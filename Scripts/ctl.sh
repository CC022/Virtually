#!/bin/bash
# 调试时的快捷方式:构建并调用 virtually 命令行工具。
#   Scripts/ctl.sh run --vm <包>
#   Scripts/ctl.sh send <命令>
# BUILD=1 强制先构建一次。
#
# 构建产物放默认的 DerivedData,不要放进仓库:仓库在「文稿」里,
# 从命令行跑测试时 testmanagerd 拉起的进程读不到那里的测试 bundle(macOS 的隐私保护)。
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCTS="$(xcodebuild -scheme Virtually -configuration Debug -showBuildSettings 2>/dev/null \
            | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
CLI="$PRODUCTS/virtually"
if [ ! -x "$CLI" ] || [ "${BUILD:-0}" = "1" ]; then
    xcodebuild -scheme Virtually -configuration Debug -quiet build >&2
fi
exec "$CLI" "$@"
