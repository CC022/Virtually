// 与 QEMU 自定义显示后端(ui/macos.c)的控制通道:定长 20 字节的二进制协议。
// 画面走共享 mmap 文件(见 Framebuffer.swift),这条 socket 只传事件:
// QEMU → 宿主:RESIZE / DAMAGE / CURSOR / CURSOR_VIS;宿主 → QEMU:鼠标、键盘、滚轮、UI info。

import AppKit
import Metal
import QuartzCore
import Darwin

// MARK: - 线协议(与 ui/macos.c 对应)

public enum Msg: Int32 {
    case resize = 1, damage = 2, cursor = 3, cursorVis = 4
    case mouseAbs = 10, mouseBtn = 11, scroll = 12, key = 13, uiInfo = 14
}

public struct Packet {
    public var type: Int32
    public var a: Int32, b: Int32, c: Int32, d: Int32
}

// MARK: - 与 QEMU 的控制通道

public final class DisplayChannel: @unchecked Sendable {
    private var listenFD: Int32 = -1
    public private(set) var connFD: Int32 = -1
    private let sockPath: String
    private let queue = DispatchQueue(label: "virtually.channel")
    private let sendLock = NSLock()

    public var onResize: (@Sendable (Int, Int, Int) -> Void)?
    public var onDamage: (@Sendable (Int, Int, Int, Int) -> Void)?
    public var onCursor: (@Sendable (Int, Int, Int, Int, Data) -> Void)?
    public var onCursorVisible: (@Sendable (Bool, Int, Int) -> Void)?

    public init(sockPath: String) {
        self.sockPath = sockPath
    }

    /// 必须在拉起 QEMU 之前调用 —— QEMU 在 init 阶段就会来连
    public func listen() throws {
        unlink(sockPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            sockPath.withCString { src in
                strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), src, raw.count - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard rc == 0 else { throw POSIXError(.EADDRINUSE) }
        guard Darwin.listen(listenFD, 1) == 0 else { throw POSIXError(.EIO) }
    }

    public func acceptInBackground() {
        queue.async { [self] in
            connFD = accept(listenFD, nil, nil)
            guard connFD >= 0 else { return }
            print("[channel] QEMU 已连接")
            readLoop()
        }
    }

    /// QEMU 退出后收尾:关掉监听与连接、删掉 socket 文件。
    /// 不关的话 QEMU 起不来时 accept 那条线程永远等着,socket 文件也一直堆在 /tmp。
    public func close() {
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        if connFD >= 0 { Darwin.close(connFD); connFD = -1 }
        unlink(sockPath)
    }

    private func readExactly(_ n: Int) -> Data? {
        var buf = Data(count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { raw -> Int in
                read(connFD, raw.baseAddress!.advanced(by: got), n - got)
            }
            if r > 0 { got += r } else if r < 0 && errno == EINTR { continue } else { return nil }
        }
        return buf
    }

    private func readLoop() {
        while let head = readExactly(MemoryLayout<Packet>.size) {
            let p = head.withUnsafeBytes { $0.load(as: Packet.self) }
            switch Msg(rawValue: p.type) {
            case .resize:
                onResize?(Int(p.a), Int(p.b), Int(p.c))
            case .damage:
                onDamage?(Int(p.a), Int(p.b), Int(p.c), Int(p.d))
            case .cursorVis:
                onCursorVisible?(p.a != 0, Int(p.b), Int(p.c))
            case .cursor:
                let bytes = Int(p.a) * Int(p.b) * 4
                guard bytes > 0, let pixels = readExactly(bytes) else { return }
                onCursor?(Int(p.a), Int(p.b), Int(p.c), Int(p.d), pixels)
            default:
                break
            }
        }
        print("[channel] 连接断开")
    }

    public func send(_ type: Msg, _ a: Int32 = 0, _ b: Int32 = 0, _ c: Int32 = 0, _ d: Int32 = 0) {
        guard connFD >= 0 else { return }
        var p = Packet(type: type.rawValue, a: a, b: b, c: c, d: d)
        sendLock.lock()
        _ = withUnsafeBytes(of: &p) { raw -> Int in
            write(connFD, raw.baseAddress!, raw.count)
        }
        sendLock.unlock()
    }
}

