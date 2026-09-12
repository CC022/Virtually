# Virtually Guest Agent
#
# 走 virtio-serial 命名端口与宿主通信,不依赖 guest 网络配置。
# 用 PowerShell 而非编译型语言:Windows ARM64 自带 PowerShell 5.1 与完整
# .NET Framework,因此宿主(macOS)上不需要任何 Windows 交叉编译工具链。
#
# 首要职责是改分辨率:Windows 的 viogpudo 是 display-only 驱动,
# 不响应主机侧的 EDID / VIRTIO_GPU_EVENT_DISPLAY 变更,
# 只能由 guest 内部调用 ChangeDisplaySettingsEx 来改 ——
# Parallels / VMware / spice-vdagent 都是这个做法。
#
# 协议:双向文本行
#   宿主 → guest :  setres <w> <h> | getres | modes | ping
#   guest → 宿主 :  ok ... | err ... | res <w> <h> | mode <w> <h> | pong | hello ...

# ---------------------------------------------------------------------------
# 两段式:同一个脚本,两个角色。
#
#   -Role system   以 SYSTEM 身份、开机(onstart)启动。持有 virtio-serial 端口,
#                  处理不需要交互桌面的命令(ping / exec / reboot)。
#                  不依赖任何人登录,也天然有权限打开那个端口。
#
#   -Role session  以普通权限、随 Explorer(注册表 Run 键)在用户会话里启动。
#                  处理**必须有交互桌面**的命令:改分辨率、光标。
#                  这些操作本来就不需要提权。
#
# 两者用命名管道 \\.\pipe\VirtuallyAgent 通信,system 侧是服务端。
#
# 为什么这么拆:之前把两件事塞进一个进程,于是它既要提权(端口 ACL 只给管理员)
# 又要在交互会话里(ChangeDisplaySettingsEx),只剩「带最高权限的登录触发计划任务」
# 一条路 —— 而那条路实测最脆:登录触发器在自动登录场景下不触发,任务存在、
# 手动运行立刻就活,查了很多轮也没查出原因。拆开之后每一段用的都是可靠触发方式。
# VirtualBox(VBoxService + VBoxTray)、VMware(vmsvc + vmusr)都是这个分法。
# ---------------------------------------------------------------------------
param([ValidateSet('system','session')][string]$Role = 'system')

# 注意:不要用 'Stop'。Add-Type 等步骤的非致命警告会让脚本直接退出,
# 且在计划任务里以隐藏窗口运行时看不到任何输出,极难排查。
$ErrorActionPreference = 'Continue'

# 无条件写启动日志,便于宿主侧从工具盘 raw 镜像里直接读取
$LogPath = $null
foreach ($d in 'D','E','F','G','H') {
    if (Test-Path "${d}:\agent.ps1") { $LogPath = "${d}:\agent-log.txt"; break }
}
# $script:Port 一旦就绪,日志同时经协议回传宿主 ——
# 隐藏窗口的计划任务看不到 stdout,写文件又要从 raw 镜像里挖,都太慢。
$script:Port = $null
function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    if ($LogPath) { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
    if ($script:Port) {
        try {
            $b = [System.Text.Encoding]::UTF8.GetBytes("log $m`n")
            $script:Port.Write($b, 0, $b.Length); $script:Port.Flush()
        } catch { }
    }
}
Log "VAAGENT 启动 pid=$PID"
$PortPath = '\\.\Global\org.virtually.agent'

