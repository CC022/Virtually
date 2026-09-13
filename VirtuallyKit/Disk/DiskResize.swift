// 扩大系统盘。
//
// 两步:
//   1. 宿主关机态 `qemu-img resize` 把 disk.qcow2 的虚拟大小改大,配置里记下 growPartition
//   2. 下次开机 agent 上线后,宿主经 `exec` 让 guest 把系统分区扩到占满
//
// 只能在关机态改,而且挂起也不行:QEMU 恢复快照时会把盘的大小改回存快照那一刻
// (block/qcow2-snapshot.c qcow2_snapshot_goto),挂起状态本身就是一条快照 ——
// 挂起时扩了容,开机 loadvm 就悄悄缩回去了。
//
// 分区扩展走现有的 `exec` 而不是给 agent 加命令:两份 agent 早就有 exec,
// 而 Linux agent 不会自己更新、Windows 要重建工具盘再开一次机才拿得到新 agent。
// 这样已经装好的机器也能直接用。细节与实测结论见 docs/DISK.md。

import Foundation

extension VMBundle {

    static let bytesPerGB: Int64 = 1 << 30

    /// 字节数向上取整到 GB。界面上的下限用它,不能往下取 —— 那样会允许「扩」到比现在还小。
    public static func wholeGB(_ bytes: Int64) -> Int {
        Int((bytes + bytesPerGB - 1) / bytesPerGB)
    }

    /// `qemu-img info --output=json` 里的 virtual-size
    public static func parseVirtualSize(_ json: String) -> Int64? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let size = obj["virtual-size"] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// 系统盘现在的虚拟大小。不信 settings.diskSizeGB:恢复扩容前的快照会把盘改回当时的大小。
    public func diskVirtualSize(qemuImg: URL) throws -> Int64 {
        // -U:只读头部的 virtual-size,虚拟机开着(QEMU 攥着写锁)也能读
        let out = try Self.run(qemuImg, ["info", "-U", "--output=json", "-f", "qcow2", diskURL.path])
        guard let size = Self.parseVirtualSize(out) else {
            throw VMError.toolFailed(qemuImg.lastPathComponent, out)
        }
        return size
    }

    /// 为什么现在不能改磁盘大小。nil 表示可以(是否正在运行由调用方另查)。
    public var diskResizeBlockedReason: String? {
        if settings.install != nil { return "安装完成后才能改磁盘大小" }
        if settings.snapshotShapes[suspendTag] != nil {
            return "虚拟机已挂起。开机后在系统里关机(不是点红叉),才能改磁盘大小"
        }
        return nil
    }

    /// 把系统盘扩到 gb,并记下「guest 里的分区还没跟上」。只增不减 —— 缩小会切掉 guest 的分区。
    public mutating func growDisk(toGB gb: Int, qemuImg: URL) throws {
        if let why = diskResizeBlockedReason { throw VMError.busy(why) }
        // qemu-img 自己也会因为拿不到写锁失败,但那句英文说不清楚是怎么回事
        if let holder = QEMUProcesses.holding(path: diskURL.path) {
            throw VMError.busy("虚拟机正在运行(进程 \(holder)),关机后才能改磁盘大小")
        }
        let current = try diskVirtualSize(qemuImg: qemuImg)
        guard Int64(gb) * Self.bytesPerGB > current else {
            throw VMError.invalid("磁盘只能扩大,不能缩小(当前 \(Self.wholeGB(current)) GB)")
        }
        try Self.run(qemuImg, ["resize", "-f", "qcow2", diskURL.path, "\(gb)G"])
        settings.diskSizeGB = gb
        settings.growPartition = true
        try save()
    }
}

// MARK: - guest 里扩分区

/// 让 guest 把系统分区扩到占满整块盘。脚本经 agent 的 `exec` 送进去,结果是一行 `VAGROW …`。
///
/// 脚本**只用 ASCII**,原因用代号表示,中文由宿主拼:Windows 的 exec 经 cmd.exe 取输出,
/// 非 ASCII 会按系统代码页乱掉。
public enum PartitionGrow {

    public enum Outcome: Equatable {
        /// note 是附带的提醒代号(比如 winre-off),没有为 nil
        case grown(from: Int64, to: Int64, note: String?)
        case noChange
        /// 分区结构不允许自动扩(C: 后面还有分区、根文件系统不是 ext4 之类),重试也没用
        case blocked(String)
        /// 这次没成,下次开机再试
        case failed(String)
    }

