// 测试共用的断言与样例。
//
// 断言写成「条件 + 一句话说明」:失败时直接看到的是这条约束为什么存在,而不只是两个值不相等。

import Foundation
import Testing
import VirtuallyKit

func expect(_ condition: Bool, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition { Issue.record(Comment(rawValue: what), sourceLocation: sourceLocation) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    if a != b { Issue.record(Comment(rawValue: "\(what):期望 \(b),实际 \(a)"), sourceLocation: sourceLocation) }
}

/// 参数数组里 `flag` 后面紧跟的那个值
func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func values(after flag: String, in args: [String]) -> [String] {
    var out: [String] = []
    for (i, a) in args.enumerated() where a == flag && i + 1 < args.count {
        out.append(args[i + 1])
    }
    return out
}

/// 一台 Windows 虚拟机的设置与由它生成的 QEMU 参数。系统盘用 nvme,即刚装完、还没切 virtio-blk 的状态。
enum Fixture {
    static let original = VMSettings(name: "测试机", cpuCount: 3, memoryMB: 4096, diskSizeGB: 64,
                                     network: .user, audioEnabled: false,
                                     displayWidth: 1920, displayHeight: 1200,
                                     diskDriver: .nvme, snapshotShapes: [:], os: .windows)
    static let bundleURL = URL(fileURLWithPath: "/tmp/Fake.vmbundle")
    static let bundle = VMBundle(url: bundleURL, settings: original)

    static func command(_ settings: VMSettings = original, sock: String = "/d") -> QemuCommand {
        QemuCommand(bundle: VMBundle(url: bundleURL, settings: settings),
                    firmwareDir: URL(fileURLWithPath: "/fw"),
                    displaySocket: sock, framebufferPath: "/fb",
                    agentSocket: "/a", qmpSocket: "/q")
    }

    static var args: [String] { command().arguments() }

    static var noNet: VMSettings {
        var s = original
        s.network = .none
        return s
    }

    /// 设备指纹:决定快照能不能恢复
    static func shape(_ st: VMSettings, sock: String = "/d") -> String {
        command(st, sock: sock).migrationFingerprint()
    }
}