# DEVMODE 的处理全部放在 C# 内部,PowerShell 只调简单方法。
#
# 原因:PowerShell 对含 ByValTStr 的结构体做 byref 封送不可靠 ——
# 实测 dmSize 正确(220,DEVMODEW)、会话正确(session=1)、
# 交互式运行与计划任务表现一致,但 EnumDisplaySettings 始终返回 False。
# 把结构体收进 C#,这些封送细节由编译器处理,不再经过 PowerShell 的值类型语义。

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class VADisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;   public short dmDriverVersion;
        public short dmSize;          public short dmDriverExtra;
        public int   dmFields;
        public int   dmPositionX;     public int   dmPositionY;
        public int   dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor;         public short dmDuplex;
        public short dmYResolution;   public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;     public int   dmBitsPerPel;
        public int   dmPelsWidth;     public int   dmPelsHeight;
        public int   dmDisplayFlags;  public int   dmDisplayFrequency;
        public int   dmICMMethod;     public int   dmICMIntent;
        public int   dmMediaType;     public int   dmDitherType;
        public int   dmReserved1;     public int   dmReserved2;
        public int   dmPanningWidth;  public int   dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ChangeDisplaySettingsExW(
        string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsW(string dev, int mode, ref DEVMODE dm);

    private const int ENUM_CURRENT = -1;
    private const int DM_PELSWIDTH  = 0x00080000;
    private const int DM_PELSHEIGHT = 0x00100000;
    private const int DM_DISPLAYFREQUENCY = 0x00400000;
    private const int CDS_UPDATEREGISTRY = 0x00000001;

    private static DEVMODE Blank() {
        DEVMODE dm = new DEVMODE();
        dm.dmDeviceName = new string('\0', 32);
        dm.dmFormName   = new string('\0', 32);
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return dm;
    }

    /// 返回 "w h 刷新率";失败返回 "0 0 0"
    public static string GetCurrent() {
        DEVMODE dm = Blank();
        if (!EnumDisplaySettingsW(null, ENUM_CURRENT, ref dm)) return "0 0 0";
        return dm.dmPelsWidth + " " + dm.dmPelsHeight + " " + dm.dmDisplayFrequency;
    }

    /// 枚举驱动暴露的全部模式,去重后以 "w h 刷新率" 每行一个返回。
    /// 必须带上刷新率:早期版本只按 w+h 去重,把同尺寸不同刷新率的模式合并了,
    /// 于是看不出驱动到底有没有 60Hz 以外的选择 —— 而这正是判断
    /// 「能不能让 guest 跑到 120Hz」的关键证据。
    public static string[] ListModes() {
        var seen = new System.Collections.Generic.List<string>();
        for (int i = 0; i < 2000; i++) {
            DEVMODE dm = Blank();
            if (!EnumDisplaySettingsW(null, i, ref dm)) break;
            string k = dm.dmPelsWidth + " " + dm.dmPelsHeight + " " + dm.dmDisplayFrequency;
            if (!seen.Contains(k)) seen.Add(k);
        }
        return seen.ToArray();
    }

    /// 单独尝试改刷新率(保持当前分辨率)
    public static int SetRefresh(int hz) {
        int[] attempts = new int[] { 0, CDS_UPDATEREGISTRY };
        int last = -99;
        foreach (int flags in attempts) {
            DEVMODE dm = Blank();
            if (!EnumDisplaySettingsW(null, ENUM_CURRENT, ref dm)) return -99;
            dm.dmDisplayFrequency = hz;
            dm.dmFields = DM_DISPLAYFREQUENCY;
            last = ChangeDisplaySettingsExW(null, ref dm, IntPtr.Zero, flags, IntPtr.Zero);
            if (last == 0) return 0;
        }
        return last;
    }

    /// 0 成功;-1 = DISP_CHANGE_FAILED;-2 = DISP_CHANGE_BADMODE(驱动未暴露该模式)
    ///
    /// 依次尝试:先动态切换(flags=0,非管理员即可),
    /// 再带 CDS_UPDATEREGISTRY 持久化(需要写 HKLM,非管理员会失败)。
    /// 之前统一用 CDS_UPDATEREGISTRY 导致非提权的 agent 一律返回 -1。
    public static int SetResolution(int w, int h) {
        int[] attempts = new int[] { 0, CDS_UPDATEREGISTRY };
        int last = -99;
        foreach (int flags in attempts) {
            DEVMODE dm = Blank();
            if (!EnumDisplaySettingsW(null, ENUM_CURRENT, ref dm)) return -99;
            dm.dmPelsWidth  = w;
            dm.dmPelsHeight = h;
            dm.dmFields     = DM_PELSWIDTH | DM_PELSHEIGHT;
            last = ChangeDisplaySettingsExW(null, ref dm, IntPtr.Zero, flags, IntPtr.Zero);
            if (last == 0) return 0;
        }
        return last;
    }
}
"@


