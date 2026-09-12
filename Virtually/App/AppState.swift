// 应用状态:资源库、正在运行的会话、启动参数。

import AppKit
import Metal
import VirtuallyKit

/// 指向一台虚拟机。WindowGroup(for:) 要求 Hashable + Codable,
/// 用包路径而不是 VMBundle 本身 —— 窗口恢复时 bundle 可能已经变了。
struct VMRef: Hashable, Codable, Identifiable {
    let path: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

@Observable @MainActor
final class AppState {
    static let shared = AppState()

    /// QEMU、固件与 guest agent 都在 app 自己的 bundle 里
    let tools = ToolPaths(appBundle: .main)
    let libraryURL = Preferences.libraryURL

    /// `virtually run` 传进来的调试参数;正常启动时全是默认值
    let debugLaunch = DebugLaunch.fromArguments()

    /// 资源库里的虚拟机。刷新是同步磁盘读,量很小(只读 config.json)。
    private(set) var library: [VMBundle] = []

    /// 已经在跑的会话,按包路径索引。
    /// **不能标 @ObservationIgnored** —— 资源库卡片上那个「运行中」的绿点靠它,
    /// 标了就永远不会亮也不会灭。
    private var sessions: [String: VMSession] = [:]

    /// 每台虚拟机上次离开时的画面。读盘只做一次,抓到新图直接更新这里。
    private(set) var thumbnails: [String: NSImage] = [:]

    /// 开不起来时给窗口看的原因,按包路径存 —— 两台同时开失败不能互相覆盖。
    /// 转圈转不出结果的界面等于没有界面。
    private(set) var launchErrors: [String: String] = [:]

    /// 启动参数指定了要开哪台;界面启动后立刻打开它并收起资源库窗口。用过一次就清掉,
    /// 否则资源库每次露面都会再开一遍并把自己关掉。
    @ObservationIgnored private(set) var launchTarget: VMRef?
    /// 接受调试控制的那一台。它用固定的通道路径(SessionPaths.debug)
    @ObservationIgnored private var debugTarget: VMRef?
    @ObservationIgnored private var controlServer: ControlServer?

    @ObservationIgnored private lazy var metalDevice: MTLDevice = {
        guard let d = MTLCreateSystemDefaultDevice() else {
            fatalError("没有可用的 Metal 设备")
        }
        return d
    }()

    private init() { refreshLibrary() }

    func refreshLibrary() {
        library = VMBundle.loadLibrary(at: libraryURL)
    }

    /// 后台读盘,回主线程一次性赋值 —— 不在 View 里按需读,
    /// 那等于在渲染过程中改状态。
    func loadThumbnails() {
        let urls = library.map { ($0.url.path, $0.thumbnailURL) }
        Task {
            let found: [String: NSImage] = await Task.detached(priority: .userInitiated) {
                var found: [String: NSImage] = [:]
                for (path, file) in urls {
                    if let img = NSImage(contentsOf: file) { found[path] = img }
                }
                return found
            }.value
            thumbnails = found
        }
    }

