#!/bin/bash
# Xcode 构建阶段「Embed QEMU」:把 QEMU 与它依赖的 dylib、Windows 的 virtio 驱动嵌进 Virtually.app,让 app 自包含。
#
#   Contents/MacOS/qemu-system-aarch64、qemu-img
#   Contents/Frameworks/lib*.dylib
#   Contents/Resources/qemu/edk2-aarch64-code.fd、efi-virtio.rom
#   Contents/Resources/VirtioDrivers/<驱动>/w11/ARM64/…、virtio-win_license.txt
#
# 构建树里的 QEMU 按绝对路径链接 ThirdParty/qemu/sysroot/lib 下的 dylib,
# 这里递归收集这些依赖,统统改成 @rpath,再用 Xcode 的签名身份逐个签名。
# QEMU 本体带 Hardened Runtime 与 qemu.entitlements(HVF、USB、录音)。
set -euo pipefail

QEMU_ROOT="$SRCROOT/ThirdParty/qemu"
BUILD="$QEMU_ROOT/build"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
MACOS="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"
FIRMWARE="$APP/Contents/Resources/qemu"

if [ ! -x "$BUILD/qemu-system-aarch64-unsigned" ] || [ ! -x "$BUILD/qemu-img" ]; then
    echo "error: 没有 QEMU 构建产物。先依次运行 ThirdParty/qemu/build-deps.sh 与 ThirdParty/qemu/build.sh"
    exit 1
fi

mkdir -p "$MACOS" "$FRAMEWORKS" "$FIRMWARE"
install -m 0755 "$BUILD/qemu-system-aarch64-unsigned" "$MACOS/qemu-system-aarch64"
install -m 0755 "$BUILD/qemu-img" "$MACOS/qemu-img"
install -m 0644 "$BUILD/pc-bios/edk2-aarch64-code.fd" "$FIRMWARE/edk2-aarch64-code.fd"
# 网卡的 UEFI 驱动 ROM。virtio-net-pci 找不到它 QEMU 直接拒绝启动。
# 构建树里的 QEMU 会自己去 qemu-bundle 里找,嵌进 app 之后只认 -L 给的目录。
ROMS="$(find "$BUILD/qemu-bundle" -type d -path '*/share/qemu' | head -1)"
install -m 0644 "$ROMS/efi-virtio.rom" "$FIRMWARE/efi-virtio.rom"

# 一个 Mach-O 引用的、需要随 app 分发的 dylib:构建树里的绝对路径,或 @rpath(libslirp)
bundled_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            "$QEMU_ROOT"/*) echo "$dep" ;;
            @rpath/*)       echo "$dep" ;;
        esac
    done
}

# @rpath/libslirp.0.dylib 这类引用在构建树里的真实位置
resolve() {
    case "$1" in
        @rpath/*)
            local name="${1#@rpath/}" hit
            hit="$(find "$BUILD/subprojects" "$QEMU_ROOT/sysroot/lib" -name "$name" -not -path '*.p/*' 2>/dev/null | head -1)"
            [ -n "$hit" ] || { echo "error: 找不到 $1" >&2; exit 1; }
            echo "$hit" ;;
        *) echo "$1" ;;
    esac
}

# 把一个 Mach-O 的依赖改写成 @rpath/<文件名>,顺带把依赖本身拷进 Frameworks(递归)
relink() {
    local file="$1" dep src name
    for dep in $(bundled_deps "$file"); do
        name="$(basename "$dep")"
        install_name_tool -change "$dep" "@rpath/$name" "$file" 2>/dev/null
        if [ ! -f "$FRAMEWORKS/$name" ]; then
            src="$(resolve "$dep")"
            cp -L "$src" "$FRAMEWORKS/$name"
            chmod u+w "$FRAMEWORKS/$name"
            install_name_tool -id "@rpath/$name" "$FRAMEWORKS/$name" 2>/dev/null
            relink "$FRAMEWORKS/$name"
        fi
    done
}

# 构建树里的 rpath 全换成 app 内的 Frameworks
reset_rpaths() {
    local file="$1" rp
    for rp in $(otool -l "$file" | awk '/LC_RPATH/{getline; getline; print $2}'); do
        install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null
    done
    install_name_tool -add_rpath "$2" "$file" 2>/dev/null
}

rm -f "$FRAMEWORKS"/lib*.dylib
for exe in "$MACOS/qemu-system-aarch64" "$MACOS/qemu-img"; do
    relink "$exe"
    reset_rpaths "$exe" "@executable_path/../Frameworks"
done

# 自检:不许留下指向构建树的路径,否则删掉 ThirdParty 之后 app 就坏了
for f in "$MACOS/qemu-system-aarch64" "$MACOS/qemu-img" "$FRAMEWORKS"/lib*.dylib; do
    if otool -L "$f" | tail -n +2 | grep -q "$QEMU_ROOT"; then
        echo "error: $f 仍引用构建树里的 dylib"; otool -L "$f"; exit 1
    fi
done

# Windows 客户机的 virtio 驱动(ThirdParty/virtio-win/fetch.sh 从官方 ISO 抽出来的 ARM64 那部分,约 4MB)。
# 装系统时随工具盘挂进 guest,用户不用再自己下 virtio-win.iso。许可证文本一起带上(BSD,再分发要附)。
DRIVERS_SRC="$SRCROOT/ThirdParty/virtio-win/drivers"
DRIVERS_DST="$APP/Contents/Resources/VirtioDrivers"
if [ ! -f "$DRIVERS_SRC/vioserial/w11/ARM64/vioser.inf" ]; then
    echo "error: 没有 virtio 驱动。先运行 ThirdParty/virtio-win/fetch.sh"
    exit 1
fi
rm -rf "$DRIVERS_DST"
ditto "$DRIVERS_SRC" "$DRIVERS_DST"

# 签名。Xcode 给了签名身份就用它 —— 同一 Team ID 才能过 Hardened Runtime 的库验证;
# 没有(ad-hoc)时不开 Hardened Runtime,否则 QEMU 加载不了自己的 dylib。
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$IDENTITY" ] || IDENTITY="-"
RUNTIME=(--options runtime)
[ "$IDENTITY" = "-" ] && RUNTIME=()
for lib in "$FRAMEWORKS"/lib*.dylib; do
    codesign --force --timestamp=none --sign "$IDENTITY" "$lib"
done
# 空数组要写成 ${RUNTIME[@]+"${RUNTIME[@]}"}:macOS 自带的 bash 3.2 在 set -u 下把 "${RUNTIME[@]}" 当未定义变量
codesign --force --timestamp=none --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$MACOS/qemu-img"
codesign --force --timestamp=none --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} \
    --entitlements "$QEMU_ROOT/qemu.entitlements" "$MACOS/qemu-system-aarch64"

echo "已嵌入 QEMU:$(ls "$FRAMEWORKS" | grep -c dylib) 个 dylib;virtio 驱动 $(cat "$DRIVERS_DST/VERSION")"
