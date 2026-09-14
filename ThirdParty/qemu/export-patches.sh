#!/bin/bash
# 把 src/qemu-<版本>/ 里对 QEMU 的改动导出成 patches/*.patch。
#
# 为什么要有这个脚本:src/ 整个不进 git(1.1G),而 app 依赖的显示后端
# ui/macos.c 就在那里面。曾经只有它一份,仓库 clone 下来根本构建不出能用的 QEMU。
# 现在 patches/ 才是唯一真相:改完源码树就跑一次这个脚本,再把 patches/ 提交。
#
# 分组:每个补丁对应一组文件。源码树里改了但不在任何组里的文件会让脚本报错,
# 免得又有改动漏在 git 之外。
#
# 只用 macOS 自带的 bash 3.2 能跑的语法(没有关联数组)。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
QEMU_VER=10.0.2
SRC="$ROOT/src/qemu-$QEMU_VER"
TARBALL="$ROOT/src/qemu.tar.xz"
OUT="$ROOT/patches"

[ -d "$SRC" ] || { echo "没有源码树 $SRC"; exit 1; }
[ -f "$TARBALL" ] || { echo "没有原始 tarball $TARBALL"; exit 1; }

# 补丁顺序即应用顺序
GROUPS_ORDER="0001-macos-display-backend 0002-hvf-pmu-migration 0003-virtio-gpu-ctrl-queue 0004-hvf-pmccntr-fast-path"

group_files() {
  case "$1" in
    # app 真正依赖的:-display macos 后端。共享 mmap 帧缓冲 + Unix socket 事件通道。
    0001-macos-display-backend)      echo "ui/macos.c ui/meson.build qapi/ui.json" ;;
    # hvf 下 PMU 状态不进快照,Windows 从挂起恢复后关不了机。见 machine.c 里 vmstate_pmu_hvf 的注释。
    0002-hvf-pmu-migration)          echo "target/arm/machine.c" ;;
    # 2D virtio-gpu 控制队列 64 → 256。viogpudo 挂 5K 帧缓冲的内存要 59 个描述符,64 塞不下。见 docs/DISPLAY.md。
    0003-virtio-gpu-ctrl-queue)      echo "hw/display/virtio-gpu-base.c" ;;
    # Windows 每秒几十万次读 PMCCNTR,不拿 BQL 处理;外加 VIRTUALLY_HVF_STATS 退出统计。见 docs/PERFORMANCE.md。
    0004-hvf-pmccntr-fast-path)      echo "target/arm/hvf/hvf.c target/arm/helper.c target/arm/internals.h" ;;
    *) echo "" ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "==> 解压原始 tarball 作对照"
tar xf "$TARBALL" -C "$TMP"
ORIG="$TMP/qemu-$QEMU_VER"

echo "==> 比对"
changed=$(cd "$TMP" && diff -rq "qemu-$QEMU_VER" "$SRC" 2>/dev/null \
  | grep -v -E "/(build|\.cache|subprojects|python|roms)(/|:)" \
  | grep -v -E "\.DS_Store|\.wraplock" \
  | grep -v "^Only in qemu-" \
  | sed -E -e "s#^Files qemu-$QEMU_VER/(.*) and .* differ\$#\1#" \
           -e "s#^Only in $SRC/?([^:]*): (.*)\$#\1/\2#" -e "s#^/##" \
  | sort) || true

all_covered=" "
for g in $GROUPS_ORDER; do all_covered="$all_covered$(group_files "$g") "; done
missing=0
for f in $changed; do
  case "$all_covered" in
    *" $f "*) ;;
    *) echo "!! $f 改动了,但不属于任何补丁分组 —— 请把它加进 export-patches.sh 的 group_files"; missing=1 ;;
  esac
done
[ "$missing" = 0 ] || exit 1

mkdir -p "$OUT"
for g in $GROUPS_ORDER; do
  out="$OUT/$g.patch"
  : > "$out"
  for f in $(group_files "$g"); do
    if [ -f "$ORIG/$f" ]; then
      (cd "$TMP" && diff -u "qemu-$QEMU_VER/$f" "$SRC/$f" \
        | sed -E -e "1s#^--- qemu-$QEMU_VER/#--- a/#" -e "2s#^\+\+\+ .*/qemu-$QEMU_VER/#+++ b/#" >> "$out") || true
    else
      (cd "$SRC" && diff -u /dev/null "$f" \
        | sed -E -e "2s#^\+\+\+ #+++ b/#" >> "$out") || true
    fi
  done
  echo "    $g.patch  ($(grep -c '^+++ ' "$out") 个文件)"
done
echo "已导出到 $OUT/。记得提交。"