    func consumeLaunchArguments() {
        guard let path = debugLaunch.vmPath else { return }
        let ref = VMRef(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        launchTarget = ref
        debugTarget = ref
        print("[app] 启动参数指定打开 \(ref.path)")
    }

    /// 资源库窗口打开命令行指定的那台之后调用
    func takeLaunchTarget() -> VMRef? {
        defer { launchTarget = nil }
        return launchTarget
    }

    /// 取得(必要时创建并启动)某台虚拟机的会话。
    ///
    /// 调试启动指定的那一台带上调试参数(ramfb、工具盘等),从资源库点开的用默认选项。
    @discardableResult
    func session(for ref: VMRef) -> VMSession? {
        if let existing = sessions[ref.path] { return existing }
        launchErrors[ref.path] = nil

        let isDebugTarget = debugTarget == ref
        var options = isDebugTarget ? debugLaunch.sessionOptions : VMSession.Options()
        guard tools.isComplete else {
            launchErrors[ref.path] = "Virtually.app 里缺少 QEMU 或固件,这个构建不完整。"
            print("[app] \(launchErrors[ref.path]!)")
            return nil
        }
        guard let bundle = try? VMBundle.load(at: ref.url) else {
            launchErrors[ref.path] = "无法读取虚拟机包:\(ref.path)"
            print("[app] \(launchErrors[ref.path]!)")
            return nil
        }
        print("[vm] \(bundle.settings.name) —— \(bundle.settings.cpuCount) 核 / \(bundle.settings.memoryMB) MB")
        // 装到一半的机器:介质记在配置里,不管从哪条路打开都要带上
        if options.installMedia == nil, let media = bundle.settings.install {
            let missing = ([media.iso, media.boot, media.tools] + [media.virtioISO].compactMap { $0 })
                .filter { !FileManager.default.fileExists(atPath: $0) }
            if !missing.isEmpty {
                launchErrors[ref.path] = "这台虚拟机还没装完,但安装介质不在了:\n" + missing.joined(separator: "\n")
                print("[app] \(launchErrors[ref.path]!)")
                return nil
            }
            options.installMedia = media
        }

        // qcow2 的写锁是独占的。另一个 QEMU 还攥着的话,这里启动会立刻失败,
        // 而 QEMU 的错误只写在 /tmp 的日志里,界面上就是一个永远转不完的圈。
        // 先自己查一遍,把话说清楚。
        if let holder = QEMUProcesses.holding(path: bundle.diskURL.path) {
            launchErrors[ref.path] = "这台虚拟机已经在运行(进程 \(holder))。先把它关掉再开。"
            print("[app] \(launchErrors[ref.path]!)")
            return nil
        }

        // 固定的调试路径只给调试那一台;别的会话各自带 pid 取路径,
        // 否则同一进程里开第二台就会和第一台撞在同一组文件上。
        let session = VMSession(bundle: bundle, tools: tools,
                                paths: isDebugTarget ? .debug : .next(),
                                options: options, device: metalDevice)
        sessions[ref.path] = session
        session.onTerminated = { [weak self] _ in
            self?.sessions[ref.path] = nil
            self?.refreshLibrary()          // 「已挂起」徽章要跟着变
            self?.syncEmergencyList()
        }
        session.onThumbnail = { [weak self] img in
            self?.thumbnails[ref.path] = img
        }
        session.onInstallFinished = { [weak self] in self?.refreshLibrary() }   // 「安装中」徽章要摘掉
        do {
            try session.start()
        } catch {
            print("[app] 启动失败:\(error.localizedDescription)")
            launchErrors[ref.path] = error.localizedDescription
            sessions[ref.path] = nil
            return nil
        }
        syncEmergencyList()
        if isDebugTarget, let socket = debugLaunch.controlSocket {
            controlServer = ControlServer(path: socket, session: session)
        }
        return session
    }

    /// 有虚拟机还活着(含正在启动、正在恢复)。退出流程据此决定要不要先存状态。
    var hasLiveSessions: Bool { sessions.values.contains { $0.state.isLive } }

    func session(ifRunning ref: VMRef) -> VMSession? { sessions[ref.path] }

    /// 退出应用时先把每台虚拟机的状态存下来,存完再走。
    ///
    /// 返回 false 表示没有要存的,调用方可以直接退出。存盘要几秒到几十秒,
    /// 所以 `applicationShouldTerminate` 走 `.terminateLater`,不能阻塞主线程 ——
    /// 阻塞了进度就不会刷新,看起来就是应用卡死。
    ///
    /// 返回值是「是否每一台都存成功了」。**有一台没存下来就不能退出**:
    /// 以前成败一律算完成,随后 applicationWillTerminate 把所有 QEMU 强杀 ——
    /// 挂着工具盘、QMP 还没连上、savevm 随便什么原因失败,Windows 就被直接拔电源。
    /// 现在失败的那台把错误留在窗口上,用户从电源菜单关机后再退出。
    /// 180 秒兜底也按失败算:取消退出,窗口上还挂着「正在保存状态」,用户能看到并决定。
    func suspendAllSessions() async -> Bool {
        // 只有跑起来的才存状态。还在启动或正在恢复的 guest 一条指令都没跑,
        // 没什么可存的,交给 applicationWillTerminate 断电即可。
        let live = sessions.values.filter { $0.state.acceptsCommands }
        guard !live.isEmpty else { return true }
        enum Outcome { case done(Bool), timeout }
        return await withTaskGroup(of: Outcome.self) { group in
            for s in live { group.addTask { .done(await s.suspendAndWait()) } }
            group.addTask { try? await Task.sleep(for: .seconds(180)); return .timeout }
            var left = live.count
            var allOK = true
            for await outcome in group {
                switch outcome {
                case .timeout: group.cancelAll(); return false
                case .done(let ok):
                    if !ok { allOK = false }
                    left -= 1
                    if left == 0 { group.cancelAll(); return allOK }
                }
            }
            return allOK
        }
    }

    /// 兜底:把所有 QEMU 带走,不留孤儿。
    ///
    /// QEMU 是 Process 起的子进程,父进程没了它照样活着,只会被 launchd 收养 ——
    /// 然后一直攥着 qcow2 的写锁,下次再开这台虚拟机就是 `Failed to get "write" lock`。
    func terminateAllSessions() {
        let running = sessions.values.compactMap { $0.qemuProcess }
        for (_, s) in sessions { s.forcePowerOff() }
        sessions.removeAll()
        syncEmergencyList()
        Self.waitForExit(running)
    }

    /// SIGTERM 之后给 QEMU 一点时间自己收尾(它要刷 qcow2 的元数据并放锁)。
    /// 等不到也就算了,上限 3 秒 —— 退出流程不能卡住。
    nonisolated private static func waitForExit(_ processes: [Process]) {
        let deadline = Date().addingTimeInterval(3)
        for p in processes {
            while p.isRunning && Date() < deadline { usleep(50_000) }
        }
    }

    /// 信号处理那条路不在主 actor 上,不能碰 sessions;给它一份带锁的进程列表。
    private let emergency = ProcessRegistry()
    private func syncEmergencyList() {
        emergency.set(sessions.values.compactMap { $0.qemuProcess })
    }

    /// 进程收到 SIGTERM/SIGINT 时同样要带走 QEMU。
    /// Cocoa 应用在这些信号上走的是默认动作,`applicationWillTerminate` 不会被调到,
    /// 而 `pkill` 发的正是 SIGTERM。
    ///
    /// 信号源**不挂在主队列上**:主线程可能正卡在 terminate 的嵌套循环里(见 ControlServer 的 quit),
    /// 或者干脆死锁 —— 那正是最需要 SIGTERM 能生效的时候。这条路是紧急出口,
    /// 只碰 emergencyProcesses 那份快照,不碰主 actor 上的任何东西。
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler { [weak self] in
                self?.emergencyTerminate()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
    nonisolated private func emergencyTerminate() {
        let running = emergency.get()
        for p in running where p.isRunning { p.terminate() }
        Self.waitForExit(running)
    }
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored private let signalQueue = DispatchQueue(label: "virtually.signals")

    /// 新建并安装。建包、构建两张介质盘都是几分钟的阻塞操作,放后台线程跑,
    /// 阶段回调跳回主 actor 给界面。完成后刷新资源库并交出 VMRef,由界面打开虚拟机窗口。
    func createAndInstall(settings: VMSettings, iso: URL, virtioISO: URL?, variantID: String,
                          unattend: UnattendOptions,
                          ubuntu: UbuntuInstallOptions = UbuntuInstallOptions(),
                          progress: @escaping @MainActor (VMInstaller.Phase) -> Void) async throws -> VMRef {
        let libraryURL = libraryURL, tools = tools
        let bundle = try await Task.detached(priority: .userInitiated) {
            try VMInstaller.prepare(
                settings: settings, iso: iso, virtioISO: virtioISO, variantID: variantID,
                libraryURL: libraryURL, tools: tools, unattendOptions: unattend,
                ubuntuOptions: ubuntu,
                progress: { phase in Task { @MainActor in progress(phase) } }).bundle
        }.value
        refreshLibrary()
        return VMRef(path: bundle.url.path)
    }

    /// 读镜像里可装的变体。同步解析要几秒(要挂载或扫 ISO 树),放后台线程。
    func inspectISO(_ iso: URL, os: GuestOS) async throws -> [InstallVariant] {
        try await Task.detached(priority: .userInitiated) {
            try ISOInspector.variants(inISO: iso, os: os)
        }.value
    }

    /// 这张镜像看起来是哪个系统。只用来校验用户选的那一项,拿不准返回 nil。
    func detectISO(_ iso: URL) async -> GuestOS? {
        await Task.detached(priority: .userInitiated) { ISOInspector.detect(iso) }.value
    }
    var runningPaths: Set<String> { Set(sessions.keys) }

    // MARK: 设置、改名、删除(只对没在跑的虚拟机)

    /// 写回设置。名字变了就连目录一起改,返回新的引用。
    /// 改内存或核数会让挂起状态与快照对不上,界面上要提示;这里只管落盘。
    func updateSettings(_ ref: VMRef, _ settings: VMSettings) throws -> VMRef {
        guard sessions[ref.path] == nil else { throw VMError.busy("虚拟机正在运行,关机后才能改设置") }
        var bundle = try VMBundle.load(at: ref.url)
        var settings = settings
        settings.name = VMSettings.sanitizedName(settings.name)
        _ = settings.clamp()
        var url = ref.url
        if settings.name != bundle.settings.name {
            let dest = url.deletingLastPathComponent()
                .appendingPathComponent("\(settings.name).\(VMBundle.fileExtension)")
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                throw VMError.alreadyExists(dest.lastPathComponent)
            }
            try FileManager.default.moveItem(at: url, to: dest)
            url = dest
            bundle = VMBundle(url: dest, settings: bundle.settings)
        }
        bundle.settings = settings
        try bundle.save()
        refreshLibrary()
        return VMRef(path: url.path)
    }

    /// 整个包移到废纸篓 —— 几十 GB 的盘,误删了还能捞回来。
    func delete(_ ref: VMRef) throws {
        guard sessions[ref.path] == nil else { throw VMError.busy("虚拟机正在运行,关机后才能删除") }
        try FileManager.default.trashItem(at: ref.url, resultingItemURL: nil)
        thumbnails[ref.path] = nil
        refreshLibrary()
    }
}
