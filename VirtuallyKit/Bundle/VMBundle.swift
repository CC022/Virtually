// VM 包:一台虚拟机的全部持久化状态。
//
// 布局(目录即包,便于用 Finder 移动/备份/删除):
//   <名字>.vmbundle/
//     config.json      —— VMSettings
//     disk.qcow2       —— 系统盘
//     nvram.qcow2      —— EFI 变量存储(启动项等)
//     snapshots/       —— 预留给 M6
//
// 用 qcow2 而非 raw:内建快照、按需增长、可移植。
// 这是 QEMU 方案相对 Virtualization.framework 的直接收益之一 ——
// VZ 的 VZDiskImageStorageDeviceAttachment 明确只支持 RAW。

import Foundation

// MARK: - 设置

/// 默认是**不联网**。
///
/// 一联网 Windows 就会自己开始下载安装更新,于是同一台虚拟机的行为不可复现:
/// 系统繁忙时登录任务的行为不可信、更新会重装显示驱动把我们写的设置刷掉、
/// 时钟还会反复跳(实测同一台机器上跨过日期)。
/// 作为默认也更合理 —— 联网应当是用户主动选择的。
/// 只有两种模式。曾经有过 vmnet 共享,但它需要 Apple 特批的
/// `com.apple.vm.networking` entitlement —— 实测直接报
/// "cannot create vmnet interface: possibly not enough privileges",
/// 留着只会让用户点一个必然失败的选项。
/// 关窗口时整机状态存在这个标签下,下次开机从它恢复。
/// 双下划线是为了和用户自己起的名字区分开 —— 界面上的快照列表会把它滤掉。
public let suspendTag = "__suspend__"

public enum NetworkMode: String, Codable, CaseIterable {
    /// SLIRP 用户态网络。免任何权限,开箱即用,但 guest 不可被外部直接访问。
    case user
    case none

    public var displayName: String {
        switch self {
        case .user:        return "共享网络(NAT)"
        case .none:        return "无网络"
        }
    }
}

/// 客户机系统。所有 OS 差异都从这个枚举分出去,别在别处再写 if。
public enum GuestOS: String, Codable, CaseIterable, Sendable {
    case windows
    case ubuntu

    public var displayName: String {
        switch self {
        case .windows: return "Windows 11"
        case .ubuntu:  return "Ubuntu"
        }
    }

    /// 新建虚拟机时的默认名字
    public var defaultVMName: String { displayName }

    /// 装得下系统的最小磁盘。Windows 11 官方要求 64GB,实测 32GB 能装上;
    /// Ubuntu 桌面版装完约 12GB。
    public var minDiskGB: Int {
        switch self {
        case .windows: return 32
        case .ubuntu:  return 16
        }
    }

    /// 要不要额外的驱动 ISO。Windows 的显卡/网卡/串口驱动都在 virtio-win 上,
    /// Linux 内核自带 virtio-blk / virtio-net / virtio-gpu,不需要。
    public var needsDriverISO: Bool { self == .windows }

    /// `-rtc base=` 的取值。**这一项错了时钟会整体偏一个时区**:
    /// Windows 认为 RTC 存的是本地时间,Linux 认为是 UTC(`/etc/adjtime` 默认 UTC)。
    /// Windows 上给 utc 会显示成 UTC 时间,Linux 上给 localtime 会偏 UTC 偏移量那么多。
    public var rtcBase: String {
        switch self {
        case .windows: return "localtime"
        case .ubuntu:  return "utc"
        }
    }

    /// 安装期要不要用 ramfb。
    /// WinPE 里没有 viogpudo,virtio-gpu 在 ExitBootServices 之后无人驱动会黑屏;
    /// Ubuntu 的安装器(casper)内核自带 virtio-gpu 驱动,直接用 virtio-gpu,
    /// 于是分辨率跟随从安装期就能用。
    public var usesRamfbDuringInstall: Bool { self == .windows }

