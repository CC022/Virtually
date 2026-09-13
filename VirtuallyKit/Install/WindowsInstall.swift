// Windows 无人值守安装。
//
// 三个部件:
//   ISOInspector       —— 从 install.wim 解析出可安装的版本列表
//   UnattendGenerator  —— 生成 autounattend.xml
//   SupportImageBuilder —— 打一张 FAT32 支持盘(应答文件 + 驱动 + agent)
//
// 整套流程在 spike 阶段已手工验证过:全自动装完约 10 分钟。
// 这里把它收进代码,让 app 能真正创建虚拟机。

import Foundation

// MARK: - ISO 检查

public struct WindowsEdition: Equatable {
    public let index: Int
    public let name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

public enum ISOInspector {

    /// 这张镜像是哪个系统的。**只用来校验用户在向导里选的那一项**,拿不准就返回 nil。
    ///
    /// 两条路互补,原因见 ISOReader 的文件头:
    ///   Ubuntu 的 ISO 是 ISO9660+Joliet,hdiutil 挂不上,得用 ISOReader
    ///   Windows 的 ISO 是纯 UDF,ISOReader 读不了,得用 hdiutil
    /// 所以先用便宜的那条(ISOReader 不挂载、不要权限),不中再去挂。
    public static func detect(_ iso: URL) -> GuestOS? {
        if let r = try? ISOReader(iso: iso) {
            defer { r.close() }
            if r.exists("/casper/vmlinuz"), r.exists("/.disk/info") { return .ubuntu }
        }
        if let mount = try? Mount(iso: iso) {
            defer { mount.detach() }
            if FileManager.default.fileExists(
                atPath: mount.path.appendingPathComponent("sources/install.wim").path) {
                return .windows
            }
        }
        return nil
    }

    /// 镜像里可装的变体。Windows 是 WIM 的映像索引,Ubuntu 是 install-sources 的 id。
    public static func variants(inISO iso: URL, os: GuestOS) throws -> [InstallVariant] {
        switch os {
        case .windows:
            return try editions(inISO: iso).map { InstallVariant(id: "\($0.index)", name: $0.name) }
        case .ubuntu:
            return try UbuntuSeedDisk.variants(inISO: iso)
        }
    }

    /// 解析 ISO 里 install.wim 的版本列表。
    ///
    /// **版本索引必须实测解析,不能硬编码**:官方中文 ARM64 ISO 只有 3 个版本
    /// (Home / Home Single Language / Pro),而不是常见的 6 个 —— 我第一次就猜错了。
    public static func editions(inISO iso: URL) throws -> [WindowsEdition] {
        let mount = try Mount(iso: iso)
        defer { mount.detach() }

        let wim = mount.path.appendingPathComponent("sources/install.wim")
        guard FileManager.default.fileExists(atPath: wim.path) else {
            throw InstallError.notWindowsISO("找不到 sources/install.wim")
        }
        return try editions(inWIM: wim)
    }

    /// WIM 尾部带一段 UTF-16LE 的 XML,描述所有映像。
    /// 头部布局:magic "MSWIM\0\0\0";0x2c 处是映像数量;
    /// 0x48 处是 rhXmlData —— flags|size(8) + offset(8) + originalSize(8)。
    public static func editions(inWIM wim: URL) throws -> [WindowsEdition] {
        let handle = try FileHandle(forReadingFrom: wim)
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: 208), header.count == 208 else {
            throw InstallError.notWindowsISO("无法读取 install.wim 头部")
        }
        guard header.prefix(8) == Data("MSWIM\0\0\0".utf8) else {
            throw InstallError.notWindowsISO("install.wim 不是有效的 WIM 文件")
        }

        func u64(_ offset: Int) -> UInt64 {
            header.subdata(in: offset..<(offset + 8)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self).littleEndian
            }
        }
        let flagsSize = u64(0x48)
        let xmlOffset = u64(0x50)
        let xmlSize = Int(flagsSize & 0x00FF_FFFF_FFFF_FFFF)
        guard xmlSize > 0, xmlSize < 8 * 1024 * 1024 else {
            throw InstallError.notWindowsISO("install.wim 的 XML 元数据尺寸异常")
        }

        try handle.seek(toOffset: xmlOffset)
        guard let raw = try handle.read(upToCount: xmlSize) else {
            throw InstallError.notWindowsISO("无法读取 install.wim 的 XML 元数据")
        }
        // WIM 的元数据是 UTF-16LE(带 BOM),不是 UTF-8
        guard let xml = String(data: raw, encoding: .utf16LittleEndian) else {
            throw InstallError.notWindowsISO("install.wim 的 XML 元数据不是有效的 UTF-16LE")
        }

