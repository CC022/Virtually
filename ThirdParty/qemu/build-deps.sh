#!/bin/bash
# 从源码构建 QEMU 的依赖到 ThirdParty/qemu/sysroot。
#
# 为什么不用 Homebrew:本项目明确不引入系统级包管理器。
# 这里只用 macOS 自带的 clang/make/curl/git + pip 装的 meson/ninja,
# 其余依赖全部源码编译进 sysroot,不污染系统。
#
# 依赖链:pkgconf(pkg-config 替代,无 glib 依赖) → glib → pixman
#         libusb(USB 真设备透传 `usb-host` 需要)
# libffi / zlib / iconv 直接用 macOS SDK 自带的。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SYSROOT="$ROOT/sysroot"
SRC="$ROOT/src"
JOBS=$(sysctl -n hw.ncpu)

# SDK 与部署目标,原因见 env.sh
source "$ROOT/env.sh"

PKGCONF_VER=2.3.0
GLIB_VER=2.82.5
GLIB_SERIES=2.82
PIXMAN_VER=0.44.2
LIBUSB_VER=1.0.27

mkdir -p "$SYSROOT" "$SRC"

# pip 装的 meson/ninja 不在默认 PATH 上
PYBIN="$HOME/Library/Python/3.9/bin"
export PATH="$PYBIN:$SYSROOT/bin:$PATH"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少 $1"; exit 1; }; }

bootstrap_tools() {
    if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
        echo "==> 安装 meson / ninja (pip --user)"
        pip3 install --user --quiet meson ninja
    fi
    need meson; need ninja; need clang; need curl
    echo "    meson $(meson --version) / ninja $(ninja --version)"
}

fetch() {  # fetch <url> <输出文件名>
    [ -f "$SRC/$2" ] && { echo "    已有 $2"; return; }
    echo "    下载 $2"
    curl -fsSL --max-time 900 -o "$SRC/$2" "$1"
}

build_pkgconf() {
    [ -x "$SYSROOT/bin/pkgconf" ] && { echo "==> pkgconf 已就绪"; return; }
    echo "==> pkgconf $PKGCONF_VER"
    fetch "https://github.com/pkgconf/pkgconf/archive/refs/tags/pkgconf-$PKGCONF_VER.tar.gz" pkgconf.tar.gz
    cd "$SRC" && tar xzf pkgconf.tar.gz
    cd "pkgconf-pkgconf-$PKGCONF_VER"
    meson setup build --prefix="$SYSROOT" --buildtype=release -Dtests=disabled
    ninja -C build -j"$JOBS" install
    # meson 找的是 pkg-config 这个名字
    ln -sf "$SYSROOT/bin/pkgconf" "$SYSROOT/bin/pkg-config"
}

build_glib() {
    pkg-config --exists glib-2.0 2>/dev/null && { echo "==> glib 已就绪 ($(pkg-config --modversion glib-2.0))"; return; }
    echo "==> glib $GLIB_VER"
    fetch "https://download.gnome.org/sources/glib/$GLIB_SERIES/glib-$GLIB_VER.tar.xz" glib.tar.xz
    cd "$SRC" && tar xf glib.tar.xz
    cd "glib-$GLIB_VER"
    # nls=disabled 避免引入 gettext;wrap-mode=default 让 glib 自行拉取 pcre2 等子项目
    meson setup build --prefix="$SYSROOT" --buildtype=release --default-library=shared \
        -Dnls=disabled -Dtests=false -Dintrospection=disabled -Dman-pages=disabled \
        -Dglib_debug=disabled --wrap-mode=default
    ninja -C build -j"$JOBS" install
}

build_pixman() {
    pkg-config --exists pixman-1 2>/dev/null && { echo "==> pixman 已就绪 ($(pkg-config --modversion pixman-1))"; return; }
    echo "==> pixman $PIXMAN_VER"
    fetch "https://www.cairographics.org/releases/pixman-$PIXMAN_VER.tar.gz" pixman.tar.gz
    cd "$SRC" && tar xzf pixman.tar.gz
    cd "pixman-$PIXMAN_VER"
    meson setup build --prefix="$SYSROOT" --buildtype=release \
        -Dtests=disabled -Ddemos=disabled -Dgtk=disabled
    ninja -C build -j"$JOBS" install
}

# libusb 是 QEMU 的 `usb-host` 设备的唯一实现路径 —— 没有它,
# `-device usb-host` 根本不会被编译进去(实测 `-device help` 里查无此项)。
# USB 大容量存储走的是另一条路(usb-storage + 磁盘镜像),不需要 libusb。
build_libusb() {
    pkg-config --exists libusb-1.0 2>/dev/null && { echo "==> libusb 已就绪 ($(pkg-config --modversion libusb-1.0))"; return; }
    echo "==> libusb $LIBUSB_VER"
    fetch "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VER/libusb-$LIBUSB_VER.tar.bz2" libusb.tar.bz2
    cd "$SRC" && tar xf libusb.tar.bz2
    cd "libusb-$LIBUSB_VER"
    # autotools 是源码树内构建,残留的目标文件带着上一次的前缀
    [ -f Makefile ] && make distclean >/dev/null
    ./configure --prefix="$SYSROOT" --disable-udev
    make -j"$JOBS" install
}

bootstrap_tools
build_pkgconf
build_glib
build_pixman
build_libusb

echo
echo "依赖就绪,sysroot = $SYSROOT"
pkg-config --modversion glib-2.0 gio-2.0 pixman-1
