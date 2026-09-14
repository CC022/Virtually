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
QEMU_VER=11.1.1
# 官方只发 GPG 签名,本机没有 gpg。这个值是第一次下载时算出来写死的,换版本要一起改
QEMU_SHA256=079ffbff8a7111bbc89022107cbabf3bbfd614d5fc9d7cc675991196aca12482
JOBS=$(sysctl -n hw.ncpu)

# SDK 与部署目标,原因见 env.sh
source "$ROOT/env.sh"

export PATH="$HOME/Library/Python/3.9/bin:$SYSROOT/bin:$PATH"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"

# QEMU 的 mkvenv 在 Python 3.9 上需要 tomli 与 distlib(3.11+ 自带 tomllib 则不需要 tomli)。
# 放进项目自己的目录,configure 时经 PYTHONPATH 给它 —— 原因见下面 configure 那段
PYDEPS="$SRC/pydeps"
USERSITE="$(python3 -c 'import site; print(site.getusersitepackages())')"
for m in tomli distlib; do
    [ -d "$PYDEPS/$m" ] && continue
    mkdir -p "$PYDEPS"
    if [ -d "$USERSITE/$m" ]; then
        cp -R "$USERSITE/$m" "$PYDEPS/"
    else
        /usr/bin/python3 -s -m pip install --quiet --target "$PYDEPS" "$m"
    fi
done

mkdir -p "$SRC" "$BUILD"

# 源码包按版本命名。以前固定叫 qemu.tar.xz,换版本时旧包还在就会解出旧版本的目录
TARBALL="$SRC/qemu-$QEMU_VER.tar.xz"
if [ ! -d "$SRC/qemu-$QEMU_VER" ]; then
    if [ ! -f "$TARBALL" ]; then
        echo "==> 下载 QEMU $QEMU_VER"
        curl -fL --max-time 1200 -o "$TARBALL.part" "https://download.qemu.org/qemu-$QEMU_VER.tar.xz"
        mv "$TARBALL.part" "$TARBALL"
    fi
    actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    if [ "$actual" != "$QEMU_SHA256" ]; then
        echo "!! $TARBALL 的 SHA256 不符:期望 $QEMU_SHA256,实际 $actual。删掉它重新下载"
        exit 1
    fi
    echo "==> 解压 QEMU $QEMU_VER"
    (cd "$SRC" && tar xf "$TARBALL")
fi

# libslirp 是 meson 在 configure 时按 subprojects/slirp.wrap 从 gitlab 克隆的。
# 别的版本的源码树里已经有同一个 revision 的就直接拷,省一次网络下载
SLIRP="$SRC/qemu-$QEMU_VER/subprojects/slirp"
if [ ! -d "$SLIRP" ]; then
    want="$(awk -F' = ' '/^revision/{print $2}' "$SRC/qemu-$QEMU_VER/subprojects/slirp.wrap")"
    for other in "$SRC"/qemu-*/subprojects/slirp; do
        [ -d "$other" ] || continue
        if [ "$(awk -F' = ' '/^revision/{print $2}' "$(dirname "$other")/slirp.wrap")" = "$want" ]; then
            echo "==> 沿用 $other(libslirp $want)"
            cp -R "$other" "$SLIRP"
            break
        fi
    done
fi

# 构建目录是按某一份源码树 configure 的。换了版本还沿用,就会拿旧源码的配置编,
# 所以记下版本,对不上就整个清掉重新 configure
if [ -f "$BUILD/build.ninja" ] && [ "$(cat "$BUILD/.qemu-version" 2>/dev/null)" != "$QEMU_VER" ]; then
    echo "==> 构建目录不是 $QEMU_VER 的,清掉重新 configure"
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
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
    echo "$QEMU_VER" > "$BUILD/.qemu-version"
    # QEMU 11 的 configure 会把源码里的 python/ 以 editable 方式装进 pyvenv。
    # 用户目录里要是装过新 pip(≥ 25.3,去掉了 setup.py develop 的兜底),而系统 Python 3.9
    # 自带的 setuptools 只有 58(没有 PEP 660 的 build_editable),两者凑在一起就装不上
    # (实测:「missing the 'build_editable' hook」)。所以这一步屏蔽用户目录,
    # 让 pyvenv 用系统自带的 pip 21;要用的 meson、pycotap、qemu.qmp 都在源码包的 python/wheels 里,不联网。
    PYTHONNOUSERSITE=1 PYTHONPATH="$PYDEPS" \
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
