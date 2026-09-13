# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Virtually:在 Apple Silicon Mac 上跑 Windows 11 / Ubuntu 的虚拟机 app。引擎是自编译的 QEMU(`-accel hvf`),
SwiftUI 宿主负责显示、输入、安装、快照、USB、传文件。文档、注释、提交信息都用中文,新写的也保持中文。

## 常用命令

```bash
# 第一次:QEMU 与依赖从源码编进 ThirdParty/qemu/sysroot(约 10 分钟)。没编好 app 就构建不过
ThirdParty/qemu/build-deps.sh
ThirdParty/qemu/build.sh

xcodebuild -scheme Virtually build
xcodebuild -scheme Virtually test
# 单个测试(Swift Testing:目标/结构体名/函数名())
xcodebuild -scheme Virtually test -only-testing:'VirtuallyKitTests/SessionTests/stateMachine()'
# 挂真实 ISO 的测试默认跳过
VIRTUALLY_ISO_TESTS=1 xcodebuild -scheme Virtually test

# 调试驱动(找到构建目录里的 virtually 命令行工具再转发;BUILD=1 强制先构建)
Scripts/ctl.sh run --vm "$HOME/Library/Application Support/Virtually/VMs/Ubuntu.vmbundle"
Scripts/ctl.sh send state        # 一行命令送进 app,打印之后几秒的日志
Scripts/ctl.sh shot /tmp/s.png   # 从共享帧缓冲截图
Scripts/ctl.sh stop              # 先挂起再退出
```

- **构建产物不要放进仓库目录**(不要传 `-derivedDataPath ./build` 之类)。仓库在「文稿」里,
  testmanagerd 读不到那里的测试 bundle。用默认 DerivedData。
- 测试 action 会顺带构建 `Virtually.app`,所以跑测试同样需要 QEMU 已经编好。
- 签名身份不进仓库:`Config/Project.xcconfig` 默认 ad-hoc,本机的 Team ID 写在被忽略的 `Config/Local.xcconfig`。不要把 `DEVELOPMENT_TEAM` 写回 `project.pbxproj`。
- `env.sh` 把第三方库固定用 macOS 26 SDK 编:更新的 SDK 编出的 glib 会调用本机没有的 `pipe2`,QEMU 启动即崩。
- 改了 `ThirdParty/qemu/src/qemu-10.0.2/` 里的源码,必须跑 `ThirdParty/qemu/export-patches.sh` 再提交 `patches/`。
  `src/` 不进 git,`patches/` 是唯一真相;新改的文件要先加进脚本里的 `group_files`。
- 工程用 file-system-synchronized groups:在 `Virtually/`、`VirtuallyKit/`、`VirtuallyCLI/`、`VirtuallyKitTests/`
  下新建 Swift 文件会自动进对应 target,不用改 `project.pbxproj`。
- 调试命令集在 `Virtually/Control/ControlServer.swift`;`virtually help` 列出命令行工具的全部命令。

## 架构

### 四个 target

- `VirtuallyKit`(静态 framework):全部引擎代码。app 与命令行工具要用的声明必须 `public`。
- `Virtually`(app):SwiftUI 界面、`AppState`(资源库 + 按包路径索引的会话)、调试控制通道。
- `VirtuallyCLI`(产物名 `virtually`):离线操作资源库(list / create / install / build-tools),
  以及驱动 app(run / send / shot / stop)。它先找到 `Virtually.app`,再用其 bundle 定位 QEMU。
- `VirtuallyKitTests`:Swift Testing。断言用 `TestSupport.swift` 的 `expect(条件, "为什么")`,
  QEMU 参数类测试从 `Fixture` 取样例。

「Embed QEMU」构建阶段(`Scripts/embed-qemu.sh`)把 QEMU、dylib、固件拷进 app,依赖改写成 `@rpath` 并逐个签名;
`GuestAgent/` 整个目录作为资源拷进 app。位置约定见 `ToolPaths`。

### 一台虚拟机运行时的样子

`VMSession`(`@MainActor`,一台虚拟机一个实例)用 `QemuCommand` 生成参数,把 QEMU 作为子进程拉起,之后经四条通道与它交互:

