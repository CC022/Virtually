// 调试启动参数:由 `virtually run` 传给 app,app 在启动时读取。
//
// 走 AppKit 原生的 `-键 值` 参数域(NSArgumentDomain),UserDefaults 直接就能读到。
// 以前用 `--flag` 风格,AppKit 会把无值开关和后面的路径错配成一对,
// 剩下的路径被当成要打开的文档 —— 那种启动下 SwiftUI 一个窗口都不建。
// 全部改成成对的 `-键 值` 之后,那一整套重排参数再 execv 自己的绕路就不需要了。

import Foundation

public struct DebugLaunch: Equatable, Sendable {
    /// 启动后直接打开这台虚拟机
    public var vmPath: String?
    /// 监听这个 Unix socket 接受调试命令(只挂给 vmPath 那一台)
    public var controlSocket: String?
    public var forceRamfb = false
    public var vblkProbe = false
    public var mountTools = false
    public var cursorDebug = false
    public var guestCursor = false
    public var extraISO: String?
    public var bootImage: String?
    public var displaySize: String?

    public init() {}

    public enum Key {
        public static let vmPath = "VMPath", controlSocket = "ControlSocket"
        public static let forceRamfb = "ForceRamfb", vblkProbe = "VblkProbe", mountTools = "MountTools"
        public static let cursorDebug = "CursorDebug", guestCursor = "GuestCursor"
        public static let extraISO = "ExtraISO", bootImage = "BootImage", displaySize = "DisplaySize"
    }

    /// app 启动时从参数域读。只看参数域,不看持久化的偏好 —— 调试参数不能残留到下次正常启动。
    public static func fromArguments() -> DebugLaunch {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        func string(_ k: String) -> String? { args[k] as? String }
        func bool(_ k: String) -> Bool { (args[k] as? String).map { ["YES", "1", "true"].contains($0) } ?? false }
        var d = DebugLaunch()
        d.vmPath = string(Key.vmPath)
        d.controlSocket = string(Key.controlSocket)
        d.forceRamfb = bool(Key.forceRamfb)
        d.vblkProbe = bool(Key.vblkProbe)
        d.mountTools = bool(Key.mountTools)
        d.cursorDebug = bool(Key.cursorDebug)
        d.guestCursor = bool(Key.guestCursor)
        d.extraISO = string(Key.extraISO)
        d.bootImage = string(Key.bootImage)
        d.displaySize = string(Key.displaySize)
        return d
    }

    /// 命令行工具拼给 app 的参数
    public var arguments: [String] {
        var a: [String] = []
        func add(_ k: String, _ v: String?) { if let v { a += ["-\(k)", v] } }
        func add(_ k: String, _ v: Bool) { if v { a += ["-\(k)", "YES"] } }
        add(Key.vmPath, vmPath)
        add(Key.controlSocket, controlSocket)
        add(Key.forceRamfb, forceRamfb)
        add(Key.vblkProbe, vblkProbe)
        add(Key.mountTools, mountTools)
        add(Key.cursorDebug, cursorDebug)
        add(Key.guestCursor, guestCursor)
        add(Key.extraISO, extraISO)
        add(Key.bootImage, bootImage)
        add(Key.displaySize, displaySize)
        // 调试实例不读也不写系统保存的窗口状态。上次调试退出时开着的虚拟机窗口若指向已删掉的包,
        // 恢复时 SwiftUI 连资源库都不建,-VMPath 指定的那台就永远打不开(实测:app 活着、一个窗口都没有)。
        // 也免得调试实例的窗口状态混进正常启动。
        if vmPath != nil { a += ["-ApplePersistenceIgnoreState", "YES"] }
        return a
    }

    /// 转成会话选项。安装介质不在这里:它记在虚拟机包的 config.json 里。
    public var sessionOptions: VMSession.Options {
        var o = VMSession.Options()
        o.forceRamfb = forceRamfb
        o.vblkProbe = vblkProbe
        o.mountTools = mountTools
        /// 强制保留宿主原生箭头。guest 若把光标画进帧缓冲就能同时看到两个,
        /// 两者的间距直观反映「输入 → guest 处理 → 画面呈现」整条链路的延迟。
        o.cursorDebug = cursorDebug
        o.hostCursor = !guestCursor
        o.extraISO = extraISO
        o.bootImage = bootImage
        if let ds = displaySize {
            let f = ds.split(separator: "x").compactMap { Int($0) }
            if f.count == 2 { o.displaySize = (f[0], f[1]) }
        }
        return o
    }
}
