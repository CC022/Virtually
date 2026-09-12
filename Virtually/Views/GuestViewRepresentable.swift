// 把现有的 GuestView(NSView + CAMetalLayer)接进 SwiftUI。
//
// GuestView 本身不动:它承载着零拷贝纹理、CADisplayLink 驱动的刷新、
// 五路优先级的光标判定、以及全部键鼠输入 —— 那些都是反复调过的,
// 重写只会把踩过的坑再踩一遍。

import SwiftUI
import VirtuallyKit

struct GuestViewRepresentable: NSViewRepresentable {
    let session: VMSession

    func makeNSView(context: Context) -> GuestView {
        // 视图由 VMSession 持有并复用:窗口关掉再开时不能丢掉已经映射好的纹理
        session.view
    }

    func updateNSView(_ nsView: GuestView, context: Context) {}
}