    /// 安装期系统盘要不要用 nvme。
    /// Windows 自带 stornvme.sys 而 viostor 要装完才有;Linux 内核自带 virtio-blk。
    public var usesNVMeDuringInstall: Bool { self == .windows }

    /// guest 里 ⌘ 对应的那个键叫什么(文案用)
    public var superKeyName: String {
        switch self {
        case .windows: return "Win 键"
        case .ubuntu:  return "Super 键"
        }
    }
}

public enum DiskDriver: String, Codable {
    case nvme
    case virtioBlk = "virtio-blk"
}

/// 一场安装用到的介质。**写进 config.json**:安装要 10 分钟、重启好几次,
/// 中途退出 app 再打开,得知道这台机器还在装、该挂哪些盘。
/// 以前只放在内存里,装到一半退出就成了一台不带介质的普通虚拟机,半截系统盘引导失败。
public struct InstallMedia: Codable, Equatable {
    /// Windows 安装 ISO(install.wim 在上面,6.8GB 放不进 FAT32)
    public var iso: String
    /// 从 ISO 复制的引导文件 + autounattend.xml,包内 boot.img
    public var boot: String
    /// agent + install-agent.bat,包内 tools.img
    public var tools: String
    /// virtio-win 驱动 ISO。**只有 Windows 要**:没有它装完就是黑屏、没网、agent 永远连不上。
    /// Linux 内核自带 virtio 驱动,这里是 nil。
    public var virtioISO: String?

    public init(iso: String, boot: String, tools: String, virtioISO: String? = nil) {
        self.iso = iso
        self.boot = boot
        self.tools = tools
        self.virtioISO = virtioISO
    }
}

public struct VMSettings: Codable, Equatable {
    public var name: String
    public var cpuCount: Int
    public var memoryMB: Int
    /// 创建时(或最后一次扩容时)给的大小。**实际大小以 qcow2 的 virtual-size 为准**:
    /// 恢复扩容前存的快照,QEMU 会把盘一起改回当时的大小(见 docs/DISK.md)。
    public var diskSizeGB: Int
    public var network: NetworkMode
    public var audioEnabled: Bool
    /// 首次启动时的显示尺寸。之后由 guest agent 按窗口大小调整。
    public var displayWidth: Int
    public var displayHeight: Int
    /// 系统盘控制器。
    ///
    /// 安装期必须是 nvme:Windows 自带 stornvme.sys,而 virtio 的 viostor
    /// 要等首次登录后才装上。装完切到 virtio-blk 有两个好处:
    ///   1. **nvme 设备不可迁移**,带它就没法做含内存的快照
    ///      (savevm 报 "State blocked by non-migratable device .../nvme")
    ///   2. virtio-blk 比模拟 NVMe 快
    public var diskDriver: DiskDriver

    /// 快照标签 → 存快照那一刻的设备指纹。
    ///
    /// 快照存的是整机状态,设备对不上就恢复不了。而 QEMU 的失败方式非常危险:
    /// load_snapshot 先 bdrv_all_goto_snapshot() 把**磁盘回滚**,再读内存,
    /// 读失败时磁盘已经换过去了。所以必须在动手之前就挡住,不能等它报错。
    public var snapshotShapes: [String: String]

    /// 非 nil 表示安装还没完成。agent 第一次上线时清掉并删除包内介质。
    public var install: InstallMedia?

    /// 客户机系统
    public var os: GuestOS

    /// true 表示虚拟盘扩过容,guest 里的系统分区还没跟上。agent 上线后宿主让它扩到占满,扩完清掉。
    /// **必须是 Optional**:旧的 config.json 里没有这个键,非 Optional 会解码失败,
    /// 而 loadLibrary 静默跳过解码失败的包 —— 虚拟机就从资源库里消失了。
    public var growPartition: Bool?

    /// 新建虚拟机的默认设置。磁盘默认给最小值的三倍上下,够装完还有余量。
    public static func `default`(for os: GuestOS) -> VMSettings {
        VMSettings(
            name: os.defaultVMName,
            cpuCount: VMSettings.defaultCPUCount,
            memoryMB: VMSettings.defaultMemoryMB,
            diskSizeGB: os == .windows ? 96 : 64,
            network: .none,
            audioEnabled: true,
            displayWidth: 1280,
            displayHeight: 800,
            diskDriver: .virtioBlk,
            snapshotShapes: [:],
            install: nil,
            os: os)
    }

