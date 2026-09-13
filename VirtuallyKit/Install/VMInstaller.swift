// 全新安装的准备流程:建包 → 构建安装盘 → 构建工具盘。
//
// 命令行的 `virtually install` 与图形界面的新建向导**共用这一份**。
// 上一次 install-agent.bat 有两份副本,改了一处另一处还是旧的,
// 白白浪费了好几轮调试 —— 不再犯第二次。
//
// 里面每一步都是几十秒到几分钟的阻塞操作(qemu-img convert、dd 1.5GB、
// 复制约 700MB),所以对外只暴露一个带阶段回调的同步函数,
// 调用方自己决定放到哪个队列上跑。

import Foundation

public enum VMInstaller {

    /// virtio-win ISO 的默认位置。找不到就得让用户自己选,**不能静默跳过**:
    /// 没有它装出来的机器没有显卡驱动(黑屏)、没有网卡、没有 vioserial(agent 永远连不上)。
    public static var defaultVirtioISO: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/virtio-win.iso")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public enum Phase {
        case inspecting
        case creatingBundle
        case buildingBootDisk
        case buildingToolsDisk
        case ready

        /// 界面上的进度,0…1
        public var fraction: Double {
            switch self {
            case .inspecting: return 0.05
            case .creatingBundle: return 0.2
            case .buildingBootDisk: return 0.45
            case .buildingToolsDisk: return 0.85
            case .ready: return 1
            }
        }

