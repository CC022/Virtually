# Guest Agent:现状与踩过的坑

## 为什么需要它

Windows 的 viogpudo 是 display-only 驱动,**不响应主机侧的 EDID / `VIRTIO_GPU_EVENT_DISPLAY`**
(实测:引导期 EDID 曾生效过一次,但 WDDM 驱动加载后 Windows 用自己记住的配置覆盖了它)。
动态分辨率只能由 guest 内部调用 `ChangeDisplaySettingsEx` 实现 ——
Parallels / VMware / spice-vdagent 全都是这个做法。

## 架构

```
宿主 app ──Unix socket──> QEMU chardev ──virtio-serial──> guest agent (PowerShell)
                                          端口名 org.virtually.agent
```

- 走 virtio-serial 而非网络:不依赖 guest 网络配置,不占端口
- guest 侧用 PowerShell:Windows ARM64 自带 5.1 + 完整 .NET Framework,
  **宿主(macOS)不需要任何 Windows 交叉编译工具链**
- QEMU 侧做 server,app 做 client(省掉握手编排)

## 当前状态(2026-09-12,先看这里;下面的「踩过的坑」是按时间记的日志,有些结论后来被推翻了)

**两个系统两份实现,同一份协议**:Windows 是 `GuestAgent/agent.ps1`(PowerShell),
Linux 是 `GuestAgent/linux/virtually-agent.py`(Python)。都是两段式(system + session),
宿主侧不分叉。Linux 侧的细节与差异见 `LINUX.md`。下面这一节讲 Windows。


- 两段式:system 角色是 `onstart` 计划任务(SYSTEM),持有 virtio-serial 端口;
  session 角色由 Run 键经 `wscript` 无窗口启动,管分辨率与光标;两者走命名管道。
  session 死了 system 用 `CreateProcessAsUser` 拉回来;宿主每 10 秒 `sesping` 探活。
- 光标:硬件光标(`HWCursor=1`)是主路径,`SetSystemCursor` 换透明位图 + `getcursor` 轮询是后备。
- 时钟:恢复快照后宿主发 `settime <unix秒>`,与 guest 时区无关。
- 更新 agent:`virtually build-tools` 重建工具盘,`virtually run --vm <包> --tools` 开一次机,system 侧开机会从工具盘同步。
- 坑 12「计划任务必须 /rl highest」与坑 16 的看护任务已经**不再适用**,被两段式取代。

## 打通过程

- ✅ vioserial ARM64 驱动安装,设备枚举为 `VIOSerialPort`
- ✅ agent 以计划任务在登录时自启(`VirtuallyAgent`)
- ✅ 双向通信正常(`ping` → `pong`,日志经协议回传宿主)
- ✅ **动态改分辨率成功**:`setres 1920 1440` → guest 切换 → virtio-gpu 上报新 scanout
  → 宿主重建零拷贝纹理,全链路自动完成
- ✅ 窗口缩放已接到 agent(不再走无效的 EDID 路径)

## 踩过的坑(每一个都真实卡住过)

### 1. PowerShell 5.1 需要 UTF-8 BOM
无 BOM 的 UTF-8 会按系统代码页(中文 Windows 上是 GBK)解释,
脚本里的中文注释变乱码并破坏引号/大括号配对,报「缺少右 `}`」但指向的行看起来完全正常。

### 2. `.bat` 必须是纯 ASCII
与上一条相反的方向:cmd.exe 同样按系统代码页读 `.bat`,
UTF-8 的中文注释会变成乱码**并被当作命令执行**。
症状是一串乱码后跟「不是内部或外部命令」,而真正该执行的那行被跳过。

### 3. `0xC0000000` 在 PowerShell 里溢出
被解析成 Int32 → -1073741824,传给 `CreateFile` 的 UInt32 参数时转换失败。
必须写 `[uint32]3221225472`。

### 4. 用 `CreateFile` 而不是 `FileStream` 开设备路径
.NET 的 `FileStream` 对设备路径会做文件语义假设(取长度等),不可靠。
qemu-guest-agent 在 Windows 上同样走 `CreateFile` P/Invoke。

### 5. `schtasks /tr` 里的嵌套引号
在 `.bat` 里给 `/tr` 传带引号的 powershell 命令行极易坏掉 ——
任务能创建成功,但动作是坏的,且以隐藏窗口运行时**完全看不到任何错误**。
改为先写一个包装 `run-agent.cmd`,`/tr` 只指向这个文件。

