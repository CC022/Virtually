// QMP 客户端:QEMU 的机器控制通道。
//
// 用途分两类:
//   运行期控制 —— 热插拔设备(安装完成后弹出安装介质、USB 透传)、链路开关
//   生命周期   —— 快照与挂起(走 HMP 的 savevm / loadvm / delvm,见下面「快照」一节)、quit
//
// 与 DisplayChannel / AgentChannel 的分工:
//   DisplayChannel  管画面与输入(自定义二进制协议,低延迟)
//   AgentChannel    管 guest 内部的事(分辨率、以后的剪贴板)
//   QMPClient       管虚拟机本身(设备、快照、状态)

import Foundation

/// socket 与锁自己管线程安全;回调声明成 @Sendable,逼着接收方自己跳回主 actor。
public final class QMPClient: @unchecked Sendable {
    private let sockPath: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "virtually.qmp")
    private let lock = NSLock()
    /// 在途命令,按 id 配对回复。QMP 允许每条命令带任意 id 并原样带回,
    /// 靠它就不依赖「回复顺序 = 发送顺序」这个隐含假设了。
    private var pendingReplies: [Int: ([String: Any]) -> Void] = [:]
    private var nextID = 1

    /// QEMU 主动上报的事件名,如 "RESET" / "SHUTDOWN" / "STOP"
    public var onEvent: (@Sendable (String, [String: Any]) -> Void)?

    public var isConnected: Bool { fd >= 0 }
    /// QEMU 已经退出,别再重连了。不设的话 connectWithRetry 会永远转下去,
    /// 每次开机失败都留下一条强持有 self 的后台线程。
    private var stopped = false

    public init(sockPath: String) { self.sockPath = sockPath }

    /// QEMU 进程退出时调用:停掉重连循环,把在途命令全部以错误回调。
    public func stop() {
        stopped = true
        failAllPending("虚拟机已退出")
    }

    /// 连接断开或从未建立时,等回复的人不能永远等下去 ——
    /// 以前 readLoop 一退出这些回调就丢了,挂起流程要等满 180 秒兜底才知道。
    private func failAllPending(_ why: String) {
        lock.lock()
        let waiting = pendingReplies.values
        pendingReplies.removeAll()
        lock.unlock()
        for handler in waiting { handler(Self.errorReply(why)) }
    }

    public static func errorReply(_ desc: String) -> [String: Any] {
        ["error": ["class": "GenericError", "desc": desc]]
    }

    /// 握手完成、能发命令了。用来在 guest 跑起来之前压初始状态(如断网)。
    public var onReady: (@Sendable () -> Void)?

    public func connectWithRetry() {
        queue.async { [self] in
            // 握手必须带超时并重连:`-qmp ...,server,nowait` 下 QEMU 很早就建好
            // 监听 socket,但 QMP monitor 要到初始化后期才会发 greeting。
            // 连得太早会 accept 成功却永远收不到 greeting,阻塞在 read 上。
            while !stopped {
                if fd < 0 {
                    fd = Self.connect(sockPath)
                    if fd < 0 { Thread.sleep(forTimeInterval: 0.5); continue }
                }
                setReadTimeout(seconds: 2)
                guard readMessage() != nil else {
                    // 没等到 greeting:关掉重来,而不是死等
                    close(fd); fd = -1; buffer.removeAll()
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                send(["execute": "qmp_capabilities"])
                guard readMessage() != nil else {
                    close(fd); fd = -1; buffer.removeAll()
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                break
            }
            guard !stopped, fd >= 0 else { return }
            setReadTimeout(seconds: 0)   // 握手完成后恢复阻塞读
            print("[qmp] 已连接")
            onReady?()
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

    /// 按**字节**缓冲,不能用 String。
    ///
    /// QMP 每行以 CRLF 结尾,而 Swift 的 String 把 "\r\n" 视为单个 Character,
    /// `firstIndex(of: "\n")` 永远匹配不到 —— 会静默地一直阻塞在 read 上。
    /// 这个坑排查了很久:Python 客户端按字节处理,同一个 socket 一切正常。
    private var buffer = Data()

    /// seconds = 0 表示恢复无限阻塞
    private func setReadTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// QMP 是一行一个 JSON 对象(行尾为 CRLF)
    private func readMessage() -> [String: Any]? {
        while true {
            if let i = buffer.firstIndex(of: 0x0a) {          // LF
                var line = buffer.subdata(in: buffer.startIndex..<i)
                buffer = buffer.subdata(in: buffer.index(after: i)..<buffer.endIndex)
                if line.last == 0x0d { line.removeLast() }     // 去掉 CR
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                return obj
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func readLoop() {
        while let msg = readMessage() {
            if let event = msg["event"] as? String {
                onEvent?(event, msg)
            } else {
                lock.lock()
                let handler = (msg["id"] as? Int).flatMap { pendingReplies.removeValue(forKey: $0) }
                lock.unlock()
                if let handler { handler(msg) }
                else { print("[qmp] 收到没有对应命令的回复:\(msg)") }
            }
        }
        print("[qmp] 连接断开")
        close(fd); fd = -1
        failAllPending("与虚拟机的连接已断开")
    }

    /// 调用方必须已持有 lock。握手阶段与 execute 都经这里写。
    private func sendLocked(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0a)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    }

    private func send(_ object: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        sendLocked(object)
    }

    /// 发一条命令;`completion` 收到该命令的回复(不含异步事件)。
    ///
    /// 未连接时**立即以错误回调**,而不是静默丢掉。以前是 `guard fd >= 0 else { return }`:
    /// 开机头几秒 QMP 还没握手完就点红叉,delvm 被丢掉,「正在保存状态」永远停在那里。
    ///
    /// 入队与写 socket 在**同一个临界区**里。分成两段的话,主线程与 QMP 读线程
    /// (回调里再发命令)并发时入队顺序与发送顺序可以不一致,回复就配错回调。
    private func send(command: String, arguments: [String: Any]?,
                      completion: @escaping ([String: Any]) -> Void) {
        var msg: [String: Any] = ["execute": command]
        if let a = arguments { msg["arguments"] = a }
        lock.lock()
        guard fd >= 0 else {
            lock.unlock()
            completion(Self.errorReply("虚拟机正在启动，请稍候"))
            return
        }
        let id = nextID
        nextID += 1
        msg["id"] = id
        pendingReplies[id] = completion
        sendLocked(msg)
        lock.unlock()
    }

    /// 发一条命令,等它的回复(不含异步事件)。出错时回复里有 "error" 字典,`errorText` 取文案。
    /// 回复在 QMP 读线程上到达,await 的一方(通常是主 actor)自动跳回自己的线程。
    public func execute(_ command: String, arguments: [String: Any]? = nil) async -> [String: Any] {
        await withCheckedContinuation { cont in
            send(command: command, arguments: arguments) { cont.resume(returning: $0) }
        }
    }

    /// 回复里的错误文案;成功为 nil
    public static func errorText(_ reply: [String: Any]) -> String? {
        guard let err = reply["error"] as? [String: Any] else { return nil }
        return "\(err["desc"] ?? err)"
    }

    // MARK: - 快照
    //
    // 走 HMP(human-monitor-command)而不是 QMP 的 snapshot-save/load 任务 API。
    // 后者是异步 job,要监听 JOB_STATUS_CHANGE 再 query-jobs 取结果;
    // HMP 的 savevm/loadvm 是同步的,错误直接以文本返回,代码量小一个数量级。
    // 两者落到 qcow2 里的是同一种内部快照,可以互相识别。
    // 内存状态落在哪块盘由 -drive 的顺序决定(见 VMBundle.swift),不靠 job API 的 vmstate 参数。

    /// 保存快照(含内存状态)。VM 会短暂暂停。返回错误文案,成功为 nil。
    public func saveSnapshot(tag: String) async -> String? {
        let out = await hmp("savevm \(tag)")
        return out.isEmpty ? nil : out
    }

    /// 恢复到快照。VM 会回到保存时的运行状态。
    public func loadSnapshot(tag: String) async -> String? {
        let out = await hmp("loadvm \(tag)")
        return out.isEmpty ? nil : out
    }

    public func deleteSnapshot(tag: String) async -> String? {
        let out = await hmp("delvm \(tag)")
        return out.isEmpty ? nil : out
    }

    public func listSnapshots() async -> String { await hmp("info snapshots") }

    /// HMP 命令的返回是纯文本;成功时通常为空串
    public func hmp(_ line: String) async -> String {
        let reply = await execute("human-monitor-command", arguments: ["command-line": line])
        if let err = Self.errorText(reply) { return "错误:\(err)" }
        return (reply["return"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 热拔设备。安装完成后用它移除安装介质 ——
    /// 否则重启会再次从安装介质引导,Windows Setup 会弹出
    /// 「请移除介质」的对话框卡住无人值守流程。
    public func removeDevice(id: String) async {
        if let err = Self.errorText(await execute("device_del", arguments: ["id": id])) {
            print("[qmp] 移除 \(id) 失败:\(err)")
        } else {
            print("[qmp] 已移除设备 \(id)")
        }
    }
}
