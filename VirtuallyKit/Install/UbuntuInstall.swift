// Ubuntu 的无人值守安装。
//
// 路线(每一步都在 26.04.1 桌面版 arm64 上实测过,结论见 docs/LINUX.md):
//
//   我们打一张 FAT32 盘,标签 CIDATA,bootindex=0:
//     EFI/boot/{bootaa64.efi,grubaa64.efi,mmaa64.efi}  从 ISO 里抄出来(Ubuntu 签名的 shim + grub)
//     EFI/boot/grub.cfg    我们写的,把 ISO 上的内核带 autoinstall 引导起来
//     user-data / meta-data  cloud-init 的 NoCloud 数据源按卷标 cidata 找它们
//   ISO 以 bootindex=2 挂着,grub 用 `search --file /.disk/info` 找到它。
//
// **桌面版安装器不会自己开始装**:即使 autoinstall 全填好、没有 interactive-sections,
// Flutter 前端也一定停在「Ready to install / Review your choices」等人点 Install。
// 实测没有任何内核参数或命令行开关能跳过(subiquity 服务端此时已是全自动模式,
// 是前端自己要确认)。所以 `early-commands` 里挂一个轮询器:等服务端状态变成
// NEEDS_CONFIRMATION,就调**它自己的 API** POST /meta/confirm —— 不点坐标、不模拟按键,
// UI 改版也不会坏。实测 200 OK,状态随即转 RUNNING,装完自己重启。
//
// 与 Windows 的对应关系:
//   autounattend.xml   ↔ user-data 的 autoinstall 段
//   FirstLogonCommands ↔ late-commands(装 agent、开自动登录)
//   AutoLogon          ↔ /etc/gdm3/custom.conf 的 AutomaticLogin

import Foundation

/// ISO 里可装的一个系统变体。Windows 是映像索引,Ubuntu 是 install-sources 的 id。
public struct InstallVariant: Equatable, Identifiable {
    /// Windows:WIM 的 index 转成字符串;Ubuntu:`ubuntu-desktop-minimal` 这类 id
    public let id: String
    public let name: String

    /// Windows 侧要的数字索引
    public var windowsIndex: Int? { Int(id) }

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct UbuntuInstallOptions {
    public var username = "vm"
    public var password = "vm"
    public var hostname = "ubuntu-vm"
    /// 与 Windows 那边一致:界面中文
    public var locale = "zh_CN.UTF-8"
    public var keyboardLayout = "us"
    /// guest 时区。**直接用 IANA 名**,不像 Windows 那样要一张映射表。
    public var timeZone = TimeZone.current.identifier
    /// install-sources.yaml 里的 id
    public var variantID = "ubuntu-desktop-minimal"
    /// 界面缩放百分比。Mac 基本都是 Retina,guest 分辨率又按物理像素给,100% 会小到看不清。
    public var scalePercent = 200
    /// 装完把 agent 也装上
    public var installGuestTools = true

    public init() {

    }
}

public enum AutoinstallGenerator {

    /// 自动确认 + 进度回传的轮询器。装在 `early-commands` 里,后台常驻。
    ///
    /// 三件事:
    ///   1. 等 NEEDS_CONFIRMATION → POST /meta/confirm(桌面版前端不会自己确认)
    ///   2. 把安装器 UI 关掉 —— 它会一直停在那个「Ready to install」页面不刷新,
    ///      留着只会让用户以为没开始装,还可能去点 Install
    ///   3. 把服务端状态写到 virtio-serial,宿主据此显示进度(否则十分钟毫无反馈)
    ///
    /// 用 python3:live 会话里有,而 curl 没有(实测 `which curl` 为空)。
    public static let confirmPoller = """
    import re, socket, subprocess, time

    SOCK = "/run/subiquity/socket"
    PORT = "/dev/virtio-ports/org.virtually.agent"

    def report(msg):
        try:
            with open(PORT, "w") as f:
                f.write("vainstall " + msg + "\\n")
        except Exception:
            pass

    def api(method, path):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        s.connect(SOCK)
        s.send((method + " " + path + " HTTP/1.1\\r\\nHost: l\\r\\nContent-Length: 0\\r\\n\\r\\n").encode())
        buf = b""
        while True:
            try:
                d = s.recv(65536)
            except Exception:
                break
            if not d:
                break
            buf += d
            if b"\\r\\n\\r\\n" in buf and len(buf) > 200:
                break
        s.close()
        return buf.decode("utf-8", "replace")

    def state():
        try:
            return open("/run/subiquity/server-state").read().strip()
        except Exception:
            return ""

    report("waiting")
    for _ in range(3600):
        if state() == "NEEDS_CONFIRMATION":
            body = api("POST", '/meta/confirm?tty="/dev/tty1"')
            report("confirmed" if "200 OK" in body else "confirm-failed")
            break
        time.sleep(1)

    # UI 不会跟着服务端走,关掉它,别让用户对着一个没用的按钮
    subprocess.run(["pkill", "-f", "ubuntu_bootstrap"], check=False)

    last = ""
    for _ in range(7200):
        body = api("GET", "/meta/status")
        m = re.search(r'"state":\\s*"([A-Z_]+)"', body)
        st = m.group(1) if m else state()
        if st and st != last:
            report(st)
            last = st
        if st in ("DONE", "ERROR"):
            break
        time.sleep(2)
    """

