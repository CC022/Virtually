# Linux(Ubuntu)支持

目标版本 **Ubuntu 26.04.1 桌面版 arm64**。下面每一条都在这台机器上实跑验证过。

## 与 Windows 的差异一览

| | Windows 11 | Ubuntu 26.04 |
|---|---|---|
| 安装应答 | `autounattend.xml` | cloud-init 的 `user-data`(内含 `autoinstall` 段) |
| 安装介质 | `boot.img` 1.5GB(ISO 的引导文件)+ `tools.img`(agent 与随 app 打包的 virtio 驱动) | 一张 CIDATA 盘,几 MB —— grub 直接从 ISO 取内核 |
| 介质构建耗时 | 几分钟(要复制约 700MB) | 几秒 |
| 安装期显示设备 | `ramfb`(WinPE 没有 viogpudo) | `virtio-gpu-pci`(casper 内核自带驱动,分辨率跟随从安装期就能用) |
| 安装期系统盘 | `nvme`(viostor 要装完才有) | `virtio-blk-pci`(内核自带),不需要探测盘 |
| `-rtc base=` | `localtime` | `utc` —— **给错了时钟整体偏一个时区** |
| virtio 驱动 | 随 app 打包,装在工具盘上 | 不需要(内核自带) |
| 装完的信号 | agent 首次上线 | 同 |
| agent 装法 | `FirstLogonCommands` 跑 `install-agent.bat` | autoinstall 的 `late-commands`(装完第一次开机 agent 就在) |
| 自动登录 | `AutoLogon` | `/etc/gdm3/custom.conf` 的 `AutomaticLogin` |
| 改分辨率 | `ChangeDisplaySettingsEx` | Mutter 的 `org.gnome.Mutter.DisplayConfig` D-Bus |
| 界面缩放 | 写 `LogPixels`,固定 200% | Mutter 按分辨率给可选倍数,从里面挑 |
| 光标 | 要打开 `HWCursor=1`,否则得用透明系统光标兜底 | **驱动自带硬件光标**,宿主那套接管不做(见坑 7) |
| 剪贴板 | `Get-Clipboard` / `Set-Clipboard` | 经 **Xwayland** 的 GTK3 剪贴板(Wayland 那条对后台进程不通,见坑 4) |
| 安装耗时 | 约 10 分钟 | 约 11 分钟(其中前 3 分钟在起 live 会话) |

## 安装路线

```
我们打一张 FAT32 盘(标签 CIDATA,bootindex=0):
  EFI/boot/{bootaa64.efi,grubaa64.efi,mmaa64.efi}   从 ISO 抄出来(Ubuntu 签名的 shim + grub)
  EFI/boot/grub.cfg     我们写的:search --file /.disk/info 找到 ISO,带 autoinstall 引导它的内核
  user-data / meta-data cloud-init 的 NoCloud 按卷标 cidata 找它们
ISO 以 bootindex=2 挂着。
```

Ubuntu 签名的 grub 启动后会 `source $prefix/grub.cfg`,而从我们这张盘的 shim 起来时 `$prefix`
就是盘上的 `/EFI/boot` —— 所以读到的是我们那份,不是 ISO 上那份。

**首次重启必须弹掉引导盘与 ISO**(现有 `installEjectPending` 那条路,与 Windows 共用)。
不弹的话装完重启又从 CIDATA 盘引导,再装一遍 —— 实测就这么循环装了两次。

## 桌面版安装器不会自己开始装(这是最关键的一条)

即使 autoinstall 全填好、`interactive-sections` 为空(默认),**Flutter 前端也一定停在
「Ready to install / Review your choices」等人点 Install**。实测:

- 服务端此时已经是全自动模式(`/run/subiquity/server-state` = `NEEDS_CONFIRMATION`),
  是前端自己要确认
- 翻遍 `ubuntu-desktop-bootstrap` snap 里的 subiquity 源码与 `libapp.so` 的字符串,
  **没有任何内核参数或命令行开关能跳过**。桌面版的 autoinstall 本来就设计成面向用户的
  (它有「导入 autoinstall 文件」「审阅」这些界面)

