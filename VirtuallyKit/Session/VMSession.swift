// 一台虚拟机的全部运行时状态。
//
// 一个会话一个实例,所以 app 能同时开多台,顺序契约也有明确的归属地。
//
// **不要把这些状态拆散**。分辨率那一组尤其:
// suppressResizeRequest / lastRequestedSize / guestSize / guestReady / resizeWork
// 与 pendingResolution / resolutionAttempt 是同一个状态机的两半
// (重构前一半在 Delegate、一半在顶层),拆开就会出现
// RESIZE → setContentSize → windowDidResize → 请求改分辨率 → 又一次 RESIZE 的死循环。

import AppKit
import ImageIO
import Metal

/// 整个会话活在主 actor 上:所有状态改动、所有 UI 触达都在主线程。
/// 通道回调(QMP 读线程、agent 线程、显示通道线程)一律 `Task { @MainActor in }` 跳回来,
/// 编译器替我们盯着 —— 以前靠手写 DispatchQueue.main.async,漏一处就是数据竞争。
@Observable @MainActor
public final class VMSession {

    /// 一台虚拟机在生命周期里的位置。**只有一个变量表示状态**。
    ///
    /// 以前是 `state`(四个 case)外加 `shuttingDown` / `userRequestedStop` / `resuming`
    /// 三个布尔在拼:`windowWantsToClose` 查两个、`suspend` 查三个、退出时查第四个,
    /// 每处各猜一遍,而且「QMP 还没握手完」和「正在跑」是同一个 `.running`。
    public enum State: Equatable {
        /// 还没 start()
        case idle
        /// QEMU 进程已起,QMP 还没握手完。这段时间任何 QMP 命令都会立刻报错。
        case starting
        /// 用 `-S` 起来的,正在 loadvm 把挂起状态读回来 —— guest 一条指令都还没跑。
        /// 这期间**不能**接受别的操作:loadvm 正在动磁盘。
        case restoring
        /// 正常运行。只有这个状态接受用户操作。
        case running
        /// 正在 savevm,存完就退出。存失败退回 `.running`。
        case suspending
        /// 正在关机(ACPI 或强制断电),不存状态
        case shuttingDown
        /// QEMU 已经退出
        case stopped(code: Int32)

        /// QEMU 进程还活着
        public var isLive: Bool {
            switch self {
            case .idle, .stopped: return false
            case .starting, .restoring, .running, .suspending, .shuttingDown: return true
            }
        }

        /// 能接受用户操作(挂起、快照、USB、网络、传文件)。
        /// 前提是 QMP 已连上、磁盘没在被 loadvm 动、也没在走退出流程。
        public var acceptsCommands: Bool { self == .running }

        /// 已经在走退出流程 —— 再点一次也不加速,而且退出是预期的
        public var isEnding: Bool { self == .suspending || self == .shuttingDown }

        public var hasExited: Bool { if case .stopped = self { return true }; return false }

        /// 给日志与调试通道看的名字
        public var label: String {
            switch self {
            case .idle:                return "idle"
            case .starting:            return "starting"
            case .restoring:           return "restoring"
            case .running:             return "running"
            case .suspending:          return "suspending"
            case .shuttingDown:        return "shuttingDown"
            case .stopped(let code):   return "stopped(\(code))"
            }
        }

        /// 不能操作时给用户的原因;可操作时为 nil
        public var blockedReason: String? {
            switch self {
            case .idle:         return "虚拟机尚未启动"
            case .starting:     return "虚拟机正在启动，请稍候"
            case .restoring:    return "虚拟机正在恢复，请稍候"
            case .suspending:   return "虚拟机正在挂起"
            case .shuttingDown: return "虚拟机正在关机"
            case .stopped:      return "虚拟机已关闭"
            case .running:      return nil
            }
        }
    }

    public struct Options {
        public var forceRamfb = false
        public var vblkProbe = false
        public var mountTools = false
        public var cursorDebug = false
        public var hostCursor = true
        public var displaySize: (w: Int, h: Int)?
        public var extraISO: String?
        /// 调试:一张 raw 盘挂到 bootindex 0(比如手工打的 Linux 引导盘),用来试安装路线
        public var bootImage: String?
        /// 非 nil 表示这是一次全新安装(介质记在 config.json 里,见 InstallMedia)
        public var installMedia: InstallMedia?

        public init() {}
    }

    // MARK: 不可观察的运行时组件

    @ObservationIgnored public var bundle: VMBundle
    @ObservationIgnored public let paths: SessionPaths
    @ObservationIgnored public let tools: ToolPaths
    @ObservationIgnored public let channel: DisplayChannel
    @ObservationIgnored public let agent: AgentChannel
    @ObservationIgnored public let qmp: QMPClient
    @ObservationIgnored public let view: GuestView
    @ObservationIgnored public let framebuffer: Framebuffer
    @ObservationIgnored public private(set) var qemu: Process?
    /// 点对点需要真 NSWindow:setContentSize / contentMinSize / 全屏都只有它有
    @ObservationIgnored public weak var window: NSWindow?

    /// QEMU 退出时回调(GUI 用来关窗口;命令行用来退进程)
    @ObservationIgnored public var onTerminated: ((Int32) -> Void)?
    @ObservationIgnored private var closeWatcher: WindowCloseWatcher?
    /// 这次开机要从挂起状态恢复(启动**意图**,不是当前状态)。
    /// QEMU 用 -S 停在原地,等 QMP 上来再 loadvm —— 那时状态才变成 `.restoring`。
    @ObservationIgnored private var wantsResume = false
    /// 刚从挂起状态回来,guest 的钟还停在存盘那一刻,等 agent 上线就把它拨正
    @ObservationIgnored private var needsTimeResync = false
    /// 挂起流程等 QEMU 真的退出才算完成 —— `quit` 的回复可能在 socket 关闭前丢掉。
    @ObservationIgnored private var suspendContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var launchedAt = Date()
    /// 安装期首次重启弹出介质,只做一次
    @ObservationIgnored private var installEjectPending = false
    /// 这次会话已经让 guest 扩过分区了(见 DiskResize.swift)
    @ObservationIgnored var partitionGrowSent = false

    // MARK: 供 UI 观察

    public private(set) var state: State = .idle
    public private(set) var guestSize: CGSize = .zero
    public private(set) var agentReady = false
    public private(set) var cursorSummary = "—"
    /// QEMU 非正常退出时的说明(含日志尾部)。以前窗口直接关掉,错误只在 /tmp 的日志里。
    public private(set) var launchFailure: String?
    /// 已透传给 guest 的宿主 USB 设备,按 `USBDevice.key` 索引。
    /// 必须活在会话里而不是面板的 @State 里 —— popover 一关状态就没了,
    /// 再打开全显示「未插入」,再点一次 device_add 就报 Duplicate ID。
    public private(set) var attachedUSB: [String: USBDevice] = [:]
    /// 当前的传输盘(见 TransferDisk.swift)。一次只有一张。
    public var transfer: TransferDisk?
    /// 等 QEMU 的 DEVICE_DELETED 事件说传输盘真的拔掉了(device_del 是异步的)
    @ObservationIgnored public var transferGoneContinuation: CheckedContinuation<Void, Never>?

    /// 剪贴板同步的记账:上次看到的宿主 changeCount 与上次从 guest 拿到的文本
    @ObservationIgnored private var clipboardTimer: Timer?
    @ObservationIgnored private var hostClipSeen = -1
    @ObservationIgnored private var guestClipLast: String?
    @ObservationIgnored private var clipboardSupported = true
    /// 调试:下一条 guest 剪贴板内容打到 stdout(平时每秒一条,不打)
    @ObservationIgnored public var debugPrintNextClip = false

