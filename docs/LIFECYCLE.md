# 虚拟机的生死

## 状态机

`VMSession.State` 是**唯一**表示状态的东西。以前是一个四 case 的 `state` 外加
`shuttingDown` / `userRequestedStop` / `resuming` 三个布尔在拼:红叉查两个、挂起查三个、
退出时查第四个,每处各猜一遍,而「QMP 还没握手完」和「正在跑」还是同一个 `.running`。

```
idle ──start()──> starting ──QMP 握手完──> running ───suspend()───> suspending ──┐
                     │                       │                                   │
                     │      (-S 起的)        │  requestShutdown / forcePowerOff  │
                     └──> restoring ─loadvm─>┤ ────────> shuttingDown ───────────┤
                                             │                                   │
                                             └──── guest 自己关机 ──────────────>┴─> stopped(code)
```

| 状态 | 含义 | 接受操作 |
|---|---|---|
| `idle` | 还没 `start()` | 否 |
| `starting` | QEMU 进程已起,QMP 还没握手完 —— 这期间任何 QMP 命令都立刻失败 | 否 |
| `restoring` | 用 `-S` 起来的,正在 `loadvm`。**guest 一条指令都还没跑,磁盘正被动** | 否 |
| `running` | 正常运行 | **是** |
| `suspending` | 正在 `savevm`,存完就退出。存失败退回 `running` | 否 |
| `shuttingDown` | 正在关机(ACPI 或强制断电),不存状态 | 否 |
| `stopped(code)` | QEMU 已退出 | 否 |

派生判定都在枚举上,别处不要再自己拼:

- `isLive` —— QEMU 进程还活着(除 `idle` 与 `stopped`)
- `acceptsCommands` —— 只有 `running`。挂起、快照、USB、网络、传文件都过这一关
- `isEnding` —— `suspending` / `shuttingDown`。再点一次也不加速;**退出是预期的,不报错**
- `blockedReason` —— 不可操作时给用户的原话
- `VMSession.isBusy` = `busyMessage != nil || !state.acceptsCommands`,界面上禁用控件就看它

两处以前会出事、现在被状态机挡住的:

- **开机头几秒点红叉**:那时 `state` 是 `starting`,QMP 还没连上。以前直接标 `.running`,
  于是 `delvm` 被丢掉、界面永远停在「正在保存状态」。
- **从挂起恢复的过程中点红叉**:`restoring` 期间 `loadvm` 正在回滚磁盘。以前会紧接着排一个
  `savevm`,两个都在动同一块盘。现在直接拒绝并说「正在恢复上次保存的状态,稍候再试」。

`resuming` 这个意图(不是状态)改叫 `wantsResume`:它只在 `buildCommand` 里定下来、
`launchQEMU` 里可能被指纹否决,握手后才把状态推进 `restoring`。

## 红叉 = 挂起,不是关机

点窗口红叉把整机状态存下来,下次打开接着用 —— 像合上笔记本,不是关电源。

存的就是一条内部快照,标签 `__suspend__`,和用户自己存的快照走同一套机制,
只是界面上的快照列表会把它滤掉。资源库的卡片会标「已挂起」。

恢复走 **`-S` + QMP `loadvm`**,而不是命令行的 `-loadvm`:

- `-S` 让 QEMU 停在 guest 一条指令都还没跑的地方,固件不会先跑一秒、也不会写 NVRAM
- 失败时还能在进程里救回来。`load_snapshot()` 是**先回滚磁盘再读内存**
  (`migration/savevm.c`),所以读内存失败时磁盘已经是快照那一刻的了 ——
  这时 `system_reset` + `cont` 冷启动恰好一致。用 `-loadvm` 的话 QEMU 直接退出,
  虚拟机看上去就成了砖。

恢复用掉的那份状态立即删除。留着的话下次开机会再试一遍同样的失败。

**设备配置变了就不恢复**。开机前拿 `QemuCommand.migrationFingerprint()` 比对,
对不上就丢掉状态冷启动 —— 改了内存或 CPU 核数之后,旧状态本来也恢复不了。
`-S` 不进指纹(自检里有这条断言),否则存的状态永远对不上。

