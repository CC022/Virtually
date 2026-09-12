# build-deps.sh 与 build.sh 共用的编译环境。source 它,不要直接执行。
#
# **第三方库必须用与部署目标同一代的 SDK 编译。**
# glib 的 meson 用「能不能链接上」判断函数是否存在,不看头文件里的可用性标注。
# Xcode 27 的 SDK 里有 pipe2 / dup3(标注 macOS 27 起可用),于是 glib 以为有、直接调用,
# 在 macOS 26 上它们是空的弱符号 —— qemu-img 一启动就在 g_unix_open_pipe 里跳到地址 0(实测)。
# QEMU 自己的 CONFIG_DUP3 也是同样的探测方式。
#
# 所以部署目标定 26.0,SDK 取 macOS 26 的那份(Command Line Tools 里通常带着)。
# 找不到就停下来说清楚,而不是悄悄编出一个在本机上崩的 QEMU。

VIRTUALLY_DEPLOYMENT_TARGET=26.0

find_sdk() {
    local major="${VIRTUALLY_DEPLOYMENT_TARGET%%.*}" dir sdk
    for dir in "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs" \
               /Library/Developer/CommandLineTools/SDKs; do
        for sdk in "$dir"/MacOSX"$major".*.sdk "$dir"/MacOSX"$major".sdk; do
            [ -d "$sdk" ] && { echo "$sdk"; return 0; }
        done
    done
    return 1
}

if ! SDKROOT="$(find_sdk)"; then
    echo "!! 找不到 macOS ${VIRTUALLY_DEPLOYMENT_TARGET%%.*} 的 SDK。"
    echo "   用更新的 SDK 编出来的 glib 会调用本机不存在的函数,QEMU 启动即崩。"
    echo "   装一份对应版本的 Command Line Tools(提供 MacOSX${VIRTUALLY_DEPLOYMENT_TARGET%%.*}.sdk)后重试。"
    exit 1
fi
export SDKROOT
export MACOSX_DEPLOYMENT_TARGET="$VIRTUALLY_DEPLOYMENT_TARGET"
echo "    SDK: $SDKROOT(部署目标 $MACOSX_DEPLOYMENT_TARGET)"
