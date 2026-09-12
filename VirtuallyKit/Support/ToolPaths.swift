import AppKit

/// QEMU、固件与 guest agent 在 Virtually.app 里的位置。
///
/// app 是自包含的:QEMU 与它的 dylib 由 Scripts/embed-qemu.sh 在构建时嵌进去,
///   Contents/MacOS/qemu-system-aarch64、qemu-img
///   Contents/Frameworks/*.dylib
///   Contents/Resources/qemu/edk2-aarch64-code.fd
///   Contents/Resources/GuestAgent/{windows,linux}
/// app 自己用 `Bundle.main`;命令行工具先找到 Virtually.app 再用它的 bundle。
public struct ToolPaths: Sendable {
    public let qemu: URL
    public let qemuImg: URL
    /// edk2 固件所在目录,传给 QEMU 的 -L
    public let firmware: URL
    /// GuestAgent/ 目录
    public let guestAgent: URL

    public var windowsAgentScript: URL { guestAgent.appendingPathComponent("windows/agent.ps1") }
    public var linuxAgentDirectory: URL { guestAgent.appendingPathComponent("linux") }

    /// Windows 工具盘。**不能放在 bundle 里**:运行时写进 Resources 会破坏代码签名,
    /// 装在 /Applications 下也没有写权限。
    public static var toolsImage: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Virtually", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tools.img")
    }

    public init(appBundle: Bundle) {
        let contents = appBundle.bundleURL.appendingPathComponent("Contents")
        let resources = appBundle.resourceURL ?? contents.appendingPathComponent("Resources")
        qemu = contents.appendingPathComponent("MacOS/qemu-system-aarch64")
        qemuImg = contents.appendingPathComponent("MacOS/qemu-img")
        firmware = resources.appendingPathComponent("qemu")
        guestAgent = resources.appendingPathComponent("GuestAgent")
    }

    /// QEMU 真的在不在。app 没嵌好 QEMU 时给界面一句明白话,而不是启动时报找不到文件。
    public var isComplete: Bool {
        [qemu, qemuImg, firmware.appendingPathComponent("edk2-aarch64-code.fd"), windowsAgentScript]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

extension ToolPaths {
    /// `qemu-system-aarch64 --version` 的第一行,如 "QEMU emulator version 10.0.2"。
    /// 只跑一次,结果缓存;跑不出来给空串,指纹照样能用。
    public var qemuVersion: String {
        if let cached = Self.versionCache[qemu.path] { return cached }
        let p = Process()
        p.executableURL = qemu
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var version = ""
        if (try? p.run()) != nil {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            version = out.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
        Self.versionCache[qemu.path] = version
        return version
    }
    nonisolated(unsafe) private static var versionCache: [String: String] = [:]
}
