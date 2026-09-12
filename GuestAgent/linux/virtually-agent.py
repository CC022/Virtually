#!/usr/bin/env python3
"""Virtually Guest Agent(Linux)

与 Windows 的 agent.ps1 **同一份文本协议、同样的两段式**,所以宿主侧一行代码都不用分叉。
用 python3:Ubuntu 桌面版预装它和 python3-gi(GNOME 自己要用),不需要联网装任何包。

两个角色:

  --role system   systemd 系统服务,root。持有 virtio-serial 端口
                  (/dev/virtio-ports/org.virtually.agent,udev 按 QEMU 的 name= 建的符号链接)。
                  处理不需要桌面的命令:ping / settime / exec / reboot。
                  需要桌面的转发给会话侧。

  --role session  systemd 用户服务,跟着 graphical-session.target 起。
                  处理**必须有桌面**的:分辨率(Mutter 的 D-Bus)、剪贴板。
                  这些本来就不需要 root。

为什么这么拆:和 Windows 上一样的理由 —— 端口只有 root 能开,而改分辨率必须在用户会话里。
两者用 $XDG_RUNTIME_DIR/virtually-agent.sock 通信:**会话侧建、system 侧连**。
方向不能反 —— 普通用户在 /run 下建不了文件(实测 PermissionError),而 root 连谁的 socket 都行。

协议(与 docs/GUEST-AGENT.md 一致):
  宿主 → guest :  ping | settime <unix秒> | exec <命令> | reboot
                   setres <w> <h> | getres | modes | setrefresh <hz>
                   hidecursor on|off | getcursor | sesping | clipget | clipset <base64>
  guest → 宿主 :  ok … | err … | pong | out <一行> | res <w> <h> <hz> | mode <w> <h> <hz>
                   cursor <形状> <可见> | clip <base64> | log <一行>
"""

import base64
import glob
import os
import re
import socket
import subprocess
import sys
import threading
import time

PORT_PATHS = ["/dev/virtio-ports/org.virtually.agent", "/dev/vport2p1", "/dev/vport0p1"]
# 两侧通信的 socket。**必须放 /run/user/<uid>/**:会话侧是普通用户,建不了 /run 下的文件
# (实测 PermissionError);而 root 连任何人的 socket 都没问题,所以方向只能是
# 「用户建、root 连」。system 侧按通配去找,不写死 uid。
IPC_NAME = "virtually-agent.sock"
IPC_DIR_GLOB = "/run/user/*/"
# 需要交互桌面的命令,一律转给会话侧
SESSION_COMMANDS = {"setres", "getres", "modes", "setrefresh",
                    "hidecursor", "getcursor", "sesping", "clipget", "clipset"}


def log(msg):
    sys.stderr.write("[va] %s\n" % msg)
    sys.stderr.flush()


# ---------------------------------------------------------------- system 角色

