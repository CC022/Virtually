# 构建与测试

## 工程结构

| 目录 | Xcode target | 是什么 |
|---|---|---|
| `Virtually/` | Virtually(app) | SwiftUI 界面、应用状态、调试控制通道 |
| `VirtuallyKit/` | VirtuallyKit(静态 framework) | 引擎:会话、QMP 与 agent 通道、显示、安装、USB、传文件 |
| `VirtuallyCLI/` | VirtuallyCLI(命令行工具 `virtually`) | 资源库操作与调试驱动,与 app 共用 VirtuallyKit |
| `VirtuallyKitTests/` | VirtuallyKitTests | Swift Testing 单元测试 |
| `GuestAgent/` | 拷进 app 的 Resources | Windows 与 Linux 的 guest agent |
| `ThirdParty/qemu/` | 由 app 的构建阶段嵌入 | QEMU 与依赖的构建脚本、补丁 |
| `Scripts/` | | `embed-qemu.sh`(构建阶段)、`ctl.sh`(调试快捷方式) |

Swift 语言模式 5,默认隔离为 nonisolated:会话与界面显式标 `@MainActor`,通道类跑自己的线程。
VirtuallyKit 里 app 与命令行工具要用的声明都是 `public`。

## 第一次构建

QEMU 不进 git,先在本机编出来(约 10 分钟,不装 Homebrew,依赖全部源码编译进 `ThirdParty/qemu/sysroot`):

```
ThirdParty/qemu/build-deps.sh     # pkgconf、glib、pixman、libusb
ThirdParty/qemu/build.sh          # QEMU,打上 patches/ 下的补丁
ThirdParty/virtio-win/fetch.sh    # Windows 客户机的 virtio 驱动(下载 837MB 的官方 ISO,抽出约 4MB)
```

源码包放在 `ThirdParty/qemu/src/`,virtio-win ISO 放在 `ThirdParty/virtio-win/src/`,已经在的就不再下载。
virtio 驱动是 Windows 内核驱动,要 WDK 编译加微软签名,macOS 上做不了,所以用官方发布的已签名二进制,
版本与 SHA256 固定在 `fetch.sh` 里。

**SDK 必须与部署目标同代**:`env.sh` 固定用 macOS 26 的 SDK 编第三方库。
用更新的 SDK 编出来的 glib 会调用本机不存在的 `pipe2`,QEMU 一启动就崩。

**签名**:仓库里不带 Team ID,默认 ad-hoc 签名,本机构建运行不需要开发者账号。
要用自己的账号签名,新建 `Config/Local.xcconfig`(不进 git),写上
`DEVELOPMENT_TEAM = <Team ID>` 与 `CODE_SIGN_IDENTITY = Apple Development`,详见 `Config/Project.xcconfig`。

之后用 Xcode 打开 `Virtually.xcodeproj`,⌘R 运行、⌘U 测试。命令行:

```
xcodebuild -scheme Virtually build
xcodebuild -scheme Virtually test
```

app 的「Embed QEMU」构建阶段把 QEMU、它的 dylib、固件嵌进 `Virtually.app`,依赖改成 `@rpath`,
逐个签名(QEMU 带 Hardened Runtime 与 `ThirdParty/qemu/qemu.entitlements`)。产物是自包含的。

**构建产物不要放进仓库目录**。仓库在「文稿」里,从命令行跑测试时 testmanagerd 拉起的进程
读不到这里的测试 bundle(macOS 隐私保护),报「couldn’t be loaded because its executable couldn’t be located」。
用默认的 DerivedData 就没事。挂真实 ISO 的测试同理,默认跳过,`VIRTUALLY_ISO_TESTS=1` 时才跑。

改了 `ThirdParty/qemu/src/` 里的 QEMU 源码,跑 `ThirdParty/qemu/export-patches.sh` 重新导出补丁再提交。

## 命令行工具

`virtually` 与 `Virtually.app` 在同一个构建目录里,`Scripts/ctl.sh` 会先找到它(没有就构建)再转发参数。

```
Scripts/ctl.sh list
Scripts/ctl.sh install Ubuntu --os ubuntu --iso ~/Downloads/ubuntu-26.04.1-desktop-arm64.iso
Scripts/ctl.sh install "Windows 11" --iso ~/Downloads/Win11_Arm64.iso
Scripts/ctl.sh run --vm "$HOME/Library/Application Support/Virtually/VMs/Ubuntu.vmbundle"
Scripts/ctl.sh send state
Scripts/ctl.sh shot /tmp/screen.png
Scripts/ctl.sh stop
```

- `run` 以调试模式拉起 app:输出写进 `/tmp/virtually.log`,控制通道在 `/tmp/virtually-control.sock`,
  这台虚拟机用固定的通道路径。调试参数(`--tools`、`--ramfb` 等)以 `-键 值` 的形式传给 app,见 `DebugLaunch`。
- `send` 把一行命令送进 app,再打印之后几秒的新日志(`--wait` 调整)。命令集见 `Virtually/Control/ControlServer.swift`。
- `stop` 走 ⌘Q 那条路:先挂起再退出,最多等 3 分钟。
- 更新 Windows agent:`virtually build-tools` 重建工具盘,再 `run --vm <包> --tools` 开一次机。

## 并发模型

- `AppState`、`VMSession`、所有 View 与 `WindowCloseWatcher` 都是 `@MainActor`。会话状态只在主 actor 上改。
- `QMPClient`、`AgentChannel`、`DisplayChannel` 各自有读线程,靠锁与非阻塞 fd 自管线程安全,
  标 `@unchecked Sendable`;它们的回调声明成 `@Sendable`,接收方必须 `Task { @MainActor in … }` 跳回来。
- `QMPClient` 对外只有 async 接口(`execute` / `hmp` / `saveSnapshot` …),回复在读线程上到达,
  `await` 的一方自动跳回自己的 actor。挂起、存快照、恢复这些流程因此是主 actor 上的线性 async 代码。
- 长任务(打盘、hdiutil、解析 ISO)用 `Task.detached` 放到后台,结果 `await` 回主 actor。
- 定时器闭包里用 `MainActor.assumeIsolated`(Timer 挂在主 run loop 上);延时用 `Task.sleep`。
- 切到 Swift 6 语言模式之前,要先把 `[String: Any]` 这类 QMP 回复换成具体类型。
- 唯一不在主 actor 上碰会话的路径是 SIGTERM 处理:它只读 `ProcessRegistry` 那份带锁的进程快照,
  因为主线程可能正卡着(见 ControlServer 里 `quit` 的注释)。