# 宿主合成光标。
#
# viogpudo 不用硬件光标(`dpy_cursor_define` 从未被调用),光标是 Windows
# 画进帧缓冲的。这意味着光标被锁在 guest 的 64Hz,而且每动一下都要走完
# 「宿主输入 → guest 重绘 → 回传 → 合成」整个来回 —— 这是鼠标手感与
# 原生差距的主要来源。
#
# 做法:把系统光标全部换成全透明位图,让 guest 不再画光标;
# 宿主拿到当前**形状名**后用对应的 NSCursor 自己画,位置直接用宿主坐标。
# 光标从此完全脱离 guest 帧率。
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class VACursor {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetSystemCursor(IntPtr hcur, uint id);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint param, IntPtr pv, uint winIni);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreateCursor(IntPtr hInst, int xHot, int yHot,
                                              int nWidth, int nHeight,
                                              byte[] andPlane, byte[] xorPlane);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr LoadImage(IntPtr hInst, IntPtr name, uint type,
                                           int cx, int cy, uint load);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetCursorInfo(ref CURSORINFO ci);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO {
        public int cbSize; public int flags; public IntPtr hCursor; public POINT pt;
    }

    private const uint SPI_SETCURSORS = 0x0057;
    private const uint IMAGE_CURSOR   = 2;
    private const uint LR_SHARED      = 0x8000;
    private const int  SM_CXCURSOR    = 13;
    private const int  SM_CYCURSOR    = 14;
    private const int  CURSOR_SHOWING = 1;

    // 只处理仍在使用的标准光标。OCR_SIZE(32640)/OCR_ICON(32641) 已废弃,
    // 对它们调 SetSystemCursor 会失败并污染日志。
    private static readonly uint[] Ids = {
        32512, 32513, 32514, 32515, 32516,
        32642, 32643, 32644, 32645, 32646,
        32648, 32649, 32650, 32651
    };
    private static readonly string[] Names = {
        "arrow", "ibeam", "wait", "cross", "up",
        "sizenwse", "sizenesw", "sizewe", "sizens", "sizeall",
        "no", "hand", "appstarting", "help"
    };

    private static System.Collections.Generic.Dictionary<IntPtr, string> map =
        new System.Collections.Generic.Dictionary<IntPtr, string>();
    public static bool Hidden = false;

    /// AND 掩码全 1、XOR 掩码全 0 = 完全透明(屏幕内容原样保留)。
    private static IntPtr MakeBlank(int w, int h) {
        int bytes = (w / 8) * h;
        byte[] and = new byte[bytes];
        byte[] xor = new byte[bytes];
        for (int i = 0; i < bytes; i++) { and[i] = 0xFF; xor[i] = 0x00; }
        return CreateCursor(IntPtr.Zero, 0, 0, w, h, and, xor);
    }

    public static string HideAll() {
        int w = GetSystemMetrics(SM_CXCURSOR);
        int h = GetSystemMetrics(SM_CYCURSOR);
        if (w <= 0 || h <= 0) { w = 32; h = 32; }
        int ok = 0;
        for (int i = 0; i < Ids.Length; i++) {
            IntPtr blank = MakeBlank(w, h);
            if (blank == IntPtr.Zero) continue;
            // SetSystemCursor 会销毁传入的句柄,所以每个 id 都要单独造一个,
            // 而且事后不能拿它做比对。
            if (SetSystemCursor(blank, Ids[i])) ok++;
        }
        // 换完之后再问系统「现在这个 id 对应哪个句柄」,用它来识别当前形状。
        // 不能记我们自己造的句柄 —— 那些已经被销毁了。
        map.Clear();
        for (int i = 0; i < Ids.Length; i++) {
            IntPtr h2 = LoadImage(IntPtr.Zero, new IntPtr(Ids[i]), IMAGE_CURSOR, 0, 0, LR_SHARED);
            if (h2 != IntPtr.Zero && !map.ContainsKey(h2)) map[h2] = Names[i];
        }
        Hidden = ok > 0;
        return ok + "/" + Ids.Length + " size=" + w + "x" + h + " mapped=" + map.Count;
    }

    public static bool Restore() {
        map.Clear();
        Hidden = false;
        return SystemParametersInfo(SPI_SETCURSORS, 0, IntPtr.Zero, 0);
    }

    /// 返回 "形状名 是否可见"。识别不出来就报 arrow —— 宁可形状退化,
    /// 也不能让宿主没有光标可画。
    public static string Current() {
        CURSORINFO ci = new CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci)) return "arrow 1";
        int vis = ((ci.flags & CURSOR_SHOWING) != 0 && ci.hCursor != IntPtr.Zero) ? 1 : 0;
        string name;
        if (!map.TryGetValue(ci.hCursor, out name)) name = "arrow";
        return name + " " + vis;
    }
}
"@