class SystemAgent:
    """持有 virtio-serial 端口,转发会话命令。"""

    def __init__(self):
        self.port = None

    def open_port(self):
        """端口要等 virtio-serial 枚举完才出现,而且宿主重连会让这端读到 EOF。
        所以无限重试、退避到 30 秒封顶 —— 与 Windows 侧同一个结论(见 GUEST-AGENT.md 坑 13)。"""
        tries = 0
        while True:
            for p in PORT_PATHS:
                if os.path.exists(p):
                    try:
                        # 无缓冲、可读可写。不能用 open(p, "r+") 的行缓冲:
                        # 写了不 flush 宿主就收不到。
                        return open(p, "r+b", buffering=0)
                    except OSError as e:
                        log("打不开 %s: %s" % (p, e))
            tries += 1
            wait = min(30, 2 * tries)
            if tries <= 3 or tries % 20 == 0:
                log("端口未就绪,第 %d 次重试(等 %d 秒)" % (tries, wait))
            time.sleep(wait)

    def send(self, line):
        if self.port is None:
            return
        try:
            self.port.write((line + "\n").encode("utf-8"))
            self.port.flush()
        except OSError as e:
            log("写失败: %s" % e)

    def run(self):
        while True:
            self.port = self.open_port()
            log("端口已打开")
            pending = b""
            while True:
                try:
                    chunk = self.port.read(4096)
                except OSError as e:
                    log("读失败: %s" % e)
                    chunk = b""
                if not chunk:
                    # 宿主 app 重启会让这端读到 EOF。不退出,重新等它连回来 ——
                    # 否则「重开一次 app」就等于 agent 永久失联。
                    log("通道断开,等宿主重连")
                    try:
                        self.port.close()
                    except OSError:
                        pass
                    self.port = None
                    time.sleep(2)
                    break
                pending += chunk
                while b"\n" in pending:
                    raw, pending = pending.split(b"\n", 1)
                    line = raw.decode("utf-8", "replace").strip()
                    if line:
                        self.handle(line)

    def handle(self, line):
        verb = line.split(None, 1)[0]
        if verb in SESSION_COMMANDS:
            for reply in self.via_session(line):
                self.send(reply)
            return
        for reply in self.local(line):
            self.send(reply)

    def local(self, line):
        parts = line.split()
        verb = parts[0]
        if verb == "ping":
            return ["pong"]
        if verb == "settime":
            # 参数是 Unix 秒(UTC),与 guest 时区无关
            arg = line[len("settime"):].strip()
            if not arg.isdigit():
                return ["err settime needs unix seconds"]
            try:
                subprocess.run(["date", "-u", "-s", "@" + arg], check=True, capture_output=True)
            except Exception as e:
                return ["err settime %s" % e]
            # 回写硬件时钟只是顺手,**失败不能让整条命令失败**:精简版 Ubuntu 里没有 hwclock。
            for cmd in (["hwclock", "--systohc"], ["/usr/sbin/hwclock", "--systohc"]):
                try:
                    if subprocess.run(cmd, check=False, capture_output=True).returncode == 0:
                        break
                except Exception:
                    continue
            return ["ok settime " + arg]
        if verb == "exec":
            cmd = line[len("exec"):].strip()
            if not cmd:
                return ["err exec needs a command"]
            try:
                r = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, timeout=120)
                out = (r.stdout + r.stderr).decode("utf-8", "replace")
                lines = ["out " + l for l in out.splitlines()]
                return lines + ["ok exec rc=%d" % r.returncode]
            except Exception as e:
                return ["err exec %s" % e]
        if verb == "reboot":
            threading.Timer(0.3, lambda: subprocess.run(
                ["systemctl", "reboot", "--ignore-inhibitors"], check=False)).start()
            return ["ok reboot"]
        return ["err unknown " + verb]

    def via_session(self, line):
        """转给会话侧。连不上就回 `err no session helper` —— 宿主见到这句会等它起来再重试。"""
        import glob
        last = None
        # 可能有多个 /run/user/*(切过用户),挨个试
        for path in sorted(glob.glob(IPC_DIR_GLOB + IPC_NAME)):
            try:
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(5)
                s.connect(path)
                s.sendall((line + "\n").encode("utf-8"))
                buf = b""
                while b"<<end>>\n" not in buf:
                    d = s.recv(65536)
                    if not d:
                        raise OSError("会话侧断开")
                    buf += d
                s.close()
                return [l for l in buf.decode("utf-8", "replace").split("\n")
                        if l and l != "<<end>>"]
            except Exception as e:
                last = e
        if last:
            log("转发失败: %s" % last)
        return ["err no session helper"]


# ------------------------------------------------------------------ 剪贴板

