// 与 guest 内 agent 的文本行通道(virtio-serial)。
// 协议见 docs/GUEST-AGENT.md。写入不能阻塞、行要按字节切 —— 两条都是踩过坑的。

import AppKit
import Metal
import QuartzCore
import Darwin

// MARK: - Guest Agent 通道(virtio-serial)

/// 与 guest 内 agent 的文本行通道。
///
/// 走 virtio-serial 而不是网络:不依赖 guest 网络配置,
/// 也不占用端口。QEMU 侧是 server,我们做 client。
/// 读写都在自己的线程上,靠锁与非阻塞 fd;回调是 @Sendable,接收方自己跳回主 actor。
public final class AgentChannel: @unchecked Sendable {
    private let sockPath: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "virtually.agent")
    private let lock = NSLock()

    public var onLine: (@Sendable (String) -> Void)?
    public var isConnected: Bool { fd >= 0 }
    private var stopped = false

    /// QEMU 退出时调用,否则 connectWithRetry 永远重连下去。
    public func stop() {
        stopped = true
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// guest 显卡驱动暴露的模式列表。
    ///
    /// viogpudo 只接受列表里的分辨率,任意尺寸会返回 DISP_CHANGE_BADMODE(-2)。
    /// 窗口可以是任意大小,所以必须由宿主侧吸附到最接近的合法模式。
    public private(set) var supportedModes: [(w: Int, h: Int)] = []
    /// guest agent 报到(收到第一条应答)时回调
    public var onReady: (@Sendable () -> Void)?
    private var announced = false

    public init(sockPath: String) { self.sockPath = sockPath }

    /// QEMU 要过一会儿才建好 socket,所以重试直到连上
    public func connectWithRetry() {
        queue.async { [self] in
            while fd < 0 && !stopped {
                fd = Self.connect(sockPath)
                if fd < 0 { Thread.sleep(forTimeInterval: 0.5) }
            }
            guard fd >= 0 else { return }
            // 必须在开始收发之前设成非阻塞,原因见 send()
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            print("[agent] 通道已连接")
            // socket 连上只代表宿主到 QEMU 这一段通了,guest 里的 agent 可能
            // 还没登录、还没起。定期 ping 直到它应答,应答后才去取模式表。
            pokeUntilReady()
            readLoop()
        }
    }

    private static func connect(_ path: String) -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withCString { strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) }
        }
        if rc != 0 { close(s); return -1 }
        return s
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        // 按**字节**缓冲。Swift 的 String 把 "\r\n" 视为单个 Character,
        // `firstIndex(of: "\n")` 匹配不到 CRLF 行尾,会静默地永久阻塞。
        // guest 侧现在发的是 LF,但不能依赖这一点。
        var pending = Data()
        while fd >= 0 {
            let n = read(fd, &buf, buf.count)
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // socket 设成了非阻塞(见 send()),没数据不代表断开。
                // 用 poll 等,而不是空转烧 CPU。
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, 200)
                continue
            }
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            while let i = pending.firstIndex(of: 0x0a) {
                let raw = pending.subdata(in: pending.startIndex..<i)
                pending = pending.subdata(in: pending.index(after: i)..<pending.endIndex)
                let line = String(decoding: raw, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                noteModes(line)
                onLine?(line)
            }
        }
        print("[agent] 通道断开")
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// 写入**不能阻塞**。
    ///
    /// guest 侧没打开 virtio-serial 端口时(agent 没起来),QEMU 的 chardev
    /// 就不再从 socket 读,内核缓冲区写满后 `write` 会永久阻塞 ——
    /// 而调用方可能是调试控制通道或主线程,于是整个 app 看起来「死了」:
    /// 命令没反应、窗口不刷新。排查了好几次才定位到这里。
    ///
    /// 现在设 O_NONBLOCK,写不进去就丢掉。这条通道上的消息要么是轮询
    /// (getcursor/ping,下一轮还会再发),要么是幂等的设置命令,丢了不影响正确性。
    public func send(_ line: String) {
        guard fd >= 0 else { return }
        let data = Array((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        let n = data.withUnsafeBufferPointer { write(fd, $0.baseAddress!, $0.count) }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            dropped += 1
            // 稀疏地报一次,免得刷屏
            if dropped == 1 || dropped % 200 == 0 {
                print("[agent] guest 未读取通道,已丢弃 \(dropped) 条消息")
            }
        }
    }
    private var dropped = 0

    private func pokeUntilReady() {
        // 必须用别的队列:`queue` 是串行的,readLoop 正跑在上面,
        // 把轮询也塞进去会让 readLoop 永远排不上号。
        DispatchQueue.global().async { [self] in
            while !announced && fd >= 0 {
                send("ping")
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    private func noteModes(_ line: String) {
        let f = line.split(separator: " ")
        if f.count >= 3, f[0] == "mode", let w = Int(f[1]), let h = Int(f[2]) {
            lock.lock(); defer { lock.unlock() }
            if !supportedModes.contains(where: { $0.w == w && $0.h == h }) {
                supportedModes.append((w, h))
            }
            return
        }
        // 安装进度是**安装器**在写,不是 agent —— 别把它当成 agent 就绪,
        // 否则宿主会以为装完了(finishInstallIfNeeded 会把介质从配置里清掉)。
        if line.hasPrefix("vainstall ") { return }
        // 任何一行(包括 agent 自己的 log)都说明 guest 侧活着 —— 此时才值得问模式表
        if !announced {
            announced = true
            send("modes")
            onReady?()
        }
    }

    /// 把任意尺寸吸附到驱动支持的模式。
    ///
    /// 优先选**不小于**请求尺寸的最小模式:画面在宿主侧缩小仍然清楚,
    /// 放大则会糊。没有更大的就取面积最大的那个。
    /// `maxPixels` 排除面积超过预算的模式:模式表里可能有驱动其实撑不住的那一档(比如刚被拒的自定义尺寸)。
    public func snap(width: Int, height: Int, maxPixels: Int = .max) -> (w: Int, h: Int) {
        lock.lock(); let modes = supportedModes.filter { $0.w * $0.h <= maxPixels }; lock.unlock()
        guard !modes.isEmpty else { return (width, height) }
        let bigEnough = modes.filter { $0.w >= width && $0.h >= height }
        if let best = bigEnough.min(by: { $0.w * $0.h < $1.w * $1.h }) { return best }
        return modes.max(by: { $0.w * $0.h < $1.w * $1.h }) ?? (width, height)
    }

    /// 精确设置分辨率,**不做吸附**。
    ///
    /// 吸附会破坏点对点:画面尺寸与窗口不一致就得缩放。任意尺寸本身是可行的,
    /// 前提是宿主先通过 `dpy_set_ui_info` 把这个尺寸告诉 virtio-gpu
    /// (见 VMSession 的 requestResolution)。`snap` 只留作两次失败后的兜底。
    public func setResolution(width: Int, height: Int) {
        send("setres \(width) \(height)")
    }
}
