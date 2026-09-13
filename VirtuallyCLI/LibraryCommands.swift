// 直接操作资源库的命令。不需要 app 在跑,但要用 app 里嵌着的 qemu-img。

import Foundation
import VirtuallyKit

enum LibraryCommands {

    static func list(_ args: inout Arguments) throws {
        let library = libraryURL(&args)
        let all = VMBundle.loadLibrary(at: library)
        if all.isEmpty { print("资源库中没有虚拟机（\(library.path)）") }
        for b in all {
            let s = b.settings
            print(String(format: "%@  %@  %d 核 / %d MB / 磁盘已用 %.1f GB%@",
                         s.name, s.os.displayName, s.cpuCount, s.memoryMB, diskUsageGB(b.diskURL),
                         s.install != nil ? "  （正在安装）" : ""))
            print("    \(b.url.path)")
        }
    }

    static func create(_ args: inout Arguments) throws {
        let tools = try AppLocator.tools(&args)
        let library = libraryURL(&args)
        var settings = VMSettings.default(for: try guestOS(&args) ?? .windows)
        settings.name = try args.required("名称")
        try applySizing(&args, to: &settings)
        let existing = args.option("from-disk").map { URL(fileURLWithPath: $0) }
        if existing != nil { print("正在将磁盘镜像转换为 qcow2，可能需要一些时间…") }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let b = try VMBundle.create(settings: settings, in: library, qemuImg: tools.qemuImg,
                                    firmwareDir: tools.firmware, existingDisk: existing)
        print("已创建：\(b.url.path)")
    }

    static func install(_ args: inout Arguments) throws {
        let tools = try AppLocator.tools(&args)
        let library = libraryURL(&args)
        let name = try args.required("名称")
        guard let isoPath = args.option("iso") else {
            throw CLIError("install 需要 --iso <ARM64 版 Windows 或 Ubuntu 安装镜像>")
        }
        let iso = URL(fileURLWithPath: isoPath)

        print(VMInstaller.Phase.inspecting.message)
        // --os 没给就从镜像认。认不出来只能让用户说清楚 —— 猜错会格掉一块盘。
        let detected = ISOInspector.detect(iso)
        let explicitOS = try guestOS(&args)
        guard let os = explicitOS ?? detected else {
            throw CLIError("无法识别镜像的系统，请用 --os windows|ubuntu 指定")
        }
        if let detected, detected != os {
            print("警告：镜像似乎是 \(detected.displayName)，但 --os 指定的是 \(os.displayName)")
        }
        print("系统：\(os.displayName)")

        let variants = try ISOInspector.variants(inISO: iso, os: os)
        for v in variants { print("  [\(v.id)] \(v.name)") }
        guard let chosen = VMInstaller.pickVariant(variants, os: os, preferred: args.option("variant")) else {
            throw CLIError("镜像中没有可安装的版本")
        }
        print("将安装：[\(chosen.id)] \(chosen.name)")

        var settings = VMSettings.default(for: os)
        settings.name = name
        try applySizing(&args, to: &settings)

        var unattend = UnattendOptions(editionIndex: chosen.windowsIndex ?? 1)
        var ubuntu = UbuntuInstallOptions()
        if let u = args.option("username") { unattend.username = u; ubuntu.username = u }
        if let p = args.option("password") { unattend.password = p; ubuntu.password = p }

        var virtio: URL? = nil
        let virtioArg = args.option("virtio-iso").map { URL(fileURLWithPath: $0) }
        if os.needsDriverISO {
            guard let found = virtioArg ?? VMInstaller.defaultVirtioISO else {
                throw CLIError("""
                    需要 virtio-win 驱动镜像：放在 ~/Downloads/virtio-win.iso，或用 --virtio-iso <路径> 指定。
                    缺少它时，安装后的 Windows 没有显卡和网络驱动。
                    """)
            }
            virtio = found
        }
        let noRun = args.flag("no-run")

        let (bundle, _) = try VMInstaller.prepare(
            settings: settings, iso: iso, virtioISO: virtio, variantID: chosen.id,
            libraryURL: library, tools: tools, unattendOptions: unattend, ubuntuOptions: ubuntu,
            progress: { phase in if phase != .creatingBundle { print(phase.message) } },
            onBundleCreated: { print("已创建：\($0.url.path)") })

        if noRun {
            print("安装介质已准备就绪。启动并开始安装：virtually run --vm \"\(bundle.url.path)\"")
            return
        }
        print("开始自动安装，约需 \(os == .windows ? 10 : 12) 分钟，期间会自动重新启动。")
        var runArgs = Arguments(["--vm", bundle.url.path] + args.rest())
        try AppControl.run(&runArgs)
    }

