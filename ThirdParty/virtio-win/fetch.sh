#!/bin/bash
# 取 Windows 客户机要装的 virtio 驱动,放进 drivers/,由 app 的构建阶段嵌进 Virtually.app。
#
# 为什么打包进 app:以前要用户自己下 virtio-win.iso(837MB)再在向导里选,
# 没有它装出来的 Windows 黑屏、没网、agent 连不上。现在驱动随工具盘挂进 guest,用户什么都不用准备。
#
# 为什么是下载而不是源码构建:Windows 内核驱动要 WDK 编译、还要微软签名,在 macOS 上做不了。
# 用的是 virtio-win 官方发布的已签名二进制;驱动本身是 BSD 许可(见 virtio-win-pkg-scripts 的
# virtio-win.spec),许可证文本随驱动一起放进 app。
#
# 版本固定。0.1.302 就是实测装过、跑过 5K 显示与关机修复的那版(viogpudo DriverVer 100.103.104.30200)。
# 换版本要重新实测,并更新下面的 SHA256 —— 官方 CHECKSUM 只列了 RPM 的 MD5,没有 ISO 的,
# 这个值是第一次下载时算出来写死的。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VER=0.1.302
URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$VER-1/virtio-win-$VER.iso"
SHA256="303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"
ISO="$ROOT/src/virtio-win-$VER.iso"
OUT="$ROOT/drivers"

# 与 WindowsInstall.swift 里 install-agent.bat 用 pnputil 装的列表一致
DRIVERS="viogpudo NetKVM vioserial viostor vioscsi Balloon viorng vioinput viosock"

mkdir -p "$ROOT/src"
if [ ! -f "$ISO" ]; then
    echo "==> 下载 virtio-win $VER(约 837MB)"
    curl -fL --max-time 3600 -o "$ISO.part" "$URL"
    mv "$ISO.part" "$ISO"
fi

echo "==> 校验"
actual="$(shasum -a 256 "$ISO" | awk '{print $1}')"
if [ "$actual" != "$SHA256" ]; then
    echo "!! SHA256 不符:期望 $SHA256,实际 $actual。删掉 $ISO 重新下载"
    exit 1
fi

echo "==> 抽取 ARM64 驱动"
TMP="$(mktemp -d)"
# ISO 里的文件是只读的,不先加写权限删不掉
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# 整张解开再挑,不按目录挑着解:ISO 里大量文件是硬链接,会跨系统版本、跨架构、甚至跨驱动指过去
# (w11/ARM64 → 2k25/ARM64,NetKVM 的 ARM64/Readme.md → amd64,各驱动的 WdfCoInstaller → fwcfg),
# 挑着解就是一连串「Hard-link target does not exist」
tar -xf "$ISO" -C "$TMP"

[ -d "$OUT" ] && chmod -R u+w "$OUT"
rm -rf "$OUT"
for d in $DRIVERS; do
    src="$TMP/$d/w11/ARM64"
    [ -d "$src" ] || { echo "!! ISO 里没有 $d/w11/ARM64"; exit 1; }
    mkdir -p "$OUT/$d/w11/ARM64"
    # 调试符号(.pdb)几十 MB,guest 里用不上
    find "$src" -maxdepth 1 -type f ! -name '*.pdb' -exec cp {} "$OUT/$d/w11/ARM64/" \;
done
cp "$TMP/virtio-win_license.txt" "$OUT/"
echo "$VER" > "$OUT/VERSION"
chmod -R u+w "$OUT"

echo "已抽取到 $OUT($(du -sh "$OUT" | awk '{print $1}'))"