    /// 生成 cloud-init 的 user-data(内含 autoinstall 段)。
    ///
    /// 手写 YAML 而不引库:要写的键是固定的十几个,而嵌进来的脚本用块标量(`|`)原样保留,
    /// 反倒比让某个序列化器去转义安全。缩进由 `indent` 统一加,不靠手数空格。
    public static func generate(_ o: UbuntuInstallOptions, agentInstall: String? = nil) -> String {
        let passwordHash = SHA512Crypt.hash(password: o.password, salt: SHA512Crypt.randomSalt())
        var late: [String] = [
            // 自动登录:agent 的会话侧要用户登录才起得来(与 Windows 的 AutoLogon 同一个理由)
            block("""
            cat > /target/etc/gdm3/custom.conf <<'CONF'
            [daemon]
            AutomaticLoginEnable=true
            AutomaticLogin=\(o.username)
            CONF
            """),
            // 首次登录的欢迎向导会挡住桌面,而虚拟机是拿来用的,不是拿来配的。
            //
            // 光写 `gnome-initial-setup-done` **不够**:实测装完第一次进桌面照样弹出来,
            // 因为跑的是 `gnome-initial-setup-upgrade-login.service`(升级后的欢迎页那一支),
            // 它不看这个标记。所以把两个用户单元一起 mask 掉 ——
            // /etc/systemd/user 下的 /dev/null 符号链接压过 /usr/lib/systemd/user,与版本无关。
            block("""
            install -d -o 1000 -g 1000 /target/home/\(o.username)/.config
            echo yes > /target/home/\(o.username)/.config/gnome-initial-setup-done
            chown 1000:1000 /target/home/\(o.username)/.config/gnome-initial-setup-done
            install -d /target/etc/systemd/user
            ln -sf /dev/null /target/etc/systemd/user/gnome-initial-setup-first-login.service
            ln -sf /dev/null /target/etc/systemd/user/gnome-initial-setup-upgrade-login.service
            """),
        ]
        if let agentInstall { late.append(block(agentInstall)) }

        return """
        #cloud-config
        autoinstall:
          version: 1
          locale: \(o.locale)
          keyboard:
            layout: \(o.keyboardLayout)
          timezone: \(o.timeZone)
          source:
            id: \(o.variantID)
            search_drivers: false
          identity:
            hostname: \(o.hostname)
            realname: \(o.username)
            username: \(o.username)
            password: "\(passwordHash)"
          storage:
            layout:
              name: direct
          refresh-installer:
            update: false
          shutdown: reboot
          early-commands:
        \(indent(block("""
        cat > /run/va-confirm.py <<'VAPY'
        \(confirmPoller)
        VAPY
        setsid python3 /run/va-confirm.py < /dev/null > /run/va-confirm.log 2>&1 &
        """), by: 4))
          late-commands:
        \(late.map { indent($0, by: 4) }.joined(separator: "\n"))
        """
    }

    /// 一条 shell 命令,用 YAML 块标量写。`- |` 之后的内容整体缩进两格。
    private static func block(_ script: String) -> String {
        "- |\n" + indent(script, by: 2)
    }

    private static func indent(_ text: String, by n: Int) -> String {
        let pad = String(repeating: " ", count: n)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
    }

    /// cloud-init 的 NoCloud 还要一份 meta-data,哪怕只有两行
    public static func metaData(hostname: String) -> String {
        "instance-id: virtually-\(UUID().uuidString.prefix(8))\nlocal-hostname: \(hostname)\n"
    }