        // 映像名在本地化 ISO 上仍是英文(实测中文 ISO 也是 "Windows 11 Pro")
        var result: [WindowsEdition] = []
        var searchStart = xml.startIndex
        while let imgRange = xml.range(of: "<IMAGE INDEX=\"", range: searchStart..<xml.endIndex) {
            guard let quoteEnd = xml.range(of: "\"", range: imgRange.upperBound..<xml.endIndex),
                  let idx = Int(xml[imgRange.upperBound..<quoteEnd.lowerBound]) else {
                searchStart = imgRange.upperBound; continue
            }
            let tail = quoteEnd.upperBound..<xml.endIndex
            if let nameOpen = xml.range(of: "<NAME>", range: tail),
               let nameClose = xml.range(of: "</NAME>", range: nameOpen.upperBound..<xml.endIndex) {
                result.append(WindowsEdition(index: idx,
                                             name: String(xml[nameOpen.upperBound..<nameClose.lowerBound])))
                searchStart = nameClose.upperBound
            } else {
                searchStart = quoteEnd.upperBound
            }
        }
        guard !result.isEmpty else {
            throw InstallError.notWindowsISO("未能从 install.wim 解析出任何版本")
        }
        return result
    }

    /// hdiutil 挂载的 RAII 包装
    public final class Mount {
        public let path: URL
        private let device: String

        public convenience init(iso: URL) throws { try self.init(image: iso, raw: false) }

        /// raw 的 FAT 镜像(传输盘)要带 imagekey,hdiutil 才认
        public init(image: URL, raw: Bool) throws {
            var args = ["attach", "-readonly", "-nobrowse", "-plist"]
            if raw { args += ["-imagekey", "diskimage-class=CRawDiskImage"] }
            let out = try VMBundle.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), args + [image.path])
            // plist 里找 dev-entry 与 mount-point
            guard let mountPoint = Mount.firstValue(after: "<key>mount-point</key>", in: out),
                  let dev = Mount.firstValue(after: "<key>dev-entry</key>", in: out) else {
                throw InstallError.notWindowsISO("无法装载 ISO")
            }
            self.path = URL(fileURLWithPath: mountPoint)
            self.device = dev
        }

        public func detach() {
            _ = try? VMBundle.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", device, "-quiet"])
        }

        private static func firstValue(after key: String, in plist: String) -> String? {
            guard let k = plist.range(of: key),
                  let open = plist.range(of: "<string>", range: k.upperBound..<plist.endIndex),
                  let close = plist.range(of: "</string>", range: open.upperBound..<plist.endIndex)
            else { return nil }
            return String(plist[open.upperBound..<close.lowerBound])
        }
    }
}

// MARK: - 应答文件

public struct UnattendOptions {
    /// 自动登录次数。见 XML 里的注释:agent 依赖用户会话。
    public var autoLogonCount = 1000

    public var editionIndex: Int
    public var uiLanguage = "zh-CN"
    /// 列表里的**第一项就是默认输入法**。把英文键盘排在中文拼音前面,
    /// 界面语言仍是中文,但开机默认是英文输入 —— 中文拼音依然在列表里,
    /// 用 Win+空格 或 Shift 随时切回。
    ///
    /// 这不只是偏好问题:中文 IME 会把注入的按键转换掉
    /// (`cmd` 变成 `c'm'd` 的拼音候选),自动化和粘贴命令都会踩到。
    public var inputLocale = "0409:00000409;0804:00000804"
    /// guest 的 DPI 缩放百分比。Mac 几乎都是 Retina,而我们把 guest 分辨率
    /// 设成宿主的物理像素以求 1:1 锐利,所以 100% 会小到看不清。
    public var dpiScalePercent = 200
    /// guest 时区,必须与宿主一致。
    ///
    /// QEMU 用 `-rtc base=localtime`,即把**宿主的本地时间**写进 guest 的 RTC。
    /// 如果 guest 认为自己在别的时区,它显示/记录的时间就会整体偏移,而每次开机
    /// RTC 又被重新播成宿主本地时间 —— 于是时钟在重启之间来回跳。
    ///
    /// 后果不只是时间显示不对:**任务计划服务会因此不再触发任何任务**。
    /// 实测宿主在 UTC-7、中文 Windows 默认 UTC+8,差 15 小时;计划任务的
    /// 「上次运行时间」永远落在当前时钟的未来,onlogon 与 onstart 触发器双双失效,
    /// 手动运行却立刻成功 —— 这个现象查了很多轮才追到时钟上。
    public var timeZone = UnattendOptions.hostWindowsTimeZone

    /// 把宿主的 IANA 时区映射成 Windows 时区 ID。表里没有的退回 UTC ——
    /// 宁可时区不对,也不能让两边不一致。
    public static var hostWindowsTimeZone: String {
        windowsTimeZone(forIANA: TimeZone.current.identifier)
    }

    /// 摘自 CLDR windowsZones 的常用部分。查不到时按当前 UTC 偏移找一个同偏移的 Windows 时区,
    /// 再不行才退回 UTC —— 校时已改成传 Unix 秒,时区不对只影响显示,不再影响计划任务。
    public static func windowsTimeZone(forIANA id: String) -> String {
        if let hit = ianaToWindows[id] { return hit }
        if let tz = TimeZone(identifier: id) {
            let offset = tz.secondsFromGMT()
            for (iana, win) in ianaToWindows.sorted(by: { $0.key < $1.key }) {
                if let t = TimeZone(identifier: iana), t.secondsFromGMT() == offset { return win }
            }
        }
        return "UTC"
    }