function Get-CurrentModeString {
    $r = [VADisplay]::GetCurrent()
    Log "enum -> $r"
    return $r
}

# --- 连接 virtio-serial 端口 ---------------------------------------------
#
# 用 CreateFile P/Invoke 而不是 FileStream 直接开设备路径:
# .NET 的 FileStream 会对设备路径做一些文件语义的假设(取长度等),不可靠;
# qemu-guest-agent 在 Windows 上同样是走 CreateFile。
#
# 端口名候选:QEMU 的 name= 属性理论上决定符号链接名,但实测 guest 侧
# 设备描述是 vport0p1,故两者都试。

Add-Type @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public class VAIO {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern SafeFileHandle CreateFile(
        string name, uint access, uint share, IntPtr sec,
        uint creation, uint flags, IntPtr template);
}
"@

# PowerShell 把 0xC0000000 解析成 Int32 会溢出成负数,CreateFile 的
# UInt32 参数转换会失败,必须显式指定类型。
$GENERIC_RW    = [uint32]3221225472   # GENERIC_READ | GENERIC_WRITE
$OPEN_EXISTING = [uint32]3

function Open-Port {
    # 一次把路径与共享模式的组合全试一遍并记录结果 —— 盲猜代价太高。
    # error 5 = ACCESS_DENIED(设备在,但打不开)
    # error 2 = FILE_NOT_FOUND(这个名字不存在)
    $names  = @('org.virtually.agent', 'vport0p1')
    $shares = @([uint32]0, [uint32]3)   # 0=独占, 3=FILE_SHARE_READ|WRITE
    foreach ($name in $names) {
        foreach ($prefix in @('\\.\Global\', '\\.\')) {
            foreach ($share in $shares) {
                $path = "$prefix$name"
                $h = [VAIO]::CreateFile($path, $GENERIC_RW, $share, [IntPtr]::Zero,
                                        $OPEN_EXISTING, [uint32]0, [IntPtr]::Zero)
                if (-not $h.IsInvalid) {
                    $fs = New-Object System.IO.FileStream($h, [System.IO.FileAccess]::ReadWrite, 4096, $false)
                    $script:Port = $fs
                    Log "opened $path share=$share"
                    return $fs
                }
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Log "VAAGENT 失败 $path share=$share -> $err"
            }
        }
    }
    return $null
}

# 单实例。同一角色只允许一个实例:system 侧独占端口,session 侧独占管道。
# 用 Global\ 前缀 —— SYSTEM 与用户会话不在同一个命名空间下,不加前缀等于没有互斥。
$mutex = New-Object System.Threading.Mutex($false, "Global\VirtuallyAgent_$Role")
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Log "VAAGENT[$Role] 已有实例在运行,退出"; exit 0 }
Log "VAAGENT[$Role] 启动 pid=$PID"

$enc = New-Object System.Text.UTF8Encoding($false)
$PipeName = 'VirtuallyAgent'
$PipeEnd  = '<<end>>'

# 必须有交互桌面才能做的命令,一律交给 session 角色。
$SessionCommands = @('setres','getres','modes','setrefresh','hidecursor','getcursor','sesping','clipget','clipset')

# --- 命令实现 -------------------------------------------------------------
# 两个 Invoke-* 都返回「若干应答行」,不直接写任何通道 ——
# 这样同一段逻辑在 system(写 virtio-serial)和 session(写管道)下都能用。