    /// 扩大系统盘。与设置面板同一条路径:关机态、没挂起、装完了才行,只增不减。
    static func resizeDisk(_ args: inout Arguments) throws {
        let tools = try AppLocator.tools(&args)
        let library = libraryURL(&args)
        let name = try args.required("名称")
        guard let gb = Int(try args.required("GB")) else { throw CLIError("磁盘大小必须是整数（GB）") }
        let url = library.appendingPathComponent("\(name).\(VMBundle.fileExtension)")
        // 不先查的话,报出来的是 Foundation 的英文原话「config.json couldn't be opened」
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("找不到虚拟机“\(name)”（资源库：\(library.path)）")
        }
        var bundle = try VMBundle.load(at: url)
        let before = VMBundle.wholeGB(try bundle.diskVirtualSize(qemuImg: tools.qemuImg))
        try bundle.growDisk(toGB: gb, qemuImg: tools.qemuImg)
        print("磁盘已从 \(before) GB 扩大到 \(gb) GB。下次启动时将自动扩展系统分区。")
    }

    static func inspectISO(_ args: inout Arguments) throws {
        let iso = URL(fileURLWithPath: try args.required("ISO 路径"))
        guard let os = ISOInspector.detect(iso) else { throw CLIError("无法识别镜像的系统") }
        print("系统：\(os.displayName)")
        for v in try ISOInspector.variants(inISO: iso, os: os) { print("  [\(v.id)] \(v.name)") }
    }

    /// 工具盘的唯一构建入口。
    static func buildTools(_ args: inout Arguments) throws {
        let tools = try AppLocator.tools(&args)
        let out = args.next().map { URL(fileURLWithPath: $0) } ?? ToolPaths.toolsImage
        // 运行中的 VM 持有这张盘,而 guest 会缓存 FAT 与簇。在它跑着的时候重建镜像,
        // guest 读到的可能是失效数据 —— 实测把一个 13658 字节的 agent.ps1
        // 变成了同样大小的全零文件,表现却只是「agent 没起来」,极难定位。
        if let holder = QEMUProcesses.holding(path: out.standardizedFileURL.path) {
            throw CLIError("工具盘正被虚拟机使用（PID \(holder)），请先停止虚拟机再重新生成。")
        }
        try SupportImageBuilder.build(
            at: out,
            autounattend: UnattendGenerator.generate(UnattendOptions(editionIndex: 3)),
            agentScript: tools.windowsAgentScript,
            installScript: SupportImageBuilder.installScript)
        print("已生成工具盘：\(out.path)")
    }

    // MARK: - 共用

    static func libraryURL(_ args: inout Arguments) -> URL {
        args.option("library").map { URL(fileURLWithPath: $0) } ?? Preferences.libraryURL
    }

    static func guestOS(_ args: inout Arguments) throws -> GuestOS? {
        guard let raw = args.option("os") else { return nil }
        guard let os = GuestOS(rawValue: raw) else {
            throw CLIError("--os 只能是 \(GuestOS.allCases.map(\.rawValue).joined(separator: " | "))")
        }
        return os
    }

    static func applySizing(_ args: inout Arguments, to settings: inout VMSettings) throws {
        if let n = try args.int("cpus") { settings.cpuCount = n }
        if let n = try args.int("memory") { settings.memoryMB = n }
        if let n = try args.int("disk") { settings.diskSizeGB = n }
        if let raw = args.option("network") {
            guard let m = NetworkMode(rawValue: raw) else { throw CLIError("--network 只能是 none | user") }
            settings.network = m
        }
        for note in settings.clamp() { print("  \(note)") }
    }

    static func diskUsageGB(_ url: URL) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.size] as? NSNumber)?.doubleValue ?? 0) / 1_073_741_824
    }
}