    // MARK: 分辨率状态机(整体,不可拆)

    @ObservationIgnored private var suppressResizeRequest = false
    @ObservationIgnored private var lastRequestedSize = CGSize.zero
    @ObservationIgnored private var guestReady = false
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResolution = CGSize.zero
    @ObservationIgnored private var resolutionAttempt = 0

    // MARK: 光标

    @ObservationIgnored private var hwCursorSeen = false
    @ObservationIgnored private var cursorPoll: Timer?
    @ObservationIgnored private var cursorTakeover: Timer?
    @ObservationIgnored private var sessionPing: Timer?
    @ObservationIgnored private var cursorTakeoverDone = false
    @ObservationIgnored private let hostCursorEnabled: Bool

    private let options: Options

    // MARK: - 构造

    public init(bundle: VMBundle, tools: ToolPaths, paths: SessionPaths = .next(),
         options: Options = Options(), device: MTLDevice) {
        self.bundle = bundle
        self.tools = tools
        self.paths = paths
        self.options = options
        self.hostCursorEnabled = options.hostCursor
        self.networkMode = bundle.settings.network

        channel = DisplayChannel(sockPath: paths.display)
        agent = AgentChannel(sockPath: paths.agent)
        qmp = QMPClient(sockPath: paths.qmp)
        framebuffer = Framebuffer(device: device, path: paths.framebuffer)

        let initial = NSSize(width: bundle.settings.displayWidth / 2,
                             height: bundle.settings.displayHeight / 2)
        view = GuestView(frame: NSRect(origin: .zero, size: initial))
        view.channel = channel
        view.framebuffer = framebuffer
        view.cursorDebug = options.cursorDebug
        view.start(device: device)
        // 视图自己上报尺寸变化,不依赖窗口 delegate(SwiftUI 会接管那个)
        view.onResized = { [weak self] px in self?.windowResized(toBackingPixels: px) }
        view.onWindowAttached = { [weak self] window in self?.attach(to: window) }
    }

    // MARK: - 启动
    //
    // 顺序契约,一步都不能换:
    //   listen() → 装 channel.on* → acceptInBackground() → 装 qmp.onEvent
    //   → qemu.run() → qmp.connectWithRetry() → agent.connectWithRetry()
    //
    // QEMU 在 init 阶段就会来连,所以 listen() 必须最先。
    // 重构前 acceptInBackground() 排在 handler 之前,只因为 QEMU 要到很后面才启动
    // 才没出事 —— 这里把它修正了。

    public func start() throws {
        state = .starting

        do { try channel.listen() } catch {
            throw VMSessionError.channelListenFailed(paths.display, error)
        }
        installChannelHandlers()
        channel.acceptInBackground()

        installAgentHandlers()

        installEjectPending = options.installMedia != nil
        qmp.onEvent = { [weak self] event, msg in
            Task { @MainActor in self?.handleQMPEvent(event, msg) }
        }
        qmp.onReady = { [weak self] in
            Task { @MainActor in await self?.qmpReady() }
        }

        let process = try launchQEMU()
        qemu = process
        // **不是 .running**:QMP 要过一两秒才握手完,这期间发命令一律失败。
        // 以前这里直接标 .running,于是开机头几秒点红叉会卡在「正在保存状态」出不来。
        state = .starting
        qmp.connectWithRetry()
        agent.connectWithRetry()
    }

    /// QMP 握手完成。断网要在 guest 加载网卡驱动之前生效 —— 握手一完成就压下去。
    private func qmpReady() async {
        reapplyNetwork()
        // 只有 -S 起来的那次需要 cont;正常启动的 VM 本来就在跑,
        // 对它发 cont 只会换回一条错误。
        if wantsResume {
            if state == .starting { state = .restoring }
            await resumeFromSuspend()
            // 恢复期间用户可能已经强制断电了,别把状态踩回 .running
            if state == .restoring { state = .running }
        } else {
            if state == .starting { state = .running }
            // 没在恢复却还留着 __suspend__,那它就是孤儿(指纹不符被拒、或配置丢了)。
            // 界面把它滤掉了,不删的话 4GB 内存状态永远占着盘,用户还看不见。
            if await qmp.deleteSnapshot(tag: suspendTag) == nil {
                print("[挂起] 已清理一份用不上的旧状态")
            }
        }
    }

    /// 发送 ACPI 关机信号,guest 走正常关机流程(有未保存的东西会提示)
    public func requestShutdown() {
        guard state.isLive, !state.isEnding else { return }
        let previous = state
        state = .shuttingDown
        begin("正在关机…")
        Task {
            if let err = QMPClient.errorText(await qmp.execute("system_powerdown")) {
                state = previous          // 没发出去,虚拟机还在跑
                finish("无法关机：\(err)")
            }
        }
    }

    /// QEMU 的异步事件只有一个入口,在这里分发。以前 onEvent 只有一个槽位,
    /// 安装期弹盘占了它,别的事件就没地方接。
    private func handleQMPEvent(_ event: String, _ msg: [String: Any]) {
        switch event {
        case "RESET" where installEjectPending:
            // 首次重启后必须热拔安装盘与 ISO,否则会再次从安装盘引导,
            // Windows Setup 弹出「请移除该介质」停在那里等人确认。
            // 工具盘保留 —— 首次登录的 FirstLogonCommands 要用它装 agent。
            installEjectPending = false
            print("[install] 检测到首次重启,弹出安装介质")
            Task {
                await qmp.removeDevice(id: QemuCommand.deviceID(forExtra: 0))   // boot.img
                await qmp.removeDevice(id: QemuCommand.deviceID(forExtra: 1))   // ISO
            }
        case "DEVICE_DELETED":
            // 透传设备被拔掉(我们 device_del,或者 guest 侧弹出)时同步列表;传输盘同理
            let data = msg["data"] as? [String: Any]
            guard let id = data?["device"] as? String else { return }
            if id.hasPrefix("usbhost_") {
                attachedUSB = attachedUSB.filter { QMPClient.usbDeviceID($0.value) != id }
            } else if id.hasPrefix("xferdev") {
                transferDeviceGone(id)
            }
        default:
            break
        }
    }

    /// 红叉的处理:保存状态,下次开机接着用 —— 不是关机。
    /// 返回 false 表示这次不关窗口 —— 窗口要留到 QEMU 真的退出,
    /// 否则用户既看不到进度,也没地方改主意。
    private func windowWantsToClose() -> Bool {
        if state.hasExited { return true }
        guard !state.isEnding else { return false }   // 已经在存了/在关了,再点也不加速
        if options.installMedia != nil {
            // 安装期挂着 raw 的安装盘,savevm 必然失败;而且装到一半的状态也不值得存。
            // 关机,下次打开接着装(介质记在配置里)。
            requestShutdown()
        } else {
            suspend()
        }
        return false
    }

    /// 给退出流程用:等它真的死掉再走。
    public var qemuProcess: Process? { qemu }

    // MARK: - 缩略图
    //
    // 抓在 QEMU 退出这一刻,不是抓在 suspend() 里 —— 这样挂起、关机、强制断电、
    // 应用退出四条路都覆盖到了。QEMU 进程虽然没了,但帧缓冲那个文件还在,
    // mmap 依然有效,内容就是最后一帧。