    public static let ianaToWindows: [String: String] = [
        // 美洲
        "America/Anchorage": "Alaskan Standard Time",
        "America/Los_Angeles": "Pacific Standard Time", "America/Vancouver": "Pacific Standard Time",
        "America/Tijuana": "Pacific Standard Time (Mexico)",
        "America/Phoenix": "US Mountain Standard Time",
        "America/Denver": "Mountain Standard Time", "America/Edmonton": "Mountain Standard Time",
        "America/Chihuahua": "Mountain Standard Time (Mexico)",
        "America/Chicago": "Central Standard Time", "America/Winnipeg": "Central Standard Time",
        "America/Mexico_City": "Central Standard Time (Mexico)",
        "America/Regina": "Canada Central Standard Time",
        "America/Bogota": "SA Pacific Standard Time", "America/Lima": "SA Pacific Standard Time",
        "America/New_York": "Eastern Standard Time", "America/Toronto": "Eastern Standard Time",
        "America/Detroit": "Eastern Standard Time", "America/Havana": "Cuba Standard Time",
        "America/Caracas": "Venezuela Standard Time",
        "America/Halifax": "Atlantic Standard Time", "America/Santiago": "Pacific SA Standard Time",
        "America/La_Paz": "SA Western Standard Time",
        "America/St_Johns": "Newfoundland Standard Time",
        "America/Sao_Paulo": "E. South America Standard Time",
        "America/Argentina/Buenos_Aires": "Argentina Standard Time",
        "America/Montevideo": "Montevideo Standard Time",
        "America/Godthab": "Greenland Standard Time", "America/Nuuk": "Greenland Standard Time",
        "Atlantic/Azores": "Azores Standard Time", "Atlantic/Cape_Verde": "Cape Verde Standard Time",
        "Pacific/Honolulu": "Hawaiian Standard Time",
        // 欧洲与非洲
        "Europe/London": "GMT Standard Time", "Europe/Dublin": "GMT Standard Time",
        "Europe/Lisbon": "GMT Standard Time", "Atlantic/Reykjavik": "Greenwich Standard Time",
        "Africa/Casablanca": "Morocco Standard Time",
        "Europe/Berlin": "W. Europe Standard Time", "Europe/Amsterdam": "W. Europe Standard Time",
        "Europe/Rome": "W. Europe Standard Time", "Europe/Stockholm": "W. Europe Standard Time",
        "Europe/Vienna": "W. Europe Standard Time", "Europe/Zurich": "W. Europe Standard Time",
        "Europe/Oslo": "W. Europe Standard Time",
        "Europe/Paris": "Romance Standard Time", "Europe/Brussels": "Romance Standard Time",
        "Europe/Madrid": "Romance Standard Time", "Europe/Copenhagen": "Romance Standard Time",
        "Europe/Warsaw": "Central European Standard Time", "Europe/Belgrade": "Central Europe Standard Time",
        "Europe/Prague": "Central Europe Standard Time", "Europe/Budapest": "Central Europe Standard Time",
        "Africa/Lagos": "W. Central Africa Standard Time",
        "Europe/Athens": "GTB Standard Time", "Europe/Bucharest": "GTB Standard Time",
        "Europe/Helsinki": "FLE Standard Time", "Europe/Kiev": "FLE Standard Time",
        "Europe/Kyiv": "FLE Standard Time", "Europe/Riga": "FLE Standard Time",
        "Europe/Sofia": "FLE Standard Time", "Europe/Vilnius": "FLE Standard Time",
        "Europe/Tallinn": "FLE Standard Time",
        "Asia/Jerusalem": "Israel Standard Time", "Africa/Cairo": "Egypt Standard Time",
        "Africa/Johannesburg": "South Africa Standard Time", "Europe/Istanbul": "Turkey Standard Time",
        "Europe/Moscow": "Russian Standard Time", "Europe/Minsk": "Belarus Standard Time",
        "Asia/Baghdad": "Arabic Standard Time", "Asia/Riyadh": "Arab Standard Time",
        "Africa/Nairobi": "E. Africa Standard Time", "Asia/Tehran": "Iran Standard Time",
        // 亚洲与大洋洲
        "Asia/Dubai": "Arabian Standard Time", "Asia/Baku": "Azerbaijan Standard Time",
        "Asia/Tbilisi": "Georgian Standard Time", "Asia/Yerevan": "Caucasus Standard Time",
        "Asia/Kabul": "Afghanistan Standard Time", "Asia/Karachi": "Pakistan Standard Time",
        "Asia/Tashkent": "West Asia Standard Time", "Asia/Yekaterinburg": "Ekaterinburg Standard Time",
        "Asia/Kolkata": "India Standard Time", "Asia/Calcutta": "India Standard Time",
        "Asia/Colombo": "Sri Lanka Standard Time", "Asia/Kathmandu": "Nepal Standard Time",
        "Asia/Dhaka": "Bangladesh Standard Time", "Asia/Almaty": "Central Asia Standard Time",
        "Asia/Yangon": "Myanmar Standard Time", "Asia/Rangoon": "Myanmar Standard Time",
        "Asia/Bangkok": "SE Asia Standard Time", "Asia/Jakarta": "SE Asia Standard Time",
        "Asia/Ho_Chi_Minh": "SE Asia Standard Time", "Asia/Saigon": "SE Asia Standard Time",
        "Asia/Novosibirsk": "N. Central Asia Standard Time", "Asia/Krasnoyarsk": "North Asia Standard Time",
        "Asia/Shanghai": "China Standard Time", "Asia/Hong_Kong": "China Standard Time",
        "Asia/Macau": "China Standard Time", "Asia/Chongqing": "China Standard Time",
        "Asia/Taipei": "Taipei Standard Time", "Asia/Singapore": "Singapore Standard Time",
        "Asia/Kuala_Lumpur": "Singapore Standard Time", "Asia/Manila": "Singapore Standard Time",
        "Australia/Perth": "W. Australia Standard Time", "Asia/Ulaanbaatar": "Ulaanbaatar Standard Time",
        "Asia/Irkutsk": "North Asia East Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time", "Asia/Seoul": "Korea Standard Time",
        "Asia/Pyongyang": "North Korea Standard Time", "Asia/Yakutsk": "Yakutsk Standard Time",
        "Australia/Darwin": "AUS Central Standard Time", "Australia/Adelaide": "Cen. Australia Standard Time",
        "Australia/Brisbane": "E. Australia Standard Time", "Australia/Sydney": "AUS Eastern Standard Time",
        "Australia/Melbourne": "AUS Eastern Standard Time", "Australia/Hobart": "Tasmania Standard Time",
        "Pacific/Guam": "West Pacific Standard Time", "Asia/Vladivostok": "Vladivostok Standard Time",
        "Pacific/Auckland": "New Zealand Standard Time", "Pacific/Fiji": "Fiji Standard Time",
        "Asia/Magadan": "Magadan Standard Time", "Pacific/Tongatapu": "Tonga Standard Time",
        "UTC": "UTC", "Etc/UTC": "UTC", "Etc/GMT": "UTC",
    ]