    // MARK: 主机能力与合理默认

    public static var hostCPUCount: Int { ProcessInfo.processInfo.processorCount }
    public static var hostMemoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) }

    /// 默认 4 核(主机不够就取主机核数)。全给 guest 会让宿主 UI 卡顿,而 QEMU 的 vCPU 线程会真的占满。
    public static var defaultCPUCount: Int { min(4, max(1, hostCPUCount)) }

    /// 给宿主留出余量。VZ 的 maximumAllowedMemorySize 等于整机物理内存,
    /// 照抄那个上限会把宿主逼进 swap —— 这里自己留。
    public static var maxMemoryMB: Int { max(1024, hostMemoryMB - 4096) }
    public static var defaultMemoryMB: Int { min(8192, maxMemoryMB) }

    /// 用户输入的名字要当目录名用:去掉路径分隔符和冒号,不许以点开头,空了给个默认值。
    public static func sanitizedName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.map { "/:\\".contains($0) ? "-" : $0 })
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)) }
        return name.isEmpty ? "虚拟机" : name
    }

    /// 把用户输入夹到可用范围,并返回被修正的项(供 UI 提示)
    public mutating func clamp() -> [String] {
        var adjusted: [String] = []
        if cpuCount < 1 || cpuCount > Self.hostCPUCount {
            cpuCount = min(max(1, cpuCount), Self.hostCPUCount)
            adjusted.append("CPU 核数调整为 \(cpuCount)(主机共 \(Self.hostCPUCount) 核)")
        }
        if memoryMB < 2048 || memoryMB > Self.maxMemoryMB {
            memoryMB = min(max(2048, memoryMB), Self.maxMemoryMB)
            adjusted.append("内存调整为 \(memoryMB)MB(上限 \(Self.maxMemoryMB)MB,已为主机留 4GB)")
        }
        if diskSizeGB < os.minDiskGB {
            diskSizeGB = os.minDiskGB
            adjusted.append("磁盘调整为 \(os.minDiskGB)GB(\(os.displayName) 装得下的最小值)")
        }
        return adjusted
    }

    public init(name: String, cpuCount: Int, memoryMB: Int, diskSizeGB: Int, network: NetworkMode, audioEnabled: Bool, displayWidth: Int, displayHeight: Int, diskDriver: DiskDriver, snapshotShapes: [String: String], install: InstallMedia? = nil, os: GuestOS, growPartition: Bool? = nil) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.network = network
        self.audioEnabled = audioEnabled
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.diskDriver = diskDriver
        self.snapshotShapes = snapshotShapes
        self.install = install
        self.os = os
        self.growPartition = growPartition
    }
}

// MARK: - 包

public struct VMBundle {
    public let url: URL
    public var settings: VMSettings

    public var configURL:    URL { url.appendingPathComponent("config.json") }
    public var diskURL:      URL { url.appendingPathComponent("disk.qcow2") }
    /// 用 qcow2 而不是 raw:`savevm` 要求**所有可写块设备**都支持快照,
    /// raw 的 pflash 会让快照直接失败
    /// ("Device 'pflash1' is writable but does not support snapshots")。
    public var nvramURL:     URL { url.appendingPathComponent("nvram.qcow2") }
    /// 上次离开时的画面,资源库卡片拿它当缩略图。放包里,删包即删图。
    public var thumbnailURL: URL { url.appendingPathComponent("thumbnail.jpg") }

    public static let fileExtension = "vmbundle"

