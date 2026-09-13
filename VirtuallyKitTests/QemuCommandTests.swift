import Foundation
import Testing
import VirtuallyKit

@Suite("QEMU 参数")
struct QemuCommandTests {

    @Test("设备与后端")
    func devices() {
        let original = Fixture.original
        let bundle = Fixture.bundle
        let cmd = Fixture.command()
        let args = cmd.arguments()

        expect(args.contains("-accel") == false, "加速器应写在 -machine 里,而非独立 -accel")
        expect(value(after: "-machine", in: args)?.contains("accel=hvf") == true, "启用 HVF")
        expectEqual(value(after: "-smp", in: args), "3", "CPU 数进入 -smp")
        expectEqual(value(after: "-m", in: args), "4096", "内存进入 -m")

        let devices = values(after: "-device", in: args)

        // 只挂一个显示设备:组合设备会让 Windows 把桌面扩展到两块屏上
        let displayDevices = devices.filter { $0.contains("gpu") || $0.contains("ramfb") || $0.contains("vga") }
        expectEqual(displayDevices.count, 1, "有且只有一个显示设备")
        expect(displayDevices.first?.hasPrefix("virtio-gpu-pci") == true, "显示设备是 virtio-gpu-pci")

        // NVMe 而非 virtio-blk:Windows 安装期零驱动依赖
        expect(devices.contains { $0.hasPrefix("nvme,") && $0.contains("bootindex=0") },
               "系统盘走 NVMe 且 bootindex=0")
        expect(values(after: "-drive", in: args).contains { $0.contains("format=qcow2") },
               "系统盘为 qcow2")

        // 绝对坐标指针:无需捕获鼠标
        expect(devices.contains("usb-tablet"), "使用绝对坐标指针")

        // guest agent 通道
        expect(devices.contains { $0.contains("virtserialport") && $0.contains("org.virtually.agent") },
               "存在 guest agent 的 virtio-serial 端口")

        // 网络模式
        expect(value(after: "-netdev", in: args)?.hasPrefix("user") == true, "user 模式生成 SLIRP")

        // 音频关闭时不应出现声卡
        expect(!devices.contains("intel-hda"), "audioEnabled=false 时无声卡")

        var withAudio = original
        withAudio.audioEnabled = true
        withAudio.network = .user
        let cmd2 = Fixture.command(withAudio)
        let args2 = cmd2.arguments()
        let devices2 = values(after: "-device", in: args2)
        // intel-hda 而非 virtio-sound:virtio-win 没有 ARM64 声卡驱动
        expect(devices2.contains("intel-hda"), "audioEnabled=true 时挂 intel-hda")
        expect(devices2.contains { $0.hasPrefix("hda-output") }, "只挂输出,不申请麦克风")
        expect(!devices2.contains { $0.contains("virtio-sound") }, "不用 virtio-sound")
        expect(value(after: "-netdev", in: args2)?.hasPrefix("user") == true, "user 模式生成 SLIRP")

        // 无网络也照样挂网卡:设备拓扑进快照,存/恢复之间动过网络开关就会不兼容。
        // 断网靠 set_link,不靠增删设备。
        let noNet = Fixture.noNet
        let args3 = Fixture.command(noNet).arguments()
        expectEqual(values(after: "-netdev", in: args3), values(after: "-netdev", in: args),
                    "网络设备拓扑与是否联网无关(快照要能跨网络开关恢复)")
        expect(values(after: "-device", in: args3).contains { $0.hasPrefix("virtio-net-pci") },
               "network=none 时网卡仍在,只是链路断开")
        // 绝不能一个网络参数都不发:QEMU 在没有 -netdev/-nic/-net 时会自己补一块
        // 默认网卡(system/vl.c 的 default_net,hw/arm/virt.c 的 default_nic),
        // 「无网络」的虚拟机会照样能上外网。这个 bug 让此前所有「断网基线」都不成立。
        expect(!values(after: "-netdev", in: args3).isEmpty,
               "始终显式给出 netdev(否则 QEMU 会补默认网卡)")
        // 缩略图落在包里
        expectEqual(bundle.thumbnailURL.lastPathComponent, "thumbnail.jpg", "缩略图叫 thumbnail.jpg")
        expectEqual(bundle.thumbnailURL.deletingLastPathComponent().path, bundle.url.path,
                    "缩略图放在虚拟机包内(删包即删图)")
        // 热插拔要插在根端口上,arm virt 的 pcie.0 不支持热插
        expect(args3.contains { $0.hasPrefix("pcie-root-port") },
               "预留 PCIe 根端口供网卡热插拔")
    }