    public var username = "vm"
    public var password = "vm"
    public var computerName = "WINVM"
    /// 首次登录时从支持盘安装 virtio 驱动并注册 guest agent
    public var installGuestTools = true

    /// 微软公开的通用版本选择密钥(非激活用),让安装程序确定性地选中 Pro。
    /// 缺了它安装会停在「产品密钥」页等待输入。
    public var productKey = "W269N-WFGWX-YVC9B-4J6C9-T83GX"

    public init(editionIndex: Int) {
        self.editionIndex = editionIndex
    }
}

public enum UnattendGenerator {

    public static func generate(_ o: UnattendOptions) -> String {
        // LabConfig 五项绕过:QEMU 可以用 swtpm 提供真 TPM,但那需要额外依赖。
        // 这些键让 Windows 11 跳过 TPM / SecureBoot / RAM / CPU / 存储检查。
        let bypasses = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck",
                        "BypassCPUCheck", "BypassStorageCheck"]
        let runSynchronous = bypasses.enumerated().map { i, key in
            """
                    <RunSynchronousCommand wcm:action="add">
                      <Order>\(i + 1)</Order>
                      <Path>reg add HKLM\\System\\Setup\\LabConfig /v \(key) /t REG_DWORD /d 1 /f</Path>
                    </RunSynchronousCommand>
            """
        }.joined(separator: "\n")

        // 首次登录:装 virtio 驱动 + 注册 agent 自启。
        // 支持盘的盘符不固定,所以用 for 循环探测。
        let firstLogon = o.installGuestTools ? """
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <CommandLine>cmd /c for %d in (D E F G H I) do @if exist %d:\\install-agent.bat call %d:\\install-agent.bat</CommandLine>
                  <Description>安装 virtio 驱动与 guest agent</Description>
                </SynchronousCommand>
              </FirstLogonCommands>
        """ : ""

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">

          <settings pass="windowsPE">
            <component name="Microsoft-Windows-International-Core-WinPE"
                       processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS"
                       xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <SetupUILanguage><UILanguage>\(o.uiLanguage)</UILanguage></SetupUILanguage>
              <InputLocale>\(o.inputLocale)</InputLocale>
              <SystemLocale>\(o.uiLanguage)</SystemLocale>
              <UILanguage>\(o.uiLanguage)</UILanguage>
              <UserLocale>\(o.uiLanguage)</UserLocale>
            </component>

            <component name="Microsoft-Windows-Setup"
                       processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS"
                       xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <RunSynchronous>
        \(runSynchronous)
              </RunSynchronous>

              <DiskConfiguration>
                <WillShowUI>OnError</WillShowUI>
                <Disk wcm:action="add">
                  <DiskID>0</DiskID>
                  <WillWipeDisk>true</WillWipeDisk>
                  <CreatePartitions>
                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                  </CreatePartitions>
                  <ModifyPartitions>
                    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID>
                      <Format>FAT32</Format><Label>System</Label></ModifyPartition>
                    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
                    <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID>
                      <Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                  </ModifyPartitions>
                </Disk>
              </DiskConfiguration>

              <ImageInstall>
                <OSImage>
                  <InstallFrom>
                    <MetaData wcm:action="add">
                      <Key>/IMAGE/INDEX</Key>
                      <Value>\(o.editionIndex)</Value>
                    </MetaData>
                  </InstallFrom>
                  <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                  <WillShowUI>OnError</WillShowUI>
                </OSImage>
              </ImageInstall>

              <UserData>
                <ProductKey>
                  <Key>\(o.productKey)</Key>
                  <WillShowUI>OnError</WillShowUI>
                </ProductKey>
                <AcceptEula>true</AcceptEula>
                <FullName>\(o.username)</FullName>
                <Organization></Organization>
              </UserData>
            </component>
          </settings>