function Invoke-SessionCommand($line) {
    $parts = $line -split '\s+'
    $out = New-Object System.Collections.ArrayList
    switch ($parts[0]) {
        # 宿主每 10 秒发一次,专门用来探会话侧还在不在 —— 不在的话 system 侧
        # 会顺手把它拉回来。没有这一下,会话侧死了要等到下次改分辨率才被发现。
        'sesping' { [void]$out.Add('ok sesping') }

        'getres' { [void]$out.Add("res $(Get-CurrentModeString)") }

        'modes' {
            foreach ($m in [VADisplay]::ListModes()) { [void]$out.Add("mode $m") }
            [void]$out.Add('ok modes')
        }

        'setres' {
            if ($parts.Count -lt 3) { [void]$out.Add('err setres needs w h') }
            else {
                $rc = [VADisplay]::SetResolution([int]$parts[1], [int]$parts[2])
                if ($rc -eq 0) {
                    [void]$out.Add('ok setres')
                    [void]$out.Add("res $(Get-CurrentModeString)")
                } else {
                    # -2 = DISP_CHANGE_BADMODE:该尺寸不在驱动模式表内。
                    # 宿主应先发 dpy_set_ui_info 把尺寸告诉 virtio-gpu 再重试。
                    [void]$out.Add("err setres rc=$rc")
                }
            }
        }

        'setrefresh' {
            if ($parts.Count -lt 2) { [void]$out.Add('err setrefresh needs hz') }
            else {
                $rc = [VADisplay]::SetRefresh([int]$parts[1])
                if ($rc -eq 0) {
                    [void]$out.Add('ok setrefresh')
                    [void]$out.Add("res $(Get-CurrentModeString)")
                } else { [void]$out.Add("err setrefresh rc=$rc") }
            }
        }

        'hidecursor' {
            if ($parts.Count -ge 2 -and $parts[1] -eq 'off') {
                $ok = [VACursor]::Restore()
                [void]$out.Add("ok hidecursor off restored=$ok")
            } else {
                $r = [VACursor]::HideAll()
                [void]$out.Add("ok hidecursor on $r")
                [void]$out.Add("cursor $([VACursor]::Current())")
            }
        }

        'getcursor' { [void]$out.Add("cursor $([VACursor]::Current())") }

        # 剪贴板只同步文本,内容 base64 走一行。剪贴板是每会话的,SYSTEM 在会话 0 看不到
        # 用户那份,所以必须在 session 角色里做。
        'clipget' {
            try {
                $t = Get-Clipboard -Raw -ErrorAction SilentlyContinue
                if ($null -eq $t) { $t = '' }
                $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$t))
                [void]$out.Add("clip $b64")
            } catch { [void]$out.Add('clip') }
        }
        'clipset' {
            try {
                if ($parts.Count -ge 2) {
                    $t = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
                    Set-Clipboard -Value $t
                } else { Set-Clipboard -Value '' }
                [void]$out.Add('ok clipset')
            } catch { [void]$out.Add("err clipset $($_.Exception.Message)") }
        }

        default { [void]$out.Add("err unknown $($parts[0])") }
    }
    return ,$out
}

function Invoke-SystemCommand($line) {
    $parts = $line -split '\s+'
    $out = New-Object System.Collections.ArrayList
    switch ($parts[0]) {
        'ping' { [void]$out.Add('pong') }

        'exec' {
            $cmd = $line.Substring(4).Trim()
            if ($cmd -eq '') { [void]$out.Add('err exec needs a command') }
            else {
                try {
                    $r = & cmd.exe /c $cmd 2>&1
                    foreach ($o in $r) { [void]$out.Add("out $o") }
                    [void]$out.Add("ok exec rc=$LASTEXITCODE")
                } catch { [void]$out.Add("err exec $($_.Exception.Message)") }
            }
        }

        # 从挂起状态恢复时,guest 的钟还停在存盘那一刻。挂一晚上再打开,
        # 时间就差一整夜 —— 界面上是错的,Windows 的计划任务也会跟着乱。
        # system 角色跑在 SYSTEM 下,有 SeSystemtimePrivilege,可以直接改。
        # 参数是 Unix 秒(UTC),与 guest 时区无关。以前是宿主本地时间字符串,
        # guest 时区一旦与宿主对不上(映射表里没有的时区退回 UTC),钟就被拨错一整个偏移。
        'settime' {
            $arg = $line.Substring(7).Trim()
            try {
                $t = [DateTimeOffset]::FromUnixTimeSeconds([int64]$arg).LocalDateTime
                Set-Date -Date $t | Out-Null
                [void]$out.Add("ok settime $arg -> $($t.ToString('yyyy-MM-dd HH:mm:ss'))")
            } catch {
                [void]$out.Add("err settime $($_.Exception.Message)")
            }
        }

        'reboot' { [void]$out.Add('ok reboot'); $script:PendingReboot = $true }

        default { [void]$out.Add("err unknown $($parts[0])") }
    }
    return ,$out
}

# --- 行读取 ---------------------------------------------------------------
# 自己拆行,不用 StreamReader:后者对设备/管道做文件语义假设(内部缓冲、按块预读),
# 在 virtio-serial 上会出现「写了不发、读了不返回」。

function New-LineBuffer { return [pscustomobject]@{ Pending = '' } }

