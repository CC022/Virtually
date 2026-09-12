import Foundation
import Testing
import VirtuallyKit

@Suite("安装")
struct InstallTests {

    /// hdiutil **挂不了** Ubuntu 26.04 桌面版的 ISO(no mountable file systems),
    /// 而 Windows 的 ISO 是纯 UDF(ISO9660 那层只有一个 README 说「这是 UDF」),
    /// ISOReader 又读不了 UDF。两者正好互补,各管一边,所以两套都要留着。
    /// 这里用 hdiutil makehybrid 现造一张小 ISO 来验读取器本身。
    @Test("ISO9660 / Joliet 读取器")
    func isoReader() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("virtually-isotest-\(UUID().uuidString.prefix(8))")
        let tree = tmp.appendingPathComponent("tree")
        let fm = FileManager.default
        try fm.createDirectory(at: tree.appendingPathComponent("casper"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tree.appendingPathComponent(".disk"), withIntermediateDirectories: true)
        try "Ubuntu 26.04.1 LTS 测试".write(to: tree.appendingPathComponent(".disk/info"),
                                            atomically: true, encoding: .utf8)
        // 长文件名(要靠 Joliet 才存得下)与一个比单扇区大的文件(要跨扇区读)
        let long = "a-rather-long-file-name-that-needs-joliet.txt"
        try String(repeating: "x", count: 200_000).write(
            to: tree.appendingPathComponent("casper/\(long)"), atomically: true, encoding: .utf8)
        try "KERNEL".write(to: tree.appendingPathComponent("casper/vmlinuz"),
                           atomically: true, encoding: .utf8)
        let iso = tmp.appendingPathComponent("test.iso")
        _ = try VMBundle.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                             ["makehybrid", "-iso", "-joliet", "-o", iso.path, tree.path, "-quiet"])
        let r = try ISOReader(iso: iso)
        defer { r.close(); try? fm.removeItem(at: tmp) }
        expect(r.exists("/casper/vmlinuz"), "读得到子目录里的文件")
        expect(r.exists("/.disk/info"), "读得到以点开头的目录")
        expect(!r.exists("/sources/install.wim"), "不存在的路径报不存在")
        expectEqual(String(decoding: try r.read("/casper/vmlinuz"), as: UTF8.self), "KERNEL",
                    "文件内容正确")
        expect(String(decoding: try r.read("/.disk/info"), as: UTF8.self).contains("Ubuntu"),
               "中文与 UTF-8 内容正确")
        // 跨扇区:200KB 的文件要能完整读出来
        let big = try r.read("/casper/\(long)")
        expectEqual(big.count, 200_000, "跨扇区的大文件长度正确(Joliet 长名也解得出)")
        expect(big.allSatisfy { $0 == UInt8(ascii: "x") }, "大文件内容没有错位")
        // 取中间一段:WIM 的 XML 元数据就靠这个
        let mid = try r.read("/casper/\(long)", offset: 100_000, count: 16)
        expectEqual(mid.count, 16, "能从文件中间取一段")
        // 流式拷贝
        let out = tmp.appendingPathComponent("copied.bin")
        try r.copy("/casper/\(long)", to: out)
        expectEqual((try? Data(contentsOf: out))?.count, 200_000, "流式拷贝的长度一致")
        expectEqual(try r.list("/casper").count, 2, "目录列举数目正确")
    }

    /// install-sources.yaml 的变体解析。只认 id 与 name.en,description 下也有 en 要躲开。
    @Test("Ubuntu 变体解析")
    func ubuntuVariants() {
        let sourcesYAML = """
        kernel:
          default: linux-generic-hwe-24.04
        sources:
        - default: true
          description:
            en: A minimal but usable Ubuntu Desktop.
          id: ubuntu-desktop-minimal
          name:
            en: Ubuntu Desktop (minimized)
          size: 6513106944
          type: fsimage-layered
        - default: false
          description:
            en: A full featured Ubuntu Desktop.
          id: ubuntu-desktop
          name:
            en: Ubuntu Desktop
          size: 8097796096
        version: 2
        """
        let variants = UbuntuSeedDisk.parseVariants(sourcesYAML)
        expectEqual(variants.count, 2, "解析出两个变体")
        expectEqual(variants.first?.id, "ubuntu-desktop-minimal", "第一个变体的 id")
        expectEqual(variants.first?.name, "Ubuntu Desktop (minimized)", "名字取 name.en,不是 description.en")
        expectEqual(variants.last?.name, "Ubuntu Desktop", "第二个变体的名字")
        expectEqual(UbuntuSeedDisk.defaultVariant(variants)?.id, "ubuntu-desktop-minimal",
                    "默认挑 minimal(装得快)")
    }

    @Test("Ubuntu autoinstall 应答文件")
    func ubuntuAutoinstall() {
        var uo = UbuntuInstallOptions()
        uo.variantID = "ubuntu-desktop"
        uo.password = "秘密口令"
        let ua = AutoinstallGenerator.generate(uo)
        expect(ua.hasPrefix("#cloud-config\n"), "cloud-init 要这一行开头")
        expect(ua.contains("autoinstall:"), "含 autoinstall 段")
        expect(ua.contains("id: ubuntu-desktop"), "变体 id 写进 source")
        expect(ua.contains("shutdown: reboot"), "装完自己重启(否则停在那儿等人)")
        expect(ua.contains("early-commands:") && ua.contains("late-commands:"), "两段命令都在")
        // **明文密码绝不能进这份文件** —— 它会被复制到 guest 的 /var/log/installer
        expect(!ua.contains("秘密口令"), "密码不以明文出现")
        expect(ua.contains("password: \"$6$"), "密码是 SHA-512 crypt 形式")
        // 自动确认那条路的三个关键点
        expect(ua.contains("NEEDS_CONFIRMATION"), "轮询器等的是这个状态")
        expect(ua.contains("/meta/confirm"), "走 subiquity 自己的 API 确认,不点 UI 坐标")
        expect(ua.contains("/run/subiquity/socket"), "API 走这个 unix socket")
        expect(ua.contains("vainstall "), "进度按 vainstall 前缀回传宿主")
        // 自动登录与欢迎向导
        expect(ua.contains("AutomaticLogin=vm"), "开自动登录(agent 会话侧要有人登录)")
        expect(ua.contains("gnome-initial-setup-done"), "跳过首次登录的欢迎向导")
        expect(ua.contains("timezone: \(TimeZone.current.identifier)"),
               "时区直接用 IANA 名,不需要 Windows 那张映射表")
        // YAML 起码要能被解析器读(用 python 的 yaml 太重,这里只查缩进没崩)
        expect(!ua.contains("\t"), "YAML 里不能有制表符")
        expect(!ua.split(separator: "\n").contains { $0.hasPrefix(" ") && $0.trimmingCharacters(in: .whitespaces).isEmpty },
               "YAML 没有只含空格的行")
        // grub 配置:必须靠 search 找 ISO,不能写死盘符
        expect(AutoinstallGenerator.grubConfig.contains("search --file --set=root /.disk/info"),
               "grub 用 search 定位 ISO")
        expect(AutoinstallGenerator.grubConfig.contains("autoinstall"), "内核行带 autoinstall")
        expect(AutoinstallGenerator.grubConfig.contains("/casper/vmlinuz")
               && AutoinstallGenerator.grubConfig.contains("/casper/initrd"), "内核与 initrd 都从 ISO 取")
    }

    /// autoinstall 里的密码必须是 crypt 形式,明文会留在 guest 的 /var/log/installer 里。
    /// macOS 上没有能算 $6$ 的工具(LibreSSL 的 openssl passwd 没有 -6,python 的 crypt 退化成 DES),
    /// 所以自己实现。向量取自 Drepper 的 SHA-crypt 规范。
    @Test("SHA-512 crypt")
    func sha512Crypt() {
        expectEqual(SHA512Crypt.hash(password: "Hello world!", salt: "saltstring"),
                    "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1",
                    "SHA-crypt 规范向量 1")
        expectEqual(SHA512Crypt.hash(password: "Hello world!",
                                     salt: "saltstringsaltstring", rounds: 10000),
                    "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.",
                    "SHA-crypt 规范向量 2(盐超 16 字符要截断,rounds 非默认时写进前缀)")
        // 盐随机且长度对得上
        let saltA = SHA512Crypt.randomSalt(), saltB = SHA512Crypt.randomSalt()
        expectEqual(saltA.count, 16, "默认盐 16 字符")
        expect(saltA != saltB, "两次生成的盐不同")
        // 同一密码同一盐必须稳定,不同盐必须不同
        expectEqual(SHA512Crypt.hash(password: "vm", salt: saltA),
                    SHA512Crypt.hash(password: "vm", salt: saltA), "同盐同密码结果稳定")
        expect(SHA512Crypt.hash(password: "vm", salt: saltA)
               != SHA512Crypt.hash(password: "vm", salt: saltB), "换盐结果就变")
        expect(SHA512Crypt.hash(password: "vm", salt: saltA).hasPrefix("$6$\(saltA)$"), "前缀含算法与盐")
        // 轮数被夹到规范范围内
        expect(SHA512Crypt.hash(password: "vm", salt: "x", rounds: 1).contains("rounds=1000$"), "轮数下限 1000")
    }

    @Test("Windows 应答文件与安装脚本")
    func windowsUnattend() throws {
        let unattend = UnattendGenerator.generate(UnattendOptions(editionIndex: 3))
        expect(unattend.contains("processorArchitecture=\"arm64\""), "应答文件标记 arm64 架构")
        for key in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck",
                    "BypassCPUCheck", "BypassStorageCheck"] {
            expect(unattend.contains(key), "包含 LabConfig 绕过项 \(key)")
        }
        expect(unattend.contains("<Value>3</Value>"), "版本索引写入 IMAGE/INDEX")
        expect(unattend.contains("<Key>W269N-"), "带通用版本选择密钥,否则会停在产品密钥页")
        expect(unattend.contains("<AcceptEula>true</AcceptEula>"), "自动接受许可协议")
        expect(unattend.contains("<HideOnlineAccountScreens>true"), "跳过联网账户页")
        expect(unattend.contains("install-agent.bat"), "首次登录安装 guest tools")
        // 分区表:ESP 260MB + MSR 16MB + 主分区扩展
        expect(unattend.contains("<Type>EFI</Type>") && unattend.contains("<Size>260</Size>"),
               "创建 260MB 的 ESP")
        expect(unattend.contains("<Extend>true</Extend>"), "主分区占满剩余空间")
        #expect(throws: Never.self, "应答文件是合法 XML") { try XMLDocument(xmlString: unattend) }

        var noToolsOptions = UnattendOptions(editionIndex: 1)
        noToolsOptions.installGuestTools = false
        let noTools = UnattendGenerator.generate(noToolsOptions)
        expect(!noTools.contains("FirstLogonCommands"), "关闭 guest tools 时不生成 FirstLogonCommands")

        // .bat 必须纯 ASCII:cmd.exe 按系统代码页读,UTF-8 中文会变乱码并被当成命令执行
        expect(SupportImageBuilder.installScript.allSatisfy { $0.isASCII },
               "install-agent.bat 必须是纯 ASCII")
        expect(SupportImageBuilder.installScript.contains("schtasks /create"),
               "安装脚本注册登录自启")
        // 只装 vioserial 会导致没有显卡驱动,开机后画面熄灭。
        // 断言意图而非字面路径:必须涵盖显示与网络驱动。
        for driver in ["viogpudo", "NetKVM", "vioserial"] {
            expect(SupportImageBuilder.installScript.contains(driver),
                   "驱动安装列表包含 \(driver)")
        }
        // pnputil 不接受路径中间的通配符,必须逐个目录枚举
        expect(!SupportImageBuilder.installScript.contains("%VIRTIO%\\*\\"),
               "不使用 pnputil 不支持的中间路径通配符")

        // 默认输入法:英文键盘必须排在第一位(列表第一项即默认)
        let localeXML = UnattendGenerator.generate(UnattendOptions(editionIndex: 3))
        expect(localeXML.contains("<InputLocale>0409:00000409;"),
               "InputLocale 以英文键盘打头(第一项即默认输入法)")
        expect(localeXML.contains("0804:00000804"),
               "中文拼音仍在输入法列表里")
        expect(SupportImageBuilder.installScript.contains("Set-WinDefaultInputMethodOverride"),
               "首次登录脚本兜底设置默认输入法")

        // guest 时区必须与宿主一致,否则时钟在重启之间来回跳,
        // 任务计划服务会因为「上次运行时间在未来」而不再触发任何任务
        expect(localeXML.contains("<TimeZone>"), "应答文件显式设置时区")
        expect(!UnattendOptions.hostWindowsTimeZone.isEmpty, "能从宿主推出 Windows 时区 ID")
        expectEqual(UnattendOptions.windowsTimeZone(forIANA: "Europe/Madrid"), "Romance Standard Time",
                    "常见时区在表里")
        // 表里没有的按当前偏移找同偏移的:圣马力诺跟着欧洲中部
        expect(UnattendOptions.windowsTimeZone(forIANA: "Europe/San_Marino") != "UTC",
               "表里没有的时区按偏移匹配,不直接退回 UTC")
        expect(UnattendOptions.ianaToWindows.count > 100, "时区表覆盖 100 个以上 IANA 名")

        // 默认不联网:联网会让 Windows 自己更新,基线不可复现
        expectEqual(VMSettings.default(for: .windows).network, NetworkMode.none, "新虚拟机默认不联网")
        // 断网时 Win11 的 OOBE 会强制要求联网,必须绕过
        expect(localeXML.contains("BypassNRO"), "应答文件绕过 OOBE 的联网强制要求")

        // 硬件光标:INF 默认关闭,必须显式打开,否则光标被画进帧缓冲
        // 显示类子键的序号不可预测(实测 0000 / 0002 / 0005),必须按 DriverDesc 匹配
        // 会话侧助手不能挂在一个 cmd 窗口下面 —— 窗口一关 agent 就没了。
        let script = SupportImageBuilder.installScript
        expect(script.contains("run-agent-session.vbs"), "会话侧用 vbs 启动器,不留控制台窗口")
        expect(!script.contains("run-agent-session.cmd\" /f")
               && script.contains("/d \"wscript.exe %USRRUN%\""),
               "Run 键指向 wscript,而不是 .cmd")
        expect(!script.contains("/create /tn VirtuallyAgentSession"),
               "会话侧不靠计划任务复活(靠 SYSTEM 侧的 CreateProcessAsUser)")

        expect(SupportImageBuilder.installScript.contains("HWCursor"),
               "安装脚本打开 virtio-gpu 硬件光标")
        expect(SupportImageBuilder.installScript.contains("DriverDesc -like '*VirtIO GPU*'"),
               "按 DriverDesc 定位显示类子键,不写死序号")

        // DPI:200% 必须在 specialize 里写进默认用户配置单元,
        // 否则 HKCU 要等下次登录才生效,首次进桌面还是 100%
        expect(localeXML.contains("<settings pass=\"specialize\">"),
               "应答文件有 specialize 段(DPI 要在账户建立前写)")
        expect(localeXML.contains("C:\\Users\\Default\\NTUSER.DAT"),
               "DPI 写进默认用户配置单元,新账户直接继承")
        expect(localeXML.contains("/v LogPixels /t REG_DWORD /d 192"),
               "默认 DPI 为 200%(LogPixels=192)")
        expect(localeXML.contains("/v Win8DpiScaling /t REG_DWORD /d 1"),
               "Win8DpiScaling=1,否则 LogPixels 会被忽略")
        // 主题同样要写默认配置单元:HKCU 版本要等 explorer 重启才生效,
        // 实测首次进桌面仍是浅色
        expect(localeXML.contains("HKU\\DefUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
               "深色主题写进默认用户配置单元(首次桌面即深色)")
        expect(localeXML.contains("img19.jpg"),
               "默认壁纸为深色版")

        // 深色主题:两个键都要设,只设 AppsUseLightTheme 会留一条白色任务栏
        expect(SupportImageBuilder.installScript.contains("AppsUseLightTheme /t REG_DWORD /d 0"),
               "安装脚本把应用设为深色")
        expect(SupportImageBuilder.installScript.contains("SystemUsesLightTheme /t REG_DWORD /d 0"),
               "安装脚本把任务栏/开始菜单设为深色")
        expect(SupportImageBuilder.installScript.contains("img19.jpg"),
               "安装脚本换成深色壁纸(img19 是 Win11 的深色版)")
        // 拷贝 agent 前必须校验来源:曾经拷出过一个大小正确但全是 NUL 的空壳
        // 不能带 /b:文件以 UTF-8 BOM 开头,标记不在第 1 行第 1 列
        expect(SupportImageBuilder.installScript.contains("findstr /c:\"Virtually Guest Agent\""),
               "拷贝 agent.ps1 前先校验来源内容")
        expect(!SupportImageBuilder.installScript.contains("findstr /b"),
               "校验不能用 /b —— BOM 会让行首匹配失败")
        expect(SupportImageBuilder.installScript.contains("agent.new"),
               "经临时文件再 move,避免半个文件成为 agent")

        // 提权脚本里重启 explorer 会让会话彻底没有 shell(纯黑桌面)。
        // 只看真正的命令行 —— 注释里必然会提到 explorer.exe 来解释这条约束。
        let realLines = SupportImageBuilder.installScript
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.uppercased().hasPrefix("REM") }
        expect(realLines.allSatisfy { !$0.contains("explorer.exe") },
               "安装脚本的命令里不出现 explorer —— 提权下重启它会导致会话无 shell")
    }

    static let windowsISO = NSHomeDirectory() + "/Downloads/Win11_25H2_Chinese_Simplified_Arm64_v2.iso"

    /// 要挂载真实 ISO,只在显式要求时跑:VIRTUALLY_ISO_TESTS=1。
    /// 从命令行跑测试时 testmanagerd 拉起的进程没有「下载」文件夹的访问权限,hdiutil 会被拒绝。
    static var isoTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["VIRTUALLY_ISO_TESTS"] == "1"
            && FileManager.default.fileExists(atPath: windowsISO)
    }

    @Test("Windows ISO 版本解析", .enabled(if: isoTestsEnabled, "设 VIRTUALLY_ISO_TESTS=1 且本机有这张 ISO 时才跑"))
    func windowsEditions() throws {
        let editions = try ISOInspector.editions(inISO: URL(fileURLWithPath: Self.windowsISO))
        expectEqual(editions.count, 3, "该中文 ARM64 ISO 含 3 个版本")
        expect(editions.contains { $0.index == 3 && $0.name.contains("Pro") },
               "Pro 的索引是 3(不是常见的 6)")
    }
}
