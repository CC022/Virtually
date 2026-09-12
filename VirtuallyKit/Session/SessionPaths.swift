import Foundation

/// 每个 session 一组通道路径。
///
/// 路径带 pid:两个 app 实例(比如 CLI 起的调试实例和 Finder 里开着的 Virtually)
/// 曾经共用同一个帧缓冲文件,第二个 QEMU 一 O_TRUNC 第一个的 mmap 就指向了
/// 被截断重写的文件,画面串台。调试工具要的固定路径见 `debug`。
public struct SessionPaths: Sendable {
    public let display: String
    public let framebuffer: String
    public let agent: String
    public let qmp: String
    public let qemuLog: String

    nonisolated(unsafe) private static var counter = 0

    public static func next() -> SessionPaths {
        defer { counter += 1 }
        let base = "/tmp/virtually-\(getpid())" + (counter == 0 ? "" : "-\(counter)")
        return SessionPaths(
            display:     "\(base)-ctl.sock",
            framebuffer: "\(base)-fb.bin",
            agent:       "\(base)-agent.sock",
            qmp:         "\(base)-qmp.sock",
            qemuLog:     "\(base)-qemu.log")
    }

    /// 被 `virtually run` 拉起、接受调试控制的那台虚拟机用这组固定路径。
    /// `virtually shot` 读的就是这里的帧缓冲。
    public static let debug = SessionPaths(
        display:     "/tmp/virtually-ctl.sock",
        framebuffer: "/tmp/virtually-fb.bin",
        agent:       "/tmp/virtually-agent.sock",
        qmp:         "/tmp/virtually-qmp.sock",
        qemuLog:     "/tmp/virtually-qemu.log")

    public init(display: String, framebuffer: String, agent: String, qmp: String, qemuLog: String) {
        self.display = display
        self.framebuffer = framebuffer
        self.agent = agent
        self.qmp = qmp
        self.qemuLog = qemuLog
    }
}
