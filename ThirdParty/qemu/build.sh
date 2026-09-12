#!/bin/bash
# 构建 QEMU(仅 aarch64-softmmu)到项目内 sysroot。
# 先跑 ./build-deps.sh 准备依赖。
#
# 为什么要自编译而不用 UTM 内置的那份:
#   1. 我们要注入自己的 UI 后端(ui/macos.c),把 DisplaySurface 直接送进 IOSurface
#   2. UTM 那份缺 libpng(screendump 只能出 PPM)、无 cocoa 后端、
#      egl-headless 出了它的 app 上下文就初始化失败
#   3. 版本与设备开关需要我们自己掌控
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SYSROOT="$ROOT/sysroot"
SRC="$ROOT/src"
BUILD="$ROOT/build"
QEMU_VER=10.0.2
JOBS=$(sysctl -n hw.ncpu)

# SDK 与部署目标,原因见 env.sh
source "$ROOT/env.sh"

export PATH="$HOME/Library/Python/3.9/bin:$SYSROOT/bin:$PATH"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"

# QEMU 的 mkvenv 在 Python 3.9 上需要这几个包(3.11+ 自带 tomllib 则不需要 tomli)
python3 -c "import distlib" 2>/dev/null || pip3 install --user --quiet distlib
python3 -c "import tomli" 2>/dev/null || pip3 install --user --quiet tomli

mkdir -p "$SRC" "$BUILD"

if [ ! -d "$SRC/qemu-$QEMU_VER" ]; then
    [ -f "$SRC/qemu.tar.xz" ] || curl -fsSL --max-time 900 \
        -o "$SRC/qemu.tar.xz" "https://download.qemu.org/qemu-$QEMU_VER.tar.xz"
    echo "==> 解压 QEMU $QEMU_VER"
    (cd "$SRC" && tar xf qemu.tar.xz)
fi

# 应用我们的补丁。patches/ 是唯一真相:app 依赖的 ui/macos.c 整个后端就在
# 0001 里,源码树本身不进 git。改了源码树要跑 ./export-patches.sh 重新导出。
#
# 已经打过的补丁跳过(用反向 dry-run 判断),没打过的必须干净地打上 ——
# 以前这里是 `|| true`,补丁失败会被静默吞掉,构建出一个缺后端的 QEMU。
if [ -d "$ROOT/patches" ] && ls "$ROOT/patches"/*.patch >/dev/null 2>&1; then
    echo "==> 应用补丁"
    for p in "$ROOT/patches"/*.patch; do
        name="$(basename "$p")"
        if (cd "$SRC/qemu-$QEMU_VER" && patch -p1 -R --dry-run -s < "$p" >/dev/null 2>&1); then
            echo "    $name 已应用,跳过"
        elif (cd "$SRC/qemu-$QEMU_VER" && patch -p1 -N -s < "$p"); then
            echo "    $name 已打上"
        else
            echo "!! $name 打不上。源码树可能被手改过与补丁冲突;"
            echo "   若源码树才是新的,先跑 ./export-patches.sh;否则删掉 src/qemu-$QEMU_VER 重来。"
            exit 1
        fi
    done
fi

# --disable-pvg:apple-gfx 设备(ParavirtualizedGraphics)我们不用 —— 显示走 virtio-gpu。
# 而且在 Xcode 27 的 SDK 上它链接不过(PGNewDeviceWithDescriptor 找不到符号)。
#
# 已经 configure 过就跳过 —— 但这会掩盖一个坑:事后往 sysroot 里加了新依赖
# (比如 libusb),重跑本脚本不会重新 configure,新依赖静默地不会被启用。
# 实测踩过一次:libusb 装好了、build.sh 跑完了、`-device help` 里依然没有 usb-host。
# 所以这里显式检查一遍已 configure 的结果与当前 sysroot 是否一致。
# 判据用 build.ninja 里有没有 host-libusb.c 的编译规则 —— 那是 usb-host 的唯一实现,
# 启用了就一定在,比解析 meson 的 JSON 简单可靠。
if [ -f "$BUILD/build.ninja" ] && [ -f "$SYSROOT/lib/pkgconfig/libusb-1.0.pc" ] \
   && ! grep -q "host-libusb" "$BUILD/build.ninja"; then
    echo "==> sysroot 里有 libusb 但当前构建没启用,重新 configure"
    RECONFIGURE=1
fi

if [ ! -f "$BUILD/build.ninja" ] || [ "${RECONFIGURE:-0}" = "1" ]; then
    echo "==> configure"
    cd "$BUILD"
    # 已存在的构建目录要带 --reconfigure,否则 meson 会拒绝
    [ -f "$BUILD/build.ninja" ] && export QEMU_CONFIGURE_EXTRA="--reconfigure"
    "$SRC/qemu-$QEMU_VER/configure" \
        --target-list=aarch64-softmmu \
        --prefix="$SYSROOT" \
        --enable-hvf \
        --enable-slirp \
    $([ -f "$SYSROOT/lib/pkgconfig/libusb-1.0.pc" ] && echo --enable-libusb) \
        --enable-vmnet \
        --enable-coreaudio \
        --enable-cocoa \
        --disable-pvg \
        --disable-gtk --disable-sdl --disable-spice --disable-vnc \
        --disable-docs --disable-guest-agent
fi

echo "==> 编译 (-j$JOBS)"
ninja -C "$BUILD" -j"$JOBS"

# macOS 上 QEMU 产出的是 -unsigned 二进制,必须签上 hypervisor entitlement 才能用 HVF。
# 注意:本地开发**不要**加 -o runtime —— 强化运行时会启用库验证,
# 拒绝加载 Team ID 不一致的 libslirp 等 dylib。
# 正式分发时所有 dylib 用同一 Developer ID 签名即可满足验证。
if [ -f "$BUILD/qemu-system-aarch64-unsigned" ]; then
    echo "==> 签名 (hypervisor entitlement)"
    cp -f "$BUILD/qemu-system-aarch64-unsigned" "$BUILD/qemu-system-aarch64"
    codesign --force --sign - \
        --entitlements "$SRC/qemu-$QEMU_VER/accel/hvf/entitlements.plist" \
        "$BUILD/qemu-system-aarch64"
fi

# 编出来能不能跑。SDK 选错时 qemu-img 一启动就崩,早点在这里拦住。
for bin in qemu-img qemu-system-aarch64; do
    "$BUILD/$bin" --version >/dev/null || { echo "!! $bin 无法运行(SDK 与部署目标见 env.sh)"; exit 1; }
done

echo
echo "产物:"
ls -lh "$BUILD/qemu-system-aarch64" 2>/dev/null || ls -lh "$BUILD"/qemu-system-* 2>/dev/null
echo "固件: $BUILD/pc-bios/"
