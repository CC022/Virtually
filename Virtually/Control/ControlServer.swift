// 调试控制通道:`virtually send <命令>` 通过 Unix socket 把一行命令送进 app。
//
// 这条通道是整个项目的诊断命脉:时区导致计划任务不触发、光标尺寸算错、
// agent 通道写阻塞、注册表子键序号不固定 —— 这些问题全是靠它定位的。
// 命令的结果照旧打到 stdout(`virtually run` 把它写进日志),命令行工具读日志拿结果 ——
// 很多结果本来就是异步的(agent 的回复、快照完成),没法在一次请求里等到。
//
// 只在启动参数带 `-ControlSocket` 时开启,只控制启动参数指定的那一台虚拟机。

import AppKit
import VirtuallyKit

@MainActor
final class ControlServer {
    private let path: String
    private let session: VMSession
    private var listenFD: Int32 = -1

    init?(path: String, session: VMSession) {
        self.path = path
        self.session = session
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
            return true
        }
        let bound = ok && withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(fd, 4) == 0 else {
            print("[control] 无法监听 \(path):\(String(cString: strerror(errno)))")
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        listenFD = fd
        print("[control] 调试控制通道:\(path)")
        let handler: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.handle(line) }
        }
        Thread.detachNewThread {
            while true {
                let conn = accept(fd, nil, nil)
                if conn < 0 { if errno == EINTR { continue }; return }
                Self.readLines(from: conn, handler)
            }
        }
    }

    /// 一个连接可以发多行,每行一条命令。读完回一个 ok,让命令行工具知道送到了。
    nonisolated private static func readLines(from conn: Int32, _ handler: @Sendable (String) -> Void) {
        defer { close(conn) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { handler(t) }
            }
            if buffer.isEmpty { _ = "ok\n".withCString { write(conn, $0, 3) } }
        }
    }

    /// 发键、点击这类要按节奏 sleep 的命令放到后台线程,别卡住主线程上的界面
    nonisolated private static func offMain(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    // MARK: - 命令

    private func handle(_ t: String) {
        let channel = session.channel
        let agent = session.agent
        let qmp = session.qmp
        let view = session.view

        switch t.split(separator: " ").first.map(String.init) {
        case "quit":
            // **不能**在主队列的一次 drain 里直接调 terminate。
            // applicationShouldTerminate 回 .terminateLater 之后 AppKit 在 terminate 内部
            // 开一个嵌套事件循环等 reply,而这个嵌套循环跑在主队列的一次 drain 里面 ——
            // libdispatch 的主队列不可重入,挂起流程里所有回到主队列的回调
            // (savevm 完成、180 秒兜底)全都排不上,应用就永远卡在那里。
            // 菜单上的 Cmd+Q 是事件循环直接调的,没有这层 drain,所以只有这条路会死。
            // 用 perform(afterDelay:) 让 terminate 从事件循环本身发起。
            Task {
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        case "setresraw":
            // 绕过宿主侧吸附,直接把请求原样发给 guest。
            // 用来判定驱动到底认不认任意尺寸 —— 吸附会掩盖真实结果。
            let p = t.split(separator: " ")
            if p.count == 3, let w = Int(p[1]), let h = Int(p[2]) {
                agent.send("setres \(w) \(h)")
                print("OK setresraw \(w)x\(h)")
            } else { print("ERR 用法: setresraw <宽> <高>") }
        case "winsize":
            // 改窗口尺寸(单位:点),用来在没有人手的情况下走通真实的拖拽路径
            let p = t.split(separator: " ").compactMap { Double($0) }
            if p.count >= 2 {
                Task {
                    session.window?.setContentSize(NSSize(width: p[0], height: p[1]))
                    print("OK winsize \(Int(p[0]))x\(Int(p[1])) 点")
                }
            } else { print("ERR 用法: winsize <宽点> <高点>") }
        case "shutdown":
            // 电源菜单里「关机」那条路:ACPI 关机,guest 不响应再强制断电
            session.requestShutdown()
            print("OK 已请求关机")
        case "suspend":
            Task {
                session.suspend()
                print("OK 已请求保存状态")
            }
        case "close":
            // 走的是红叉那条路(windowShouldClose),用来验证关窗口 = 关机
            Task {
                session.window?.performClose(nil)
                print("OK 已请求关闭窗口")
            }
        case "fullscreen":
            Task {
                session.window?.toggleFullScreen(nil)
                print("OK 切换全屏")
            }
        case "uiinfo":
            // 直接向 QEMU 发 dpy_set_ui_info。用来验证 viogpudo 认不认宿主给的尺寸 ——
            // 早先的「不认」结论是在传了 0 宽高时得出的,而 0 的含义是「关掉这个输出」。
            let p = t.split(separator: " ").compactMap { Int32($0) }
            if p.count >= 2, p[0] > 0, p[1] > 0 {
                channel.send(.uiInfo, p[0], p[1])
                print("OK uiinfo \(p[0])x\(p[1])")
            } else { print("ERR 用法: uiinfo <宽> <高>(必须为正)") }
        case "cursor":
            // 两侧状态必须一起切,否则会出现两个光标或一个都没有
            let mode = t.split(separator: " ").dropFirst().first.map(String.init) ?? "host"
            Task {
                session.setCursorMode(hostDrawn: mode != "guest")
                print(mode == "guest" ? "OK 光标交回 guest 绘制" : "OK 光标改由宿主绘制")
            }
        case "setrefresh":
            let p = t.split(separator: " ")
            if p.count == 2, let hz = Int(p[1]) { agent.send("setrefresh \(hz)"); print("OK setrefresh \(hz)") }
            else { print("ERR 用法: setrefresh <Hz>") }
        case "setres":
            let p = t.split(separator: " ")
            if p.count == 3, let w = Int(p[1]), let h = Int(p[2]) {
                Task {
                    session.setResolutionManually(CGSize(width: w, height: h))
                }
                print("OK setres \(w)x\(h)")
            } else { print("ERR 用法: setres <宽> <高>") }
        case "network":
            // 与界面**共用** VMSession.applyNetwork,不是另写一份。
            // install-agent.bat 有过两份副本分叉的教训,不再犯。
            let arg = t.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let mode = NetworkMode(rawValue: arg) else {
                print("ERR 用法: network none|user"); break
            }
            // 走 applyNetwork 而不是 setNetwork —— 前者还负责落盘与 busy 状态,
            // 命令行必须跑的是界面按钮跑的那条完整路径。
            Task {
                session.applyNetwork(mode)
                print("OK 已请求切换到 \(mode.displayName)")
            }
        case "snaps":
            // 诊断用:走 VMSession 的刷新路径(与界面完全相同),
            // 把结果条数打出来。这样能把「VMSession 没刷新」与
            // 「SwiftUI 没观察到」两种可能分开 —— 界面上看都是「列表没更新」。
            Task {
                await session.refreshSnapshotsNow()
                print("OK VMSession 缓存的快照 \(session.snapshots.count) 条:"
                    + session.snapshots.map(\.id).joined(separator: ", "))
            }
        case "usbls":
            // 直接看 IOKit 枚举结果。system_profiler 在这台机器上返回空,
            // 所以数据源换成了 IOKit —— 这条命令就是用来盯住它的。
            let devices = USBEnumerator.devices()
            for (i, d) in devices.enumerated() {
                let note = d.blockedReason.map { "  ⚠︎ \($0)" } ?? "  ✓ 可透传"
                print("  [\(i)] \(d.idString)  \(d.name)\(note)")
            }
            print("  共 \(devices.count) 个")
        case "usbtest":
            // 插一个**模拟** USB 鼠标。macOS 上造不出宿主侧的虚拟 USB 设备
            // (要 DriverKit 扩展 + Apple 特批 entitlement),但模拟设备走的是
            // 完全相同的 device_add 路径,能验掉除 libusb 本身之外的整条链路。
            let sub = t.split(separator: " ").dropFirst().first.map(String.init) ?? "on"
            Task {
                let err = sub == "off" ? await qmp.detachTestUSBDevice() : await qmp.attachTestUSBDevice()
                print(err.map { "ERR \($0)" } ?? "OK 模拟 USB 鼠标已\(sub == "off" ? "拔出" : "插入")")
            }
        case "usb":
            let p = t.split(separator: " ").map(String.init)
            let devices = USBEnumerator.devices()
            switch p.count > 1 ? p[1] : "list" {
            case "list":
                for (i, d) in devices.enumerated() {
                    let note = d.blockedReason.map { "  ⚠︎ \($0)" } ?? ""
                    print("  [\(i)] \(d.idString)  \(d.name)\(note)")
                }
                if devices.isEmpty { print("  (未发现可透传的 USB 设备)") }
            case "attach", "detach":
                guard p.count == 3, let i = Int(p[2]), devices.indices.contains(i) else {
                    print("ERR 用法: usb attach|detach <序号>"); break
                }
                let d = devices[i]
                if p[1] == "attach", let why = d.blockedReason {
                    print("ERR \(d.name) 无法透传:\(why)")
                    break
                }
                // 走 VMSession,与界面同一条路径(透传状态记在会话里)
                let attach = p[1] == "attach"
                Task {
                    if attach { session.attachUSB(d) } else { session.detachUSB(d) }
                    print("OK 已请求 \(p[1]) \(d.name),结果看状态条 / 日志")
                }
            default: print("ERR 用法: usb list|attach <n>|detach <n>")
            }
        case "keys":
            // 组合键:全部按下再逆序抬起。只有单键的话没法发 Win+R,
            // 只能走开始菜单搜索 —— 那条路会被中文 IME 改写,极不可靠。
            let codes = t.split(separator: " ").dropFirst().compactMap { Int32($0) }
            if codes.isEmpty { print("ERR 用法: keys <qcode> [qcode...]"); break }
            Self.offMain {
                for c in codes { channel.send(.key, c, 1); Thread.sleep(forTimeInterval: 0.02) }
                for c in codes.reversed() { channel.send(.key, c, 0); Thread.sleep(forTimeInterval: 0.02) }
                print("OK keys \(codes.map(String.init).joined(separator: "+"))")
            }
        case "sweep":
            // 以固定节奏画圈移动鼠标,用来测「有输入时」的真实出帧率
            let p = t.split(separator: " ").compactMap { Int32($0) }
            let secs = p.count >= 1 ? Double(p[0]) : 3
            Task {
                let size = session.guestSize
                Task.detached {
                    let t0 = Date()
                    var i = 0.0
                    while Date().timeIntervalSince(t0) < secs {
                        let a = i * 0.15
                        let x = Int32(size.width  / 2 + cos(a) * size.width  / 4)
                        let y = Int32(size.height / 2 + sin(a) * size.height / 4)
                        channel.send(.mouseAbs, x, y)
                        i += 1
                        usleep(4000)   // 250Hz,高于任何显示刷新率
                    }
                    print("OK sweep 结束,\(Int(i)) 个移动事件")
                }
            }
        case "fps":
            Task { @MainActor in print("OK \(view.takeStats())") }
        case "state":
            Task {
                print("OK state=\(session.state.label) busy=\(session.busyMessage ?? "-") "
                    + "agent=\(agent.isConnected) qmp=\(qmp.isConnected) "
                    + "guest=\(session.guestSize) 光标=\(view.cursorStatus)")
            }
        case "uidump":
            // 工具栏控件的实际尺寸只能从视图树上量 —— SwiftUI 的 .controlSize
            // 在 NSToolbarItem 上是否生效,靠看截图判断不了。
            Task {
                guard let w = session.window else { print("ERR 没有窗口"); return }
                print("OK 窗口 content=\(w.contentView?.bounds.size ?? .zero) guest视图=\(view.bounds.size)")
                if let bar = w.contentView?.superview {
                    dumpViews(bar, depth: 0, skip: w.contentView)
                }
            }
        case "key":
            let parts = t.split(separator: " ")
            if parts.count >= 2, let q = Int32(parts[1]) {
                Self.offMain {
                    channel.send(.key, q, 1)
                    Thread.sleep(forTimeInterval: 0.05)
                    channel.send(.key, q, 0)
                    print("OK key \(q)")
                }
            } else { print("ERR 用法: key <qcode>") }
        case "type":
            // 逐字符发键。中文 Windows 下 IME 会转换按键,自动化前先切英文。
            let text = String(t.dropFirst(5))
            Self.offMain {
                for ch in text {
                    let q = qcodeForCharacter(ch)
                    guard q.code != 0 else { continue }
                    if q.shift { channel.send(.key, QKeyCode.shift, 1) }
                    channel.send(.key, q.code, 1)
                    Thread.sleep(forTimeInterval: 0.02)
                    channel.send(.key, q.code, 0)
                    if q.shift { channel.send(.key, QKeyCode.shift, 0) }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                print("OK typed \(text.count) chars")
            }
        case "click":
            let p = t.split(separator: " ").compactMap { Int32($0) }
            if p.count >= 2 {
                Self.offMain {
                    channel.send(.mouseAbs, p[0], p[1])
                    Thread.sleep(forTimeInterval: 0.05)
                    channel.send(.mouseBtn, 0, 1)
                    Thread.sleep(forTimeInterval: 0.05)
                    channel.send(.mouseBtn, 0, 0)
                    print("OK click \(p[0]),\(p[1])")
                }
            } else { print("ERR 用法: click <x> <y>(guest 像素)") }
        case "snapshot":
            // **走 VMSession,与界面完全同一条路径**。
            // 早先这里直接调 qmp,于是界面上的 CRLF 解析 bug 在命令行里测不出来 ——
            // 命令行显示一切正常,界面却是空列表。同一条路径才有诊断价值。
            let p = t.split(separator: " ").map(String.init)
            let sub = p.count > 1 ? p[1] : "list"
            let tag = p.count > 2 ? p[2] : ""
            Task {
                switch sub {
                case "save" where !tag.isEmpty:   session.saveSnapshot(named: tag)
                case "load" where !tag.isEmpty:   session.restoreSnapshot(tag)
                case "delete" where !tag.isEmpty: session.deleteSnapshot(tag)
                case "list":                      session.refreshSnapshots()
                default:
                    print("ERR 用法: snapshot save|load|delete <tag> | snapshot list")
                    return
                }
                // 盯住 busy 是否会清掉 —— 清不掉界面就永久禁用,表现为「不能操作」
                var waited = 0
                while let busy = session.busyMessage {
                    if waited > 180 { print("ERR 超过 180 秒仍在「\(busy)」,busy 没有清除"); return }
                    try? await Task.sleep(for: .seconds(2))
                    waited += 2
                }
                print("OK \(sub) 完成,用时约 \(waited)s,state=\(session.state.label),"
                    + "快照 \(session.snapshots.count) 条"
                    + (session.lastError.map { ",错误:\($0)" } ?? ""))
            }
        case "activate":
            // 把窗口变成 key。剪贴板同步只在窗口是 key 时跑,脚本起的实例没人点它。
            Task {
                NSApp.activate(ignoringOtherApps: true)
                session.window?.makeKeyAndOrderFront(nil)
                print("OK 已激活")
            }
        case "hostkey":
            // hostkey cmd+shift+v:造 NSEvent 喂给 GuestView 自己的按键处理,
            // 测「宿主按键 → guest 收到什么」这一层(⌘ 翻译)。`keys` 直接发 qcode,测不到它。
            // 用它而不是 osascript:后者要辅助功能权限。
            let spec = t.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            Task {
                if let err = session.view.debugHostKey(spec) { print("ERR \(err)") }
                else { print("OK hostkey \(spec)") }
            }
        case "clipstate":
            // 下一次轮询拿到的 guest 剪贴板内容打出来,与宿主的并排
            session.debugPrintNextClip = true; session.debugClipboardTick()
        case "xfer":
            // 传文件:xfer <路径>... 打盘插入;xfer retrieve 取回。与界面同一条路径。
            let p = t.split(separator: " ").dropFirst().map(String.init)
            Task {
                if p.first == "retrieve" { session.retrieveTransferDisk(); print("OK 已请求取回") }
                else if p.isEmpty { print("ERR 用法: xfer <路径>... | xfer retrieve") }
                else { session.sendFiles(p.map { URL(fileURLWithPath: $0) }); print("OK 已请求传入 \(p.count) 个文件") }
            }
        case "qmp":
            let cmd = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            Task { print("OK qmp \(cmd) -> \(await qmp.execute(cmd))") }
        case "hmp":
            // 一行 HMP 原样转给 QEMU。上面的 qmp 带不了参数,而开日志与跟踪都要参数:
            // hmp log guest_errors / hmp trace-event virtio_gpu_cmd_* on,输出进 QEMU 的日志文件
            let line = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            Task { print("OK hmp \(line) -> \(await qmp.hmp(line))") }
        default:
            agent.send(t)
            print("OK sent: \(t)")
        }
    }
}

/// 打印视图树,给 uidump 用。跳过 guest 画面那一支 —— 它下面没有控件。
private func dumpViews(_ v: NSView, depth: Int, skip: NSView?) {
    if v === skip { return }
    let cls = String(describing: type(of: v))
    let f = v.frame
    let pad = String(repeating: "  ", count: depth)
    let size = String(format: "%.0fx%.0f @ %.0f,%.0f", f.width, f.height, f.origin.x, f.origin.y)
    print("\(pad)\(cls)  \(size)")
    guard depth < 8 else { return }
    for sub in v.subviews { dumpViews(sub, depth: depth + 1, skip: skip) }
}