解法:`early-commands` 里挂一个后台轮询器,等状态变成 `NEEDS_CONFIRMATION`,
就调**它自己的 API**:

```
POST /meta/confirm?tty="/dev/tty1"   经 /run/subiquity/socket
```

实测回 `HTTP/1.1 200 OK` + `x-status: ok`,状态随即转 `RUNNING`,装完按 `shutdown: reboot`
自己重启。**不点坐标、不模拟按键**,所以 UI 改版也不会坏。

轮询器还做两件事:

- **把安装器 UI 关掉**(`pkill -f ubuntu_bootstrap`)。它不会跟着服务端刷新 ——
  实测装完整个过程界面一直停在那个「Ready to install」页面,留着只会让用户以为没开始装,
  还可能去点 Install
- 把服务端状态按 `vainstall <状态>` 写进 virtio-serial,宿主显示在状态条上。
  这是那十几分钟里唯一的进度来源

用 python3 写:live 会话里有 python3,而**没有 curl**(实测 `which curl` 为空)。

## ISO 读取:两套并存,各管一边

- **Ubuntu 的 ISO:`hdiutil` 挂不了**(`no mountable file systems`,`imageinfo` 也 internal error),
  但镜像完好 —— ISO9660 的 PVD 在 lba 16,Joliet SVD 在 lba 18,外加一张 GPT。
  所以有了 `VirtuallyKit/Install/ISOReader.swift`(自己读 ISO9660 + Joliet)。
- **Windows 的 ISO 是纯 UDF**:ISO9660 那层只有一个 `README.TXT` 写着「这是 UDF」,
  `ISOReader` 读不了,得靠 `hdiutil`(它认 UDF)。

两者正好互补,所以两套都留着。`ISOInspector.detect` 先试便宜的 ISOReader(不挂载、不要权限),
不中再去挂。

## Linux guest agent

`GuestAgent/linux/virtually-agent.py`,**同一份文本协议、同样两段式**,宿主侧一行都没分叉。

| | 身份 | 触发 | 管什么 |
|---|---|---|---|
| `--role system` | root | systemd 系统服务 | virtio-serial 端口、`ping`/`settime`/`exec`/`reboot` |
| `--role session` | 用户 | `graphical-session.target` | 分辨率(Mutter D-Bus)、剪贴板、桌面设置 |

两侧的 socket 在 `$XDG_RUNTIME_DIR/virtually-agent.sock`:**会话侧建、system 侧连**。
方向不能反 —— 普通用户在 `/run` 下建不了文件(实测 `PermissionError`),而 root 连谁的都行。
system 侧按 `/run/user/*/` 通配找,不写死 uid。

用 python3 + python3-gi:Ubuntu 桌面版都预装(GNOME 自己要用),**不需要联网装任何包**。

端口的设备名:`/dev/virtio-ports/org.virtually.agent`(udev 按 QEMU 的 `name=` 建的符号链接,
实测指向 `../vport2p1`)。

## 实测踩到的坑

### 1. Mutter 拒绝小分辨率上的 2 倍缩放
```
GDBus.Error:org.freedesktop.DBus.Error.InvalidArgs: Scale 2 not valid for resolution 1280x800
```
逻辑尺寸会小到没法用(Mutter 要求逻辑高度 ≥600)。所以**不能凭空给 2** ——
改成在 `GetCurrentState` 给出的 `supported-scales` 里挑不超过目标的最大值。
窗口够大(≥1600×1200 物理像素)时 2 倍就在列表里,自然切过去;小窗口下是 1 倍,
界面偏小但内容更多。这是 Mutter 的规则,不是我们能绕的。

### 2. 欢迎向导:写 `gnome-initial-setup-done` 挡不住
装完第一次进桌面照样弹「欢迎来到 Ubuntu 26.04.1 LTS!」。查下来跑的是
`gnome-initial-setup-upgrade-login.service`(升级后的欢迎页那一支),它不看这个标记。
改成把两个用户单元一起 mask:`/etc/systemd/user/` 下指向 `/dev/null` 的符号链接
压过 `/usr/lib/systemd/user/`,与版本无关。