    /// 我们放在 CIDATA 盘上的 grub 配置。
    ///
    /// Ubuntu 签名的 grub 启动后会 `source $prefix/grub.cfg`,而从我们这张盘的 shim 起来时
    /// `$prefix` 就是盘上的 /EFI/boot —— 所以这份配置会被读到,而不是 ISO 上那份。
    /// ISO 靠 `search --file /.disk/info` 定位,不写死盘符。
    public static let grubConfig = """
    set timeout=0
    search --file --set=root /.disk/info
    menuentry "Virtually autoinstall" {
        set gfxpayload=keep
        linux ($root)/casper/vmlinuz autoinstall --- quiet splash console=tty0
        initrd ($root)/casper/initrd
    }
    """
}

// MARK: - 引导盘

public enum UbuntuSeedDisk {

    /// Ubuntu 签名的引导链。三个都要:shim 验 grub,mm 是 MokManager。
    public static let efiFiles = ["bootaa64.efi", "grubaa64.efi", "mmaa64.efi"]

    /// 打一张 CIDATA 盘。256MB 够 —— 里面只有 4MB 的 EFI 文件和几个文本。
    public static func build(at image: URL, iso: URL, options: UbuntuInstallOptions,
                      agentPayload: ((URL) throws -> Void)? = nil,
                      agentInstall: String? = nil) throws {
        let reader = try ISOReader(iso: iso)
        defer { reader.close() }
        for f in efiFiles {
            guard reader.exists("/EFI/boot/\(f)") else {
                throw InstallError.unsupportedISO("镜像里找不到 EFI/boot/\(f),这不像 Ubuntu 的安装镜像")
            }
        }
        try FATImageBuilder.build(at: image, megabytes: 256, label: "CIDATA") { volume in
            let efi = volume.appendingPathComponent("EFI/boot")
            try FileManager.default.createDirectory(at: efi, withIntermediateDirectories: true)
            for f in efiFiles {
                try reader.copy("/EFI/boot/\(f)", to: efi.appendingPathComponent(f))
            }
            try write(AutoinstallGenerator.grubConfig, to: efi.appendingPathComponent("grub.cfg"))
            try write(AutoinstallGenerator.generate(options, agentInstall: agentInstall),
                      to: volume.appendingPathComponent("user-data"))
            try write(AutoinstallGenerator.metaData(hostname: options.hostname),
                      to: volume.appendingPathComponent("meta-data"))
            if let agentPayload {
                let dir = volume.appendingPathComponent("agent")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try agentPayload(dir)
            }
        }
    }

    /// Linux 侧一律 LF —— 与 Windows 那边的 CRLF 正好相反
    private static func write(_ text: String, to url: URL) throws {
        try Data(text.replacingOccurrences(of: "\r\n", with: "\n").utf8).write(to: url, options: .atomic)
    }

    /// 从 ISO 解析可装的变体。只认 `id:` 与 `name:` 下的 `en:`,不引 YAML 库。
    ///
    /// install-sources.yaml 的形状:
    /// ```
    /// sources:
    /// - default: true
    ///   id: ubuntu-desktop-minimal
    ///   name:
    ///     en: Ubuntu Desktop (minimized)
    /// ```
    public static func variants(inISO iso: URL) throws -> [InstallVariant] {
        let reader = try ISOReader(iso: iso)
        defer { reader.close() }
        guard reader.exists("/casper/install-sources.yaml") else {
            throw InstallError.unsupportedISO("镜像里找不到 casper/install-sources.yaml")
        }
        let text = String(decoding: try reader.read("/casper/install-sources.yaml"), as: UTF8.self)
        return parseVariants(text)
    }

    public static func parseVariants(_ yaml: String) -> [InstallVariant] {
        var out: [InstallVariant] = []
        var id: String?
        var inName = false
        for raw in yaml.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 新的一项开始:把上一项还没配上名字的情况兜住
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if let pending = id { out.append(InstallVariant(id: pending, name: pending)); id = nil }
                inName = false
            }
            if let v = value(of: "id", in: trimmed) {
                if let pending = id { out.append(InstallVariant(id: pending, name: pending)) }
                id = v
                inName = false
                continue
            }
            if trimmed == "name:" { inName = true; continue }
            if inName, let v = value(of: "en", in: trimmed) {
                if let have = id { out.append(InstallVariant(id: have, name: v)); id = nil }
                inName = false
                continue
            }
            // description: 下面也有 en:,别把它当名字
            if trimmed.hasSuffix(":") && trimmed != "name:" { inName = false }
        }
        if let pending = id { out.append(InstallVariant(id: pending, name: pending)) }
        return out
    }

    private static func value(of key: String, in trimmed: String) -> String? {
        guard trimmed.hasPrefix("\(key):") else { return nil }
        let v = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// 默认变体:优先带 minimal 的那个(装得快、体积小),否则第一个
    public static func defaultVariant(_ list: [InstallVariant]) -> InstallVariant? {
        list.first { $0.id.contains("minimal") } ?? list.first
    }
}
