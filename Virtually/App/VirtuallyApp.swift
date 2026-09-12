// 应用入口、场景与菜单。
//
// 调试用的启动参数(直接开某台虚拟机、控制 socket 等)见 VirtuallyKit 的 DebugLaunch,
// 由命令行工具 `virtually run` 传入。

import SwiftUI
import VirtuallyKit

@main
struct VirtuallyMain {
    static func main() {
        // stdout 重定向到文件时是全缓冲的,要攒满 4KB 才落盘。`virtually run` 把日志写到文件,
        // 不改成行缓冲的话启动初期那几十行会一直卡在缓冲区里,看上去就像 app 没反应。
        setvbuf(stdout, nil, _IOLBF, 0)
        // main() 在主线程上,但类型上不是主 actor;AppState 是,所以要声明一下
        MainActor.assumeIsolated {
            AppState.shared.installSignalHandlers()
            AppState.shared.consumeLaunchArguments()
        }
        VirtuallyApp.main()
    }
}

// MARK: - 菜单

/// 当前带键盘焦点的虚拟机窗口里的会话,供菜单命令用
struct VMSessionFocusKey: FocusedValueKey { typealias Value = VMSession }
extension FocusedValues {
    var vmSession: VMSession? {
        get { self[VMSessionFocusKey.self] }
        set { self[VMSessionFocusKey.self] = newValue }
    }
}

/// 快捷键一律带 ⌃⌘:guest 视图会把普通的 ⌘ 组合截给 Windows 当 Win 键,
/// 只有 ⌃⌘ 会放行给宿主(见 GuestView.performKeyEquivalent)。
struct VMCommands: Commands {
    @FocusedValue(\.vmSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("虚拟机") {
            Button("挂起") { session?.suspend() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(session == nil)
            Button("关机") { session?.requestShutdown() }
                .disabled(session == nil)
            Divider()
            Button("资源库") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: [.control, .command])
        }
    }
}

struct VirtuallyApp: App {
    @State private var app = AppState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("虚拟机", id: "library") {
            LibraryView()
                .environment(app)
        }
        .defaultSize(width: 860, height: 560)
        .commands { VMCommands() }

        Settings { PreferencesView() }

        WindowGroup(id: "vm", for: VMRef.self) { $ref in
            if let ref {
                VMWindowView(ref: ref)
                    .environment(app)
            }
        }
        // 恢复窗口 = 把那台虚拟机开起来。这是 macOS 的默认行为,但要让用户能关掉
        .restorationBehavior(Preferences.restoreWindows ? .automatic : .disabled)
        // 工具栏要显示出来,所以保留标题栏。
        // 此前用 .hiddenTitleBar 配浮动胶囊,胶囊被判定体验不好已改回常驻工具栏。
        //
        // unifiedCompact 是这里唯一能压低工具栏高度的旋钮:默认样式实测 52 点,
        // 而 .controlSize(.small) 只作用于图标本身(量到 11x11),玻璃托盘仍是 36 点。
        // 标题也去掉 —— 虚拟机名在资源库里看得到,占着 345 点没有意义。
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}

/// 紧急出口用的进程列表:主 actor 写,信号队列读,靠锁隔开。
final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    func set(_ p: [Process]) { lock.lock(); processes = p; lock.unlock() }
    func get() -> [Process] { lock.lock(); defer { lock.unlock() }; return processes }
}

/// 只为了一件事:退出前把 QEMU 带走,不留孤儿进程攥着磁盘锁。
///
/// 用 applicationWillTerminate 而不是 SwiftUI 的 scene 生命周期 ——
/// Cmd+Q、菜单退出、注销、`kill` 都会走到这里。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 退出前先存状态。存盘期间应用还活着,窗口上照常显示「正在保存状态」。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.hasLiveSessions else { return .terminateNow }
        Task { @MainActor in
            let allSaved = await AppState.shared.suspendAllSessions()
            // 没存下来的不退出。退出等于强杀 QEMU,那台 Windows 就是被拔电源。
            if !allSaved { print("[app] 有虚拟机的状态没保存成功,取消退出") }
            NSApp.reply(toApplicationShouldTerminate: allSaved)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.terminateAllSessions()
    }
    /// 关掉最后一个窗口不等于退出 —— 资源库还在,虚拟机也可能还开着。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
