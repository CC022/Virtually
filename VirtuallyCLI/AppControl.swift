// 驱动 app 的调试命令。
//
// run 拉起的实例:用 SessionPaths.debug 那组固定路径,监听 controlSocket,输出写进 logFile。
// 同一时间只有一个调试实例,pid 记在 pidFile。

import AppKit
import ImageIO
import UniformTypeIdentifiers
import VirtuallyKit

enum AppControl {
    static let controlSocket = "/tmp/virtually-control.sock"
    static let logFile = "/tmp/virtually.log"
    static let pidFile = "/tmp/virtually-debug.pid"

    // MARK: run

    static func run(_ args: inout Arguments) throws {
        let app = try AppLocator.app(&args)
        var launch = DebugLaunch()
        guard let vm = args.option("vm") else { throw CLIError("run 需要 --vm <虚拟机包>") }
        launch.vmPath = URL(fileURLWithPath: vm).standardizedFileURL.path
        launch.controlSocket = controlSocket
        launch.forceRamfb = args.flag("ramfb")
        launch.vblkProbe = args.flag("vblk-probe")
        launch.mountTools = args.flag("tools")
        launch.cursorDebug = args.flag("cursor-debug")
        launch.guestCursor = args.flag("guest-cursor")
        launch.extraISO = args.option("iso")
        launch.bootImage = args.option("boot-img")
        launch.displaySize = args.option("display-size")

        if let pid = runningDebugPID() {
            print("已有调试实例(pid \(pid)),先把它停掉")
            try stopInstance(pid: pid)
        }

        guard let exe = app.executableURL else { throw CLIError("\(app.bundlePath) 里没有可执行文件") }
        let pid = try spawnDetached(exe.path, launch.arguments, log: logFile)
        try "\(pid)".write(toFile: pidFile, atomically: true, encoding: .utf8)
        print("已启动 pid=\(pid) 日志=\(logFile)")
    }

    /// 脱离本进程的会话再启动:命令行工具被 Ctrl+C 或超时杀掉时,虚拟机不能跟着没掉。
    private static func spawnDetached(_ path: String, _ arguments: [String], log: String) throws -> pid_t {
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        guard rc == 0 else { throw CLIError("启动失败:\(String(cString: strerror(rc)))") }
        return pid
    }

    // MARK: send / log

    static func send(_ args: inout Arguments) throws {
        let wait = try args.int("wait") ?? 2
        let line = args.rest().joined(separator: " ")
        guard !line.isEmpty else { throw CLIError("send 需要一条命令") }
        let before = logSize()
        try deliver(line)
        Thread.sleep(forTimeInterval: TimeInterval(wait))
        print(newLog(since: before), terminator: "")
    }

    static func log(_ args: inout Arguments) throws {
        let count = args.next().flatMap(Int.init) ?? 30
        let text = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
        print(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count + 1)
                  .joined(separator: "\n"), terminator: "")
    }

    private static func deliver(_ line: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("socket() 失败") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(controlSocket.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else {
            throw CLIError("连不上调试实例(\(controlSocket))。先用 virtually run --vm <包> 启动。")
        }
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var ack = [UInt8](repeating: 0, count: 8)
        _ = read(fd, &ack, ack.count)
    }

    private static func logSize() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: logFile))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func newLog(since offset: UInt64) -> String {
        guard let h = FileHandle(forReadingAtPath: logFile) else { return "" }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    // MARK: stop

    static func stop(_ args: inout Arguments) throws {
        guard let pid = runningDebugPID() else { print("没有在跑的调试实例"); return }
        try stopInstance(pid: pid)
        print("已停止")
    }

    /// quit 走的是 ⌘Q 那条路:先把虚拟机状态存下来再退出,要几秒到几十秒。
    /// 直接杀进程等于把正在 savevm 的 QEMU 拔电源,所以只等它自己退。
    /// app 存不下状态会取消退出(日志里有原因),这时不强杀,把原因交给用户。
    private static func stopInstance(pid: pid_t) throws {
        let before = logSize()
        try deliver("quit")
        for _ in 0..<180 {
            if kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(atPath: pidFile)
                return
            }
            let recent = newLog(since: before)
            if recent.contains("取消退出") {
                let why = recent.split(separator: "\n").filter { $0.hasPrefix("[vm]") || $0.hasPrefix("[app]") }
                throw CLIError("app 取消了退出,虚拟机还开着:\n" + why.joined(separator: "\n")
                               + "\n可以先 send 关机(ACPI),或在窗口里处理后再 stop。")
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw CLIError("3 分钟还没退出,没有强杀。看 virtually log 里卡在哪。")
    }

    private static func runningDebugPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return nil }
        return pid
    }

    // MARK: shot

    /// 从共享帧缓冲截图。尺寸取日志里最后一次「映射 WxH stride=S」。
    static func shot(_ args: inout Arguments) throws {
        let out = URL(fileURLWithPath: try args.required("输出 PNG 路径"))
        let log = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
        let regex = try NSRegularExpression(pattern: #"映射 (\d+)x(\d+) stride=(\d+)"#)
        guard let m = regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).last else {
            throw CLIError("日志里还没有帧缓冲映射记录")
        }
        func group(_ i: Int) -> Int { Int((log as NSString).substring(with: m.range(at: i)))! }
        let (w, h, stride) = (group(1), group(2), group(3))
        let data = try Data(contentsOf: URL(fileURLWithPath: SessionPaths.debug.framebuffer), options: .alwaysMapped)
        guard data.count >= stride * h else { throw CLIError("帧缓冲比 \(w)x\(h) 小,画面可能正在改尺寸,再试一次") }

        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        if let crop = args.next() {
            let f = crop.split(separator: ",").compactMap { Int($0) }
            guard f.count == 4 else { throw CLIError("裁剪格式是 x,y,w,h") }
            rect = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // 帧缓冲是 x8r8g8b8 小端,即内存里 BGRX
        guard let provider = CGDataProvider(data: data.prefix(stride * h) as CFData),
              let full = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                          | CGBitmapInfo.byteOrder32Little.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let image = full.cropping(to: rect),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CLIError("生成图片失败") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError("写 \(out.path) 失败") }
        print("\(image.width)x\(image.height) -> \(out.path)")
    }
}