    /// 发给 agent 的一行命令
    public static func agentCommand(for os: GuestOS) -> String {
        switch os {
        case .windows:
            // EncodedCommand 是 UTF-16LE 的 base64,整条命令里没有引号,
            // 不用操心 cmd /c 的嵌套引号(GUEST-AGENT.md 坑 5)
            let encoded = Data(windowsScript.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
                .base64EncodedString()
            return "exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand \(encoded)"
        case .ubuntu:
            return "exec echo \(Data(linuxScript.utf8).base64EncodedString()) | base64 -d | sh"
        }
    }

    /// agent 回的一行。只认 `out VAGROW …`,别的返回 nil。
    public static func parse(_ line: String) -> Outcome? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 3, f[0] == "out", f[1] == "VAGROW" else { return nil }
        let rest = f.dropFirst(3).joined(separator: " ")
        switch f[2] {
        case "grown":
            guard f.count >= 5, let from = Int64(f[3]), let to = Int64(f[4]) else { return nil }
            return .grown(from: from, to: to, note: f.count > 5 ? String(f[5]) : nil)
        case "nochange": return .noChange
        case "blocked":  return .blocked(rest)
        case "failed":   return .failed(rest)
        default:         return nil
        }
    }

    /// blocked 的代号 → 给用户看的话
    public static func explainBlocked(_ code: String) -> String {
        let head = "磁盘已经扩大,但系统分区没法自动扩展"
        if code == "partition-after-c" { return head + ":C: 后面还有恢复分区以外的分区。请在「磁盘管理」里手动调整" }
        if code == "not-partition" { return head + ":根文件系统不在普通分区上(比如 LVM)。请在系统里手动调整" }
        if code.hasPrefix("fstype-") {
            return head + ":根文件系统是 \(code.dropFirst("fstype-".count)),只会自动扩 ext4。请在系统里手动调整"
        }
        return head + "(\(code))。请在系统里手动调整"
    }

    /// grown 附带的提醒 → 给用户看的话。nil 表示不用说
    public static func explainNote(_ note: String?) -> String? {
        switch note {
        case nil: return nil
        case "winre-off":
            return "系统分区已扩展,但 Windows 恢复环境没能重新启用。可在管理员命令行里运行 reagentc /enable 再试"
        case let other?: return "系统分区已扩展(\(other))"
        }
    }

    /// SYSTEM 身份跑。
    ///
    /// **C: 后面几乎一定跟着一个 WinRE 恢复分区**:应答文件只建了 EFI + MSR + C:,
    /// 但 Setup 自己从 C: 尾部切了 853MB 出来放 WinRE(实测 25H2 中文 ARM64)。它挡着 C: 扩不出去。
    /// 处理办法是把它删掉、让 WinRE 搬进 C:\Recovery —— Windows 官方支持这种布局,以后再扩容也只要一步:
    ///   reagentc /disable(winre.wim 挪回 System32\Recovery)→ 删恢复分区 → 扩 C: → reagentc /enable
    /// 恢复分区以外的分区挡着就不动它,报 blocked。
    /// 盘尾空闲不到 256MB 就什么都不做 —— 没得可扩时绝不能去删恢复分区。
    /// 删分区前不看 reagentc /disable 的返回码(上次跑到一半、WinRE 已经关着时它回什么没验证过),
    /// 而是核对 /info 里的位置不再指向这个分区
    /// (用 Contains 不用 -match:路径里的 `\p` 在 .NET 正则里是转义)。
    static let windowsScript = """
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $step = 'query'
    try {
        $c = Get-Partition -DriveLetter C
        $n = $c.DiskNumber
        $disk = Get-Disk -Number $n
        $parts = @(Get-Partition -DiskNumber $n)
        $lastEnd = ($parts | ForEach-Object { $_.Offset + $_.Size } | Measure-Object -Maximum).Maximum
        $after = @($parts | Where-Object { $_.Offset -gt $c.Offset })
        $recovery = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
        if ($disk.Size - $lastEnd -lt 256MB) {
            'VAGROW nochange'
        } elseif (@($after | Where-Object { $_.GptType -ne $recovery }).Count -gt 0) {
            'VAGROW blocked partition-after-c'
        } else {
            $note = ''
            if ($after.Count -gt 0) {
                $step = 'reagentc-disable'
                & reagentc.exe /disable | Out-Null
                $info = & reagentc.exe /info | Out-String
                foreach ($r in $after) {
                    if ($info.ToLower().Contains('harddisk' + $n + '\\partition' + $r.PartitionNumber + '\\')) { throw 'WinRE still on the recovery partition' }
                }
                $step = 'remove-recovery'
                foreach ($r in $after) { Remove-Partition -DiskNumber $n -PartitionNumber $r.PartitionNumber -Confirm:$false }
            }
            $step = 'resize'
            $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
            if ($max -gt $c.Size) { Resize-Partition -DriveLetter C -Size $max }
            if ($after.Count -gt 0) {
                $step = 'reagentc-enable'
                & reagentc.exe /enable | Out-Null
                if ($LASTEXITCODE -ne 0) { $note = ' winre-off' }
            }
            $now = (Get-Partition -DriveLetter C).Size
            if ($now -gt $c.Size) { "VAGROW grown $($c.Size) $now$note" } else { "VAGROW nochange$note" }
        }
    } catch {
        "VAGROW failed $step " + ($_.Exception.Message -replace '\\s+', ' ')
    }
    """