          <!-- specialize 在 OOBE **之前**跑,此时用户账户还没建立。
               DPI 缩放是每用户设置,写进 HKCU 要重新登录才生效;写进
               C:\\Users\\Default\\NTUSER.DAT 则会被之后新建的账户继承,
               第一眼看到的桌面就已经是 200%。
               Mac 基本都是 Retina 屏,我们又把 guest 分辨率设成物理像素做到 1:1,
               100% 缩放下所有东西都只有一半大,必须配 200%。 -->
          <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment"
                       processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS"
                       xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <RunSynchronous>
                <!-- 默认不给虚拟机联网(见 VMSettings.network 的说明)。
                     Windows 11 较新版本的 OOBE 在没有网络时会停在
                     「让我们为你连接到网络」不让继续,BypassNRO 关掉这个强制要求。
                     HideOnlineAccountScreens 只管账户页,管不了这一页。 -->
                <RunSynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Path>reg load HKU\\DefUser C:\\Users\\Default\\NTUSER.DAT</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>3</Order>
                  <!-- 192 = 96 * 2。Win8DpiScaling=1 表示「使用自定义 LogPixels」, -->
                  <!-- 少了它系统会忽略 LogPixels 走自动缩放。 -->
                  <Path>reg add "HKU\\DefUser\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d \(o.dpiScalePercent * 96 / 100) /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>4</Order>
                  <Path>reg add "HKU\\DefUser\\Control Panel\\Desktop" /v Win8DpiScaling /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- 深色主题同理:写 HKCU 要等 explorer 重启(即下次登录)才生效,
                     首次进桌面仍是浅色。写进默认配置单元,新账户一开始就是深色。
                     应用与系统外壳是**两个**开关,只设前者会留一条白色任务栏。 -->
                <RunSynchronousCommand wcm:action="add">
                  <Order>5</Order>
                  <Path>reg add "HKU\\DefUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" /v AppsUseLightTheme /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>6</Order>
                  <Path>reg add "HKU\\DefUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" /v SystemUsesLightTheme /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <!-- img19 是 Win11 的深色壁纸,img0 是浅色的。 -->
                <RunSynchronousCommand wcm:action="add">
                  <Order>7</Order>
                  <Path>reg add "HKU\\DefUser\\Control Panel\\Desktop" /v WallPaper /t REG_SZ /d "C:\\Windows\\Web\\Wallpaper\\Windows\\img19.jpg" /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                  <Order>8</Order>
                  <Path>reg unload HKU\\DefUser</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>

          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core"
                       processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS"
                       xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <InputLocale>\(o.inputLocale)</InputLocale>
              <SystemLocale>\(o.uiLanguage)</SystemLocale>
              <UILanguage>\(o.uiLanguage)</UILanguage>
              <UserLocale>\(o.uiLanguage)</UserLocale>
            </component>

