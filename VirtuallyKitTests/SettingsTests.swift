import Foundation
import Testing
import VirtuallyKit

@Suite("设置")
struct SettingsTests {

    @Test("夹取到主机能承受的范围")
    func clamp() {
        var s = VMSettings.default(for: .windows)
        s.cpuCount = 9999
        s.memoryMB = 999_999
        s.diskSizeGB = 1
        let notes = s.clamp()
        expectEqual(s.cpuCount, VMSettings.hostCPUCount, "CPU 上限夹到主机核数")
        expectEqual(s.memoryMB, VMSettings.maxMemoryMB, "内存上限夹到 maxMemoryMB")
        expectEqual(s.diskSizeGB, 32, "磁盘下限 32GB")
        expectEqual(notes.count, 3, "三项都应产生提示")

        var low = VMSettings.default(for: .windows)
        low.cpuCount = 0
        low.memoryMB = 128
        _ = low.clamp()
        expectEqual(low.cpuCount, 1, "CPU 下限 1")
        expectEqual(low.memoryMB, 2048, "内存下限 2048MB")

        expect(VMSettings.maxMemoryMB <= VMSettings.hostMemoryMB - 4096
               || VMSettings.maxMemoryMB == 1024,
               "内存上限须为主机留出 4GB 余量")
    }

    @Test("默认核数")
    func defaultCPUCount() {
        expectEqual(VMSettings.defaultCPUCount, min(4, VMSettings.hostCPUCount), "默认 4 核,主机不够取主机核数")
        expectEqual(VMSettings.default(for: .windows).cpuCount, VMSettings.defaultCPUCount, "默认设置用默认核数")
    }

    @Test("名字清洗")
    func sanitizedName() {
        expectEqual(VMSettings.sanitizedName("  a/b:c  "), "a-b-c", "路径分隔符与冒号换成连字符")
        expectEqual(VMSettings.sanitizedName("..hidden"), "hidden", "不许以点开头")
        expectEqual(VMSettings.sanitizedName("   "), "虚拟机", "空名给默认值")
    }

    @Test("config.json 往返")
    func codableRoundTrip() throws {
        let original = Fixture.original
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VMSettings.self, from: data)
        expectEqual(decoded, original, "VMSettings 往返")
        // 安装介质要能进出 config.json,中途退出再打开才接得上
        var installing = original
        installing.install = InstallMedia(iso: "/a.iso", boot: "/b.img", tools: "/t.img", virtioISO: "/v.iso")
        let back = try JSONDecoder().decode(VMSettings.self, from: JSONEncoder().encode(installing))
        expectEqual(back.install?.virtioISO, "/v.iso", "InstallMedia 往返")
        expect(decoded.install == nil, "没在安装的机器 install 为 nil")
    }
}