### 3. guest 自己息屏 = 宿主看到一台「死机的虚拟机」
GNOME 默认 5 分钟息屏。息屏时 Mutter 关掉 CRTC,virtio-gpu 的 scanout 随之关闭,
QEMU 画面变成 `Display output is not active` —— **和真死机一模一样**,我自己误判过一次。
锁屏更烦:自动登录进去了,五分钟后又要输密码。

会话侧 agent 一启动就用 `gsettings` 关掉(`idle-delay=0`、`lock-enabled=false`、
`sleep-inactive-ac-type='nothing'`)。用 gsettings 而不是 dconf 系统库,
是因为这样对**已经装好的**虚拟机也生效 —— agent 会随工具盘更新。

### 4. 剪贴板:Wayland 那条对后台进程两个方向都不通
~~所以剪贴板走 GTK 的 `Gdk.Clipboard` …… 实测 GTK 这条双向都通。~~ **这条结论是错的。**
当时的「验证」是 agent 自己写、自己读,读到的是 GTK 进程内的缓存。用户一试就发现粘不出来。

真实情况(Ubuntu 26.04 的 GNOME 上实测,每一步都换一个**独立进程**或真实应用来验):

- **写**:`wl_data_device.set_selection` 要带一个输入事件的 serial。agent 没有窗口、
  没收到过键鼠事件,拿不到。GTK4 的 `clipboard.set()` 照样返回成功,但 Mutter 不认 ——
  终端里 Ctrl+Shift+V 什么都没有
- **读**:Mutter 只把选区发给**有键盘焦点**的客户端。另开一个进程读,回「无法读取空剪贴板」
- wl-clipboard 在 GNOME 上也是靠临时弹窗口抢焦点做到的。宿主每秒轮询一次,
  用它就是每秒闪一次焦点,所以即使用户装了也不用(而且 ISO 的 `pool/` 里本来就没有)

解法:**经 Xwayland 走 X11 剪贴板**。X11 没有焦点限制,而 Mutter 把 X 的 CLIPBOARD
与 Wayland 选区双向桥接。实测:

| 方向 | 做法 | 结果 |
|---|---|---|
| 宿主 → guest | agent 用 GTK3(`GDK_BACKEND=x11`)写入 | 原生 Wayland 的终端里 Ctrl+Shift+V 粘出来,中文完好 |
| guest → 宿主 | 终端里复制,agent 经 X11 读 | 宿主 `pbpaste` 拿到,中文完好 |

几个要点:

- Xwayland 按需启动,agent 第一次连它时拉起来,之后一直连着
- 授权文件是 Mutter 生成的 `$XDG_RUNTIME_DIR/.mutter-Xwaylandauth.*`。
  用户服务的环境里未必有 `XAUTHORITY`,找不到就按这个名字去找
- **agent 必须常驻**:选区的拥有者负责在别人粘贴时供数据
- 读到的内容缓存着,选区换主人(`owner-change`)才重读。
  否则宿主每秒一问,就是每秒让当前拥有者供一次数据
- GTK 对象只在自己那条线程里碰,IPC 线程经 `GLib.idle_add` 投递

### 5. `settime` 里 hwclock 缺失把时间设**错**了
精简版 Ubuntu 里没有 `hwclock`。它一失败,整条 `settime` 就回 `err`;
当时宿主见到 err 会退回本地时间字符串的老格式重发,而 agent 按空格切只取了日期,钟被设成那天的零点。
现在:hwclock 只是顺手,失败不影响成败;协议只剩 Unix 秒一种格式。

### 6. bootindex 会撞
引导盘、系统盘、ISO 三个都要显式排号,而 `--iso` 那条调试路径原来给 ISO 排 1,
与系统盘撞上,QEMU 直接拒绝启动(`The bootindex 1 has already been used`)。
现在统一成 引导盘 0 / 系统盘 1 / ISO 2。