### 6. 端口被上一个实例占着会报 ACCESS_DENIED
`win32 error 5` 一度让我以为是权限问题(试了 `/rl highest`),
实际是之前调试时残留的 agent 进程仍持有端口。干净启动后一次就打开了。
**error 5 与 error 2 的区别很有用**:5 说明名字对、设备在;2 说明名字不存在。

### 7. 中文 Windows 的输入法会转换注入的按键
自动化时 `"abc def ghi"` 变成了 `按不出得分给hij'k'l`。
这不是虚拟机输入路径的 bug —— 真实用户敲键盘同样经过 IME ——
但自动化脚本必须先把 IME 切到英文(Shift 切换),否则一切键盘注入都不可靠。

### 8. PowerShell 对结构体的 byref 封送不可靠 —— 本轮最难的一个
`EnumDisplaySettings` 始终返回 False,而 `dmSize=220`(DEVMODEW 正确大小)、
`session=1`(交互会话正常)、交互式运行与计划任务表现一致 —— 所有明显嫌疑都被排除。
**解法:把 DEVMODE 连同全部 P/Invoke 收进 `Add-Type` 的 C# 里**,
PowerShell 只调 `GetCurrent()` / `ListModes()` / `SetResolution()` 这类简单方法。
改完立刻正常。教训:PowerShell 里凡是涉及含 `ByValTStr` 的结构体 byref 调用,
一律放进 C#,不要在 PowerShell 层面拼结构体。

### 9. `CDS_UPDATEREGISTRY` 需要管理员
非提权的 agent 用它调 `ChangeDisplaySettingsEx` 一律返回 `-1`(DISP_CHANGE_FAILED),
容易误判成「模式不支持」(那应该是 `-2` DISP_CHANGE_BADMODE)。
改为先用 `flags=0` 做动态切换(非管理员即可),再尝试持久化。

### 10. 运行中重建工具盘镜像不会到达 guest
QEMU 持有镜像文件时,宿主侧重建 `tools.img`,guest 的 FAT 缓存仍是旧的。
我因此连续几轮都在「拷贝陈旧内容」而不自知。
**正确顺序:重建镜像 → 重启 VM → 再从工具盘拷贝。**

### 11. HMP `sendkey` 在快速连发时丢字符
`"powershell -NoProfile"` 变成 `"power shell-NoProfile"`,空格错位。
已改用 QMP `input-send-event` 显式发按下/抬起。

### 12. vioserial 端口的 ACL 只给管理员 —— 这是「agent 不工作」的真正原因
非提权进程打开 `\\.\Global\org.virtually.agent` 一律返回 **win32 error 5**
(ACCESS_DENIED)。error 5 很容易被当成「端口被别的进程占着」——
我第一次就是这么判断的,还为此去掉了 `/rl highest`。

**决定性实验**:在 guest 里以管理员身份 `tasklist | findstr powershell`,
确认**一个 powershell 进程都没有**,端口依然报 5;
随后用同一个 `agent.ps1`,普通控制台报 5、管理员控制台立刻回 `pong`。

所以计划任务**必须**带 `/rl highest`。当初去掉它的理由(提权会丢失交互桌面,
导致 `EnumDisplaySettings` 失败)是错的:任务仍然跑在用户自己的会话里,
`ChangeDisplaySettingsEx` 照常工作(实测 `setres 1920x1200` 生效)。

### 13. agent 不能「重试几次就放弃」
早期版本重试 5 次后 `exit 1`。端口没就绪的原因几乎都是暂时的
(vioserial 刚枚举完、宿主还没连上 chardev、上一个实例没退干净),
结果就是「开机时刚好没赶上 → 这一整轮开机都没有 agent」,
外部表现是改分辨率静默失效,和 agent 崩溃完全无法区分。
现在改成**无限重试 + 退避到 30 秒封顶**,日志按指数稀疏。
读到 EOF 也不再退出,而是重新等宿主连上 —— 否则「重开一次 app」
就等于 agent 永久失联,必须重新登录才能恢复。

### 14. `LogonCount` 用完 → 没有用户会话 → onlogon 任务不触发
`autounattend.xml` 里原本是 `<LogonCount>3</LogonCount>`。用完之后 Windows
停在登录界面,agent 作为 onlogon 计划任务自然不会运行。
症状同样是「改分辨率静默失效」。虚拟机随时可能被快照回滚到任意时刻,
给一个大数(现为 1000)比给 3 合理得多。