    /// 默认存放位置。放 Application Support 而不是 Documents:
    /// 这些是几十 GB 的运行时数据,不该混进用户文档,也不该被 iCloud 同步。
    public static var defaultLibraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Virtually/VMs", isDirectory: true)
    }

    // MARK: 读写

    public static func load(at url: URL) throws -> VMBundle {
        let data = try Data(contentsOf: url.appendingPathComponent("config.json"))
        let settings = try JSONDecoder().decode(VMSettings.self, from: data)
        return VMBundle(url: url, settings: settings)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: configURL, options: .atomic)
    }

    /// 扫描库目录。损坏的包跳过而不是让整个库加载失败。
    public static func loadLibrary(at libraryURL: URL = defaultLibraryURL) -> [VMBundle] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: libraryURL, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension == fileExtension }
            .compactMap { try? load(at: $0) }
            .sorted { $0.settings.name.localizedStandardCompare($1.settings.name) == .orderedAscending }
    }

    // MARK: 创建

    /// 建包并分配磁盘。`existingDisk` 非空时转换已有镜像(raw/qcow2 均可),
    /// 否则创建空盘。
    public static func create(settings: VMSettings,
                       in libraryURL: URL = defaultLibraryURL,
                       qemuImg: URL,
                       firmwareDir: URL,
                       existingDisk: URL? = nil) throws -> VMBundle {
        var settings = settings
        settings.name = VMSettings.sanitizedName(settings.name)
        _ = settings.clamp()

        let fm = FileManager.default
        let bundleURL = libraryURL.appendingPathComponent("\(settings.name).\(fileExtension)")
        guard !fm.fileExists(atPath: bundleURL.path) else {
            throw VMError.alreadyExists(bundleURL.lastPathComponent)
        }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let bundle = VMBundle(url: bundleURL, settings: settings)
        do {
            if let source = existingDisk {
                // convert 而不是 copy:顺带把 raw 转成 qcow2,并丢掉空洞
                try run(qemuImg, ["convert", "-p", "-O", "qcow2", source.path, bundle.diskURL.path])
            } else {
                try run(qemuImg, ["create", "-f", "qcow2", bundle.diskURL.path, "\(settings.diskSizeGB)G"])
            }

            // EFI 变量存储:64MB 全 0xff(空白 flash 的语义)
            try makeBlankNVRAM(at: bundle.nvramURL, qemuImg: qemuImg)

            try bundle.save()
        } catch {
            // 半截的包留着,库里看不见(没有 config.json),同名再建又报「已存在」。
            try? fm.removeItem(at: bundleURL)
            throw error
        }
        return bundle
    }

    /// 安装完成后把包内介质删掉:boot.img 1.5GB、tools.img、探测盘。用户自己的 ISO 不碰。
    public func removeInstallLeftovers() {
        let fm = FileManager.default
        for name in ["boot.img", "tools.img", "vblk-probe.img"] {
            try? fm.removeItem(at: url.appendingPathComponent(name))
        }
    }

    /// aarch64 的 EFI pflash 需要 64MB。空白 flash 是全 1,不是全 0 ——
    /// 用全 0 填充部分固件会当成已写入的垃圾数据。
    /// 先写 raw 再转 qcow2:新建的 qcow2 读出来是全 0,而 EDK2 靠 0xff
    /// 判断「这块 flash 还没用过」。直接建空 qcow2 会让固件把 0 当成垃圾变量。
    public static func makeBlankNVRAM(at url: URL, qemuImg: URL) throws {
        let raw = url.deletingPathExtension().appendingPathExtension("raw")
        try writeBlankFlash(at: raw)
        try run(qemuImg, ["convert", "-f", "raw", "-O", "qcow2", raw.path, url.path])
        try? FileManager.default.removeItem(at: raw)
    }

    public static func writeBlankFlash(at url: URL) throws {
        let size = 64 * 1024 * 1024
        let chunk = [UInt8](repeating: 0xff, count: 1024 * 1024)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for _ in 0..<(size / chunk.count) {
            try handle.write(contentsOf: chunk)
        }
    }

    @discardableResult
    public static func run(_ tool: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw VMError.toolFailed(tool.lastPathComponent, out)
        }
        return out
    }

    public init(url: URL, settings: VMSettings) {
        self.url = url
        self.settings = settings
    }
}