| 通道 | 类 | 用途 |
|---|---|---|
| 共享 mmap 帧缓冲 | `Framebuffer` | `MTLBuffer(bytesNoCopy:)` 零拷贝成 Metal 纹理,`GuestView` 用 CADisplayLink 呈现 |
| 显示 socket | `DisplayChannel` | 自定义 `-display macos` 后端(`patches/0001` 里的 `ui/macos.c`)的 20 字节定长消息:resize/damage/光标 ↔ 键鼠 |
| QMP socket | `QMPClient` | 快照、USB、网络、传输盘热插拔;对外只有 async 接口 |
| agent socket | `AgentChannel` | virtio-serial 端口 `org.virtually.agent` 上的文本协议:改分辨率、剪贴板、校时、光标 |

通道路径带 pid(`SessionPaths.next()`);`virtually run` 起的调试实例用固定的 `/tmp/virtually-*`(`SessionPaths.debug`),
日志在 `/tmp/virtually.log`,控制通道 `/tmp/virtually-control.sock`,QEMU 日志 `/tmp/virtually-qemu*.log`。

### 需要跨文件理解的约定

- **状态只看 `VMSession.State`**(idle → starting → restoring/running → suspending/shuttingDown → stopped)。
  能否操作用 `acceptsCommands` / `isEnding` / `blockedReason`,不要另加布尔去拼。分辨率那组字段是一个状态机,不要拆开。详见 `docs/LIFECYCLE.md`。
- **红叉 = 挂起**:存成内部快照 `__suspend__`,下次用 `-S` + QMP `loadvm` 恢复。开机前比对
  `QemuCommand.migrationFingerprint()`,设备配置变了就丢弃状态冷启动。改动设备参数时想清楚是否要进指纹、
  是否要升 `fingerprintVersion`;`-S` 不能进指纹。存快照/挂起前必须先拔 USB。
- **QEMU 参数顺序有语义**:系统盘 `-drive` 必须排在 pflash 之前(内存状态写进第一个可快照的盘),bootindex 在安装期与平时不同。
  `QemuCommandTests` 对这些有断言。
- **按系统分支**:`GuestOS` 决定安装期显示设备(Windows 用 ramfb)、系统盘控制器(Windows 安装期 nvme)和 `-rtc base=`
  (Windows `localtime`、Linux `utc`,给错时钟整体偏一个时区)。
- **guest agent 两份实现一份协议**:`GuestAgent/windows/agent.ps1`(PowerShell 5.1,需 UTF-8 BOM;`.bat` 必须纯 ASCII)
  与 `GuestAgent/linux/virtually-agent.py`,都是 system + session 两段式。改协议时两边与 `AgentChannel` 一起改,并更新 `docs/GUEST-AGENT.md` 的协议段。
- **安装**:Windows 走 `UnattendGenerator` 生成 `autounattend.xml` + `SupportImageBuilder` 打 FAT32 盘;Ubuntu 走 `AutoinstallGenerator` 的 cloud-init CIDATA 盘。
  「装完」的信号是 agent 首次上线。
- **并发**:Swift 5 语言模式,默认 nonisolated。会话、`AppState`、View 显式 `@MainActor`;
  `QMPClient` / `AgentChannel` / `DisplayChannel` 自带读线程、标 `@unchecked Sendable`,回调 `@Sendable`,
  接收方 `Task { @MainActor in … }` 跳回。写 agent socket 是非阻塞的,写不进就丢(guest 没开端口时阻塞写会卡死整个 app)。
  唯一不经主 actor 碰进程的是 SIGTERM 处理,只读 `ProcessRegistry` 的带锁快照。
- **不能留孤儿 QEMU**:它会一直攥着 qcow2 写锁。退出(含信号)要把 QEMU 带走;开机前先查 `QEMUProcesses` 有没有别的进程占着这个包。

## 项目约束

- 引擎是 QEMU + Hypervisor.framework,**不要建议换成 Virtualization.framework**:实测 VZ 引导不了 Windows。
- 鼠标跟手是首要体验指标。显示/输入路径的改动先确认没有增加延迟、拷贝或编解码环节。
- 不装 Homebrew。第三方依赖源码构建进 `ThirdParty/qemu/sysroot`;需要下载任何东西先说明名称、版本、来源、用途。
- `docs/` 下每篇记的是实测结论和踩过的坑(GUEST-AGENT、LIFECYCLE、SNAPSHOTS、USB、TRANSFER、LINUX、INSTALL-WIZARD、DISK)。
  改某个子系统前先读对应那篇,很多看似可以简化的写法是被实测否掉的。需要人肉眼确认的项记在 `docs/PENDING-VERIFICATION.md`。