另外注意:**解锁不是登录**,onlogon 不会因解锁而触发。
但由于 agent 现在不会自行退出,锁屏/解锁不再影响它。

### 15.5 viogpudo 的 INF 里有三个可调开关(2026-09-09 发现)
`viogpudo.inf` 的 `[VioGpuDod_DeviceSettings]`:

```
HKR,, HWCursor,            REG_DWORD, 0
HKR,, FlexResolution,      REG_DWORD, 1
HKR,, UsePhysicalMemory,   REG_DWORD, 0
HKR,, UsePresentProgress,  REG_DWORD, 0
```

- `FlexResolution=1` 解释了为什么任意分辨率可行(见 `DISPLAY-PERF.md`)
- **`HWCursor=0` 解释了 `dpy_cursor_define` 为什么从未被调用** ——
  硬件光标是被驱动默认关掉的,不是不支持。把它设成 1 理论上就能拿到
  真实的光标位图与热点,比现在用 `SetSystemCursor` 全局替换成透明位图
  更干净(形状精确、不改全局状态、失败时不会让 guest 没有光标)。
  **已验证可用**:打开后 guest 上报 64x64 位图,鼠标移动的帧缓冲脏区
  从 53/s 降到 0/s。`SetSystemCursor` 那套降级为后备。

### 15. 驱动装好了,分辨率仍只能取列表内的值(结论已被推翻)
**注意:下面这条的结论后来被证明是错的,保留是为了记住错在哪。**

viogpudo 只接受它暴露的模式(实测 23 个,含 1280x800 / 1920x1200 /
1920x1440 / 3840x2160 / 5120x2160 等),任意尺寸返回 `-2 DISP_CHANGE_BADMODE`。
窗口是任意大小的,所以**吸附必须在宿主侧做**:
agent 报到后宿主自动 `modes` 取表并缓存,`setResolution` 选
「不小于请求尺寸的最小模式」——画面在宿主侧缩小仍清楚,放大则会糊。

### 16. onlogon 单独用太脆弱 —— 改成自愈
agent 没起来的原因至今遇到过四种,**从外部看完全一样**(改分辨率静默失效):
`LogonCount` 用完导致根本没人登录 / 解锁不是登录 / 进程自己退了 /
任务跑完但进程不在了(`上次结果: 0`,却查不到 powershell 进程)。
逐个追根因的成本远高于收益。

现在:`VirtuallyAgent`(onlogon)之外再建一个 `VirtuallyAgentWatch`
(每 5 分钟),两个都指向同一个 runner;agent 启动时取
`Global\VirtuallyAgentSingleton` 互斥锁,多余实例立刻退出。
无论哪种原因掉线,5 分钟内自动恢复。

