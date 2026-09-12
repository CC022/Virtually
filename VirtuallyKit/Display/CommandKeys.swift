// ⌘ 在 guest 里的两种身份:编辑快捷键里当 Ctrl,其余时候当 Win / Super。
//
// Mac 用户按 ⌘V 是想粘贴,而 guest 里粘贴是 Ctrl+V —— ⌘ 原样发成 Win/Super 的话,
// 剪贴板同步做得再好也粘不出来。反过来 Win+E、Super 单击开「活动」这些又得留着。
//
// 难点在于 ⌘ 按下的那一刻还不知道接下来按什么,而**不能先发 Super 再撤回**:
// GNOME 在 Super「按下又抬起、中间没有别的键」时打开活动概览,Windows 同样会弹开始菜单。
// 所以 ⌘ 按下时先不发,等下一个动作再决定:
//
//   ⌘ 按下                  → 挂起(什么都不发)
//   挂起时按编辑键(V 等)   → Ctrl↓ V↓,⌘ 记为「已用掉」,抬起时不再补发
//   挂起时按其他键          → 补发 Super↓,再发这个键(Super+E 照常)
//   挂起时点鼠标            → 补发 Super↓(GNOME 的 Super+拖动窗口要它)
//   ⌘ 抬起,期间什么都没按  → Super↓↑ 补一次单击
//
// 顺带修掉一个老问题:⌘Tab 切走时 Tab 被 macOS 吞掉,以前 guest 只收到 Super 按下和
// 失焦时补的抬起,正好凑成一次单击,切个应用 guest 就弹出活动概览。现在失焦时挂起的 ⌘ 直接丢弃。
//
// 纯状态机,不碰 NSEvent,输出要发的 (qcode, 按下/抬起) 序列 —— 自检直接测它。

public struct CommandKeyTranslator {
    public typealias Event = (code: Int32, down: Bool)

    /// 按 Ctrl 发的键。都是 Mac 上 ⌘ 与 Windows/Linux 上 Ctrl 意思相同的那批;
    /// 刻意不含 R、L、E、D、H、Q —— Win+R 运行、Win+L 锁屏、Win+E 资源管理器这些在 guest 里常用。
    public static let controlKeys: Set<Int32> = Set("acvxzyfsnopwt".map { qcodeForCharacter($0).code })

    public enum Meta: Equatable {
        case up
        case pending    // ⌘ 按着,还没发给 guest
        case consumed   // ⌘ 按着,已经被当成 Ctrl 用过 —— 抬起时什么都不补
        case sent       // 已经作为 Super 发给 guest 了
    }

    /// 关掉时 ⌘ 就是 Super,按下立刻发,与改之前一样
    public var enabled = true
    public private(set) var meta = Meta.up
    /// 以 Ctrl 发出去、还按着的键
    private var substituted = Set<Int32>()
    /// 真正的 Ctrl 键按着的话,替换时就不能替它抬起
    public var physicalControl = false

    public init() {}

    public mutating func commandChanged(down: Bool) -> [Event] {
        if down {
            guard meta == .up else { return [] }
            if enabled { meta = .pending; return [] }
            meta = .sent
            return [(QKeyCode.meta, true)]
        }
        defer { meta = .up }
        switch meta {
        case .pending:  return [(QKeyCode.meta, true), (QKeyCode.meta, false)]   // 单击 ⌘
        case .sent:     return [(QKeyCode.meta, false)]
        case .consumed, .up: return []
        }
    }

    public mutating func keyDown(_ code: Int32) -> [Event] {
        switch meta {
        case .pending, .consumed:
            if Self.controlKeys.contains(code) {
                meta = .consumed
                let pressCtrl = substituted.isEmpty && !physicalControl   // 已经按着就不再按
                substituted.insert(code)
                return (pressCtrl ? [(QKeyCode.ctrl, true)] : []) + [(code, true)]
            }
            meta = .sent
            return [(QKeyCode.meta, true), (code, true)]
        case .up, .sent:
            return [(code, true)]
        }
    }

    public mutating func keyUp(_ code: Int32) -> [Event] {
        guard substituted.remove(code) != nil else { return [(code, false)] }
        // 同时按着两个编辑键(⌘ 按住连续 C、V 重叠)时,Ctrl 要等最后一个抬起
        let releaseCtrl = substituted.isEmpty && !physicalControl
        return [(code, false)] + (releaseCtrl ? [(QKeyCode.ctrl, false)] : [])
    }

    /// ⌘ 组合被宿主拿去了(菜单快捷键):guest 什么都没收到,抬起时也不该补单击
    public mutating func hostHandledShortcut() {
        if meta == .pending { meta = .consumed }
    }

    /// 鼠标按下前调用:挂起的 ⌘ 此时就该是 Super 了
    public mutating func pointerPressed() -> [Event] {
        guard meta == .pending else { return [] }
        meta = .sent
        return [(QKeyCode.meta, true)]
    }

    /// 失焦:只抬起**已经发出去**的,挂起的 ⌘ 直接丢弃,不补单击
    public mutating func releaseAll() -> [Event] {
        var out: [Event] = substituted.map { ($0, false) }
        if !substituted.isEmpty && !physicalControl { out.append((QKeyCode.ctrl, false)) }
        if meta == .sent { out.append((QKeyCode.meta, false)) }
        substituted.removeAll()
        meta = .up
        return out
    }
}
