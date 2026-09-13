import CoreGraphics
import Foundation
import Testing
import VirtuallyKit

@Suite("输入与显示")
struct InputTests {

    /// ⌘ 在编辑快捷键里当 Ctrl
    @Test("⌘ 键翻译")
    func commandKeys() {
        func str(_ evs: [CommandKeyTranslator.Event]) -> String {
            evs.map { "\($0.code)\($0.down ? "↓" : "↑")" }.joined(separator: " ")
        }
        let v = qcodeForCharacter("v").code, e = qcodeForCharacter("e").code
        let meta = QKeyCode.meta, ctrl = QKeyCode.ctrl

        var t = CommandKeyTranslator()
        var seq = t.commandChanged(down: true) + t.keyDown(v) + t.keyUp(v) + t.commandChanged(down: false)
        expectEqual(str(seq), str([(ctrl, true), (v, true), (v, false), (ctrl, false)]),
                    "⌘V 发成 Ctrl+V,全程不出现 Super(否则 GNOME 会开活动概览)")

        t = CommandKeyTranslator()
        seq = t.commandChanged(down: true) + t.keyDown(e) + t.keyUp(e) + t.commandChanged(down: false)
        expectEqual(str(seq), str([(meta, true), (e, true), (e, false), (meta, false)]), "⌘E 仍是 Super+E")

        t = CommandKeyTranslator()
        seq = t.commandChanged(down: true) + t.commandChanged(down: false)
        expectEqual(str(seq), str([(meta, true), (meta, false)]), "单按 ⌘ 补一次 Super 单击")

        t = CommandKeyTranslator()
        seq = t.commandChanged(down: true) + t.commandChanged(down: false)
        _ = t.commandChanged(down: true); seq = t.releaseAll()
        expect(seq.isEmpty, "⌘Tab 切走(失焦)时挂起的 ⌘ 直接丢弃,不补单击")

        t = CommandKeyTranslator()
        seq = t.commandChanged(down: true) + t.keyDown(v) + t.commandChanged(down: false) + t.keyUp(v)
        expectEqual(str(seq), str([(ctrl, true), (v, true), (v, false), (ctrl, false)]),
                    "先松 ⌘ 后松 V:Ctrl 跟着 V 抬起")

        t = CommandKeyTranslator()
        let c = qcodeForCharacter("c").code
        seq = t.commandChanged(down: true) + t.keyDown(c) + t.keyDown(v) + t.keyUp(c)
        expectEqual(str(seq), str([(ctrl, true), (c, true), (v, true), (c, false)]), "两个编辑键重叠时 Ctrl 不提前抬起")
        seq = t.keyUp(v) + t.commandChanged(down: false)
        expectEqual(str(seq), str([(v, false), (ctrl, false)]), "最后一个编辑键抬起才抬 Ctrl")

        t = CommandKeyTranslator()
        t.physicalControl = true
        seq = t.commandChanged(down: true) + t.keyDown(v) + t.keyUp(v)
        expectEqual(str(seq), str([(v, true), (v, false)]), "真 Ctrl 按着时不替它按下抬起")

        t = CommandKeyTranslator()
        seq = t.commandChanged(down: true) + t.pointerPressed() + t.commandChanged(down: false)
        expectEqual(str(seq), str([(meta, true), (meta, false)]), "⌘ 加鼠标按下落实成 Super(拖动窗口)")

        t = CommandKeyTranslator()
        _ = t.commandChanged(down: true); t.hostHandledShortcut()
        expect(t.commandChanged(down: false).isEmpty, "⌘ 组合归宿主时抬起不补 Super 单击")

        t = CommandKeyTranslator()
        t.enabled = false
        seq = t.commandChanged(down: true) + t.keyDown(v) + t.keyUp(v) + t.commandChanged(down: false)
        expectEqual(str(seq), str([(meta, true), (v, true), (v, false), (meta, false)]), "关掉时 ⌘ 原样是 Super")
    }

    @Test("键位表")
    func keymap() {
        expectEqual(qcode(for: 0x31), 60, "空格映射到 QKeyCode spc(60)")
        expectEqual(qcode(for: 0x24), 35, "回车映射到 ret(35)")
        expect(macKeyToQCode.count > 100, "键位表应覆盖 100 个以上按键")
        expect(qcode(for: 0xFFFF) == 0, "未知键返回 unmapped(0)")
    }

