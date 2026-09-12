// 传文件:宿主与 guest 之间搬文件的「U 盘」。
//
// 没有走 virtio-fs 或 SMB:前者要 guest 装 WinFsp 且 ARM64 支持未验,后者宿主没有 samba。
// 这里复用已经跑通的那条路 —— 安装介质就是这么挂进 guest 的:
//   宿主把文件打成一张 FAT32 raw 镜像 → QMP blockdev-add + device_add usb-storage → guest 看到一个 U 盘
//   取回:device_del(guest 侧等于拔 U 盘)→ blockdev-del → 宿主只读挂载镜像,复制出来 → 删镜像
// Windows 对可移动盘默认「快速删除」策略,不缓存写入,直接拔是安全的。
//
// 这张盘是 raw,savevm 会拒绝(不支持快照),所以挂起与存快照前要先拔掉
// (VMSession.detachAllUSB 顺手做)。镜像留在包里,下次打开还能取回。

import AppKit

/// 打一张 FAT32 raw 镜像并往里放东西。安装盘、工具盘、传输盘都用它。
///
/// `hdiutil attach -imagekey diskimage-class=CRawDiskImage` 是关键 ——
/// 否则 hdiutil 产出的是 UDIF 容器,QEMU 读不了。
public enum FATImageBuilder {
    /// 卷标最多 11 个字符,只用大写字母数字
    public static func build(at image: URL, megabytes: Int, label: String,
                      populate: (URL) throws -> Void) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: image)
        // 稀疏文件即可,hdiutil 与 newfs 都不在乎;dd 一遍 1.5GB 纯属浪费时间
        fm.createFile(atPath: image.path, contents: nil)
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: UInt64(megabytes) * 1024 * 1024)
        try handle.close()

        let attach = try VMBundle.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                      ["attach", "-imagekey", "diskimage-class=CRawDiskImage",
                                       "-nomount", image.path])
        guard let device = attach.split(separator: "\n").first?
                .split(separator: " ").first.map(String.init) else {
            throw InstallError.imageBuildFailed("无法确定挂载设备")
        }
        defer { _ = try? VMBundle.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                      ["detach", device, "-quiet"]) }

        try VMBundle.run(URL(fileURLWithPath: "/usr/sbin/diskutil"),
                         ["eraseDisk", "FAT32", label, "MBR", device])
        Thread.sleep(forTimeInterval: 2)

        let volume = URL(fileURLWithPath: "/Volumes/\(label)")
        guard fm.fileExists(atPath: volume.path) else {
            throw InstallError.imageBuildFailed("格式化后未找到 \(volume.path)")
        }
        try populate(volume)

        // macOS 会撒下 ._ 伴随文件,Windows 看到会困惑
        if let e = fm.enumerator(atPath: volume.path) {
            for case let name as String in e where (name as NSString).lastPathComponent.hasPrefix("._") {
                try? fm.removeItem(at: volume.appendingPathComponent(name))
            }
        }
    }

    /// 装下这些文件要多大的盘:总量加一成再加 32MB 余量,最少 64MB(FAT32 有簇数下限)
    public static func megabytes(for urls: [URL]) -> Int {
        var total: Int64 = 0
        for u in urls {
            if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e {
                    total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return max(64, Int(Double(total) * 1.1 / 1_048_576) + 32)
    }
}

/// 一张挂在 guest 上(或等着取回)的传输盘
public struct TransferDisk: Equatable {
    public let image: URL
    public let node: String        // blockdev 节点名
    public let device: String      // usb-storage 的 QOM id
    public var files: [String]     // 放进去时的文件名,给界面看
    public var attached: Bool

    public init(image: URL, node: String, device: String, files: [String], attached: Bool) {
        self.image = image
        self.node = node
        self.device = device
        self.files = files
        self.attached = attached
    }
}

extension QMPClient {
    /// 运行时挂一张 raw 盘:先建块节点,再插 usb-storage。返回错误文案,成功为 nil。
    public func addTransferDisk(_ d: TransferDisk) async -> String? {
        if let err = Self.errorText(await execute("blockdev-add", arguments: [
            "driver": "raw", "node-name": d.node,
            "file": ["driver": "file", "filename": d.image.path],
        ])) { return err }
        if let err = Self.errorText(await execute("device_add", arguments: [
            "driver": "usb-storage", "id": d.device, "bus": "usb.0",
            "drive": d.node, "removable": true,
        ])) {
            // 设备没插上,块节点也别留着
            _ = await execute("blockdev-del", arguments: ["node-name": d.node])
            return err
        }
        return nil
    }

    /// 拔掉。device_del 是异步的:QEMU 要等 guest 确认才真的删,DEVICE_DELETED 事件到了才能删块节点。
    public func removeTransferDevice(_ d: TransferDisk) async -> String? {
        Self.errorText(await execute("device_del", arguments: ["id": d.device]))
    }

    public func removeTransferNode(_ d: TransferDisk) async -> String? {
        Self.errorText(await execute("blockdev-del", arguments: ["node-name": d.node]))
    }
}

extension VMSession {

    /// 包里还没取回的传输盘(上次挂起前自动拔掉的那些)
    public func findLeftoverTransferDisks() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("transfer-") && $0.pathExtension == "img" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// 把这些文件装进一张新盘插给 guest。一次只能有一张盘在 guest 上。
    public func sendFiles(_ urls: [URL]) {
        guard !isBusy else { finish(state.blockedReason); return }
        guard transfer == nil else { finish("已经有一张传输盘在 guest 上,先取回它"); return }
        let names = urls.map(\.lastPathComponent)
        let stamp = Int(Date().timeIntervalSince1970)
        let image = bundle.url.appendingPathComponent("transfer-\(stamp).img")
        let disk = TransferDisk(image: image, node: "xfer\(stamp)", device: "xferdev\(stamp)",
                                files: names, attached: false)
        begin("正在打包 \(names.count) 个文件…")
        Task {
            // 打盘要 hdiutil / diskutil / 复制,几秒到几十秒,放到后台线程
            let built: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try FATImageBuilder.build(at: image, megabytes: FATImageBuilder.megabytes(for: urls),
                                              label: "VIRTUALLY") { volume in
                        for u in urls {
                            try FileManager.default.copyItem(at: u, to: volume.appendingPathComponent(u.lastPathComponent))
                        }
                    }
                    return nil
                } catch { return error }
            }.value
            if let built { finish("打包失败:\(built.localizedDescription)"); return }
            begin("正在插入传输盘…")
            if let err = await qmp.addTransferDisk(disk) { finish("插入传输盘失败:\(err)"); return }
            var d = disk; d.attached = true
            transfer = d
            finish(nil)
        }
    }

    /// 从 guest 拔出,复制到宿主的下载目录,删镜像。
    public func retrieveTransferDisk() {
        guard !isBusy, let disk = transfer else { return }
        begin("正在从 guest 弹出传输盘…")
        Task {
            if disk.attached {
                guard await ejectTransferDisk(disk) else { return }
            }
            await copyOutTransferDisk(disk)
        }
    }

    /// device_del 并等 DEVICE_DELETED 事件,然后删块节点。失败时把错误写到状态条并返回 false。
    private func ejectTransferDisk(_ disk: TransferDisk) async -> Bool {
        if let err = await qmp.removeTransferDevice(disk) {
            finish("弹出失败:\(err)")
            return false
        }
        // QEMU 要等 guest 确认才真的删设备;事件到了 transferDeviceGone 会把我们叫醒。
        if transfer?.attached == true {
            await withCheckedContinuation { cont in transferGoneContinuation = cont }
        }
        _ = await qmp.removeTransferNode(disk)
        return true
    }

    /// DEVICE_DELETED 到了:标记已拔,叫醒等着的人
    public func transferDeviceGone(_ id: String) {
        guard var disk = transfer, disk.device == id else { return }
        disk.attached = false
        transfer = disk
        transferGoneContinuation?.resume()
        transferGoneContinuation = nil
    }

    /// 只读挂载镜像,复制到 ~/Downloads/<虚拟机名>-传出-<时间>/,在访达里露出来,删镜像
    private func copyOutTransferDisk(_ disk: TransferDisk) async {
        begin("正在复制到宿主…")
        let vmName = bundle.settings.name
        let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let mount = try ISOInspector.Mount(image: disk.image, raw: true)
                defer { mount.detach() }
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
                let dest = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/\(vmName)-传出-\(f.string(from: Date()))")
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let items = try FileManager.default.contentsOfDirectory(at: mount.path, includingPropertiesForKeys: nil)
                for item in items where !item.lastPathComponent.hasPrefix(".")
                    && item.lastPathComponent != "System Volume Information" {
                    try FileManager.default.copyItem(at: item, to: dest.appendingPathComponent(item.lastPathComponent))
                }
                return .success(dest)
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let dest):
            try? FileManager.default.removeItem(at: disk.image)
            transfer = nil
            finish(nil)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        case .failure(let e):
            // 镜像留着,下次还能取
            transfer = nil
            finish("复制失败:\(e.localizedDescription)。镜像还在 \(disk.image.lastPathComponent)")
        }
    }

    /// 上次没取回的盘:直接从镜像复制出来(它不在 guest 上)
    public func retrieveLeftover(_ image: URL) {
        guard !isBusy, transfer == nil else { return }
        let stamp = image.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "transfer-", with: "")
        let disk = TransferDisk(image: image, node: "xfer\(stamp)", device: "xferdev\(stamp)", files: [], attached: false)
        transfer = disk
        begin("正在复制到宿主…")
        Task { await copyOutTransferDisk(disk) }
    }

    /// 挂起/存快照前调用:raw 盘会让 savevm 失败。镜像留在包里,下次打开可以取回。
    public func detachTransferDiskForSnapshot() async {
        guard let disk = transfer, disk.attached else { return }
        print("[传文件] 存快照前先拔出传输盘,镜像留在包里")
        _ = await ejectTransferDisk(disk)
    }
}