            <component name="Microsoft-Windows-Shell-Setup"
                       processorArchitecture="arm64"
                       publicKeyToken="31bf3856ad364e35" language="neutral"
                       versionScope="nonSxS"
                       xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <ComputerName>\(o.computerName)</ComputerName>
              <TimeZone>\(o.timeZone)</TimeZone>
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(o.username)</Name>
                    <Group>Administrators</Group>
                    <DisplayName>\(o.username)</DisplayName>
                    <Password><Value>\(o.password)</Value><PlainText>true</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled>
                <Username>\(o.username)</Username>
                <!-- 次数用完后 Windows 会停在登录界面。agent 是 onlogon 触发的
                     计划任务,没有用户会话就不会运行 —— 表现为「改分辨率静默失效」,
                     而且看不出和 agent 崩溃有什么区别。虚拟机本来就随时可能被
                     快照回滚到任意时刻,给一个大数比给 3 合理得多。 -->
                <LogonCount>\(o.autoLogonCount)</LogonCount>
                <Password><Value>\(o.password)</Value><PlainText>true</PlainText></Password>
              </AutoLogon>
        \(firstLogon)
            </component>
          </settings>
        </unattend>
        """
    }
}

// MARK: - 支持盘

public enum SupportImageBuilder {

    /// 打一张 FAT32 支持盘。除了应答文件与 agent,还会把 ISO 的引导文件复制进来,
    /// **让支持盘自己成为引导设备**。
    ///
    /// 为什么要这么做:直接引导 Windows ISO 会停在
    /// 「Press any key to boot from CD or DVD」等待按键 —— 无人值守流程会永远卡在那里。
    /// 从硬盘引导则没有这个提示。这也是制作 Windows 安装 U 盘的标准做法:
    /// 只放 boot.wim(671MB),体积更大的 install.wim(6.8GB,超过 FAT32 单文件上限)
    /// 留在 ISO 上,Setup 启动后自己会找到。
    ///
    /// 用 `hdiutil attach -imagekey diskimage-class=CRawDiskImage` 是关键 ——
    /// 否则 hdiutil 产出的是 UDIF 容器,QEMU 读不了。
    /// `drivers` 是 virtio 驱动目录(ToolPaths.virtioDrivers),里面的东西原样拷到盘的根目录。
    public static func build(at image: URL,
                      autounattend: String,
                      agentScript: URL?,
                      installScript: String?,
                      drivers: URL? = nil,
                      bootFilesFrom isoMount: URL? = nil) throws {
        let fm = FileManager.default
        // 带引导文件时需要 1.5GB(boot.wim 约 671MB);否则 256MB 足够。
        // FAT32 需要足够的簇数,再小 newfs 会拒绝。
        let megabytes = isoMount == nil ? 256 : 1536
        try FATImageBuilder.build(at: image, megabytes: megabytes, label: "VTOOLS") { volume in

        // 引导文件:efi/(含 \EFI\BOOT\BOOTAA64.EFI)、boot/、bootmgr.efi、sources/boot.wim
        if let iso = isoMount {
            for item in ["efi", "boot", "bootmgr.efi"] {
                let src = iso.appendingPathComponent(item)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: volume.appendingPathComponent(item))
                }
            }
            let sources = volume.appendingPathComponent("sources")
            try fm.createDirectory(at: sources, withIntermediateDirectories: true)
            let bootWim = iso.appendingPathComponent("sources/boot.wim")
            guard fm.fileExists(atPath: bootWim.path) else {
                throw InstallError.imageBuildFailed("ISO 中找不到 sources/boot.wim")
            }
            try fm.copyItem(at: bootWim, to: sources.appendingPathComponent("boot.wim"))
        }

        try write(autounattend, to: volume.appendingPathComponent("autounattend.xml"), bom: false)

        if let agent = agentScript {
            // PowerShell 5.1 读无 BOM 的 UTF-8 会按系统代码页(中文 Windows 上是 GBK)解释,
            // 脚本里的中文会变乱码并破坏引号/大括号配对 —— 必须加 BOM。
            let text = try String(contentsOf: agent, encoding: .utf8)
            try write(text, to: volume.appendingPathComponent("agent.ps1"), bom: true)
        }
        if let drivers {
            // 目录结构与 virtio-win ISO 一致(<驱动>/w11/ARM64),install-agent.bat 就能照旧认出这张盘。
            // 约 4MB,256MB 的盘放得下
            for item in try fm.contentsOfDirectory(atPath: drivers.path) where !item.hasPrefix(".") {
                try fm.copyItem(at: drivers.appendingPathComponent(item),
                                to: volume.appendingPathComponent(item))
            }
        }
        if let script = installScript {
            // 相反方向:cmd.exe 同样按系统代码页读 .bat,
            // UTF-8 的中文注释会变乱码**并被当成命令执行**,所以 .bat 必须是纯 ASCII。
            guard script.allSatisfy({ $0.isASCII }) else {
                throw InstallError.imageBuildFailed("install-agent.bat 含非 ASCII 字符,cmd.exe 会读成乱码")
            }
            try write(script, to: volume.appendingPathComponent("install-agent.bat"), bom: false)
        }
        }   // FATImageBuilder.build 会顺手清掉 ._ 伴随文件
    }

    /// Windows 侧一律要 CRLF
    private static func write(_ text: String, to url: URL, bom: Bool) throws {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\n", with: "\r\n")
        var data = bom ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(Data(normalized.utf8))
        try data.write(to: url, options: .atomic)
    }

    /// 首次登录时运行:装 vioserial 驱动、把 agent 装到本地、注册登录自启。
    /// **必须是纯 ASCII** —— 见 build() 里的说明。
    public static let installScript = """
    @echo off
    REM Install virtio drivers, copy agent locally, register logon task.
    REM The virtio drivers ship inside the app and are copied onto this tools
    REM disk, laid out like the virtio-win ISO (<driver>\\w11\\ARM64), so the
    REM VIRTIO lookup below finds the tools disk itself.
    REM
    REM NOTE: this file must stay pure ASCII. cmd.exe reads .bat with the system
    REM codepage (GBK on a Chinese Windows); UTF-8 comments turn into mojibake
    REM and get executed as commands.
    REM
    REM Everything is logged to the tools disk so the host can read it back
    REM without any GUI interaction -- this runs from FirstLogonCommands where
    REM the console is invisible, and blind GUI automation is unreliable
    REM (the Chinese IME rewrites injected keystrokes).
    setlocal enabledelayedexpansion
    for %%d in (D E F G H I) do if exist %%d:\\agent.ps1 set TOOLS=%%d:
    for %%d in (D E F G H I) do if exist %%d:\\vioserial\\w11\\ARM64\\vioser.inf set VIRTIO=%%d:
    set LOG=%TOOLS%\\install-log.txt
    echo === install-agent start %DATE% %TIME% === > "%LOG%"
    echo TOOLS=%TOOLS% VIRTIO=%VIRTIO% >> "%LOG%"
    REM wmic was removed in recent Windows builds; fsutil is always present.
    fsutil fsinfo drives >> "%LOG%" 2>&1

    if not defined VIRTIO echo VIRTIO NOT FOUND -- no drivers installed >> "%LOG%"
    REM pnputil does not accept a wildcard in the middle of a path, so the
    REM driver folders have to be enumerated explicitly. viogpudo in particular
    REM is required: without a display driver Windows stops updating the
    REM framebuffer after boot and the screen goes to
    REM "Display output is not active".
    if defined VIRTIO (
      for %%p in (viogpudo NetKVM vioserial viostor vioscsi Balloon viorng vioinput viosock) do (
        if exist "%VIRTIO%\\%%p\\w11\\ARM64" (
          echo --- installing %%p >> "%LOG%"
          pnputil /add-driver "%VIRTIO%\\%%p\\w11\\ARM64\\*.inf" /install >> "%LOG%" 2>&1
        ) else (
          echo --- missing %VIRTIO%\\%%p\\w11\\ARM64 >> "%LOG%"
        )
      )
    )