    /// root 身份跑。growpart 来自 cloud-guest-utils,Ubuntu 桌面版 minimal 就带(26.04.1 的清单里有);
    /// 它会把 GPT 备份头挪到新盘尾,并用 partx 通知内核,对挂着的根分区也行。
    /// resize2fs **总是跑一次**:上次分区扩了而文件系统没扩完,这次也能补上。
    static let linuxScript = """
    say() { echo "VAGROW $*"; }
    fs=$(findmnt -no FSTYPE /)
    [ "$fs" = ext4 ] || { say blocked "fstype-$fs"; exit 0; }
    src=$(findmnt -no SOURCE /)
    name=${src##*/}
    [ -r "/sys/class/block/$name/partition" ] || { say blocked not-partition; exit 0; }
    part=$(cat "/sys/class/block/$name/partition")
    disk=/dev/$(lsblk -no PKNAME "$src" | head -n 1)
    command -v growpart >/dev/null 2>&1 || { say failed no-growpart; exit 0; }
    before=$(cat "/sys/class/block/$name/size")
    growpart "$disk" "$part" >/dev/null 2>&1
    [ $? -le 1 ] || { say failed growpart; exit 0; }
    after=$(cat "/sys/class/block/$name/size")
    resize2fs "$src" >/dev/null 2>&1 || { say failed resize2fs; exit 0; }
    if [ "$after" -gt "$before" ]; then say grown $((before * 512)) $((after * 512)); else say nochange; fi
    """
}

extension VMSession {

    /// agent 上线时调。扩过容而分区还没跟上,就让 guest 扩。每次会话只发一次。
    func growPartitionIfNeeded() {
        guard bundle.settings.growPartition == true, bundle.settings.install == nil,
              !partitionGrowSent else { return }
        partitionGrowSent = true
        let os = bundle.settings.os
        Task {
            // 和开机时的光标接管错开。Windows 的 exec 是同步跑的,
            // Get-PartitionSupportedSize 要几秒,期间 agent 不处理别的命令。
            try? await Task.sleep(for: .seconds(10))
            // 这十秒里关机或挂起了就不发;标记还在配置里,下次开机再来
            guard agent.isConnected, state.acceptsCommands else { return }
            print("[磁盘] 让 guest 把系统分区扩到占满")
            agent.send(PartitionGrow.agentCommand(for: os))
        }
    }

    func partitionGrowReported(_ outcome: PartitionGrow.Outcome) {
        switch outcome {
        case .grown(let from, let to, let note):
            print("[磁盘] 系统分区已扩展:\(VMBundle.wholeGB(from)) GB → \(VMBundle.wholeGB(to)) GB")
            clearGrowPartition()
            if let text = PartitionGrow.explainNote(note) {
                if busyMessage == nil { finish(text) } else { print("[磁盘] \(text)") }
            }
        case .noChange:
            print("[磁盘] 系统分区已经占满,不用扩")
            clearGrowPartition()
        case .blocked(let code):
            // 重试也没用,标记清掉;状态条上说一句,别的长任务在跑就不抢它的位置
            clearGrowPartition()
            let text = PartitionGrow.explainBlocked(code)
            if busyMessage == nil { finish(text) } else { print("[磁盘] \(text)") }
        case .failed(let why):
            print("[磁盘] 扩展系统分区失败,下次开机再试:\(why)")
        }
    }

    private func clearGrowPartition() {
        var updated = bundle
        updated.settings.growPartition = nil
        do { try updated.save(); bundle = updated }
        catch { print("[磁盘] 标记没能写回配置:\(error.localizedDescription)") }
    }
}