互斥锁必须带 `Global\` 前缀 —— 提权任务和普通会话不在同一命名空间,
不加前缀会各拿各的锁,等于没有互斥。

### 17. error 5 不是「端口被占」
这个结论反复确认了两次,值得单独记:提权的普通控制台里
`tasklist` 显示**一个 powershell 都没有**,非提权打开端口依然报 5。
所以看到 error 5 应当先查权限,而不是去找占用者。

### 18. 最隐蔽的一次:agent.ps1 变成了「大小正确的全零文件」
症状还是老样子 —— 改分辨率没反应。查下来:计划任务跑了(`上次结果: 0`)、
没有 powershell 进程、agent 一行日志都没有。手动跑才看到真相:

```
无法将“ ”项识别为 cmdlet…
所在位置 C:\ProgramData\Virtually\agent.ps1:1 字符: 1
```

C: 上那份 `agent.ps1` **大小 13658 字节完全正确,内容全是 NUL**。

根因是我自己:在虚拟机运行期间重建了 `tools.img`(就是坑 10),
guest 缓存的 FAT 与簇失效,`copy` 于是复制出一个空壳。

两道防线:
1. `virtually build-tools` 检测到工具盘正被虚拟机挂着就**拒绝**重建,并说明原因。
2. 拷贝前用 `findstr` 校验来源内容,再经临时文件 `move` 过去(原子替换)。

校验**不能加 `/b`** —— 文件以 UTF-8 BOM 开头,标记不在第 1 行第 1 列。
我第一版加了 `/b`,结果守卫对着好文件报「来源为空或损坏」,
差点又误判成一次真实损坏。

### 19. 写 agent 通道会永久阻塞(排查了好几次才定位)
guest 侧没打开 virtio-serial 端口时(agent 没起来),QEMU 的 chardev 就不再从
socket 读,内核缓冲写满之后宿主的 `write` **永久阻塞**。调用方可能是 stdin
控制线程,也可能是主线程(光标轮询的 Timer),于是整个 app 看起来「死了」:
命令没反应、窗口不刷新,但进程还在。

我先后把这个现象误判成「控制脚本的 FIFO 持有者被杀了」和「app 崩溃了」,
折腾了好几轮才找到真因。

**修法**:socket 设 `O_NONBLOCK`,写不进去就丢弃并稀疏计数。这条通道上的消息
要么是轮询(下一轮还会发),要么是幂等的设置命令,丢了不影响正确性。
读循环相应地把 `EAGAIN` 当成「暂时没数据」,用 `poll` 等待而不是当作断开。

### 20. 新装的虚拟机在后台跑 Windows 更新 —— 会污染一切结论
干净安装完成后,Windows 会自己开始下载安装更新。期间:

- 系统繁忙,登录时的计划任务行为不可信
- 更新可能重装显示驱动,把我们写的 `HWCursor` 设置刷掉
- 时钟反复跳(实测同一台机器上从 13:08 跳到 16:27,还跨过日期)

而我在排查过程中一直用「杀掉 QEMU」来重启,等于反复断电打断更新,
让状态更加不可复现。**任何关于 agent 自启、注册表设置是否生效的实验,
都必须先有一个不会自己变化的基线。**

### 21. 根因:guest 时区与宿主不一致 → 任务计划服务不再触发任何任务
这是「agent 不自启」查了很多轮的真正原因,值得完整记下。

**症状**:计划任务存在、配置正确、`schtasks /run` 手动触发**立刻**就活,
但 onlogon 和后来改的 onstart **两个触发器都从不触发**。
`schtasks /query /v` 里唯一异常的是「上次运行时间」落在当前时钟的**未来**约 15 小时。

**根因**:QEMU 用 `-rtc base=localtime`,把**宿主本地时间**写进 guest 的 RTC。
宿主在 `America/Los_Angeles`(UTC-7),而中文 Windows 安装后默认
China Standard Time(UTC+8)—— 正好差 15 小时。于是 guest 记录的时间整体偏移,
而每次开机 RTC 又被重新播成宿主本地时间,时钟就在重启之间来回跳。
任务计划服务在「上次运行时间在未来」的状态下不再触发。

**修法**:在 `autounattend.xml` 里按宿主时区显式设置 guest 时区
(`UnattendOptions.hostWindowsTimeZone`,一张 IANA → Windows 时区 ID 的映射表,
表里没有的退回 UTC —— 宁可时区不对,也不能两边不一致)。
改完之后 guest 时钟与宿主一致(实测 22:33 vs 22:34),两个触发器立即恢复正常。

**教训**:虚拟机的时钟不是无关紧要的显示问题。它会让依赖时间的系统服务
静默地整体失效,而表现出来的症状(「计划任务不触发」)和时钟毫无关联。

### 22. viogpudo 落在哪个显示类子键是不固定的
打开硬件光标要写 `HKLM\...\Class\{4d36e968-...}\<NNNN>\HWCursor`。
那个 `NNNN` **不固定**:一台机器上是 `0000`,另一台是 `0002`
(`0000`/`0001` 是基本显示适配器和一个残留项)。
只写低位序号会静默地写不到正确的键上 —— 我因此以为「设了注册表也没用」,
浪费了好几轮。现在对 `0000`–`0004` 全写;在别的适配器键下多一个不认识的值是无害的。

要确认落在哪个键,查 `DriverDesc`:viogpudo 的是
`Red Hat VirtIO GPU DOD controller`。

## 协议

```
宿主 → guest :  setres <w> <h> | setrefresh <hz> | getres | modes | ping | sesping
                 exec <命令> | reboot | hidecursor on|off | getcursor
                 settime <unix秒>   (恢复快照后校时;Unix 秒与 guest 时区无关,
                                     旧的 'yyyy-MM-dd HH:mm:ss' 本地时间格式仍兼容)
                 clipget | clipset <base64>   (文本剪贴板,session 角色,见 TRANSFER.md)