function Read-Lines($stream, $buf, $state) {
    $n = $stream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { return $null }
    $state.Pending += $enc.GetString($buf, 0, $n)
    $lines = New-Object System.Collections.ArrayList
    while ($state.Pending.Contains("`n")) {
        $i = $state.Pending.IndexOf("`n")
        $l = $state.Pending.Substring(0, $i).Trim()
        $state.Pending = $state.Pending.Substring($i + 1)
        if ($l -ne '') { [void]$lines.Add($l) }
    }
    # 前置逗号防止 PowerShell 把集合展开。
    # 不加的话:空集合返回 $null(调用方会误判成对端断开,进而反复重连),
    # 单元素集合返回标量(调用方的 .Add() 直接不存在)。
    return ,$lines
}

function Write-Lines($stream, $lines) {
    foreach ($l in $lines) {
        $b = $enc.GetBytes("$l`n")
        $stream.Write($b, 0, $b.Length)
    }
    $stream.Flush()
}

# 写回宿主(只有 system 角色持有 virtio-serial 端口)
function Send-Line($text) {
    if ($null -eq $script:Port) { return }
    try {
        $b = $enc.GetBytes("$text`n")
        $script:Port.Write($b, 0, $b.Length)
        $script:Port.Flush()
        # 光标轮询是 20Hz,逐条记日志会把工具盘刷爆,也淹掉真正有用的信息
        if (-not $text.StartsWith('cursor ') -and -not $text.StartsWith('clip') -and $text -ne 'ok sesping') { Log "VAAGENT ->host: $text" }
    } catch {
        Log "VAAGENT 写失败: $($_.Exception.Message)"
    }
}

# --- session 角色 ---------------------------------------------------------
# 管道服务端。让会话侧当服务端有个好处:管道由普通用户创建,而 SYSTEM
# 能打开任何管道,所以不需要给管道配 ACL。反过来做就得处理安全描述符。

function Start-SessionRole {
    # 单实例由脚本开头那道 Global\VirtuallyAgent_session 互斥体把住 ——
    # 会话侧现在有两条启动路径(登录时的 Run 键、system 侧的救场),重复启动是常态,
    # 多出来的那个会在那里直接 exit。
    $buf = New-Object byte[] 4096
    while ($true) {
        $srv = $null
        try {
            $srv = New-Object System.IO.Pipes.NamedPipeServerStream(
                $PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte)
            Log "VAAGENT[session] 等待 system 侧连接"
            $srv.WaitForConnection()
            Log "VAAGENT[session] 已连接"
            $state = New-LineBuffer
            while ($true) {
                $lines = Read-Lines $srv $buf $state
                if ($null -eq $lines) { break }
                foreach ($l in $lines) {
                    $reply = Invoke-SessionCommand $l
                    [void]$reply.Add($PipeEnd)
                    Write-Lines $srv $reply
                }
            }
        } catch {
            Log "VAAGENT[session] 管道异常: $($_.Exception.Message)"
        } finally {
            if ($srv) { try { $srv.Dispose() } catch {} }
        }
        Start-Sleep -Milliseconds 500
    }
}

# --- system 角色 ----------------------------------------------------------

$script:Client = $null
$script:ClientBuf = New-Object byte[] 4096

