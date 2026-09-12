# 安装向导:现状

> **两个系统**。这篇讲 Windows 那条路;Ubuntu 的看 `LINUX.md`。
> 向导里有「系统」下拉,选完镜像会认它是哪个系统,与下拉不符就拦住。
> 命令行是 `--os windows|ubuntu`(不给就从镜像认),版本用 `--variant <id>`。


`virtually install <名字> --iso <Windows ARM64 镜像> [--disk GB] [--memory MB]`

## 已跑通

1. **ISO 检查** —— 解析 install.wim 尾部的 UTF-16LE XML 元数据,列出版本并自动选中 Pro。
   **索引必须实测解析,不能硬编码**:该中文 ARM64 ISO 只有 3 个版本(Pro = 3),
   不是常见的 6 个。
2. **建包** —— qcow2 空盘 + 64MB 全 0xff 的 NVRAM。
3. **介质构建** —— 两张 FAT32 盘:
   - `boot.img`(1.5GB):ISO 的引导文件 + `autounattend.xml`
   - `tools.img`(256MB):`agent.ps1` + `install-agent.bat`
4. **无人值守安装** —— 语言、产品密钥、许可协议、TPM/SecureBoot 检查绕过、
   磁盘分区、版本选择全部自动完成,进度走到文件复制阶段并自动重启。

## 三个已解决的坑

### 引导顺序
支持盘、ISO、系统盘的 bootindex 必须显式指定。最初支持盘没排序,
EDK2 枚举到这张没有引导器的 FAT32 卷并尝试引导,卡死在 TianoCore logo。

### 「Press any key to boot from CD or DVD」
直接引导 Windows ISO 会停在这个提示等按键,无人值守流程会永远卡住。
**解法不是发按键,而是把 ISO 的引导文件复制到 FAT32 盘上从"硬盘"引导** ——
这也是制作 Windows 安装 U 盘的标准做法。`install.wim`(6.8GB)超过 FAT32
单文件上限,留在 ISO 上即可,Setup 会自己找到;只需复制 `boot.wim`(671MB)。

### 安装期黑屏:`Display output is not active`
WinPE 没有 viogpudo 驱动,`virtio-gpu-pci` 在 ExitBootServices 之后无人驱动。
**安装期改用纯 `ramfb`**(固件交接的线性帧缓冲,不依赖任何 guest 驱动),
装完切回 `virtio-gpu-pci` 以支持动态分辨率。
注意不能用 `virtio-ramfb` 这个组合设备 —— 它会向 Windows 暴露两个显示适配器。

值得一提的是,这个坑本身不难,难的是**没有画面时只能靠猜**:
第一次遇到时我只能通过 qcow2 增长和 CPU 占用推断安装在进行,
修好显示后一眼就看到卡在哪。

## 安装状态是持久化的(2026-09-11)

介质路径(Windows ISO、包内 boot.img / tools.img、virtio-win ISO)写在 `config.json` 的
`install` 键里。装到一半退出 app 再打开,资源库卡片标「安装中」,打开时自动带上介质接着装;
介质文件找不到就在窗口里说清楚,而不是挂一台不带介质的机器去引导半截系统盘。
安装期点红叉是关机,不是挂起 —— raw 的安装盘本来就存不了快照。

agent 第一次上线就是安装结束的信号(驱动和 agent 都是首次登录脚本装的)。
这时清掉 `install` 键,QEMU 退出后删掉包内的 boot.img(1.5GB)、tools.img 和探测盘。

**virtio-win ISO 是必需项**。向导里必须选(默认位置 `~/Downloads/virtio-win.iso` 有就自动填),
命令行 `virtually install` 找不到就直接退出并说明。以前找不到会静默不挂,装出来的机器没有显卡驱动(黑屏)、
没有网卡、没有 vioserial(agent 永远连不上),从外面看完全不知道为什么。

## 重启后的交接(已完成)

首次重启时必须**热拔安装盘**,否则会再次从它引导,Windows Setup 弹出
「似乎你已开始升级,并已从安装介质启动…请移除该介质」并停下等人确认。
现在 `QMPClient` 在 QMP 的第一个 `RESET` 事件到达时 `device_del` 掉
`boot.img` 与 ISO,保留 `tools.img` 与 virtio-win ISO 供首次登录装驱动。

