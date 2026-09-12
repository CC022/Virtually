# Virtually

在 Apple Silicon 的 Mac 上跑 Windows 11 与 Ubuntu 虚拟机。引擎是自己编译的 QEMU(HVF 加速),
画面经共享内存直接进 Metal 纹理,输入、剪贴板、传文件、USB 透传、快照与挂起都由宿主 app 管。

- 新建虚拟机时全自动安装:Windows 用 `autounattend.xml`,Ubuntu 用 cloud-init autoinstall
- guest agent 负责分辨率跟随、剪贴板、校时,Windows 与 Linux 同一套文本协议

构建、测试与命令行工具见 [docs/BUILD.md](docs/BUILD.md)。各子系统的设计与实测结论在 `docs/` 下:

| 文档 | 内容 |
|---|---|
| [INSTALL-WIZARD.md](docs/INSTALL-WIZARD.md) | Windows 无人值守安装 |
| [LINUX.md](docs/LINUX.md) | Ubuntu 支持 |
| [GUEST-AGENT.md](docs/GUEST-AGENT.md) | guest agent 协议与踩过的坑 |
| [LIFECYCLE.md](docs/LIFECYCLE.md) | 启动、挂起、退出 |
| [SNAPSHOTS.md](docs/SNAPSHOTS.md) | 快照 |
| [USB.md](docs/USB.md) | USB 透传 |
| [TRANSFER.md](docs/TRANSFER.md) | 传文件与剪贴板 |
| [PENDING-VERIFICATION.md](docs/PENDING-VERIFICATION.md) | 待人工验证的项 |