    REM Default to the English keyboard. InputLocale in autounattend.xml already
    REM orders it first, but on Windows 11 the per-user default is stored in the
    REM language profile rather than HKCU\\Keyboard Layout\\Preload, so poking the
    REM registry alone does not stick. This is the supported API for it.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$l = Get-WinUserLanguageList; if (-not ($l.LanguageTag -contains 'en-US')) { $l.Add('en-US') }; Set-WinUserLanguageList $l -Force; Set-WinDefaultInputMethodOverride -InputTip '0409:00000409'" >> "%LOG%" 2>&1

    REM Turn on the virtio-gpu hardware cursor. viogpudo.inf ships HWCursor=0,
    REM so by default the driver paints the pointer INTO the framebuffer: every
    REM mouse move dirties the screen and the pointer is stuck at the guest's
    REM frame rate. With it on, the guest sends the cursor bitmap over the
    REM virtio-gpu cursor queue instead and the host draws it natively.
    REM Measured: mouse-move framebuffer damage went from ~53/s to 0/s.
    REM Takes effect when the driver next starts, i.e. after a reboot.
    REM
    REM Which display-class subkey viogpudo lands in is NOT predictable -- measured
    REM 0000, 0002 and 0005 on three otherwise identical installs. Two earlier
    REM attempts failed because of this: guarding with "reg query ... &&" never
    REM executed at all, and writing a fixed 0000-0004 range missed the 0005 case.
    REM Match on DriverDesc instead. PowerShell because .bat cannot correlate the
    REM key line with the value line in "reg query /s" output without fragile
    REM for/f parsing -- which is exactly what silently did nothing the first time.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}' | Where-Object { (Get-ItemProperty $_.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc -like '*VirtIO GPU*' } | ForEach-Object { Set-ItemProperty $_.PSPath -Name HWCursor -Value 1 -Type DWord; Write-Output ('HWCursor set on ' + $_.PSChildName) }" >> "%LOG%" 2>&1

    REM DPI scaling for the current account. autounattend.xml already seeds this
    REM into the default user hive during specialize, so a fresh install comes up
    REM at 200% on the very first desktop; this is the fallback for machines
    REM installed before that existed. HKCU only takes effect from the next
    REM sign-in -- the session's DPI is fixed when it starts.
    reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d 192 /f >> "%LOG%" 2>&1
    reg add "HKCU\\Control Panel\\Desktop" /v Win8DpiScaling /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1

    REM Dark theme by default. Two values: apps and the shell (taskbar/Start) are
    REM separate switches, and setting only AppsUseLightTheme leaves a white taskbar.
    REM This runs as the logged-on user, so HKCU is that user's hive.
    reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" /v AppsUseLightTheme /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
    reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" /v SystemUsesLightTheme /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
    REM The two Personalize values only darken the chrome; the wallpaper is a
    REM separate setting, so a light bloom would stay behind a dark taskbar.
    REM img19.jpg is Windows 11's dark bloom (img0.jpg is the light one) --
    REM guarded, because older builds ship only img0.
    if exist "%SystemRoot%\\Web\\Wallpaper\\Windows\\img19.jpg" (
      reg add "HKCU\\Control Panel\\Desktop" /v WallPaper /t REG_SZ /d "%SystemRoot%\\Web\\Wallpaper\\Windows\\img19.jpg" /f >> "%LOG%" 2>&1
      RUNDLL32.EXE user32.dll,UpdatePerUserSystemParameters
    )
    REM Do NOT restart explorer here. Two reasons, both learned the hard way:
    REM  * This script runs elevated (FirstLogonCommands). "start explorer.exe"
    REM    from an elevated process launches explorer elevated, which Windows
    REM    refuses -- explorer exits immediately. Killing it first then leaves the
    REM    session with no shell at all: a completely black screen, no wallpaper,
    REM    no taskbar, while the agent still answers. Very confusing to diagnose.
    REM  * It is unnecessary. Explorer reads the theme when it starts, and during
    REM    a fresh install it starts *after* this script, so the very first
    REM    desktop is already dark.
    REM When re-running this script by hand on an installed system, sign out and
    REM back in to pick up the theme.

    mkdir "%ProgramData%\\Virtually" 2>nul
    REM Verify the source before copying. A blind "copy" once produced a
    REM 13658-byte file of NUL bytes on C: -- right size, no content -- because
    REM the host had rebuilt tools.img while the VM held it and the guest's
    REM cached clusters went stale. PowerShell then died at "line 1 char 1" on
    REM a run of NULs, and from outside it looked exactly like "the agent just
    REM does not start". findstr is a cheap content check -- note: no /b, since
    REM the file starts with a UTF-8 BOM and the marker is not at column 1.
    findstr /c:"Virtually Guest Agent" "%TOOLS%\\agent.ps1" >nul 2>&1
    if errorlevel 1 (
      echo REFUSING to copy agent.ps1 -- source looks empty or corrupt >> "%LOG%"
    ) else (
      copy /Y "%TOOLS%\\agent.ps1" "%ProgramData%\\Virtually\\agent.new" >> "%LOG%" 2>&1
      move /Y "%ProgramData%\\Virtually\\agent.new" "%ProgramData%\\Virtually\\agent.ps1" >> "%LOG%" 2>&1
    )
    REM Wrapper cmd avoids nested quoting inside schtasks /tr, which is unreliable:
    REM the task gets created but its action is broken, and with a hidden window
    REM there is no visible error at all.
    REM ---- Two-part agent -------------------------------------------------
    REM
    REM  system  : SYSTEM identity, ONSTART trigger. Owns the virtio-serial port
    REM            (whose ACL only grants Administrators) and handles anything
    REM            that does not need a desktop.
    REM  session : plain user, launched from the Run key with Explorer. Handles
    REM            what DOES need the interactive desktop -- resolution and
    REM            cursor -- none of which needs elevation.
    REM
    REM They talk over the named pipe \\\\.\\pipe\\VirtuallyAgent.
    REM
    REM Why not one process: it would need elevation AND the interactive desktop
    REM at once, which leaves only "logon-triggered task with highest privileges".
    REM That trigger measurably does not fire under autologon -- the task's last
    REM run stayed frozen at install time across many reboots while running it by
    REM hand worked instantly, and neither a 20s delay nor a repeating watchdog
    REM helped. ONSTART-as-SYSTEM and the Run key are both reliable.
    REM VirtualBox (VBoxService + VBoxTray) and VMware (vmsvc + vmusr) split the
    REM same way.
    set SYSRUN=%ProgramData%\\Virtually\\run-agent-system.cmd
    set USRRUN=%ProgramData%\\Virtually\\run-agent-session.vbs

    REM The system runner also refreshes agent.ps1 from the tools disk, so
    REM updating the agent is just "rebuild tools.img + reboot". It runs first
    REM (boot, before logon), so the session side always gets the fresh copy.
    REM %%%%d survives one round of .bat expansion and lands in the .cmd as %%d.
    > "%SYSRUN%" echo @echo off
    >> "%SYSRUN%" echo for %%%%d in (D E F G H I) do call :sync %%%%d
    >> "%SYSRUN%" echo goto :run
    >> "%SYSRUN%" echo :sync
    >> "%SYSRUN%" echo if not exist %%1:\\agent.ps1 goto :eof
    >> "%SYSRUN%" echo findstr /c:"Virtually Guest Agent" %%1:\\agent.ps1 ^>nul 2^>^&1 ^|^| goto :eof
    >> "%SYSRUN%" echo copy /Y %%1:\\agent.ps1 "%ProgramData%\\Virtually\\agent.new" ^>nul
    >> "%SYSRUN%" echo move /Y "%ProgramData%\\Virtually\\agent.new" "%ProgramData%\\Virtually\\agent.ps1" ^>nul
    >> "%SYSRUN%" echo goto :eof
    >> "%SYSRUN%" echo :run
    >> "%SYSRUN%" echo powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ProgramData%\\Virtually\\agent.ps1" -Role system

    REM The session runner is a .vbs, NOT a .cmd. A .cmd in the Run key is
    REM launched by cmd.exe, which owns a console window that stays on screen
    REM for as long as the agent runs -- PowerShell's -WindowStyle Hidden does
    REM not help, since PowerShell inherits that console instead of making one.
    REM Closing that window killed the agent. wscript with intWindowStyle 0
    REM starts the process with no console at all and then exits.
    REM No quotes anywhere inside: %ProgramData% has no spaces in it, so
    REM nothing needs quoting. Nested quoting through echo -> vbs ->
    REM schtasks /tr is exactly the kind of thing that silently produces a broken
    REM command with no visible error.
    > "%USRRUN%" echo CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -File %ProgramData%\\Virtually\\agent.ps1 -Role session", 0, False

    schtasks /create /tn VirtuallyAgentSystem /f /ru SYSTEM /sc onstart /tr "%SYSRUN%" >> "%LOG%" 2>&1
    REM HKLM rather than HKCU so it applies to whatever account signs in.
    reg add "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" /v VirtuallyAgent /t REG_SZ /d "wscript.exe %USRRUN%" /f >> "%LOG%" 2>&1

    REM No scheduled task for the session half. If it dies, the SYSTEM agent
    REM brings it back itself with CreateProcessAsUser against the active console
    REM session -- see VASession in agent.ps1. A task would have to be registered
    REM under the right user name, and this script can be re-run as SYSTEM, in
    REM which case %USERNAME% is the machine account and the task is useless.

    REM Start both now so the machine is usable without a reboot. The session one
    REM is launched directly because the Run key only fires at the next logon.
    schtasks /run /tn VirtuallyAgentSystem >> "%LOG%" 2>&1
    start "" wscript.exe "%USRRUN%"

    echo === install-agent done === >> "%LOG%"
    """
}

public enum InstallError: LocalizedError {
    case notWindowsISO(String)
    /// 镜像不是我们认得的安装介质(Windows 或 Ubuntu)
    case unsupportedISO(String)
    case imageBuildFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notWindowsISO(let m): return "无法识别安装镜像：\(m)"
        case .unsupportedISO(let m): return "不支持此安装镜像：\(m)"
        case .imageBuildFailed(let m): return "无法准备安装介质：\(m)"
        }
    }
}