public enum VMError: LocalizedError {
    case alreadyExists(String)
    case toolFailed(String, String)
    case busy(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name): return "\(name) 已存在"
        case .toolFailed(let tool, let out): return "\(tool) 执行失败:\n\(out)"
        case .busy(let why): return why
        case .invalid(let why): return why
        }
    }
}

// MARK: - QEMU 命令行

/// 把 VMSettings 编译成 QEMU 参数。
/// 集中在一处,避免参数散落在启动代码里。
public struct QemuCommand {
    public let bundle: VMBundle
    public let firmwareDir: URL
    public let displaySocket: String
    public let framebufferPath: String
    public let agentSocket: String
    public let qmpSocket: String
    /// 安装介质等额外挂载
    public var extraDrives: [(path: String, isCDROM: Bool, bootIndex: Int?)] = []
    /// 安装模式:安装介质排在系统盘之前。
    /// 平时系统盘必须是 bootindex=0,否则空白 NVRAM 下会落到 UEFI shell。
    public var installing = false
    /// 开机即暂停(`-S`)。只在要恢复挂起状态时用:让 QEMU 停在 guest 还没跑一条指令
    /// 的地方,先把状态读进来再 cont。不这样的话固件会先跑一秒,还可能写 NVRAM。
    public var startPaused = false
    /// 强制使用 ramfb。用于救场:guest 缺显卡驱动导致画面熄灭时,
    /// ramfb 不依赖任何 guest 驱动,能让人重新看到画面去修。
    public var forceRamfb = false
    /// 挂一块小的 virtio-blk 假盘,只为让 Windows 绑定 viostor。
    ///
    /// pnputil 把驱动放进 DriverStore,但只对**在场**的设备真正安装并配置服务。
    /// 安装期系统盘是 nvme,virtio-blk 设备不在场,于是 viostor 的服务没被建成
    /// 引导驱动 —— 直接切到 virtio-blk 会 INACCESSIBLE_BOOT_DEVICE 反复重启。
    /// 先挂假盘让它绑定一次,之后切换才安全。
    public var virtioBlkProbe: String?
    /// 客户机系统。决定安装期的显示设备与系统盘控制器,以及 `-rtc base=`。
    public var guestOS: GuestOS = .windows
    /// QEMU 的版本号,进指纹。不同版本的迁移流格式不保证兼容,重编 QEMU 后旧快照可能读不回来 ——
    /// 而读不回来的代价是磁盘已被回滚。空串表示没查到(自检里就是)。
    public var qemuVersion = ""

    /// extraDrives 第 i 项对应的 QOM 设备 id
    public static func deviceID(forExtra i: Int) -> String { "usbdev\(i)" }

    /// 系统盘设备行。安装期一律 nvme —— WinPE 里没有 viostor。
    public var systemDiskDevice: String {
        let boot = "bootindex=\(installing ? 1 : 0)"
        // nvme 只为 Windows 存在:
        //   安装期必须用它(WinPE 里没有 viostor,而 Windows 自带 stornvme.sys)。
        // Linux 内核自带 virtio-blk,任何时候都用它 —— 省掉「装完再切」那一步,
        // 也省掉为了让 Windows 绑定 viostor 而挂的那块探测盘。
        let wantsNVMe = guestOS.usesNVMeDuringInstall
            && (installing || bundle.settings.diskDriver == .nvme)
        return wantsNVMe ? "nvme,drive=hd0,serial=vm0,\(boot)"
                         : "virtio-blk-pci,drive=hd0,\(boot)"
    }

