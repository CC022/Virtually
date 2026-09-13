import Foundation
import Testing
import VirtuallyKit

@Suite("会话")
struct SessionTests {

    /// 以前是一个四 case 的 state 外加三个布尔在拼状态,每处判定各猜一遍。
    /// 这些派生属性是「能不能操作」「要不要报错」的唯一依据,必须覆盖。
    @Test("状态机")
    func stateMachine() {
        typealias S = VMSession.State
        // QEMU 进程还在的那几个
        for live in [S.starting, .restoring, .running, .suspending, .shuttingDown] {
            expect(live.isLive, "\(live.label) 算进程还活着")
            expect(!live.hasExited, "\(live.label) 不算已退出")
        }
        expect(!S.idle.isLive, "idle 时进程还没起")
        expect(!S.stopped(code: 0).isLive, "stopped 时进程已经没了")
        expect(S.stopped(code: 1).hasExited, "stopped 算已退出")

        // **只有 running 接受用户操作**:starting 时 QMP 还没握手完,
        // restoring 时 loadvm 正在动磁盘,suspending / shuttingDown 已经在退了
        expect(S.running.acceptsCommands, "running 可操作")
        for blocked in [S.idle, .starting, .restoring, .suspending, .shuttingDown, .stopped(code: 0)] {
            expect(!blocked.acceptsCommands, "\(blocked.label) 不可操作")
            expect(blocked.blockedReason != nil, "\(blocked.label) 要说得出不能操作的原因")
        }
        expect(S.running.blockedReason == nil, "running 没有阻塞原因")

        // 退出流程只有这两个 —— 退出码为 0 时不该报「意外退出」
        expect(S.suspending.isEnding && S.shuttingDown.isEnding, "挂起与关机算退出流程中")
        for notEnding in [S.idle, .starting, .restoring, .running] {
            expect(!notEnding.isEnding, "\(notEnding.label) 不算在走退出流程")
        }
        // guest 自己关机时状态还是 running,那时退出是意料之外但也不该报错(靠运行时长区分)
        expect(!S.running.isEnding, "guest 自己关机时我们没在走退出流程")
        expectEqual(S.stopped(code: 3).label, "stopped(3)", "stopped 的名字带退出码")
    }

    @Test("快照名与内部标签")
    func snapshotNames() {
        // 快照名进 HMP 命令行并按空格切列,只能用一小撮字符;内部标签不许占
        expect(VMSession.snapshotNameProblem("clean-install") == nil, "普通快照名合法")
        expect(VMSession.snapshotNameProblem("v1.2_ok") == nil, "点与下划线合法")
        expect(VMSession.snapshotNameProblem("my snap") != nil, "含空格的快照名被拒绝")
        expect(VMSession.snapshotNameProblem(suspendTag) != nil, "内部保留标签被拒绝")
        expect(VMSession.snapshotNameProblem("") != nil, "空名被拒绝")

        // 会话路径带 pid:两个 app 实例不能撞在同一个帧缓冲文件上
        expect(SessionPaths.next().framebuffer.contains("\(getpid())"), "会话路径带进程号")
        expect(!SessionPaths.debug.framebuffer.contains("\(getpid())"), "调试实例用固定路径,截图工具认得到")
    }

    /// HMP 的纯文本表格,表头和提示行都要能被滤掉
    @Test("快照列表解析")
    func snapshotParsing() {
        let snapText = """
        List of snapshots present on all disks:
        ID      TAG    VM_SIZE      DATE        VM_CLOCK     ICOUNT
        --      clean-install    1.57 GiB 2026-09-08 20:23:52  0000:01:49.713         --
        1       gui-test         2.10 GiB 2026-09-10 18:05:11  0000:02:30.001         --
        """
        let snapRows = VMSession.parseSnapshots(snapText)
        expectEqual(snapRows.count, 2, "解析出两条快照,表头与提示行被滤掉")
        expectEqual(snapRows.first?.id ?? "", "clean-install", "取到快照名")
        expect(snapRows.first?.size == "1.57 GiB", "取到快照体积")
        expect(VMSession.parseSnapshots("There is no snapshot available.").isEmpty,
               "无快照时返回空列表")
        // HMP 实际返回的是 CRLF 行尾。Swift 把 "\r\n" 当单个 Character,
        // 按 "\n" 切会一条都切不出来 —— 之前就是这样静默返回 0 条的。
        let crlf = snapText.replacingOccurrences(of: "\n", with: "\r\n")
        expectEqual(VMSession.parseSnapshots(crlf).count, 2, "CRLF 行尾同样能解析")
    }