    @Test("显示尺寸钳制")
    func displayClamp() {
        let tiny = VMDisplay.clamp(CGSize(width: 320, height: 200))
        expectEqual(Int(tiny.width), 800, "低于下限时钳到 800 宽")
        expectEqual(Int(tiny.height), 600, "低于下限时钳到 600 高")

        let odd = VMDisplay.clamp(CGSize(width: 1466, height: 942))
        expectEqual(Int(odd.width), 1466, "范围内的任意尺寸原样保留(点对点的前提)")

        // 5K 屏全屏正好在预算之内,点对点原样保留
        let fiveK = VMDisplay.clamp(CGSize(width: 5120, height: 2880))
        expectEqual(fiveK, CGSize(width: 5120, height: 2880), "5K 全屏不缩小")

        // 6K 屏全屏:超过预算,应等比缩小而不是改长宽比
        let big = VMDisplay.clamp(CGSize(width: 6016, height: 3384))
        expect(big.width * big.height <= VMDisplay.maxPixels, "超限时缩到像素预算之内")
        let srcRatio = 6016.0 / 3384.0, dstRatio = big.width / big.height
        expect(abs(srcRatio - dstRatio) < 0.01, "缩小时保持长宽比")
        expect(Int(big.width) % 2 == 0 && Int(big.height) % 2 == 0,
               "缩出来的宽高是偶数:2 倍屏上窗口才能贴合到整数个点")

        // 帧缓冲段还没扩大的 Windows 按旧上限缩(实测 5120x2560 → 4690x2345 这种奇数高曾导致差 1 像素)
        let legacy = VMDisplay.clamp(CGSize(width: 5120, height: 2560), maxPixels: VMDisplay.legacyMaxPixels)
        expect(legacy.width * legacy.height <= VMDisplay.legacyMaxPixels, "旧预算之内")
        expect(Int(legacy.width) % 2 == 0 && Int(legacy.height) % 2 == 0, "旧预算下同样取偶数")
    }

    /// 息屏时 QEMU 写的是近乎全黑的一张图,不该覆盖掉上一张好图
    @Test("缩略图空白判定")
    func blankDetection() {
        func synthetic(_ fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
            let w = 64, h = 40
            var px = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let (b, g, r) = fill(x, y)
                    let i = (y * w + x) * 4
                    px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = 255
                }
            }
            return px.withUnsafeMutableBytes { raw -> CGImage? in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                                      CGBitmapInfo.byteOrder32Little.rawValue)
                else { return nil }
                return ctx.makeImage()
            }
        }
        if let black = synthetic({ _, _ in (0, 0, 0) }) {
            expect(Framebuffer.looksBlank(black), "纯黑判为空白")
        } else { expect(false, "构造纯黑测试图") }
        let colourful: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in
            let b = UInt8((x * 4) % 256)
            let g = UInt8((y * 6) % 256)
            return (b, g, UInt8(200))
        }
        if let desktop = synthetic(colourful) {
            expect(!Framebuffer.looksBlank(desktop), "有内容的画面不判为空白")
        } else { expect(false, "构造彩色测试图") }
    }
}

@Suite("Windows 帧缓冲预留")
struct DisplayMemoryTests {

    @Test("发给 agent 的注册表命令")
    func agentCommand() throws {
        let cmd = DisplayMemory.agentCommand
        expect(!cmd.contains("\n") && cmd.hasPrefix("exec powershell.exe "), "一行、走 exec")
        expect(!cmd.contains("\"") && cmd.count < 8191, "没有引号、短于 cmd.exe 上限")
        let b64 = try #require(cmd.split(separator: " ").last.map(String.init))
        let script = try #require(Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf16LittleEndian) })
        expect(script.contains("PersistentDispMode0Width") && script.contains("PersistentDispMode0Height"),
               "写的是 viogpudo 启动时读的那两个值")
        expect(script.contains("-Value \(DisplayMemory.width)") && script.contains("-Value \(DisplayMemory.height)"),
               "预留尺寸与 DisplayMemory 一致")
        expect(script.contains("DEVPKEY_Device_Driver"), "设备键从驱动属性里找,不写死 0000")
        expect(script.unicodeScalars.allSatisfy(\.isASCII), "纯 ASCII(输出经 cmd 按代码页读)")
        expect(Double(DisplayMemory.width * DisplayMemory.height) == Double(VMDisplay.maxPixels),
               "宿主的像素上限与 guest 预留的帧缓冲对应")
    }

    @Test("解析 guest 回的结果")
    func parse() {
        expectEqual(DisplayMemory.parse("out VADISP ready"), .ready, "已经够大")
        expectEqual(DisplayMemory.parse("out VADISP written"), .written, "刚写入")
        expectEqual(DisplayMemory.parse("out VADISP none"), .noDevice, "没有 virtio 显卡")
        expectEqual(DisplayMemory.parse("out VADISP failed Access is denied"), .failed("Access is denied"), "失败原因")
        expect(DisplayMemory.parse("out VAGROW nochange") == nil, "别的标记不认")
    }
}