    private func captureThumbnail() {
        // 没进过桌面就别抢这张图。实测在引导阶段强制断电,抓到的是 TianoCore
        // 那张启动画面 —— 它有 logo,躲得过空白判定,却把一张好好的桌面图覆盖掉了。
        // agentReady 是「guest 真的起来了」唯一可靠的信号。
        guard agentReady else { return }
        guard let cg = framebuffer.snapshot(maxWidth: 640) else { return }
        // 息屏时 QEMU 写的是 "Display output is not active" 那张近乎全黑的图。
        // 存下来还不如留着上一张。
        guard !Framebuffer.looksBlank(cg) else {
            print("[缩略图] 最后一帧几乎是空白,保留上一张")
            return
        }
        let url = bundle.thumbnailURL
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            print("[缩略图] 写入失败 \(url.path)"); return
        }
        onThumbnail?(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }

    /// 抓到新缩略图时通知界面,省得等下次重读磁盘
    @ObservationIgnored public var onThumbnail: ((NSImage) -> Void)?

    // MARK: - 挂起与恢复
    //
    // 关窗口不是关机,是把整机状态存下来,下次开机接着用。
    // 存的就是一条内部快照,标签 __suspend__,与用户自己存的那些走同一套机制。
    //
    // 恢复走 -S + QMP loadvm,而不是命令行的 -loadvm:失败时还能在进程里救回来。
    // load_snapshot 会先把磁盘回滚再读内存(migration/savevm.c),所以读内存失败时
    // 磁盘已经是快照那一刻的了 —— 这时候 reset + cont 冷启动恰好是一致的。
    // 用 -loadvm 的话 QEMU 直接就退出了,虚拟机看上去成了砖。

    private func resumeFromSuspend() async {
        if let err = await qmp.loadSnapshot(tag: suspendTag) {
            print("[挂起] 恢复失败,改为冷启动:\(err)")
            _ = await qmp.execute("system_reset")
        } else {
            print("[挂起] 已恢复")
            afterSnapshotLoaded()
        }
        // 不管成没成,这份状态都用掉了 —— 留着下次又会试一遍同样的失败
        _ = await qmp.deleteSnapshot(tag: suspendTag)
        forgetShape(of: suspendTag)
        _ = await qmp.execute("cont")
        // 恢复出来的链路状态是存的时候那一份,未必等于用户现在选的
        reapplyNetwork()
    }

    /// loadvm 成功之后两条路径(开机恢复挂起、会话内恢复用户快照)共用的收尾。
    private func afterSnapshotLoaded() {
        // guest 的钟停在存盘那一刻。agent 已连着就直接拨,没连上等它上线再拨。
        resyncGuestClock()
        // 恢复出来的 guest 多半不画光标(存盘前系统光标已被换成透明的,
        // 或者它用硬件光标而 QEMU 不会重新推位图)。先把宿主箭头顶上,
        // 等接管确认之后再交给形状轮询。
        view.setFallbackArrow(true)
        // 快照里带着存档时的链路状态,恢复回来未必等于用户现在选的
        reapplyNetwork()
    }

    private func resyncGuestClock() {
        guard agent.isConnected, agentReady else { needsTimeResync = true; return }
        // 传 Unix 秒而不是本地时间字符串:与 guest 时区无关。以前传宿主本地时间,
        // guest 时区一旦和宿主对不上(映射表里没有的时区退回 UTC),钟就被拨错一整个偏移。
        agent.send("settime \(Int(Date().timeIntervalSince1970))")
    }

    /// 关窗口走这里:存状态,存完退出 QEMU。存不下来就什么都不做,窗口留着。
    public func suspend() { Task { _ = await suspendAndWait() } }

    /// 同上,但等到有结果:退出应用时要等所有虚拟机都有结果。
    /// 成功的信号挂在 QEMU 进程退出上,而不是 `quit` 的回复:QEMU 可能先关 socket 再让回复到达。
    public func suspendAndWait() async -> Bool {
        guard !state.isEnding, !state.hasExited else { return false }
        // 这次开机挂过安装介质:工具盘、驱动 ISO 之类不支持快照,savevm 必然失败。
        // 装完之后也一样,要关机或重启一次,下次开机不挂介质了才能挂起。
        guard options.installMedia == nil else {
            finish(bundle.settings.install == nil
                   ? "安装后首次启动时无法挂起。请重新启动虚拟机或将其关机。"
                   : "安装期间无法挂起。请等待安装完成，或将虚拟机关机。")
            return false
        }
        guard state.acceptsCommands else {
            finish(state.blockedReason)
            return false
        }
        state = .suspending
        begin("正在挂起…")
        // 先拔掉透传的 USB 设备。usb-host 会进内存状态,而下次开机命令行上没有它,
        // loadvm 报 Unknown savevm section,挂起状态就废了,表现为「明明挂起了,再开却是重启」。
        await detachAllUSB()
        // 先把旧的那份删掉。savevm 对已存在的标签会报错。
        _ = await qmp.deleteSnapshot(tag: suspendTag)
        if let err = await qmp.saveSnapshot(tag: suspendTag) {
            if state == .suspending { state = .running }
            // 最常见的原因是挂了不支持快照的盘(`virtually run --tools` 挂的工具盘就是),
            // 平时不会遇到。把 QEMU 的原话带上,否则无从下手。
            finish("无法挂起：\(err)。可以改为关机。")
            return false
        }
        rememberShape(of: suspendTag)
        if state.hasExited { return true }   // 存的过程中 QEMU 已经没了
        return await withCheckedContinuation { cont in
            suspendContinuation = cont
            Task {
                _ = await qmp.execute("quit")
                // quit 之后 QEMU 不退就强杀。状态已经落盘,之后的写入本来就会被下次 loadvm 丢掉。
                try? await Task.sleep(for: .seconds(20))
                if let p = qemu, p.isRunning {
                    print("[挂起] QEMU 收到 quit 后 20 秒仍未退出,强制断电")
                    p.terminate()
                }
            }
        }
    }

    /// 直接断电。相当于拔电源线,guest 没有机会保存任何东西。
    public func forcePowerOff() {
        guard state.isLive else { return }
        state = .shuttingDown
        qemu?.terminate()
    }

    /// 视图入窗时统一设置窗口策略。
    ///
    /// 点对点依赖 setContentSize,全屏与最小尺寸也都只有真 NSWindow 才有 ——
    /// 所以会话必须持有窗口引用,不能只靠纯 SwiftUI 的 .frame。
    private func attach(to window: NSWindow) {
        self.window = window
        // 点红叉不是「把窗口收起来」,是关这台虚拟机。
        // 以前关了窗口 QEMU 还在跑,而应用退出时又不管它,于是留下一个没有父进程的
        // QEMU 死死攥着 qcow2 的写锁 —— 下次再开这台虚拟机就是
        // `Failed to get "write" lock`,表现为「开不了机」。
        // 不把 SwiftUI 自己的 delegate 顶掉:只截 windowShouldClose,别的都转发回去。
        closeWatcher = WindowCloseWatcher(forwardingTo: window.delegate) { [weak self] in
            self?.windowWantsToClose() ?? true
        }
        window.delegate = closeWatcher
        window.acceptsMouseMovedEvents = true            // mouseMoved 必需
        window.makeFirstResponder(view)                  // 键盘输入必需
        window.collectionBehavior.insert(.fullScreenPrimary)
        // 最小值按 guest 的**像素**下限换算成点,这样无论几倍屏,
        // 拖到最小时 guest 分辨率也不会低于 800x600。
        let scale = window.screen?.backingScaleFactor ?? 2
        window.contentMinSize = NSSize(width: VMDisplay.minWidth / scale,
                                       height: VMDisplay.minHeight / scale)
        window.title = bundle.settings.name
    }

    // MARK: - 供界面调用

    public func toggleFullScreen() { window?.toggleFullScreen(nil) }