    @Test("USB 设备身份")
    func usbIdentity() {
        // 同型号两只 USB 设备靠 locationID 区分,QOM id 也要不一样
        let dongleA = USBDevice(name: "Token", vendorID: 0x1234, productID: 0x5678, vendorName: "",
                                locationID: 0x01100000, address: 5, blockedReason: nil)
        let dongleB = USBDevice(name: "Token", vendorID: 0x1234, productID: 0x5678, vendorName: "",
                                locationID: 0x01200000, address: 6, blockedReason: nil)
        expect(dongleA.key != dongleB.key, "同 VID:PID 不同插口的设备键不同")
        expect(QMPClient.usbDeviceID(dongleA) != QMPClient.usbDeviceID(dongleB), "同型号两只设备的 QOM id 不同")
        expectEqual(dongleA.hostBus ?? -1, 1, "hostbus 取 locationID 的高 8 位(与 libusb darwin 一致)")
    }

    /// 枚举本身依赖真实硬件,不进测试;但分类逻辑是纯函数,必须覆盖 ——
    /// 它决定用户会不会去点一个注定失败的设备。
    @Test("USB 设备分类")
    func usbClassification() {
        expect(USBEnumerator.blockedReason(name: "USB2.0 Hub", deviceClass: 9) != nil,
               "集线器被判为不可透传")
        expect(USBEnumerator.isHub(name: "任意名字", deviceClass: 9),
               "按设备类判定集线器,不只靠名字")
        expect(USBEnumerator.blockedReason(name: "Apple Keyboard", deviceClass: 0) != nil,
               "键盘被判为内核占用")
        // 名字匹配靠不住:一只 Razer 鼠标叫 DeathAdder V4 Pro,名字里没有任何关键词。
        // 接口类才是协议事实。
        expect(USBEnumerator.blockedReason(name: "DeathAdder V4 Pro", deviceClass: 0,
                                           interfaceClasses: [3]) != nil,
               "按接口类判定 HID,不受设备名影响")
        expect(USBEnumerator.reasonForInterfaceClass(0xFF) == nil,
               "厂商自定义类没有内核驱动匹配,判为可透传")
        expect(USBEnumerator.blockedReason(name: "Studio Display XDR", deviceClass: 0) != nil,
               "显示器自带设备不可透传")
        expect(USBEnumerator.blockedReason(name: "SafeNet eToken 5110", deviceClass: 0) == nil,
               "加密狗这类没有内核驱动匹配的设备判为可透传")
    }

    @Test("app 内的工具位置")
    func toolPaths() {
        let app = Bundle(path: "/Applications/Virtually.app") ?? Bundle.main
        let tools = ToolPaths(appBundle: app)
        let contents = app.bundleURL.appendingPathComponent("Contents").path
        expect(tools.qemu.path.hasPrefix(contents + "/MacOS/"), "QEMU 在 Contents/MacOS 下")
        expect(tools.qemuImg.path.hasPrefix(contents + "/MacOS/"), "qemu-img 在 Contents/MacOS 下")
        expectEqual(tools.firmware.lastPathComponent, "qemu", "固件在 Resources/qemu")
        expect(tools.windowsAgentScript.path.hasSuffix("GuestAgent/windows/agent.ps1"), "Windows agent 的位置")
        expect(tools.linuxAgentDirectory.path.hasSuffix("GuestAgent/linux"), "Linux agent 的位置")
        // 运行时写进 bundle 会破坏签名,装在 /Applications 下也没有写权限
        expect(!ToolPaths.toolsImage.path.contains(".app/"), "工具盘不在 app bundle 里")
    }

    @Test("调试启动参数")
    func debugLaunchArguments() {
        var d = DebugLaunch()
        d.vmPath = "/x/Ubuntu.vmbundle"
        d.controlSocket = "/tmp/c.sock"
        d.mountTools = true
        d.displaySize = "1280x800"
        let a = d.arguments
        // 必须全是成对的 -键 值:无值开关会让 AppKit 把后面的路径当成要打开的文档
        expectEqual(a.count % 2, 0, "参数成对")
        expect(stride(from: 0, to: a.count, by: 2).allSatisfy { a[$0].hasPrefix("-") && !a[$0 + 1].hasPrefix("-") },
               "偶数位是键,奇数位是值")
        expectEqual(value(after: "-MountTools", in: a), "YES", "布尔开关写成 YES")
        expect(!a.contains("-ForceRamfb"), "没开的开关不出现")
        expectEqual(value(after: "-ApplePersistenceIgnoreState", in: a), "YES",
                    "调试实例不恢复窗口:旧窗口指向删掉的包时,SwiftUI 会一个窗口都不建")
        expectEqual(d.sessionOptions.displaySize?.w, 1280, "显示尺寸解析")
        expect(d.sessionOptions.mountTools, "工具盘开关传到会话选项")
        expect(d.sessionOptions.hostCursor, "默认宿主画光标")
    }
}