guest → 宿主 :  …另有 `vainstall <状态>`,那是 **Ubuntu 安装器**在写,不是 agent ——
                 宿主不能把它当成「agent 就绪」(见 AgentChannel 里那处判断)
guest → 宿主 :  ok ... | err ... | res <w> <h> <hz> | mode <w> <h> <hz>
                 pong | out <一行输出> | cursor <形状名> <是否可见> | clip <base64>
```

扩大系统盘之后,宿主借 `exec` 让 guest 扩分区,回一行 `out VAGROW …`(见 DISK.md)。
**协议没有为此加命令**:已经装好的机器拿不到新 agent,而 `exec` 两份实现早就都有。

`setres` 返回 `err setres rc=-2` 表示 `DISP_CHANGE_BADMODE`,即驱动没有暴露该模式。
**已验证**:驱动确实只接受固定模式表,故宿主侧做吸附(见坑 15)。

宿主在 socket 连上后会每 5 秒 `ping` 一次,直到 guest 侧有任何一行回应
为止 —— socket 通了只代表宿主到 QEMU 这一段通了,guest 里的 agent
可能还没登录、还没起。收到第一行后自动发 `modes` 取模式表。

## 会话侧助手的生命周期

两段式 agent 里,会话侧那半管光标和分辨率,必须待在用户的交互会话里。
它曾经挂在一个 cmd 窗口下面:Run 键指向 `run-agent-session.cmd`,
而 .cmd 由 cmd.exe 启动,那个控制台窗口会一直留在桌面上 ——
`powershell -WindowStyle Hidden` 救不了,PowerShell 继承的是已有的控制台,
不会自己开一个。用户把窗口一关,agent 就没了。

现在:

- **启动**:Run 键指向 `wscript.exe C:\ProgramData\Virtually\run-agent-session.vbs`,
  vbs 里 `Run ..., 0, False` 起 PowerShell,窗口样式 0,桌面上什么都不留。
- **复活**:SYSTEM 侧的 agent 发现管道连不上就自己把它拉起来。
  SYSTEM 在会话 0,直接起进程够不着用户桌面,所以走
  `WTSQueryUserToken` + `CreateProcessAsUser`(`agent.ps1` 里的 `VASession`),
  `lpDesktop` 设成 `winsta0\default`。VBoxService 和 vmtoolsd 也是这么做的。
- **不用计划任务**:`onlogon` 触发器在自动登录下实测不触发;
  按需 `schtasks /run` 又要求任务事先以正确的用户名注册,
  而装机脚本可能被以 SYSTEM 重跑,那时 `%USERNAME%` 是机器账户,任务就是废的。
- **发现**:宿主每 10 秒发一条 `sesping`。没有它,会话侧死了要等到下次
  改分辨率或换光标形状才被发现。
- **防重复**:脚本开头的 `Global\VirtuallyAgent_<role>` 互斥体。
  现在有两条启动路径,重复启动是常态,多出来的那个直接退出。
- **自检**:system 角色一启动就跑 `Repair-SessionLauncher` —— 确认 `.vbs` 内容正确、
  Run 键指向 `wscript.exe`、老的 `.cmd` 已删除,顺便杀掉这次开机被老 `.cmd`
  启起来的那个带窗口的实例。

「启动方式」的维护必须待在 `agent.ps1` 里,不能只写在 `install-agent.bat` 里 ——
后者只在装机时跑一次,之后再改启动方式就再也落不到已有的虚拟机上。
而 `run-agent-system.cmd` 每次开机都会从工具盘刷新 `agent.ps1`,
所以放在这里的逻辑是能跟着更新走的。

**已有虚拟机怎么升级**:挂着工具盘开一次机(`virtually run --vm <包> --tools`)。开机时 system 侧会把
`agent.ps1` 从工具盘同步到 C:,新的自检逻辑随即生效,不需要再手动跑
`install-agent.bat`。实测一台停在老 `.cmd` 上的虚拟机,这样开一次机之后
`.cmd` 已删除、`.vbs` 已就位、Run 键已改,桌面上没有任何控制台窗口。

实测:杀掉会话侧进程后,宿主 10 秒内探到,SYSTEM 侧拉起新进程并重新连上。