    // MARK: - 长任务状态
    //
    // 进行中状态与结果必须活在会话里,不能活在 popover 的 View 里 ——
    // popover 一关 View 就销毁,而 savevm 要落 GB 级内存状态、实测几十秒,
    // 结果回来时早就没人接了。用户看到的就是「点了没反应」。

    public struct SnapshotRow: Identifiable, Equatable {
        public let id: String       // tag
        public let size: String
        public let date: String

        public init(id: String, size: String, date: String) {
            self.id = id
            self.size = size
            self.date = date
        }
    }

    public private(set) var busyMessage: String?
    public private(set) var lastError: String?

    /// 界面据此禁用操作:有长任务在跑,或虚拟机不在可操作状态。
    public var isBusy: Bool { busyMessage != nil || !state.acceptsCommands }

    /// 状态条上显示什么。长任务的文案优先,其次是状态本身值得说的那几个 ——
    /// 从挂起恢复要几秒黑屏,不说一句用户不知道发生了什么。
    public var statusText: String? {
        if let busyMessage { return busyMessage }
        // 安装进度优先于「正在启动」:装系统那十几分钟里它是唯一的反馈
        if let installerStatus { return installerStatus }
        switch state {
        case .starting:  return "正在启动…"
        case .restoring: return "正在恢复…"
        default:         return nil
        }
    }
    public private(set) var snapshots: [SnapshotRow] = []
    /// 界面显示用。构造时从配置初始化,之后由 applyNetwork 维护。
    public private(set) var networkMode: NetworkMode = .none

    public func begin(_ what: String) {
        busyMessage = what
        lastError = nil
    }
    public func finish(_ err: String?) {
        busyMessage = nil
        lastError = err
        // 出错必须落到 stdout。界面上有提示,但 `virtually send` 那条调试路径只看日志 ——
        // 「点了没反应」查半天,结果错误一直躺在一个没人读的属性里。
        if let err { print("[vm] \(err)") }
    }

    public func clearError() { lastError = nil }

    // MARK: 网络

    public func applyNetwork(_ mode: NetworkMode) {
        begin("正在切换网络…")
        Task {
            let err = await setNetwork(mode)
            if err == nil {
                networkMode = mode
                persistNetwork(mode)
            }
            finish(err.map { "无法切换网络：\($0)" })
        }
    }

    // MARK: 快照

    /// savevm 要落 GB 级内存状态,几十秒是正常的 —— 界面必须说出来,
    /// 否则用户等几秒就以为坏了(实测就是这么被误判的)。
    public func saveSnapshot(named tag: String) {
        guard !isBusy else { lastError = state.blockedReason; return }
        if let problem = Self.snapshotNameProblem(tag) { lastError = problem; return }
        begin("正在拍摄快照…")
        Task {
            // 同挂起:透传的 USB 设备不能进快照,恢复时它不在了整条快照就读不回来
            await detachAllUSB()
            let err = await qmp.saveSnapshot(tag: tag)
            if err == nil { rememberShape(of: tag) }
            finish(err.map { "无法拍摄快照：\($0)" })
            await refreshSnapshotsNow()
        }
    }