    /// 迁移意义上的「机器形状」。只取决定快照能不能对上的那些参数:
    /// 机器类型、CPU、内存、以及所有设备/后端。socket 与文件路径不算 ——
    /// 同一台虚拟机换个会话号路径就变了,那不该让快照失效。
    public func migrationFingerprint() -> String {
        let shaping: Set<String> = ["-machine", "-cpu", "-smp", "-m", "-device", "-netdev", "-nic"]
        let args = arguments()
        var parts: [String] = []
        var i = 0
        while i < args.count - 1 {
            if shaping.contains(args[i]) {
                var value = args[i + 1]
                // 初始分辨率不影响迁移兼容性 —— 它只是开机时 EDID 报的尺寸,
                // 之后由 agent 随窗口改。进指纹只会让调试参数 DisplaySize 一变挂起状态就作废。
                if value.hasPrefix("virtio-gpu-pci,") {
                    value = value.split(separator: ",")
                        .filter { !$0.hasPrefix("xres=") && !$0.hasPrefix("yres=") }
                        .joined(separator: ",")
                }
                parts.append("\(args[i]) \(value)")
            }
            i += 1
        }
        // 设备顺序在命令行上是稳定的,但排序能挡掉无关的重排
        return Self.fingerprintVersion + "\n" + "qemu \(qemuVersion)\n"
            + parts.sorted().joined(separator: "\n")
    }

    /// 指纹格式版本。**内存状态落盘位置之类会让旧快照读不回来的改动,就要升这个号**:
    /// 让旧指纹直接对不上,走「配置不符,拒绝恢复」—— 恢复失败的代价是磁盘已被回滚。
    public static let fingerprintVersion = "v1"