class X11Clipboard:
    """经 Xwayland 读写剪贴板。

    **Wayland 这条路对后台进程是死的,两个方向都是**(Ubuntu 26.04 的 GNOME 上实测):
      * 写:wl_data_device.set_selection 要带一个输入事件的 serial,
        没有窗口、没收到过键鼠事件的进程拿不到。GTK4 的 clipboard.set() 照样返回,
        但只改了进程内的值 —— 在终端里 Ctrl+Shift+V 什么都粘不出来
      * 读:Mutter 只把选区发给**有键盘焦点**的客户端,另开一个进程读,得到「剪贴板为空」
    早先的「实测双向都通」是自己写、自己读,读到的是 GTK 进程内缓存 —— 验证方法错了。

    wl-clipboard 在 GNOME 上是靠临时弹一个窗口抢焦点做到的,每秒轮询一次就是每秒闪一次焦点,
    所以即使用户装了它也不用。

    X11 没有焦点限制,而 Mutter 会把 X 的 CLIPBOARD 与 Wayland 选区双向桥接
    (实测:X 客户端写入,原生 Wayland 的终端能粘出来;终端里复制,X 客户端能读到,中文完好)。
    Xwayland 是按需启动的,第一次连它会拉起来,之后我们一直连着。

    **进程必须常驻**:谁拥有选区谁负责在别人粘贴时供数据,我们退出了剪贴板就空了。
    GTK 的对象只在自己那条线程里碰,别的线程经 GLib.idle_add 投递、用 Event 等结果。
    """

    TIMEOUT = 3

    def __init__(self):
        self._ready = threading.Event()
        self._error = None
        self._cb = None
        self._text = ""
        # 选区换了主人就置脏,下次 clipget 才真的去读。宿主每秒问一次,
        # 不缓存的话就是每秒让当前拥有者(可能是某个卡住的应用)供一次数据。
        self._dirty = True
        threading.Thread(target=self._main, name="clipboard", daemon=True).start()
        if not self._ready.wait(15):
            raise OSError("剪贴板线程 15 秒没起来")
        if self._error:
            raise self._error

    @staticmethod
    def _find_xauthority():
        """Mutter 给 Xwayland 的授权文件。用户服务的环境里未必有 XAUTHORITY
        (取决于它和 gnome-shell 谁先起),没有就按 Mutter 的命名去运行目录里找。"""
        cur = os.environ.get("XAUTHORITY")
        if cur and os.path.exists(cur):
            return cur
        run_dir = os.environ.get("XDG_RUNTIME_DIR") or ("/run/user/%d" % os.getuid())
        found = sorted(glob.glob(os.path.join(run_dir, ".mutter-Xwaylandauth.*")),
                       key=os.path.getmtime)
        return found[-1] if found else None

    def _main(self):
        try:
            os.environ["GDK_BACKEND"] = "x11"
            os.environ.setdefault("DISPLAY", ":0")
            xauth = self._find_xauthority()
            if xauth:
                os.environ["XAUTHORITY"] = xauth
            import gi
            gi.require_version("Gtk", "3.0")
            gi.require_version("Gdk", "3.0")
            from gi.repository import Gtk, Gdk   # 导入时 PyGObject 就做了 init_check
            if Gdk.Display.get_default() is None:
                raise OSError("连不上 Xwayland(DISPLAY=%s XAUTHORITY=%s)"
                              % (os.environ.get("DISPLAY"), xauth))
            self._cb = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
            self._cb.connect("owner-change", self._owner_changed)
        except Exception as e:
            self._error = e
            self._ready.set()
            return
        self._ready.set()
        Gtk.main()

    def _owner_changed(self, *args):
        self._dirty = True

    def _call(self, fn):
        """在 GTK 线程里跑 fn(box, done),等它调 done.set()。"""
        from gi.repository import GLib
        box = {}
        done = threading.Event()

        def run():
            try:
                fn(box, done)
            except Exception as e:
                box["error"] = e
                done.set()
            return False

        GLib.idle_add(run)
        if not done.wait(self.TIMEOUT):
            raise TimeoutError("剪贴板 %d 秒没响应" % self.TIMEOUT)
        if "error" in box:
            raise box["error"]
        return box.get("value")

    def set_text(self, text):
        def fn(box, done):
            self._cb.set_text(text, -1)
            done.set()
        self._call(fn)

    def get_text(self):
        def fn(box, done):
            if not self._dirty:
                box["value"] = self._text
                done.set()
                return
            self._dirty = False

            def got(_cb, text, *rest):
                # 图片、文件之类不是文本 → None,回空串;宿主不会拿空串去清自己的剪贴板
                self._text = text or ""
                box["value"] = self._text
                done.set()

            self._cb.request_text(got)

        try:
            return self._call(fn)
        except TimeoutError:
            self._dirty = True      # 拥有者没应答,下次再读,别把旧值当新值缓存着
            raise


# --------------------------------------------------------------- session 角色