    /// 快照名进 HMP 命令行,按空格切参数;`info snapshots` 的输出也按空格切列。
    /// 所以只允许一小撮字符。内部标签也不许用户占。
    public nonisolated static func snapshotNameProblem(_ tag: String) -> String? {
        if tag.isEmpty { return "请输入快照名称" }
        if tag == suspendTag { return "“\(tag)”是保留名称" }
        let ok = tag.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)
        }
        if !ok || tag.count > 64 { return "名称只能包含字母、数字和 _ - .，最多 64 个字符" }
        return nil
    }

    /// 开机时那条命令行的设备指纹。存快照时记下来,恢复前拿它比对。
    @ObservationIgnored private var currentShape = ""

    /// 这条快照现在能不能恢复。界面据此把「恢复」按钮灰掉 ——
    /// 让用户点下去再报错是不行的,那一下会把磁盘换掉。
    public func canRestore(_ tag: String) -> Bool {
        bundle.settings.snapshotShapes[tag] == currentShape
    }

    private func rememberShape(of tag: String) {
        var updated = bundle
        var shapes = updated.settings.snapshotShapes
        shapes[tag] = currentShape
        updated.settings.snapshotShapes = shapes
        do { try updated.save(); bundle = updated }
        catch { print("[vm] 快照指纹没能写回配置:\(error.localizedDescription)") }
    }

    private func forgetShape(of tag: String) {
        var shapes = bundle.settings.snapshotShapes
        guard shapes[tag] != nil else { return }
        shapes[tag] = nil
        var updated = bundle
        updated.settings.snapshotShapes = shapes
        do { try updated.save(); bundle = updated } catch { }
    }

    public func restoreSnapshot(_ tag: String) {
        guard !isBusy else { lastError = state.blockedReason; return }
        // **必须在动手之前挡住。** QEMU 的 loadvm 是先回滚磁盘再读内存,
        // 等它报错时磁盘已经换过去了,虚拟机只能断电。
        guard canRestore(tag) else {
            lastError = "快照“\(tag)”与当前硬件配置不兼容，无法恢复"
            return
        }
        begin("正在恢复快照…")
        Task {
            await detachAllUSB()
            guard let err = await qmp.loadSnapshot(tag: tag) else {
                afterSnapshotLoaded()
                finish(nil)
                await refreshSnapshotsNow()
                return
            }
            // **失败时只能断电,绝不能 cont。**
            //
            // load_snapshot 的顺序是:bdrv_all_goto_snapshot() → qemu_system_reset()
            // → qemu_loadvm_state()(migration/savevm.c)。也就是说读内存失败时,
            // **磁盘已经回滚到快照那一刻了**,而且 CPU 已被复位。
            // 这时 cont 等于让一台刚复位的机器在一块被换掉的磁盘上继续跑 ——
            // 实测就是这么把一台虚拟机写坏的:之后固件阶段 100% CPU 空转,再也起不来。
            //
            // 断电是安全的:磁盘此刻就是快照那一刻的状态,重新开机能正常引导。
            forcePowerOff()
            finish(Self.explainRestore(err: err, tag: tag))
        }
    }

    /// 最常见的失败是设备配置变了 —— 快照存的是整机状态,包含每个设备的状态,
    /// 设备增减之后就对不上。直接把 QEMU 的原话抛给用户没有意义。
    public nonisolated static func explainRestore(err: String, tag: String) -> String {
        let tail = "。虚拟机已关机，磁盘已回到快照“\(tag)”，可以重新启动。"
        if err.contains("does not exist in one or more devices")
            || err.contains("Unknown savevm section")
            || err.contains("Unknown ramblock") {
            return "快照“\(tag)”与当前硬件配置不兼容" + tail
        }
        return "无法恢复快照：\(err)" + tail
    }

    public func deleteSnapshot(_ tag: String) {
        guard !isBusy else { lastError = state.blockedReason; return }
        begin("正在删除快照…")
        Task {
            let err = await qmp.deleteSnapshot(tag: tag)
            if err == nil { forgetShape(of: tag) }
            finish(err.map { "无法删除快照：\($0)" })
            await refreshSnapshotsNow()
        }
    }

    /// `info snapshots` 返回的是 HMP 的纯文本表格,只能自己解析。
    /// 形如:  `--  clean-install  1.57 GiB 2026-09-08 20:23:52  0000:01:49.713  --`
    public func refreshSnapshots() { Task { await refreshSnapshotsNow() } }

    public func refreshSnapshotsNow() async {
        let out = await qmp.listSnapshots()
        snapshots = Self.parseSnapshots(out).filter { $0.id != suspendTag }
    }

    public nonisolated static func parseSnapshots(_ text: String) -> [SnapshotRow] {
        // **必须用 isNewline,不能 split(separator: "\n")**。
        // HMP 的输出是 CRLF 行尾,而 Swift 把 "\r\n" 当作单个 Character,
        // 按 "\n" 切一个都匹配不到,整段文本会被当成一行 —— 于是解析出 0 条,
        // 界面上表现为「保存成功了但列表不更新」。
        // 同一个坑在 QMP 客户端和 agent 通道上各踩过一次,这是第三次。
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 7 else { return nil }
            // 首列是 ID:要么是数字,要么是 "--"。表头与提示行都过不了这一关。
            guard f[0] == "--" || Int(f[0]) != nil else { return nil }
            return SnapshotRow(id: String(f[1]),
                               size: "\(f[2]) \(f[3])",
                               date: "\(f[4]) \(f[5])")
        }
    }

    // MARK: USB

    public func isAttached(_ d: USBDevice) -> Bool { attachedUSB[d.key] != nil }

    public func attachUSB(_ d: USBDevice) {
        guard !isBusy, !isAttached(d) else { return }
        begin("正在连接“\(d.name)”…")
        Task {
            let err = await qmp.attachUSB(d)
            if err == nil { attachedUSB[d.key] = d }
            finish(err.map { Self.explainUSB(err: $0, device: d) })
        }
    }

    public func detachUSB(_ d: USBDevice) {
        guard !isBusy, isAttached(d) else { return }
        begin("正在断开“\(d.name)”…")
        Task {
            let err = await qmp.detachUSB(d)
            // 「设备不存在」也算拔掉了:多半是宿主侧已经物理拔出,QEMU 早就把它删了
            if err == nil || err!.contains("not found") { attachedUSB[d.key] = nil }
            finish(err.map { Self.explainUSB(err: $0, device: d) })
        }
    }

    /// 存快照 / 挂起前把透传设备全部拔掉,拔完(不论成败)再返回。不改 busy 状态,调用方自己管。
    /// 传输盘(raw,savevm 不认)也在这里一起拔。
    private func detachAllUSB() async {
        await detachTransferDiskForSnapshot()
        let devices = Array(attachedUSB.values)
        guard !devices.isEmpty else { return }
        print("[usb] 存快照前先拔出 \(devices.count) 个透传设备")
        for d in devices {
            if let err = await qmp.detachUSB(d) { print("[usb] 拔出 \(d.name) 失败:\(err)") }
            attachedUSB[d.key] = nil
        }
    }

    /// QMP 的原始错误对用户没有意义,补一句可操作的解释
    public nonisolated static func explainUSB(err: String, device: USBDevice) -> String {
        if err.contains("Permission") || err.contains("Access") {
            return "“\(device.name)”正被 macOS 使用。如果是 U 盘，请先在访达中推出。"
        }
        if err.contains("No such device") || err.contains("not found") {
            return "“\(device.name)”已移除"
        }
        return "“\(device.name)”：\(err)"
    }

    /// 网络热插拔:不重启虚拟机就能换网络模式。返回错误文案,成功为 nil。
    public func setNetwork(_ mode: NetworkMode) async -> String? {
        // 只切链路。网卡是开机就在的固定设备 —— 见 VMBundle 里那段注释:
        // 增删设备会让快照在网络开关前后不兼容。
        QMPClient.errorText(await qmp.execute("set_link", arguments: ["name": "nic0", "up": mode == .user]))
    }

    /// 用户的选择要留到下次开机。写失败不打扰用户 —— 网络这次已经切好了。
    private func persistNetwork(_ mode: NetworkMode) {
        var updated = bundle
        updated.settings.network = mode
        do { try updated.save(); bundle = updated }
        catch { print("[vm] 网络设置没能写回配置:\(error.localizedDescription)") }
    }

    /// 把当前网络模式重新压到 QEMU 上。开机后和每次恢复快照后都要做一次:
    /// 快照里带着存档时的链路状态,恢复回来可能与用户现在选的不一致。
    public func reapplyNetwork() {
        let mode = networkMode
        Task { _ = await setNetwork(mode) }
    }

    // MARK: - 通道回调

    private func installChannelHandlers() {
        channel.onResize = { [weak self] w, h, stride in
            Task { @MainActor in self?.handleGuestResize(w: w, h: h, stride: stride) }
        }
        channel.onDamage = { [weak self] _, _, _, _ in
            Task { @MainActor in self?.view.markDirty() }
        }
        channel.onCursor = { [weak self] w, h, hx, hy, pixels in
            Task { @MainActor in
                guard let self else { return }
                if !self.hwCursorSeen {
                    self.hwCursorSeen = true
                    self.view.setFallbackArrow(false)   // guest 给位图了,用它的
                    // 硬件光标可能晚到(Ubuntu 进桌面后几秒才开光标平面),这时接管已经在重试了。
                    // 不停掉的话它 3 分钟后放弃,顶一个宿主箭头上来 —— 屏幕上就是两个光标。
                    if !self.cursorTakeoverDone { self.cursorTakeover?.invalidate() }
                    print("[cursor] guest 启用了硬件光标(\(w)x\(h)),改用它上报的位图")
                }
                self.view.setGuestCursor(w: w, h: h, hotX: hx, hotY: hy, pixels: pixels)
            }
        }
        channel.onCursorVisible = { [weak self] on, gx, gy in
            Task { @MainActor in
                self?.view.setCursorVisible(on)
                self?.view.reportGuestCursor(x: gx, y: gy)
            }
        }
    }

    /// guest 换了分辨率 → 重映射帧缓冲、让窗口贴合以保证点对点
    private func handleGuestResize(w: Int, h: Int, stride: Int) {
        framebuffer.remap(width: w, height: h, stride: stride)
        view.resizeSurface(width: w, height: h)

        if let window {
            let scale = window.backingScaleFactor
            // 两种情况下不能动窗口:
            //   * 全屏时窗口尺寸由系统决定,改它会打架
            //   * 已经吻合时改它是无谓的抖动(拖拽末尾很容易触发)
            // 有工具栏之后 contentView 不再等于 guest 视图,差的那一条必须补上,
            // 否则窗口与 guest 尺寸永远差一个工具栏高度,来回抖动对不齐。
            let content = window.contentView?.bounds.size ?? .zero
            let chromeH = max(0, content.height - view.bounds.height)
            let chromeW = max(0, content.width - view.bounds.width)
            let want = NSSize(width: CGFloat(w) / scale + chromeW,
                              height: CGFloat(h) / scale + chromeH)
            let now = content
            let fullscreen = window.styleMask.contains(.fullScreen)
            if !fullscreen,
               abs(want.width - now.width) > 0.5 || abs(want.height - now.height) > 0.5 {
                suppressResizeRequest = true
                window.setContentSize(want)
                suppressResizeRequest = false
            }
        }

        lastRequestedSize = CGSize(width: w, height: h)
        guestSize = CGSize(width: w, height: h)
        // 引导早期(640x480 之类)不要请求改分辨率 —— 那会把 virtio-gpu 的 scanout 关掉
        if w > 640 || h > 480 { guestReady = true }
    }

    private func installAgentHandlers() {
        // 两个回调都在 agent 线程上到达,整体跳回主 actor再处理(每秒二十来条,开销可忽略)
        agent.onLine = { [weak self] line in
            Task { @MainActor in self?.agentLine(line) }
        }
        agent.onReady = { [weak self] in
            Task { @MainActor in self?.agentBecameReady() }
        }
    }

    private func agentLine(_ line: String) {
        let f = line.split(separator: " ")
        if line.hasPrefix("err no session helper") || line.hasPrefix("err session helper lost") {
            // 两段式:改分辨率和光标由会话侧处理。system 侧在,但用户会话里的
            // 那一半没起来 —— 显示相关的功能会静默失效,必须说出来。
            // 命令是被**丢掉**的,不是排队等着,所以发起方得自己重试。
            if hostCursorEnabled { cursorTakeoverLost() }
            print("[agent] guest 的会话侧助手未运行,显示相关命令暂不可用")
            return
        }
        if line.hasPrefix("ok sesping") { return }   // 每 10 秒一条,不打日志
        if line.hasPrefix("ok hidecursor on") {
            cursorTakeoverConfirmed()
            print("[agent] \(line)")
            return
        }
        if line.hasPrefix("vainstall ") {
            installerReported(String(line.dropFirst("vainstall ".count)))
            return
        }
        if line.hasPrefix("err setres") { handleResolutionFailure() }
        if line.hasPrefix("clip ") || line == "clip" {
            let b64 = line.count > 5 ? String(line.dropFirst(5)) : ""
            guestClipboardArrived(b64)
            return   // 每秒一条,不打日志
        }
        if line.hasPrefix("err unknown clip") {
            // 老 agent 没有这两条命令;别每秒刷一条错误
            clipboardSupported = false
            clipboardTimer?.invalidate()
            print("[剪贴板] guest 的 agent 版本太老,不支持剪贴板同步(virtually build-tools 重建工具盘,再 run --tools 开一次机可更新)")
            return
        }
        if line.hasPrefix("ok setres") { pendingResolution = .zero }
        if let outcome = PartitionGrow.parse(line) {
            partitionGrowReported(outcome)
            return
        }
        if f.count >= 2, f[0] == "cursor" {
            view.setHostCursor(name: String(f[1]), showing: f.count < 3 || f[2] != "0")
            cursorSummary = view.cursorStatus
            return   // 每秒 20 条,不打日志
        }
        print("[agent] \(line)")
    }

    private func agentBecameReady() {
        print("[agent] guest 侧已就绪")
        agentReady = true
        startSessionPing()
        if needsTimeResync {
            needsTimeResync = false
            resyncGuestClock()
        }
        finishInstallIfNeeded()
        growPartitionIfNeeded()
        installerStatus = nil      // agent 上线就说明装完了,进度条该撤了
        startClipboardSync()
        guard hostCursorEnabled else { return }
        // 光标命令只在**形状变化或指针出现**时才发,开机后鼠标没动过就一条都收不到。
        // 所以先动一下鼠标把它逼出来,再给足 3 秒判定。
        channel.send(.mouseAbs, Int32(guestSize.width / 2), Int32(guestSize.height / 2))
        Task {
            try? await Task.sleep(for: .seconds(3))
            if hwCursorSeen {
                print("[cursor] 硬件光标可用,不做全局替换")
                cursorSummary = view.cursorStatus
                return
            }
            // 透明系统光标这套只有 Windows 的 agent 做得到。Linux 的 virtio-gpu 驱动总用硬件光标,
            // 没见到只是还没开光标平面,等位图来就行,宿主箭头先顶着(onCursor 里会撤掉)。
            guard bundle.settings.os == .windows else {
                print("[cursor] 还没收到硬件光标,先用宿主箭头等它")
                view.setFallbackArrow(true)
                cursorSummary = view.cursorStatus
                return
            }
            print("[cursor] 未见硬件光标,改用透明系统光标 + 形状轮询")
            beginCursorTakeover()
        }
    }

    /// agent 能上线,说明驱动和 agent 都装好了 —— 安装到此结束。
    /// 把介质从配置里清掉(下次开机不再挂),包内的 boot.img / tools.img / 探测盘删掉。
    /// 这一次开机挂着的盘不动,QEMU 退出后文件才真的释放。
    private func finishInstallIfNeeded() {
        guard options.installMedia != nil, bundle.settings.install != nil else { return }
        var updated = bundle
        updated.settings.install = nil
        do {
            try updated.save()
            bundle = updated
            print("[install] 安装完成,介质已从配置里清掉")
            onInstallFinished?()
        } catch {
            print("[install] 安装完成但配置没能写回:\(error.localizedDescription)")
        }
    }
    /// 安装完成时通知界面刷新资源库(徽章要变),并在 QEMU 退出后删介质
    @ObservationIgnored public var onInstallFinished: (() -> Void)?

    /// Ubuntu 安装器回传的状态。桌面版安装器的界面不会跟着服务端刷新,我们把它关掉了,
    /// 所以这条是用户在十几分钟里唯一的进度来源(见 UbuntuInstall.swift 的说明)。
    public private(set) var installerStatus: String?

    private func installerReported(_ rest: String) {
        let text: String
        switch rest {
        case "waiting":         text = "正在准备安装…"
        case "confirmed":       text = "正在安装…"
        case "confirm-failed":  text = "未能自动开始安装，请在虚拟机中点按“Install”"
        case "RUNNING":         text = "正在安装…"
        case "POST_RUNNING":    text = "正在完成配置…"
        case "DONE":            text = "安装完成，正在重新启动…"
        case "ERROR":           text = "安装出错，请查看虚拟机窗口"
        default:                text = "正在安装…"
        }
        installerStatus = text
        print("[install] \(rest) → \(text)")
    }

    // MARK: 剪贴板
    //
    // 只同步文本。每秒问 guest 一次 `clipget`,宿主这边看 NSPasteboard.changeCount。
    // 两个方向都记住「上次是谁写的」,否则 A 写给 B、B 又写回 A,来回抖。
    // 只在窗口是 key 时同步 —— 用户不在这台机器上时没必要每秒一次往返。

    private func startClipboardSync() {
        clipboardTimer?.invalidate()
        guard clipboardSupported else { return }
        hostClipSeen = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipboardTick() }   // Timer 在主 run loop 上触发
        }
    }

    /// 调试:不管窗口是不是 key,立刻同步一次
    public func debugClipboardTick() { clipboardTick(force: true) }

    private func clipboardTick(force: Bool = false) {
        guard agent.isConnected, force || (Preferences.clipboardSync && window?.isKeyWindow == true) else { return }
        let pb = NSPasteboard.general
        if pb.changeCount != hostClipSeen {
            hostClipSeen = pb.changeCount
            if let text = pb.string(forType: .string), text != guestClipLast {
                guestClipLast = text
                agent.send("clipset " + Data(text.utf8).base64EncodedString())
                return
            }
        }
        agent.send("clipget")
    }

    private func guestClipboardArrived(_ b64: String) {
        guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) else { return }
        if debugPrintNextClip {
            debugPrintNextClip = false
            print("OK guest 剪贴板=「\(text)」 宿主=「\(NSPasteboard.general.string(forType: .string) ?? "")」")
        }
        guard text != guestClipLast else { return }
        guestClipLast = text
        let pb = NSPasteboard.general
        // 空文本不推:guest 复制了图片或文件时 Get-Clipboard 也会回空,别把宿主的剪贴板清掉
        guard !text.isEmpty else { return }
        pb.clearContents()
        pb.setString(text, forType: .string)
        hostClipSeen = pb.changeCount
    }

    // MARK: 光标接管
    //
    // 「把 guest 的系统光标换成透明位图」这一步**必须确认成功之后**才能开始自己画,
    // 否则就是两个光标:guest 画进帧缓冲的那个,加上我们按轮询形状画的那个。
    //
    // 它确实会失败。会话侧助手要等用户登录才起来,而这里在 agent 就绪后 3 秒就发 ——
    // 早了的话 system 侧只回一句 `err no session helper` 就把命令丢了,
    // 而 `getcursor` 稍后又能成功,于是轮询照常开始,两个光标就这么来的。
    // 这是个竞态,所以时好时坏。

    private func beginCursorTakeover() {
        cursorTakeoverDone = false
        cursorTakeover?.invalidate()
        agent.send("hidecursor on")
        var tries = 0
        cursorTakeover = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.cursorTakeoverDone else { t.invalidate(); return }
                tries += 1
                guard tries <= 90 else {
                    // 3 分钟还没起来就别试了。但不能就这么撒手 —— guest 未必在画光标,
                    // 撒手就等于一个光标都没有。顶一个宿主箭头上去。
                    print("[cursor] 会话侧助手一直没起来,改用宿主箭头")
                    self.view.setFallbackArrow(true)
                    t.invalidate(); return
                }
                self.agent.send("hidecursor on")
            }
        }
    }

    /// guest 确认已经把系统光标换成透明的了 —— 这时候才轮到我们画。
    private func cursorTakeoverConfirmed() {
        guard !cursorTakeoverDone else { return }
        cursorTakeoverDone = true
        cursorTakeover?.invalidate()
        view.setFallbackArrow(false)
        startCursorPolling()
        cursorSummary = view.cursorStatus
    }

    /// 会话侧助手掉了。停止轮询并等它回来重新接管。
    ///
    /// 这里**不**把宿主光标一起收掉:助手正常退出会还原系统光标,但被强杀就不会,
    /// 那种情况下收掉就一个光标都没有了。宁可暂时多一个,也不能一个都没有。
    private func cursorTakeoverLost() {
        guard cursorTakeoverDone else { return }
        cursorPoll?.invalidate()
        cursorPoll = nil
        view.dropHostCursor()
        cursorSummary = view.cursorStatus
        beginCursorTakeover()
    }

    /// 每 10 秒探一次 guest 的会话侧助手。它管光标和分辨率,死了界面上看就是
    /// 「窗口拖了不跟随」「光标不对」,而 system 侧只有被请求时才会发现它没了。
    /// 探到没有,system 侧就会自己把它拉回来。
    private func startSessionPing() {
        sessionPing?.invalidate()
        sessionPing = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.agent.isConnected else { return }
                self.agent.send("sesping")
            }
        }
    }

    private func startCursorPolling() {
        cursorPoll?.invalidate()
        cursorPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.agent.isConnected { self.agent.send("getcursor") } else { self.view.dropHostCursor() }
            }
        }
    }

    /// 手动在「宿主绘制」与「guest 自绘」之间切换。两侧状态必须一起切,
    /// 否则会出现两个光标或一个都没有。
    public func setCursorMode(hostDrawn: Bool) {
        if hostDrawn {
            agent.send("hidecursor on")
            startCursorPolling()
        } else {
            agent.send("hidecursor off")
            cursorPoll?.invalidate()
            cursorPoll = nil
            view.dropHostCursor(deliberate: true)
        }
        cursorSummary = view.cursorStatus
    }

    // MARK: - 分辨率
    //
    // 任意分辨率**必须两步走**,顺序不能反:
    //   1. dpy_set_ui_info(w, h) → 写进 virtio-gpu 的 req_state[0],
    //      viogpudo 会把这个尺寸加进自己的模式表
    //   2. 等驱动取到之后,agent 调 ChangeDisplaySettingsEx 精确设置
    // 只做第 2 步一律返回 -2 DISP_CHANGE_BADMODE。width/height 必须非零 ——
    // 0 在 QEMU 里的含义是「关掉这个输出」,画面会直接熄灭。

    /// 只有 virtio-gpu 支持 ui_info;安装期与调试参数 ForceRamfb 用的 ramfb 不支持
    /// 只有 virtio-gpu 支持 ui_info;ramfb 不支持,给它发 QEMU 会 assert 直接 abort。
    /// 安装期是否用 ramfb 取决于系统:Windows 用(WinPE 没驱动),Ubuntu 不用。
    private var displaySupportsUIInfo: Bool {
        if options.forceRamfb { return false }
        if options.installMedia != nil, bundle.settings.os.usesRamfbDuringInstall { return false }
        return true
    }

    public func requestResolution(_ px: CGSize, attempt: Int = 0) {
        guard displaySupportsUIInfo else { print("[ui] 当前显示设备不支持改分辨率,忽略"); return }
        pendingResolution = px
        resolutionAttempt = attempt
        let w = Int32(px.width), h = Int32(px.height)
        print("[ui] 请求 \(w)x\(h)\(attempt > 0 ? "(第 \(attempt + 1) 次)" : "")")
        channel.send(.uiInfo, w, h)
        guard agent.isConnected else {
            print("[ui] agent 未就绪,画面按窗口缩放")
            return
        }
        // 给驱动一点时间把新尺寸并进模式表。首次 0.35s 足够(实测 3s 必成);
        // 失败后重试给足 1.2s。
        let wait = attempt == 0 ? 0.35 : 1.2
        Task {
            try? await Task.sleep(for: .seconds(wait))
            agent.send("setres \(Int(px.width)) \(Int(px.height))")
        }
    }

    /// 两次精确尝试都失败才退回模式表里最接近的一档 —— 那意味着放弃点对点。
    private func handleResolutionFailure() {
        guard pendingResolution != .zero else { return }
        if resolutionAttempt == 0 {
            requestResolution(pendingResolution, attempt: 1)
        } else {
            let m = agent.snap(width: Int(pendingResolution.width),
                               height: Int(pendingResolution.height))
            print("[ui] 精确设置两次都失败,退回模式表里的 \(m.w)x\(m.h)(画面会被缩放)")
            agent.send("setres \(m.w) \(m.h)")
            pendingResolution = .zero
        }
    }

    /// 窗口尺寸变了 → 让 guest 分辨率等于窗口的**物理像素**(点对点)。
    /// 拖拽过程中每帧都会触发,所以防抖 200ms;防抖放在宿主侧,
    /// QEMU 那边才能用 delay=false 立即通知,省掉它内置的 1 秒。
    public func windowResized(toBackingPixels raw: CGSize) {
        // ramfb(安装期、ForceRamfb)没有 ui_info,QEMU 侧收到这条会 assert 直接 abort。
        // 画面只按窗口缩放,不请求改分辨率。
        guard displaySupportsUIInfo, guestReady, !suppressResizeRequest else { return }
        let px = VMDisplay.clamp(raw)
        guard px != lastRequestedSize, px != guestSize else { return }
        lastRequestedSize = px

        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            requestResolution(px)
        }
    }

    /// 命令行显式设分辨率。
    ///
    /// 重构前这里把 suppressResizeRequest 置真后**永不复位**,于是用过一次 setres
    /// 之后拖窗口就再也不改分辨率了。现在只压制一小段时间,够盖住由此触发的
    /// 那一次 RESIZE 回波即可。
    public func setResolutionManually(_ px: CGSize) {
        suppressResizeRequest = true
        requestResolution(VMDisplay.clamp(px))
        Task {
            try? await Task.sleep(for: .seconds(2))
            suppressResizeRequest = false
        }
    }

    // MARK: - 拉起 QEMU

    private func buildCommand() -> QemuCommand {
        var startBundle = bundle
        if let ds = options.displaySize {
            startBundle.settings.displayWidth = ds.w
            startBundle.settings.displayHeight = ds.h
            print("[display] 初始尺寸 \(ds.w)x\(ds.h)")
        }

        // 有没有可用的挂起状态,在这里定下来:指纹对不上就当没有,冷启动。
        wantsResume = startBundle.settings.snapshotShapes[suspendTag] != nil

        var command = QemuCommand(bundle: startBundle, firmwareDir: tools.firmware,
                                  displaySocket: paths.display,
                                  framebufferPath: paths.framebuffer,
                                  agentSocket: paths.agent, qmpSocket: paths.qmp)
        command.qemuVersion = tools.qemuVersion
        command.guestOS = startBundle.settings.os

        if options.forceRamfb {
            command.forceRamfb = true
            print("[display] 强制 ramfb(不依赖 guest 显卡驱动)")
        }
        // 探测盘是为了让 Windows 在「设备在场」时绑定 viostor。Linux 不需要。
        if options.vblkProbe || (options.installMedia != nil && startBundle.settings.os == .windows) {
            command.virtioBlkProbe = makeProbeDisk()
        }
        if options.mountTools {
            command.extraDrives.append((path: ToolPaths.toolsImage.path,
                                        isCDROM: false, bootIndex: nil))
            command.extraDrives.append((path: VMInstaller.defaultVirtioISO?.path ?? NSHomeDirectory() + "/Downloads/virtio-win.iso",
                                        isCDROM: true, bootIndex: nil))
            print("[tools] 已挂载工具盘与 virtio-win ISO")
        }
        if let media = options.installMedia {
            command.installing = true
            // 两个系统都是「引导盘排最前」:
            //   Windows:boot.img 自带引导文件,从硬盘引导不会出现
            //            「Press any key to boot from CD or DVD」的等待按键提示
            //   Ubuntu :CIDATA 盘上是 Ubuntu 签名的 shim+grub 与我们的 grub.cfg
            // 两边 ISO 都要挂着 —— Windows 的 install.wim(6.8GB)超过 FAT32 单文件上限,
            // Ubuntu 的内核与 squashfs 本来就只在 ISO 上。
            command.extraDrives.append((path: media.boot, isCDROM: false, bootIndex: 0))
            command.extraDrives.append((path: media.iso,  isCDROM: true,  bootIndex: 2))
            if startBundle.settings.os == .windows {
                command.extraDrives.append((path: media.tools, isCDROM: false, bootIndex: 20))
                // 驱动 ISO 是必需的,路径记在配置里。以前默默找 ~/Downloads,找不到就不挂,
                // 装出来的机器黑屏、没网、agent 连不上。
                if let virtio = media.virtioISO {
                    command.extraDrives.append((path: virtio, isCDROM: true, bootIndex: nil))
                }
            }
            // Ubuntu 的 agent 就在引导盘上,没有单独的工具盘,所以这里只有两块。
        } else if let iso = options.extraISO {
            if let boot = options.bootImage {
                // 与真实安装同一套排布:引导盘 0、系统盘 1(借 installing 挤过去)、ISO 2
                command.installing = true
                command.extraDrives.append((path: boot, isCDROM: false, bootIndex: 0))
                command.extraDrives.append((path: iso, isCDROM: true, bootIndex: 2))
                print("[boot] 引导盘 \(boot),ISO \(iso)")
            } else {
                command.extraDrives.append((path: iso, isCDROM: true, bootIndex: 1))
                print("[iso] 安装介质 \(iso)")
            }
        }
        return command
    }

    /// 16MB 的 virtio-blk 假盘。让首次登录的 pnputil 在**设备在场**时配置好 viostor
    /// 服务 —— 否则装完切到 virtio-blk 系统盘会 INACCESSIBLE_BOOT_DEVICE 反复重启。
    /// WinPE 没有 viostor,所以它在安装阶段对 Setup 不可见,不会干扰选盘。
    private func makeProbeDisk() -> String {
        let probe = bundle.url.appendingPathComponent("vblk-probe.img").path
        if !FileManager.default.fileExists(atPath: probe) {
            FileManager.default.createFile(atPath: probe, contents: nil)
            try? FileHandle(forWritingAtPath: probe)?.truncate(atOffset: 16 * 1024 * 1024)
        }
        return probe
    }

    private func launchQEMU() throws -> Process {
        var command = buildCommand()
        currentShape = command.migrationFingerprint()   // -S 不在指纹取值范围内
        if wantsResume, bundle.settings.snapshotShapes[suspendTag] != currentShape {
            print("[挂起] 保存的状态与当前设备配置不符,改为冷启动")
            wantsResume = false
            forgetShape(of: suspendTag)
        }
        command.startPaused = wantsResume
        if wantsResume { print("[挂起] 从保存的状态继续") }

        let process = Process()
        process.executableURL = tools.qemu
        process.arguments = command.arguments()

        FileManager.default.createFile(atPath: paths.qemuLog, contents: nil)
        if let handle = FileHandle(forWritingAtPath: paths.qemuLog) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            print("[qemu] 退出 code=\(code)")
            Task { @MainActor in self?.qemuExited(code: code) }
        }
        do {
            launchedAt = Date()
            try process.run()
            print("[qemu] 已启动 pid=\(process.processIdentifier)")
            return process
        } catch {
            throw VMSessionError.qemuLaunchFailed(error)
        }
    }

    private func qemuExited(code: Int32) {
        // 退出前那一刻的状态决定这次退出是不是预期的,所以先取再改
        let wasEnding = state.isEnding
        state = .stopped(code: code)
        cursorPoll?.invalidate()
        sessionPing?.invalidate()
        cursorTakeover?.invalidate()
        clipboardTimer?.invalidate()
        busyMessage = nil
        captureThumbnail()
        // 收尾。不做的话每开一次虚拟机就漏一个视图、一段 mmap、两条重连线程。
        qmp.stop()
        agent.stop()
        channel.close()
        view.stop()
        framebuffer.release()
        suspendContinuation?.resume(returning: true)
        suspendContinuation = nil
        transferGoneContinuation?.resume()
        transferGoneContinuation = nil
        // 安装已经结束(配置里没有介质了)而这次开机还挂着它们:现在文件释放了,删掉
        if options.installMedia != nil, bundle.settings.install == nil {
            bundle.removeInstallLeftovers()
            print("[install] 已删除包内安装介质")
        }
        onTerminated?(code)
        window?.delegate = closeWatcher?.original   // 否则 close() 又会被拦下来

        // 不是我们让它退的、或者退出码不为零:留着窗口把原因说出来。
        // 以前这里无条件关窗口,固件缺失、参数错误、HVF 没签名,用户只看到窗口闪一下就没了。
        // guest 自己关机(开始菜单里关)也算正常,那时 state 还是 .running。
        // 但开机头十秒就退出多半是出了事 —— 比如 EFI 找不到启动项直接关机。
        let ran = Date().timeIntervalSince(launchedAt)
        let abnormal = code != 0 || (!wasEnding && ran < 10)
        if abnormal {
            launchFailure = Self.describeExit(code: code, ran: ran, logPath: paths.qemuLog)
            print("[qemu] \(launchFailure!)")
        } else {
            window?.close()
        }
    }

    /// 把 QEMU 日志的尾部带上。写锁冲突、找不到固件、ISO 路径错,原话都在那里。
    public nonisolated static func describeExit(code: Int32, ran: TimeInterval, logPath: String) -> String {
        var text = "虚拟机运行 \(Int(ran)) 秒后退出（退出码 \(code)）"
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let lines = log.split(whereSeparator: \.isNewline).suffix(12)
            if !lines.isEmpty { text += "\n\n" + lines.joined(separator: "\n") }
        }
        return text
    }

}

public enum VMSessionError: LocalizedError {
    case channelListenFailed(String, Error)
    case qemuLaunchFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .channelListenFailed(let path, let e): return "无法建立显示连接：\(e.localizedDescription)"
        case .qemuLaunchFailed(let e):              return "无法启动虚拟机：\(e.localizedDescription)"
        }
    }
}