        public var message: String {
            switch self {
            case .inspecting:        return "正在检查安装镜像…"
            case .creatingBundle:    return "正在创建虚拟机…"
            case .buildingBootDisk:  return "正在准备安装介质…"
            case .buildingToolsDisk: return "正在准备 Virtually 工具…"
            case .ready:             return "准备就绪"
            }
        }
    }

    /// 选择要装的变体。
    ///
    /// Windows:索引必须来自实测解析,不能硬编码 —— 该中文 ARM64 ISO 只有 3 个版本,
    /// Pro 是 3 而不是常见的 6。Ubuntu:优先 minimal(装得快)。
    public static func pickVariant(_ list: [InstallVariant], os: GuestOS, preferred: String?) -> InstallVariant? {
        if let preferred, let match = list.first(where: { $0.id == preferred }) { return match }
        switch os {
        case .windows: return list.first { $0.name.contains("Pro") } ?? list.last
        case .ubuntu:  return UbuntuSeedDisk.defaultVariant(list)
        }
    }

    /// 建包并构建安装介质。同步阻塞,调用方负责挑队列。
    ///
    /// 两个系统的介质不一样:
    ///   Windows:boot.img(1.5GB,ISO 的引导文件 + 应答文件)+ tools.img(agent)+ virtio-win ISO
    ///   Ubuntu :一张 CIDATA 盘(EFI 引导链 + grub.cfg + cloud-init 的 user-data),几 MB
    public static func prepare(settings: VMSettings,
                        iso: URL,
                        virtioISO: URL?,
                        variantID: String,
                        libraryURL: URL,
                        tools: ToolPaths,
                        unattendOptions: UnattendOptions,
                        ubuntuOptions: UbuntuInstallOptions = UbuntuInstallOptions(),
                        progress: @escaping (Phase) -> Void,
                        onBundleCreated: ((VMBundle) -> Void)? = nil) throws -> (bundle: VMBundle, media: InstallMedia) {

        let os = settings.os
        if os.needsDriverISO {
            guard let virtioISO, FileManager.default.fileExists(atPath: virtioISO.path) else {
                throw InstallError.notWindowsISO("找不到 virtio-win 驱动镜像")
            }
        }
        progress(.creatingBundle)
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        var bundle = try VMBundle.create(settings: settings, in: libraryURL,
                                         qemuImg: tools.qemuImg, firmwareDir: tools.firmware)
        // 包一建好就交出去 —— 调用方要在开始构建介质之前就把路径显示出来,
        // 否则「已创建」会排在几分钟的介质构建之后,读起来像是最后才建的包
        onBundleCreated?(bundle)

        let bootImage  = bundle.url.appendingPathComponent("boot.img")
        let media: InstallMedia
        do {
            switch os {
            case .windows:
                media = try prepareWindows(bundle: bundle, iso: iso, virtioISO: virtioISO!,
                                           variantID: variantID, tools: tools,
                                           unattendOptions: unattendOptions,
                                           bootImage: bootImage, progress: progress)
            case .ubuntu:
                media = try prepareUbuntu(bundle: bundle, iso: iso, variantID: variantID,
                                          tools: tools, options: ubuntuOptions,
                                          bootImage: bootImage, progress: progress)
            }
        } catch {
            // 半截的包留着没用:库里看不见(config.json 还没写 install 键),同名再建又报已存在
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }

        progress(.ready)
        // 写进配置:中途退出 app 再打开,还知道这台在装、该挂什么
        bundle.settings.install = media
        try bundle.save()
        return (bundle, media)
    }

    private static func prepareWindows(bundle: VMBundle, iso: URL, virtioISO: URL,
                                       variantID: String, tools: ToolPaths,
                                       unattendOptions: UnattendOptions,
                                       bootImage: URL,
                                       progress: (Phase) -> Void) throws -> InstallMedia {
        var options = unattendOptions
        options.editionIndex = Int(variantID) ?? unattendOptions.editionIndex
        let unattend = UnattendGenerator.generate(options)
        let toolsImage = bundle.url.appendingPathComponent("tools.img")

        // 直接引导 ISO 会停在「Press any key to boot from CD or DVD」等按键,
        // 无人值守流程会永远卡住。把 ISO 的引导文件复制到 FAT32 盘上从「硬盘」引导
        // 就没有这个提示 —— 这也是制作 Windows 安装 U 盘的标准做法。
        // install.wim(6.8GB)超过 FAT32 单文件上限,留在 ISO 上让 Setup 自己找。
        let mount = try ISOInspector.Mount(iso: iso)
        defer { mount.detach() }

        progress(.buildingBootDisk)
        try SupportImageBuilder.build(at: bootImage, autounattend: unattend,
                                      agentScript: nil, installScript: nil,
                                      bootFilesFrom: mount.path)

        progress(.buildingToolsDisk)
        try SupportImageBuilder.build(
            at: toolsImage, autounattend: unattend,
            agentScript: tools.windowsAgentScript,
            installScript: SupportImageBuilder.installScript)

        return InstallMedia(iso: iso.path, boot: bootImage.path,
                            tools: toolsImage.path, virtioISO: virtioISO.path)
    }

    /// Ubuntu 只要一张盘。**引导文件不用复制**:grub 直接从 ISO 上取内核,
    /// 我们那张盘上只有 4MB 的 EFI 引导链和几个文本文件,所以这一步几秒就完。
    private static func prepareUbuntu(bundle: VMBundle, iso: URL, variantID: String,
                                      tools: ToolPaths, options: UbuntuInstallOptions,
                                      bootImage: URL,
                                      progress: (Phase) -> Void) throws -> InstallMedia {
        var o = options
        o.variantID = variantID
        progress(.buildingBootDisk)
        let linuxAgent = tools.linuxAgentDirectory
        let hasAgent = FileManager.default.fileExists(atPath: linuxAgent.path)
        try UbuntuSeedDisk.build(
            at: bootImage, iso: iso, options: o,
            agentPayload: hasAgent ? { dir in
                for f in (try? FileManager.default.contentsOfDirectory(atPath: linuxAgent.path)) ?? [] {
                    try FileManager.default.copyItem(at: linuxAgent.appendingPathComponent(f),
                                                     to: dir.appendingPathComponent(f))
                }
            } : nil,
            agentInstall: hasAgent ? LinuxAgent.installScript(username: o.username) : nil)
        // tools 指向同一张盘:Ubuntu 没有单独的工具盘,agent 就在引导盘的 agent/ 目录里
        return InstallMedia(iso: iso.path, boot: bootImage.path,
                            tools: bootImage.path, virtioISO: nil)
    }
}
