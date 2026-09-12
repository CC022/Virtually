import AppKit

/// NSWindow 的 delegate 只是为了截住关闭动作。单独一个类,
/// 因为 VMSession 是 @Observable,让它去继承 NSObject 很别扭。
///
/// SwiftUI 的 WindowGroup 自己也装了 delegate(窗口恢复、场景生命周期都靠它)。
/// 直接顶掉会把那些都弄丢,所以这里只实现 windowShouldClose,其余消息全部转发给原来的。
@MainActor
public final class WindowCloseWatcher: NSObject, NSWindowDelegate {
    private let shouldClose: () -> Bool
    private(set) weak var original: NSWindowDelegate?

    public init(forwardingTo original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }

    public override func responds(to sel: Selector!) -> Bool {
        super.responds(to: sel) || (original?.responds(to: sel) ?? false)
    }
    public override func forwardingTarget(for sel: Selector!) -> Any? {
        original?.responds(to: sel) == true ? original : nil
    }
}