**恢复后要拨钟**。guest 的时间停在存盘那一刻,挂一晚上再打开就差一整夜。
agent 上线时宿主发一条 `settime`,system 角色跑在 SYSTEM 下,
有 `SeSystemtimePrivilege`,直接 `Set-Date`。实测残余偏差约 1–2 秒。

**存之前先拔 USB**:透传设备会进内存状态,而下次开机命令行上没有它,状态就废了。
`suspend()` 先 `detachAllUSB` 再 savevm。

**QMP 还没连上就点红叉**:直接报「尚未连上控制通道,稍候再试」,不进入保存流程。
以前 delvm 被静默丢掉,「正在保存状态」永远停在那里。

**完成的信号是 QEMU 进程退出**,不是 `quit` 的回复 —— 那条回复可能在 socket 关闭前丢掉。
`quit` 之后 20 秒还不退就强杀,状态已经落盘,之后的写入本来就会被下次 loadvm 丢掉。

**存不下来怎么办**:窗口留着,报出 QEMU 的原话,用户可以从电源菜单关机。
已知会失败的情况是挂了不支持快照的盘 —— `--tools` 那张工具盘就是:

```
Error: Device 'extra0' is writable but does not support snapshots
```

平时不挂它,不影响正常使用。

## 完整规则

| 动作 | 行为 |
|---|---|
| 点窗口红叉 | 保存状态并退出 QEMU。窗口**不立刻关**,留着显示「正在挂起…」 |
| 工具栏「关机」 | ACPI 关机,不保存状态 |
| 工具栏「强制关机」 | 立即断电,相当于拔电源线 |
| Cmd+Q / 菜单退出 | 先把每台虚拟机的状态存下来再退出(`.terminateLater`),上限 180 秒。**有一台没存成功就取消退出**,错误留在那台的窗口上 —— 以前是照样退出并强杀,等于拔电源 |
| QEMU 自己退了 / 起不来 | 窗口**不关**,把退出码和日志尾部显示出来。以前窗口闪一下就没了,原因只在 /tmp 的日志里。判据是「退出前不在 `isEnding`」加「跑了不到十秒」—— guest 自己在开始菜单里关机不会被误判,而 EFI 找不到启动项那种秒退会 |
| SIGTERM / SIGINT / SIGHUP | 来不及存,强制断电。Cocoa 应用对这些信号走默认动作,`applicationWillTerminate` **不会**被调到,所以另外装了 `DispatchSource` 信号源 |
| 关掉最后一个窗口 | 应用不退出 —— 资源库还在,别的虚拟机可能还开着 |

红叉不立刻关窗口是有意的:存盘要几秒到几十秒,窗口先没了的话用户既看不到进度,
也没地方改主意。

## 不能留下孤儿 QEMU

QEMU 是 `Process` 起的子进程。macOS 没有 `PDEATHSIG` —— 父进程没了它照样活着,
被 launchd 收养,然后**一直攥着 qcow2 的写锁**。下一次再开这台虚拟机就是:

```
Failed to get "write" lock
Is another process using the image [.../nvram.qcow2]?
```

这个错误只写在 `/tmp/virtually-qemu*.log` 里,界面上表现为一个永远转不完的圈,
看起来就是「开不了机」。实测已经这样卡住过一次。

所以:退出应用(含信号)一定要把 QEMU 带走;开机前也先查一遍有没有别的 qemu
正打开这个包的磁盘(`CLI.runningQEMUHolding`),有的话直接把话说清楚:

```
这台虚拟机已经在运行(进程 99817)。先把它关掉再开。
```

比让 QEMU 自己去撞锁、再让用户对着一个转圈的窗口发呆要好。

## 调试

通道路径带 pid(`/tmp/virtually-<pid>-*`),两个 app 实例不会再撞在同一个帧缓冲文件上。
`virtually run` 拉起的调试实例用固定的 `/tmp/virtually-*`(`SessionPaths.debug`),`virtually shot` 认得到。

`virtually send close` 走的就是红叉那条路(`windowShouldClose`),
`send suspend` 直接调 `VMSession.suspend()`。会话里的错误一律也打到 stdout ——
以前只存在一个没人读的属性里,表现就是「点了没反应」。
