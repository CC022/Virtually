import Foundation
import Testing
import VirtuallyKit

/// 测试 bundle 与 Virtually.app 在同一个 Products 目录下,qemu-img 就在 app 里
private final class DiskTestsToken {}
private let builtQemuImg = Bundle(for: DiskTestsToken.self).bundleURL
    .deletingLastPathComponent().appendingPathComponent("Virtually.app/Contents/MacOS/qemu-img")

@Suite("磁盘扩容")
struct DiskTests {

    @Test("旧 config.json 没有 growPartition 也能读")
    func oldConfigDecodes() throws {
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Fixture.original)) as! [String: Any]
        obj["growPartition"] = nil
        let data = try JSONSerialization.data(withJSONObject: obj)
        // 解码失败的包会被 loadLibrary 静默跳过 —— 虚拟机就从资源库里消失了
        let decoded = try JSONDecoder().decode(VMSettings.self, from: data)
        expect(decoded.growPartition == nil, "缺这个键时为 nil")
        expectEqual(decoded.diskSizeGB, Fixture.original.diskSizeGB, "其余字段照常")
    }

    @Test("解析 qemu-img info 的 virtual-size")
    func parseVirtualSize() {
        let json = """
        {
            "children": [],
            "virtual-size": 137438953472,
            "filename": "/x/disk.qcow2",
            "format": "qcow2",
            "actual-size": 21474836480
        }
        """
        expectEqual(VMBundle.parseVirtualSize(json), 137_438_953_472, "取 virtual-size 而不是 actual-size")
        expect(VMBundle.parseVirtualSize("qemu-img: Could not open") == nil, "报错文本解析不出来")
        expectEqual(VMBundle.wholeGB(137_438_953_472), 128, "整 GB")
        expectEqual(VMBundle.wholeGB(50 * (1 << 30) + 1), 51, "向上取整:下限不能比现在还小")
    }

    @Test("不能改磁盘大小的情形")
    func blockedReasons() {
        var s = Fixture.original
        expect(VMBundle(url: Fixture.bundleURL, settings: s).diskResizeBlockedReason == nil, "关机态可以改")

        s.snapshotShapes["clean-install"] = "shape"
        expect(VMBundle(url: Fixture.bundleURL, settings: s).diskResizeBlockedReason == nil,
               "用户快照不挡:恢复时盘回到当时大小,前后一致")

        s.snapshotShapes[suspendTag] = "shape"
        expect(VMBundle(url: Fixture.bundleURL, settings: s).diskResizeBlockedReason != nil,
               "已挂起不能改:loadvm 会把盘缩回挂起那一刻的大小")

        var installing = Fixture.original
        installing.install = InstallMedia(iso: "/a.iso", boot: "/b.img", tools: "/t.img")
        expect(VMBundle(url: Fixture.bundleURL, settings: installing).diskResizeBlockedReason != nil,
               "安装中不能改")
    }

    @Test("发给 agent 的扩分区命令")
    func agentCommand() throws {
        let win = PartitionGrow.agentCommand(for: .windows)
        expect(!win.contains("\n") && win.hasPrefix("exec "), "Windows:一行、走 exec")
        expect(win.count < 8191, "短于 cmd.exe 的命令行上限")
        expect(!win.contains("\""), "整条命令没有引号(cmd /c 的嵌套引号会坏)")
        let b64 = try #require(win.split(separator: " ").last.map(String.init))
        let bytes = try #require(Data(base64Encoded: b64))
        let script = try #require(String(data: bytes, encoding: .utf16LittleEndian))
        expect(script.contains("Resize-Partition") && script.contains("VAGROW"), "EncodedCommand 解回来是扩分区脚本")
        expect(script.contains("de94bba4-06d1-4d40-a16a-bfd50179d6ac") && script.contains("reagentc.exe /enable"),
               "挡在 C: 后面的 WinRE 恢复分区要删掉、WinRE 搬进 C:")
        expect(!script.contains("-match"), "WinRE 位置用 Contains 比对:路径里的 \\p 在 .NET 正则里是转义")
        expect(script.unicodeScalars.allSatisfy(\.isASCII), "Windows 脚本纯 ASCII(输出经 cmd 按代码页读)")

        let linux = PartitionGrow.agentCommand(for: .ubuntu)
        expect(!linux.contains("\n") && linux.hasPrefix("exec echo ") && linux.hasSuffix("| base64 -d | sh"),
               "Linux:一行、base64 解码后交给 sh")
        let lb64 = String(linux.split(separator: " ")[2])
        let lscript = try #require(Data(base64Encoded: lb64).flatMap { String(data: $0, encoding: .utf8) })
        expect(lscript.contains("growpart") && lscript.contains("resize2fs"), "Linux 脚本扩分区再扩文件系统")
        expect(lscript.unicodeScalars.allSatisfy(\.isASCII), "Linux 脚本纯 ASCII")
    }

    @Test("解析 guest 回的结果")
    func parseOutcome() {
        expectEqual(PartitionGrow.parse("out VAGROW grown 68719476736 137438953472"),
                    .grown(from: 68_719_476_736, to: 137_438_953_472, note: nil), "扩成功")
        expectEqual(PartitionGrow.parse("out VAGROW grown 1 2 winre-off"),
                    .grown(from: 1, to: 2, note: "winre-off"), "扩成功但带提醒")
        expect(PartitionGrow.explainNote("winre-off")?.contains("reagentc") == true, "WinRE 没重新启用要说怎么补")
        expect(PartitionGrow.explainNote(nil) == nil, "没有提醒就不说话")
        expectEqual(PartitionGrow.parse("out VAGROW nochange"), .noChange, "已占满")
        expectEqual(PartitionGrow.parse("out VAGROW blocked partition-after-c"),
                    .blocked("partition-after-c"), "被后面的分区挡住")
        expectEqual(PartitionGrow.parse("out VAGROW failed Access denied here"),
                    .failed("Access denied here"), "失败原因保留空格")
        expect(PartitionGrow.parse("out VAGROW grown x y") == nil, "数字不对不认")
        expect(PartitionGrow.parse("ok exec rc=0") == nil, "无关的行不认")
        expect(PartitionGrow.parse("out C:\\> VAGROW nochange") == nil, "只认行首的 VAGROW")
        expect(PartitionGrow.explainBlocked("fstype-btrfs").contains("btrfs"), "文件系统类型带进提示")
    }

    @Test("带快照的 qcow2 扩容", .enabled(if: FileManager.default.isExecutableFile(atPath: builtQemuImg.path),
                                     "要先构建出 Virtually.app(里面嵌着 qemu-img)"))
    func growRealImage() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("virtually-disk-test-\(UUID().uuidString.prefix(8)).vmbundle")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var settings = Fixture.original
        settings.diskSizeGB = 1
        var bundle = VMBundle(url: dir, settings: settings)
        try bundle.save()
        try VMBundle.run(builtQemuImg, ["create", "-f", "qcow2", bundle.diskURL.path, "1G"])
        // 带内部快照:v3 的 qcow2 允许扩,v2 不行
        try VMBundle.run(builtQemuImg, ["snapshot", "-c", "s1", bundle.diskURL.path])

        try bundle.growDisk(toGB: 2, qemuImg: builtQemuImg)
        expectEqual(try bundle.diskVirtualSize(qemuImg: builtQemuImg), 2 * (1 << 30), "virtual-size 变成 2GB")
        let saved = try VMBundle.load(at: dir).settings
        expectEqual(saved.diskSizeGB, 2, "配置里记下新大小")
        expect(saved.growPartition == true, "配置里记下 guest 分区待扩")

        #expect(throws: VMError.self, "不能缩小") { try bundle.growDisk(toGB: 1, qemuImg: builtQemuImg) }
        #expect(throws: VMError.self, "一样大也不算扩") { try bundle.growDisk(toGB: 2, qemuImg: builtQemuImg) }
        expectEqual(try bundle.diskVirtualSize(qemuImg: builtQemuImg), 2 * (1 << 30), "失败时盘不动")
    }
}