function Connect-Session {
    if ($script:Client -and $script:Client.IsConnected) { return $true }
    if ($script:Client) { try { $script:Client.Dispose() } catch {}; $script:Client = $null }
    try {
        $c = New-Object System.IO.Pipes.NamedPipeClientStream(
            '.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        # 短超时:会话侧没起来时要快速失败,不能把宿主的命令卡住
        $c.Connect(1500)
        $script:Client = $c
        Log "VAAGENT[system] 已连上 session 侧"
        return $true
    } catch { return $false }
}

# 会话侧没起来就去把它拉起来。
#
# 它可能压根没启动(用户还没登录完),也可能被用户关掉了。SYSTEM 在会话 0,
# 直接 Start-Process 起来的进程也在会话 0,够不着用户桌面 —— 必须拿用户的令牌
# 用 CreateProcessAsUser 开到交互会话里去。这正是 VBoxService、vmtoolsd 的做法。
#
# 不走计划任务:onlogon 触发器在自动登录下实测不触发,而按需 `schtasks /run`
# 又要求任务事先以正确的用户名注册 —— 装机脚本要是以 SYSTEM 重跑过一次,
# 那个用户名就是错的。令牌这条路不依赖任何预先登记的东西。
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class VASession {
    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(IntPtr existing, uint access, IntPtr attrs,
        int impersonationLevel, int tokenType, out IntPtr dup);
    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool DestroyEnvironmentBlock(IntPtr env);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUser(IntPtr token, string app, string cmd,
        IntPtr procAttrs, IntPtr threadAttrs, bool inherit, uint flags, IntPtr env,
        string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public int cb; public string reserved; public string desktop; public string title;
        public int x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute;
        public int flags; public short showWindow; public short reserved2;
        public IntPtr reserved3, stdInput, stdOutput, stdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION { public IntPtr process, thread; public int pid, tid; }

    private const uint MAXIMUM_ALLOWED = 0x02000000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint CREATE_NO_WINDOW = 0x08000000;

    /// 返回新进程 pid;失败返回 -(Win32 错误码),0 表示没有活动的交互会话。
    public static int Launch(string commandLine) {
        uint sid = WTSGetActiveConsoleSessionId();
        if (sid == 0xFFFFFFFF) { return 0; }

        IntPtr token, dup = IntPtr.Zero, env = IntPtr.Zero;
        if (!WTSQueryUserToken(sid, out token)) { return -Marshal.GetLastWin32Error(); }
        try {
            // SecurityImpersonation(2) / TokenPrimary(1)
            if (!DuplicateTokenEx(token, MAXIMUM_ALLOWED, IntPtr.Zero, 2, 1, out dup)) {
                return -Marshal.GetLastWin32Error();
            }
            CreateEnvironmentBlock(out env, dup, false);

            STARTUPINFO si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(si);
            si.desktop = "winsta0\\default";   // 不指定就开不到用户桌面上
            PROCESS_INFORMATION pi;
            bool ok = CreateProcessAsUser(dup, null, commandLine, IntPtr.Zero, IntPtr.Zero,
                false, CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, env, null, ref si, out pi);
            if (!ok) { return -Marshal.GetLastWin32Error(); }
            CloseHandle(pi.process); CloseHandle(pi.thread);
            return pi.pid;
        } finally {
            if (env != IntPtr.Zero) { DestroyEnvironmentBlock(env); }
            if (dup != IntPtr.Zero) { CloseHandle(dup); }
            CloseHandle(token);
        }
    }
}
"@

$script:LastRevive = [DateTime]::MinValue

function Revive-Session {
    if (([DateTime]::UtcNow - $script:LastRevive).TotalSeconds -lt 15) { return }
    $script:LastRevive = [DateTime]::UtcNow
    $cmd = 'wscript.exe "' + $env:ProgramData + '\Virtually\run-agent-session.vbs"'
    try {
        $r = [VASession]::Launch($cmd)
        if ($r -gt 0) { Log "VAAGENT[system] 已拉起会话侧 pid=$r" }
        elseif ($r -eq 0) { Log "VAAGENT[system] 没有活动的交互会话,等用户登录" }
        else { Log "VAAGENT[system] 拉起会话侧失败 win32=$(-$r)" }
    } catch {
        Log "VAAGENT[system] 拉起会话侧异常: $($_.Exception.Message)"
    }
}

function Invoke-ViaSession($line) {
    if (-not (Connect-Session)) {
        Revive-Session
        return ,@("err no session helper")
    }
    try {
        Write-Lines $script:Client @($line)
        $state = New-LineBuffer
        $out = New-Object System.Collections.ArrayList
        while ($true) {
            $lines = Read-Lines $script:Client $script:ClientBuf $state
            if ($null -eq $lines) { throw "session 侧断开" }
            foreach ($l in $lines) {
                if ($l -eq $PipeEnd) { return ,$out }
                [void]$out.Add($l)
            }
        }
    } catch {
        Log "VAAGENT[system] 转发失败: $($_.Exception.Message)"
        try { $script:Client.Dispose() } catch {}
        $script:Client = $null
        Revive-Session
        return ,@("err session helper lost")
    }
}

# 启动器自检。
#
# install-agent.bat 只在装机时跑一次,之后再改启动方式就再也落不到已有的虚拟机上了。
# 所以把「会话侧怎么启动」这件事的维护搬到 agent 自己身上 —— agent.ps1 每次开机
# 都会从工具盘刷新,这段跟着一起更新。
#
# 具体要保证的:Run 键指向 wscript 跑 .vbs(窗口样式 0,桌面上不留控制台窗口),
# 而不是老的 .cmd —— .cmd 由 cmd.exe 启动,那个黑窗口会一直挂在桌面上,
# 用户一关 agent 就没了。
function Repair-SessionLauncher {
    $dir = Join-Path $env:ProgramData 'Virtually'
    $vbs = Join-Path $dir 'run-agent-session.vbs'
    $old = Join-Path $dir 'run-agent-session.cmd'
    $want = 'CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -File ' +
            (Join-Path $dir 'agent.ps1') + ' -Role session", 0, False'
    try {
        $cur = if (Test-Path $vbs) { (Get-Content $vbs -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
        if ($cur -ne $want) {
            Set-Content -Path $vbs -Value $want -Encoding ASCII
            Log "VAAGENT[system] 已写入 run-agent-session.vbs"
        }
        $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
        $wantRun = "wscript.exe $vbs"
        $curRun = (Get-ItemProperty -Path $key -Name VirtuallyAgent -ErrorAction SilentlyContinue).VirtuallyAgent
        if ($curRun -ne $wantRun) {
            Set-ItemProperty -Path $key -Name VirtuallyAgent -Value $wantRun
            Log "VAAGENT[system] 已把 Run 键改成 $wantRun"
        }
        if (Test-Path $old) {
            Remove-Item $old -Force -ErrorAction SilentlyContinue
            Log "VAAGENT[system] 已删除旧的 run-agent-session.cmd"
            # 这次开机很可能已经被老 .cmd 启起来了,连窗口一起。杀掉,
            # 随后 Revive-Session 会用新路径把它无窗口地拉回来。
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like '*-Role session*' } |
                ForEach-Object {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    Log "VAAGENT[system] 杀掉带窗口的会话侧 pid=$($_.ProcessId)"
                }
        }
    } catch {
        Log "VAAGENT[system] 启动器自检失败: $($_.Exception.Message)"
    }
}

function Start-SystemRole {
    Repair-SessionLauncher
    $port = $null
    $tries = 0
    while ($null -eq $port) {
        $port = Open-Port
        if ($null -eq $port) {
            $tries++
            $wait = [Math]::Min(30, 2 * $tries)
            if ($tries -le 3 -or $tries % 20 -eq 0) {
                Log "VAAGENT[system] 端口未就绪,第 $tries 次重试(等 $wait 秒)"
            }
            Start-Sleep -Seconds $wait
        }
    }
    $script:Port = $port

    $buf = New-Object byte[] 4096
    $state = New-LineBuffer
    while ($true) {
        $lines = $null
        try { $lines = Read-Lines $port $buf $state }
        catch { Log "VAAGENT[system] 读失败: $($_.Exception.Message)" }

        if ($null -eq $lines) {
            # 宿主 app 重启会让这端读到 EOF。不退出,重新等它连回来。
            try { $port.Dispose() } catch {}
            Log "VAAGENT[system] 通道断开,等待宿主重连"
            $port = $null
            while ($null -eq $port) { Start-Sleep -Seconds 2; $port = Open-Port }
            $script:Port = $port
            $state = New-LineBuffer
            continue
        }

        foreach ($l in $lines) {
            # getcursor 20Hz、sesping 每 10 秒,逐条记会把日志刷爆
            if ($l -ne 'getcursor' -and $l -ne 'sesping' -and $l -ne 'clipget' -and -not $l.StartsWith('clipset ')) { Log "VAAGENT[system] <-host: $l" }
            $verb = ($l -split '\s+')[0]
            $reply = if ($SessionCommands -contains $verb) { Invoke-ViaSession $l }
                     else { Invoke-SystemCommand $l }
            foreach ($r in $reply) { Send-Line $r }
            if ($script:PendingReboot) {
                Start-Sleep -Milliseconds 300
                & shutdown.exe /r /t 0
                $script:PendingReboot = $false
            }
        }
    }
}

# --- 入口 -----------------------------------------------------------------

if ($Role -eq 'session') {
    try { Start-SessionRole }
    finally {
        # 会话结束前务必还原系统光标。否则 guest 会一直没有光标可用 ——
        # 这比「鼠标不够跟手」严重得多。
        if ([VACursor]::Hidden) {
            $r = [VACursor]::Restore()
            Log "VAAGENT[session] 退出前还原系统光标 restored=$r"
        }
    }
} else {
    Start-SystemRole
}
Log "VAAGENT[$Role] 退出"