### 7. 硬件光标晚到几秒,触发了 Windows 那套接管
agent 就绪后宿主等 3 秒看有没有硬件光标。Ubuntu 进桌面后要再过几秒才开光标平面,
于是宿主开始发 `hidecursor on` 做透明光标接管。Linux agent 回的是 `ok hidecursor`
(不带 `on`),宿主永远等不到确认,每 2 秒重发。**3 分钟后放弃,顶一个宿主箭头上去,
而 guest 的硬件光标还在:屏幕上两个光标。**

现在:非 Windows 的 guest 不做接管,没见到硬件光标就先用宿主箭头等着;
硬件光标一到就撤掉箭头,并停掉可能正在重试的接管。

### 8. ⌘V 在 guest 里是 Super+V,不是粘贴
剪贴板同步做对了也没用:宿主把 ⌘ 原样发成 Super,而 Linux 与 Windows 里粘贴都是 Ctrl+V。
所以 ⌘ 加编辑键(A C V X Z Y F S N O P T W)改发 Ctrl,其余仍是 Super,见 `VirtuallyKit/Display/CommandKeys.swift`。
偏好设置里可以关。

难点是**不能先发 Super 再撤回**:GNOME 在 Super 按下又抬起、中间没有别的键时打开活动概览。
所以 ⌘ 按下时先不发,等下一个键再决定。顺带修掉了 ⌘Tab 切走时 guest 弹出活动概览的问题。
终端里粘贴是 Ctrl+Shift+V,对应按 ⌘⇧V。

### 9. 持久的显示配置会弹「保留这些显示设置吗?」
`ApplyMonitorsConfig` 用持久模式(method=2)时,GNOME 每次都弹确认框,没人点就在 15 秒后还原。
实测分辨率留下了,2 倍缩放却被退回 1 倍,而且每拖一次窗口弹一次。
改用临时模式(method=1):不弹框,也不写 `monitors.xml`。每次开机宿主都会按窗口大小重新 `setres`,不需要持久化。

## 已验证的清单

| 项 | 结果 |
|---|---|
| 无人值守安装(向导与 `virtually install` 同一条路) | ✅ 约 11 分钟,零交互 |
| 自动确认(subiquity API) | ✅ 200 OK,状态转 RUNNING |
| 首次重启弹介质、从系统盘引导 | ✅ |
| 自动登录 | ✅ GDM 直接进桌面 |
| agent 两个角色 | ✅ `pong` / `sesping` 都通 |
| 拖窗口分辨率跟随 | ✅ 900×620 点 → guest 1800×1160,点对点 |
| 硬件光标 | ✅ QEMU 日志有 `cursor_define 64x64`,宿主状态「硬件光标」 |
| 剪贴板双向 | ~~✅ GTK 路径~~ 验证方法错了,实际不通。改走 Xwayland 后 ✅(真实应用里粘贴与复制) |
| ⌘V / ⌘⇧V | ✅ 活动概览搜索框里 ⌘V、终端里 ⌘⇧V 都粘出宿主文本,概览不会被误开 |
| 硬件光标晚到 | ✅ 不再发 `hidecursor`,不再出现两个光标 |
| 传文件双向 | ✅ GNOME 自动挂到 `/run/media/<用户>/VIRTUALLY` |
| 红叉挂起 | ✅ 传输盘自动拔出,状态 2.84 GiB 落在 disk.qcow2 |
| 恢复挂起 | ✅ 分辨率与硬件光标都保住,时钟自动拨正 |
| `-rtc base=utc` | ✅ guest 本地时间与宿主一致 |
| 安装进度回传 | ✅ 状态条显示「正在安装系统…」 |

## 还没做

- **Linux agent 不会自己更新**。Windows 靠工具盘同步,Linux 这边还没做,
  已经装好的 Ubuntu 虚拟机要手工把新的 `virtually-agent.py` 放进 `/usr/local/lib/virtually/`
- **USB 透传**没在 Linux guest 上试过(宿主侧与 Windows 共用一条路,guest 侧是 Linux 内核自己的事)
- 音频同 Windows,仍未人工验证
- 第二块盘 / 多显示器 / 3D 加速都不在范围内