    @Test("迁移指纹")
    func migrationFingerprint() {
        let original = Fixture.original
        let args = Fixture.args
        let noNet = Fixture.noNet
        func shape(_ st: VMSettings, sock: String = "/d") -> String { Fixture.shape(st, sock: sock) }
        // 恢复挂起状态要 -S:让 QEMU 停在 guest 还没跑之前,先读状态再 cont
        var paused = Fixture.command()
        expect(!paused.arguments().contains("-S"), "平时不加 -S")
        let shapeBefore = paused.migrationFingerprint()
        paused.startPaused = true
        expect(paused.arguments().contains("-S"), "恢复挂起状态时加 -S")
        expectEqual(paused.migrationFingerprint(), shapeBefore,
                    "-S 不进指纹(否则存的状态永远对不上)")
        expectEqual(shape(original), shape(original, sock: "/另一个会话.sock"),
                    "指纹不含 socket 路径(同一台机器换会话号不该让快照失效)")
        expectEqual(shape(original), shape(noNet),
                    "指纹与是否联网无关(断网只改链路,不动设备)")
        var moreRAM = original
        moreRAM.memoryMB = original.memoryMB * 2
        expect(shape(original) != shape(moreRAM), "改内存必须让旧快照失效")

        // 内存状态落在第一个可写且支持快照的块设备上(bdrv_all_find_vmstate_bs 按命令行顺序)。
        // 系统盘必须排在 nvram 的 pflash 之前,否则 4GB 的内存状态全进 64MB 的 EFI 变量文件 ——
        // 实测 nvram.qcow2 膨胀到 15–30GB。
        let firstWritableQcow2 = values(after: "-drive", in: args)
            .first { $0.contains("format=qcow2") && !$0.contains("readonly=on") }
        expect(firstWritableQcow2?.contains("disk.qcow2") == true,
               "第一个可写的 qcow2 drive 必须是系统盘(内存状态才不会写进 nvram)")
        // 会让旧快照读不回来的改动靠升版本号挡住,旧快照按「配置不符」拒绝
        expect(shape(original).hasPrefix(QemuCommand.fingerprintVersion + "\n"), "指纹带格式版本前缀")
        var otherSize = original
        otherSize.displayWidth = 1000; otherSize.displayHeight = 700
        expectEqual(shape(original), shape(otherSize), "初始分辨率不进指纹(改初始尺寸不该让挂起状态作废)")
        // 重编 QEMU 后迁移流格式未必兼容,版本号进指纹
        var otherQemu = Fixture.command()
        otherQemu.qemuVersion = "QEMU emulator version 99.0"
        expect(otherQemu.migrationFingerprint() != shape(original), "QEMU 版本进指纹")
    }

    @Test("NVRAM")
    func nvram() throws {
        let args = Fixture.args
        let nvram = URL(fileURLWithPath: NSTemporaryDirectory() + "virtually-test-nvram-\(UUID().uuidString.prefix(8)).fd")
        try? FileManager.default.removeItem(at: nvram)
        try VMBundle.writeBlankFlash(at: nvram)
        let size = (try FileManager.default.attributesOfItem(atPath: nvram.path)[.size] as? NSNumber)?.intValue ?? 0
        expectEqual(size, 64 * 1024 * 1024, "NVRAM 为 64MB")
        // 空白 flash 是全 1。用全 0 填充,部分固件会当成已写入的垃圾数据。
        let head = try FileHandle(forReadingFrom: nvram).read(upToCount: 4096) ?? Data()
        expect(head.allSatisfy { $0 == 0xff }, "NVRAM 以 0xff 填充")
        try? FileManager.default.removeItem(at: nvram)
        // pflash 必须是 qcow2:raw 的可写 pflash 会让 savevm 直接失败
        expect(args.contains { $0.contains("if=pflash") && $0.contains("format=qcow2") },
               "可写 pflash 用 qcow2(否则无法快照)")
    }

    @Test("安装期引导顺序")
    func installBootOrder() {
        let bundle = Fixture.bundle
        var installCmd = QemuCommand(bundle: bundle, firmwareDir: URL(fileURLWithPath: "/fw"),
                                     displaySocket: "/d", framebufferPath: "/fb",
                                     agentSocket: "/a", qmpSocket: "/q")
        installCmd.installing = true
        // 支持盘自带引导文件,排最前;ISO 退后(install.wim 仍在其上)
        installCmd.extraDrives = [(path: "/support.img", isCDROM: false, bootIndex: 0),
                                  (path: "/win.iso", isCDROM: true, bootIndex: 2)]
        let installArgs = installCmd.arguments()
        let installDevices = values(after: "-device", in: installArgs)

        expect(installDevices.contains { $0.hasPrefix("nvme,") && $0.contains("bootindex=1") },
               "安装期系统盘退到 bootindex=1")
        // WinPE 没有 viogpudo,virtio-gpu 在 ExitBootServices 后会黑屏
        expect(installDevices.contains("ramfb"), "安装期用 ramfb(不依赖 guest 驱动)")
        expect(!installDevices.contains("virtio-gpu-pci"), "安装期不用 virtio-gpu-pci")
        // 支持盘带引导文件且排最前:从硬盘引导可避开 ISO 的「按任意键」提示
        expect(installDevices.contains { $0.contains("usb-storage") && $0.contains("bootindex=0")
                                         && $0.contains("removable=on") },
               "支持盘作为引导设备排在最前")
        expect(installDevices.contains { $0.contains("usb-storage") && $0.contains("bootindex=2") },
               "ISO 挂着但不排首位")
        // 安装介质要能热拔,必须有显式设备 id
        expect(installDevices.allSatisfy { !$0.contains("usb-storage") || $0.contains("id=usbdev") },
               "每个 usb-storage 都有可用于 device_del 的 id")
        expectEqual(QemuCommand.deviceID(forExtra: 0), "usbdev0", "设备 id 命名稳定")
        expect(!installDevices.contains { $0.hasPrefix("nvme,") && $0.contains("bootindex=0") },
               "安装期系统盘不应占 bootindex=0")
    }