QMP 客户端当初「连上但永远收不到 greeting」的原因见 `VirtuallyKit/Session/QMP.swift` 的注释:
Swift 的 `String` 把 `"\r\n"` 当成**单个 Character**,
`firstIndex(of: "\n")` 永远匹配不到 QMP 的 CRLF 行尾,于是静默地阻塞在 read 上。
改成按字节缓冲即可。同样的隐患在 `AgentChannel` 里也一并修了。

## 首次登录脚本(`install-agent.bat`)

由 `autounattend.xml` 的 `FirstLogonCommands` 调起,**以管理员身份运行**。
它是整个安装流程里最容易静默失败的一环,因此**全程把输出写到工具盘**
(`install-log.txt`),宿主随时可以读回来 —— 这条通道是后面几个坑都靠它定位的。
盲操作 guest 的 GUI 代价高得多(中文 IME 会改写注入的按键)。

它做四件事:

1. **装 virtio 驱动** —— 显式枚举驱动目录逐个 `pnputil /add-driver ... /install`。
   曾用 `%VIRTIO%\*\w11\ARM64\*.inf` 一把梭:**pnputil 不接受路径中段的通配符**,
   静默地什么都没装。改用 `for` 显式枚举后 9 个驱动包全部装上(oem1–oem9)。
   更早还踩过一次 `^` 续行:`if defined VIRTIO for ... do ^` 换行后语句被拆坏,
   同样是静默失败。现在一律用括号块,不用续行。
2. **默认英文输入法** —— `Set-WinDefaultInputMethodOverride`。
   Win11 的每用户默认输入法存在语言配置里而不是 `HKCU\Keyboard Layout\Preload`,
   只改注册表不生效。`autounattend.xml` 的 `InputLocale` 也把
   `0409:00000409` 排在第一位(列表第一项即默认)。
3. **默认深色主题** —— `AppsUseLightTheme` 与 `SystemUsesLightTheme` 是**两个**开关,
   只设前者会留一条白色任务栏;壁纸还要单独换成 `img19.jpg`(Win11 的深色版,
   `img0.jpg` 是浅色版),否则深色任务栏配浅色壁纸。设完重启 explorer,
   让用户第一眼看到的桌面就是深色的。
4. **注册两段式 agent** —— system 角色是 `onstart` 计划任务(SYSTEM 身份),
   session 角色由 Run 键经 wscript 无窗口启动;细节与演变过程见 `GUEST-AGENT.md`「会话侧助手的生命周期」。

`run-agent-system.cmd` 每次开机会先从工具盘同步最新的 `agent.ps1`,
所以更新 agent 只需「`virtually build-tools` + `virtually run --vm <包> --tools` 开一次机」,不用进 guest 手工操作。

## 快照的两个前置条件(M6)

`savevm` 要求**所有可写块设备都支持快照**,踩了两次:

- `nvme` 设备**不可迁移**:`State blocked by non-migratable device '...'/nvme`。
  改用 `virtio-blk-pci`。但安装期必须仍用 nvme —— WinPE 里没有 viostor。
  切换还有个前提:`pnputil` 只对**在场**的设备真正配置服务,安装期
  virtio-blk 不在场,直接切会 INACCESSIBLE_BOOT_DEVICE 反复重启。
  先用 `--vblk-probe` 挂一块 16MB 假盘让 Windows 绑定一次 viostor,之后切换才安全。
- 可写的 `pflash`(NVRAM)是 raw 时同样挡住快照:
  `Device 'pflash1' is writable but does not support snapshots`。
  改成 qcow2。注意**不能直接建空 qcow2**:新建的 qcow2 读出来是全 0,
  而 EDK2 靠全 0xff 判断「这块 flash 没用过」。要先写 raw 再 convert。

## 脚本文件的编码约束

- `agent.ps1` 必须带 UTF-8 BOM。
- `install-agent.bat` **必须是纯 ASCII**:cmd 用系统代码页(中文 Windows 是 GBK)
  读 .bat,UTF-8 注释会变成乱码并被当成命令执行。