class SessionAgent:
    """管必须有交互桌面的那些命令。服务端是它自己(root 能连任何 socket)。"""

    def __init__(self):
        self.scale_applied = False
        self._clipboard = None
        self.tune_desktop()

    # ---- 开机先把几个对虚拟机不合适的默认设置关掉 ----
    #
    # 虚拟机会自己息屏、自己锁屏。息屏时 virtio-gpu 的 scanout 被关掉,
    # QEMU 画面变成 "Display output is not active" —— 从宿主看就是**一台死机的虚拟机**
    # (我自己就这么误判过一次)。锁屏更烦:自动登录进去了,五分钟后又要输密码。
    # 用 gsettings 而不是 dconf 系统库:会话侧本来就跑在用户会话里,
    # 而且换了 agent 之后对**已经装好的**虚拟机也生效。
    def tune_desktop(self):
        for schema, key, value in [
            ("org.gnome.desktop.session", "idle-delay", "0"),                 # 永不息屏
            ("org.gnome.desktop.screensaver", "lock-enabled", "false"),       # 不锁屏
            ("org.gnome.desktop.screensaver", "idle-activation-enabled", "false"),
            ("org.gnome.settings-daemon.plugins.power", "sleep-inactive-ac-type", "'nothing'"),
        ]:
            try:
                subprocess.run(["gsettings", "set", schema, key, value],
                               check=False, capture_output=True, timeout=10)
            except Exception as e:
                log("设 %s %s 失败: %s" % (schema, key, e))

    # ---- Mutter:分辨率与缩放 ----
    #
    # GNOME/Wayland 下改分辨率只能走 Mutter 的 D-Bus,gsettings 里没有这一项;
    # 缩放同理(存在 monitors.xml 里,不是 gsettings)。
    # 宿主先发 dpy_set_ui_info,virtio-gpu 的 EDID 里就有了那个尺寸,
    # 这边再 ApplyMonitorsConfig 选中它。

    def _display_config(self):
        from gi.repository import Gio
        return Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None,
            "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig", None)

    def _current_state(self):
        proxy = self._display_config()
        return proxy.call_sync("GetCurrentState", None,
                               __import__("gi").repository.Gio.DBusCallFlags.NONE,
                               -1, None).unpack()

    def modes(self):
        try:
            serial, monitors, logical, props = self._current_state()
            out = []
            for spec, mlist, mprops in monitors:
                for mode in mlist:
                    mid, w, h, refresh = mode[0], mode[1], mode[2], mode[3]
                    out.append("mode %d %d %d" % (w, h, round(refresh)))
            return out + ["ok modes"]
        except Exception as e:
            return ["err modes %s" % e]

    def getres(self):
        try:
            serial, monitors, logical, props = self._current_state()
            for spec, mlist, mprops in monitors:
                for mode in mlist:
                    if "is-current" in mode[6] and mode[6]["is-current"]:
                        return ["res %d %d %d" % (mode[1], mode[2], round(mode[3]))]
            return ["err getres no current mode"]
        except Exception as e:
            return ["err getres %s" % e]

    @staticmethod
    def _pick_scale(mode, target):
        """在 Mutter 自己给出的 supported-scales 里挑不超过 target 的最大值。
        **不能凭空给 2**:小分辨率下 Mutter 直接拒绝
        (实测 1280x800 给 2 → "Scale 2 not valid for resolution 1280x800"),
        因为逻辑尺寸会小到没法用。窗口大的时候 2 倍才在列表里。
        mode 的形状是 (id, w, h, refresh, preferred_scale, supported_scales, props)。"""
        try:
            supported = [float(s) for s in mode[5]]
        except Exception:
            supported = []
        usable = [s for s in supported if s <= target + 1e-6]
        if usable:
            return max(usable)
        return float(mode[4]) if len(mode) > 4 else 1.0

    def setres(self, w, h, scale=None):
        """选中 w×h 的模式。scale 为 None 时按目标缩放自动挑一个 Mutter 认的。"""
        try:
            from gi.repository import GLib, Gio
            proxy = self._display_config()
            serial, monitors, logical, props = self._current_state()
            if not monitors:
                return ["err setres no monitor"]
            spec, mlist, mprops = monitors[0]
            connector = spec[0]
            want = None
            for mode in mlist:
                if mode[1] == w and mode[2] == h:
                    # 同尺寸有多个刷新率时取最高的
                    if want is None or mode[3] > want[3]:
                        want = mode
            if want is None:
                # 驱动还没把这个尺寸并进模式表 —— 宿主会再发一次 ui_info 后重试
                return ["err setres rc=-2"]
            if scale is None:
                scale = self._pick_scale(want, self.target_scale())
            # ApplyMonitorsConfig(serial, method=1 临时/2 持久, logical_monitors, properties)
            # **必须用临时**:持久模式下 GNOME 会弹「保留这些显示设置吗?」,没人点就在 15 秒后还原 ——
            # 实测分辨率还在,2 倍缩放被退回 1 倍,每拖一次窗口弹一次。
            # 不写 monitors.xml 也没关系:每次开机宿主都会按窗口大小重新 setres。
            lm = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (
                serial, 1,
                [(0, 0, float(scale), 0, True, [(connector, want[0], {})])],
                {}))
            proxy.call_sync("ApplyMonitorsConfig", lm, Gio.DBusCallFlags.NONE, -1, None)
            return ["ok setres"] + self.getres()
        except Exception as e:
            return ["err setres %s" % e]

    @staticmethod
    def target_scale():
        """想要的缩放倍数。Mac 基本都是 Retina,而宿主把 guest 分辨率设成**物理像素**,
        所以 100% 下所有东西只有一半大。窗口够大时 Mutter 会允许 2 倍。"""
        try:
            return float(os.environ.get("VA_SCALE_PERCENT", "200")) / 100.0
        except ValueError:
            return 2.0

    def apply_initial_scale(self):
        """首次连上按当前分辨率挑一个能用的缩放(对应 Windows 那边写 LogPixels 的位置)。
        小窗口下 Mutter 只认 1 倍,那就 1 倍 —— 窗口拖大之后 setres 会再挑一次。"""
        if self.scale_applied:
            return []
        self.scale_applied = True
        try:
            serial, monitors, logical, props = self._current_state()
            for spec, mlist, mprops in monitors:
                for mode in mlist:
                    if mode[6].get("is-current"):
                        return self.setres(mode[1], mode[2])
        except Exception as e:
            return ["log 初始缩放没设上: %s" % e]
        return []

    # ---- 剪贴板 ----
    #
    # 只同步文本。实现在 X11Clipboard 里,见那边的注释:为什么走 Xwayland 而不是 Wayland。

    def _x11_clipboard(self):
        if self._clipboard is None:
            self._clipboard = X11Clipboard()
        return self._clipboard

    def clipget(self):
        try:
            text = self._x11_clipboard().get_text()
            return ["clip " + base64.b64encode(text.encode("utf-8")).decode("ascii")]
        except Exception as e:
            log("clipget 失败: %s" % e)
            return ["err unknown clipget"]      # 宿主见到这句就停掉轮询,不再每秒刷错误

    def clipset(self, b64):
        data = base64.b64decode(b64) if b64 else b""
        try:
            self._x11_clipboard().set_text(data.decode("utf-8", "replace"))
            return ["ok clipset"]
        except Exception as e:
            log("clipset 失败: %s" % e)
            return ["err unknown clipset"]

    # ---- 分发 ----

    def handle(self, line):
        parts = line.split()
        verb = parts[0]
        if verb == "sesping":
            return ["ok sesping"]
        if verb == "modes":
            # 取模式表的同时把初始缩放设上 —— 宿主 agent 一就绪就会问模式表
            return self.modes() + self.apply_initial_scale()
        if verb == "getres":
            return self.getres()
        if verb == "setres":
            if len(parts) < 3:
                return ["err setres needs w h"]
            return self.setres(int(parts[1]), int(parts[2]))
        if verb == "setrefresh":
            # Mutter 的刷新率跟着模式走,不单独设
            return ["ok setrefresh"]
        if verb in ("hidecursor", "getcursor"):
            # Linux 的 virtio-gpu 驱动自带硬件光标,宿主直接拿到位图,
            # 不需要 Windows 那套「把系统光标换成透明的再自己画」。
            return ["ok " + verb]
        if verb == "clipget":
            return self.clipget()
        if verb == "clipset":
            return self.clipset(parts[1] if len(parts) > 1 else "")
        return ["err unknown " + verb]

    def run(self):
        # XDG_RUNTIME_DIR 就是 /run/user/<uid>,由 systemd 的用户实例给出;
        # 万一没有(手工跑)就自己拼。
        run_dir = os.environ.get("XDG_RUNTIME_DIR") or ("/run/user/%d" % os.getuid())
        sock_path = os.path.join(run_dir, IPC_NAME)
        try:
            os.unlink(sock_path)
        except OSError:
            pass
        srv = socket.socket(socket.AF_UNIX)
        srv.bind(sock_path)
        os.chmod(sock_path, 0o600)   # 只有本人和 root,root 本来就不受限
        srv.listen(4)
        log("IPC socket: %s" % sock_path)
        log("会话侧就绪,等 system 侧连接")
        while True:
            conn, _ = srv.accept()
            try:
                buf = b""
                while b"\n" not in buf:
                    d = conn.recv(4096)
                    if not d:
                        break
                    buf += d
                line = buf.decode("utf-8", "replace").strip()
                if line:
                    replies = self.handle(line) + ["<<end>>"]
                    conn.sendall(("\n".join(replies) + "\n").encode("utf-8"))
            except Exception as e:
                log("会话侧处理异常: %s" % e)
            finally:
                try:
                    conn.close()
                except OSError:
                    pass


def main():
    role = "system"
    if "--role" in sys.argv:
        role = sys.argv[sys.argv.index("--role") + 1]
    log("启动 role=%s pid=%d" % (role, os.getpid()))
    if role == "session":
        SessionAgent().run()
    else:
        SystemAgent().run()


if __name__ == "__main__":
    main()