    /// 三处差异一错就是黑屏或时钟偏一个时区,而这三处都只在安装期或启动参数里,
    /// 跑起来之后看不出来 —— 所以必须在这里钉住。
    @Test("按系统分支")
    func guestOSBranches() throws {
        let original = Fixture.original
        let args = Fixture.args
        var ubuntuSettings = original
        ubuntuSettings.os = .ubuntu
        var ubuntuInstall = Fixture.command(ubuntuSettings)
        ubuntuInstall.guestOS = .ubuntu
        ubuntuInstall.installing = true
        ubuntuInstall.extraDrives = [(path: "/boot.img", isCDROM: false, bootIndex: 0),
                                     (path: "/ubuntu.iso", isCDROM: true, bootIndex: 2)]
        let ubuntuArgs = ubuntuInstall.arguments()
        let ubuntuDevices = values(after: "-device", in: ubuntuArgs)
        // casper 的内核自带 virtio-gpu 驱动,不用 ramfb —— 于是分辨率跟随从安装期就能用
        expect(!ubuntuDevices.contains("ramfb"), "Ubuntu 安装期不用 ramfb")
        expect(ubuntuDevices.contains { $0.hasPrefix("virtio-gpu-pci") }, "Ubuntu 安装期用 virtio-gpu")
        // Linux 内核自带 virtio-blk,不需要 Windows 那个「装完再切」的两段式
        expect(!ubuntuDevices.contains { $0.hasPrefix("nvme,") }, "Ubuntu 安装期不用 nvme")
        expect(ubuntuDevices.contains { $0.hasPrefix("virtio-blk-pci,drive=hd0") },
               "Ubuntu 安装期系统盘就是 virtio-blk")
        // **这一项错了时钟会整体偏一个时区**
        expectEqual(value(after: "-rtc", in: ubuntuArgs), "base=utc", "Linux 认为 RTC 存 UTC")
        expectEqual(value(after: "-rtc", in: args), "base=localtime", "Windows 认为 RTC 存本地时间")
        // 引导顺序:引导盘 0 / 系统盘 1 / ISO 2,三个都不能撞
        // (撞了 QEMU 直接拒绝启动:"The bootindex 1 has already been used")
        expect(ubuntuDevices.contains { $0.contains("usb-storage") && $0.contains("bootindex=0") },
               "Ubuntu 的 CIDATA 引导盘排最前")
        expect(ubuntuDevices.contains { $0.hasPrefix("virtio-blk-pci") && $0.contains("bootindex=1") },
               "系统盘退到 1")
        expect(ubuntuDevices.contains { $0.contains("usb-storage") && $0.contains("bootindex=2") },
               "ISO 排 2")
        let bootIndexes = ubuntuDevices.compactMap { dev -> String? in
            dev.split(separator: ",").first { $0.hasPrefix("bootindex=") }.map(String.init)
        }
        expectEqual(bootIndexes.count, Set(bootIndexes).count, "bootindex 不能重复")

        // GuestOS 的取值写进 config.json,不能随便改
        expectEqual(GuestOS(rawValue: "ubuntu"), GuestOS.ubuntu, "GuestOS 的 rawValue 稳定")
        expectEqual(GuestOS(rawValue: "windows"), GuestOS.windows, "GuestOS 的 rawValue 稳定")
        expect(GuestOS.windows.needsVirtioDrivers, "Windows 的工具盘要带 virtio 驱动")
        expect(!GuestOS.ubuntu.needsVirtioDrivers, "Ubuntu 内核自带 virtio 驱动")
        expect(GuestOS.ubuntu.minDiskGB < GuestOS.windows.minDiskGB, "Ubuntu 装得下的盘更小")
        // 驱动 ISO 只有 Windows 有,所以这个字段是可选的
        var media = InstallMedia(iso: "/i.iso", boot: "/b.img", tools: "/b.img", virtioISO: nil)
        var withMedia = ubuntuSettings
        withMedia.install = media
        let back = try JSONDecoder().decode(VMSettings.self, from: JSONEncoder().encode(withMedia))
        expect(back.install?.virtioISO == nil, "没有驱动盘时 virtioISO 为 nil 且能往返")
        expectEqual(back.os, GuestOS.ubuntu, "系统能往返")
        media.virtioISO = "/v.iso"
        expectEqual(media.virtioISO, "/v.iso", "Windows 的驱动盘路径记得住")
    }
}