    public func arguments() -> [String] {
        let s = bundle.settings
        var args: [String] = [
            "-L", firmwareDir.path,
            "-machine", "virt,accel=hvf,gic-version=3,highmem=on",
            "-cpu", "host",
            "-smp", "\(s.cpuCount)",
            "-m", "\(s.memoryMB)",
            // 系统盘的 -drive **必须排在 pflash 之前**。savevm 把内存状态写到
            // 第一个可写且支持快照的块设备上(block/snapshot.c bdrv_all_find_vmstate_bs,
            // 按 BlockBackend 创建顺序即命令行顺序)。以前 nvram 排在前面,
            // 结果每条快照 4GB 的内存状态全落进了 64MB 的 EFI 变量文件,
            // 实测 nvram.qcow2 膨胀到 15–30GB。-drive 不进指纹,这里挪动不影响设备拓扑。
            "-drive", "file=\(bundle.diskURL.path),if=none,id=hd0,format=qcow2",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(firmwareDir.path)/edk2-aarch64-code.fd",
            "-drive", "if=pflash,format=qcow2,file=\(bundle.nvramURL.path)",
            // 只挂一个显示设备。组合设备(如 virtio-ramfb)会向 guest 暴露
            // 两个显示适配器,Windows 会把桌面扩展到两块屏上。
            //
            // 安装期用纯 ramfb:WinPE 没有 viogpudo 驱动,virtio-gpu 在
            // ExitBootServices 之后无人驱动,画面会变成 "Display output is not active"。
            // ramfb 是固件交接的线性帧缓冲,不需要任何 guest 驱动。
            // 装完驱动后切回 virtio-gpu-pci,才能支持动态分辨率。
            // xres/yres 会写进 virtio-gpu 的 req_state[0],也就是 guest 通过
            // GET_DISPLAY_INFO 与 EDID 看到的「宿主希望的尺寸」。
            // 运行时的 dpy_set_ui_info 改的是同一组字段,区别只在时机。
            "-device", ((installing && guestOS.usesRamfbDuringInstall) || forceRamfb) ? "ramfb"
                : "virtio-gpu-pci,xres=\(s.displayWidth),yres=\(s.displayHeight)",
            "-device", "qemu-xhci,id=usb",
            "-device", "usb-kbd",
            // 绝对坐标指针:无需捕获鼠标,不受两端加速曲线差异影响
            "-device", "usb-tablet",
            "-device", systemDiskDevice,
        ]

        // 网卡**永远都在**,联网与否只改链路状态(等价于拔网线),不增删设备。
        //
        // 为什么不按需热插:设备拓扑进快照。装着网卡存的快照,恢复到没网卡的机器上
        // 直接失败(实测 `Unknown ramblock "0000:00:04.0:00.0/virtio-net-pci.rom",
        // cannot accept migration`),而且失败后虚拟机停在 restore-vm 状态。
        // 只要用户在存快照和恢复之间动过网络开关,快照就废了 —— 这条路走不通。
        //
        // 换后端也不行:netdev_del 只是把 NIC 标成 peer_deleted 并置链路断开,
        // 随后的 netdev_add 不会重新配对(net/net.c qemu_del_net_client)。
        // 所以后端固定为 SLIRP,开关走 set_link。
        //
        // 断网的严密性:开机即 .none 时 VMSession 会在 QMP 一连上就 set_link off,
        // 那时 guest 还没开始跑,更没加载网卡驱动。SLIRP 是纯用户态 NAT,
        // 不发包就什么都出不去,所以这段空窗期不存在泄漏。
        //
        // pcie-root-port 留着:网卡插在 rp0 上,arm virt 的根总线 pcie.0
        // 不支持热插拔,而 USB 之类以后仍可能需要 rp1。
        args += ["-device", "pcie-root-port,id=rp0,chassis=1,slot=0",
                 "-device", "pcie-root-port,id=rp1,chassis=2,slot=1",
                 "-netdev", "user,id=net0",
                 "-device", "virtio-net-pci,netdev=net0,bus=rp0,id=nic0"]

        if s.audioEnabled {
            // intel-hda 而不是 virtio-sound:Windows 有原生 HD Audio 驱动,
            // 而 virtio-win 没有 ARM64 声卡驱动。
            // 用 hda-output 而非 hda-duplex,避免申请麦克风权限导致日志刷屏。
            args += ["-device", "intel-hda",
                     "-device", "hda-output,audiodev=snd0",
                     "-audiodev", "coreaudio,id=snd0"]
        }

        // guest agent 通道
        args += [
            "-device", "virtio-serial-pci,id=vser0",
            "-chardev", "socket,id=agentchr,path=\(agentSocket),server=on,wait=off",
            "-device", "virtserialport,bus=vser0.0,chardev=agentchr,name=org.virtually.agent",
        ]

        if let probe = virtioBlkProbe {
            args += ["-drive", "file=\(probe),if=none,id=probe0,format=raw",
                     "-device", "virtio-blk-pci,drive=probe0"]
        }

        for (i, drive) in extraDrives.enumerated() {
            let id = "extra\(i)"
            var opts = "file=\(drive.path),if=none,id=\(id),format=raw"
            if drive.isCDROM { opts += ",media=cdrom" }
            args += ["-drive", opts]
            // 显式 id:安装完成后要用 QMP device_del 把安装介质热拔掉
            var dev = "usb-storage,drive=\(id),id=\(Self.deviceID(forExtra: i))"
            if let bi = drive.bootIndex { dev += ",bootindex=\(bi)" }
            if !drive.isCDROM { dev += ",removable=on" }
            args += ["-device", dev]
        }

        args += [
            "-display", "macos,fb=\(framebufferPath),sock=\(displaySocket)",
            "-qmp", "unix:\(qmpSocket),server,nowait",
            // Windows 认为 RTC 存本地时间,Linux 认为存 UTC。给错了时钟整体偏一个时区 ——
            // 而 Windows 上时钟偏了会让任务计划服务静默失效(见 GUEST-AGENT.md 坑 21)。
            "-rtc", "base=\(guestOS.rtcBase)",
        ]
        if startPaused { args += ["-S"] }
        return args
    }

    public init(bundle: VMBundle, firmwareDir: URL, displaySocket: String, framebufferPath: String, agentSocket: String, qmpSocket: String, extraDrives: [(path: String, isCDROM: Bool, bootIndex: Int?)] = [], virtioBlkProbe: String? = nil, guestOS: GuestOS = .windows) {
        self.bundle = bundle
        self.firmwareDir = firmwareDir
        self.displaySocket = displaySocket
        self.framebufferPath = framebufferPath
        self.agentSocket = agentSocket
        self.qmpSocket = qmpSocket
        self.extraDrives = extraDrives
        self.virtioBlkProbe = virtioBlkProbe
        self.guestOS = guestOS
    }
}
