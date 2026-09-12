// 画面视图:CAMetalLayer + CADisplayLink 呈现共享帧缓冲,光标合成,全部键鼠输入。
//
// 三条关键路径,都是为了「跟手」:
//   画面:mmap 共享内存 → MTLBuffer(bytesNoCopy:) → MTLTexture,零拷贝零编解码
//   刷新:CADisplayLink 驱动,跟随宿主刷新率,而不是 QEMU 的固定定时器
//   光标:位置用宿主自己的鼠标坐标,只从 guest 取位图,与 guest 帧率解耦

import AppKit
import Metal
import QuartzCore
import Darwin

extension NSCursor {
    /// 全透明光标 —— 用于在 guest 自绘光标时隐藏宿主指针。
    /// resetCursorRects 调用很频繁,位图只画一次。
    public static let hidden: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus(); NSColor.clear.set(); NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: 1)); img.unlockFocus()
        return NSCursor(image: img, hotSpot: .zero)
    }()
}

// MARK: - 画面视图

public final class GuestView: NSView {
    public let metalLayer = CAMetalLayer()
    public var framebuffer: Framebuffer?
    public var channel: DisplayChannel?
    public var agent: AgentChannel?

    private var commandQueue: MTLCommandQueue?
    private var displayLink: CADisplayLink?
    private var needsPresent = true

    // 帧率埋点。三个数分别对应三个可能的瓶颈:
    //   damages —— QEMU 每秒送来多少次脏区(受 dcl.update_interval 与 guest 出图速度限制)
    //   ticks   —— CADisplayLink 每秒回调多少次(宿主显示器刷新率的上限)
    //   presents—— 真正提交给 Metal 的帧(= ticks 中「有新内容」的那部分)
    // presents 远低于 ticks 说明瓶颈在 guest/QEMU 侧,不在宿主绘制。
    private var nDamage = 0, nTick = 0, nPresent = 0
    private var statsSince = CFAbsoluteTimeGetCurrent()

    /// guest 光标位图。位置不用 guest 的,只用它的样子。
    private var guestCursor: NSCursor?
    /// 留一份原始位图:窗口换到不同缩放倍数的屏幕时要按新倍数重算尺寸
    private var lastCursorPixels: (w: Int, h: Int, hotX: Int, hotY: Int, pixels: Data)?

    /// agent 报来的 guest 逻辑光标形状。有它就说明 guest 侧的光标已被隐藏,
    /// 由宿主用原生 NSCursor 绘制 —— 位置走宿主坐标,完全不受 guest 帧率影响。
    private var hostCursorName: String?
    private var hostCursorShowing = true
    /// 最后一次收到形状上报的时刻。agent 掉线后要退回「guest 自绘」模式,
    /// 否则 guest 恢复画光标了,宿主还在画自己的,就会看到两个。
    private var hostCursorAt: CFTimeInterval = 0
    private var hostCursorExpiry: Task<Void, Never>?
    /// 是否曾经进入过宿主接管模式。用来区分两种「现在没有形状上报」:
    /// 从未接管(guest 自己画,宿主该隐藏)vs 接管过又断了
    /// (guest 的光标很可能还是透明的,宿主必须画点什么)。
    private var hostCursorEverActive = false
    private var cursorVisible = true
    /// 调试:强制用宿主原生箭头,便于与 guest 自绘光标比对延迟
    public var cursorDebug = false

    /// 拿不准 guest 到底画不画光标时,兜底显示宿主箭头。
    ///
    /// 最后那条 else 之所以敢把宿主光标藏掉,前提是「guest 自己画」。
    /// 从挂起状态恢复时这个前提不成立:guest 的系统光标在存盘前就被换成透明的了,
    /// 或者它用的是硬件光标而 QEMU 恢复后不会重新把位图推给显示后端 ——
    /// 两种情况下 guest 都不画,宿主又藏着,结果一个光标都没有。
    public var fallbackArrow = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.pixelFormat = .bgra8Unorm
    }
    public required init?(coder: NSCoder) { fatalError() }

    public func start(device: MTLDevice) {
        metalLayer.device = device
        commandQueue = device.makeCommandQueue()
        // 刷新跟随宿主显示器,而不是 QEMU 的固定定时器
        let link = displayLink(target: self, selector: #selector(tick))
        // 不设的话在 ProMotion 屏上可能被钉在 60Hz。给出完整区间,
        // 让系统按屏幕能力跑到最高。
        if let max = window?.screen?.maximumFramesPerSecond, max > 0 {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(max), maximum: Float(max), preferred: Float(max))
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// displayLink(target: self) 强持有 self,不 invalidate 这个视图永远不会释放。
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    public func markDirty() { needsPresent = true; nDamage += 1 }

    /// 视图尺寸变化时上报**物理像素**。
    ///
    /// 不走 NSWindowDelegate.windowDidResize:SwiftUI 会接管窗口的 delegate,
    /// 我们再去抢就会打架。视图自己上报在 AppKit 与 SwiftUI 下都成立。
    public var onResized: ((CGSize) -> Void)?
    /// 入窗时回调一次。窗口策略(最小尺寸、全屏、第一响应者)由会话统一设置,
    /// 视图自己不该决定这些。
    public var onWindowAttached: ((NSWindow) -> Void)?

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResized?(convertToBacking(bounds).size)
    }

    /// 入窗之后才能拿到屏幕刷新率与缩放倍数。
    ///
    /// 此前 start(device:) 在 contentView = view **之前**调用,那时 window 还是 nil,
    /// 于是 preferredFrameRateRange 从来没被设过 —— ProMotion 屏可能一直钉在 60Hz。
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        // 窗口失焦(Cmd+Tab 切走)时视图收不到修饰键的抬起事件,guest 会一直以为 Win 按着。
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        metalLayer.contentsScale = window.backingScaleFactor
        if let max = window.screen?.maximumFramesPerSecond, max > 0 {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(max), maximum: Float(max), preferred: Float(max))
        }
        onWindowAttached?(window)
        markDirty()
    }

    /// 取一次统计并清零
    public func takeStats() -> String {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.001, now - statsSince)
        let link = displayLink?.preferredFrameRateRange
        let s = String(format:
            "脏区 %.1f/s  显示回调 %.1f/s  实际出帧 %.1f/s  (取样 %.1fs,DisplayLink 上限 %.0f–%.0f Hz)",
            Double(nDamage) / dt, Double(nTick) / dt, Double(nPresent) / dt, dt,
            link?.minimum ?? 0, link?.maximum ?? 0)
        nDamage = 0; nTick = 0; nPresent = 0; statsSince = now
        return s
    }

    @objc private func tick() {
        nTick += 1
        guard needsPresent,
              let tex = framebuffer?.texture,
              let queue = commandQueue,
              let drawable = metalLayer.nextDrawable() else { return }
        needsPresent = false
        nPresent += 1

        guard let cmd = queue.makeCommandBuffer() else { return }
        let w = min(tex.width, drawable.texture.width)
        let h = min(tex.height, drawable.texture.height)
        // drawable 比 guest 画面大时(拖大窗口的瞬间),没盖到的那一条要清成黑的,
        // 否则那里是上一帧的残影。一个只清屏的空渲染通道就够。
        if w < drawable.texture.width || h < drawable.texture.height {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        guard let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    public func resizeSurface(width: Int, height: Int) {
        // 点对点的三个条件缺一不可:
        //   drawableSize   = guest 像素数
        //   contentsScale  = 屏幕缩放倍数
        //   bounds(点) × contentsScale = drawableSize
        // 前两个在这里保证,第三个由窗口尺寸驱动 guest 分辨率来保证。
        // contentsScale 不跟上的话,层会把 drawableSize 拉伸到
        // bounds×1 的尺寸上,Retina 下等于把画面缩掉一半再放大,全糊。
        metalLayer.contentsScale = window?.backingScaleFactor ?? metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: width, height: height)
        markDirty()
    }

    /// 窗口在不同缩放倍数的屏幕之间移动时(外接屏 ↔ 内置屏)要重新对齐
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let s = window?.backingScaleFactor else { return }
        metalLayer.contentsScale = s
        // 光标尺寸是按倍数换算出来的,换屏后要重算
        if let c = lastCursorPixels {
            setGuestCursor(w: c.w, h: c.h, hotX: c.hotX, hotY: c.hotY, pixels: c.pixels)
        }
        markDirty()
    }

    // MARK: 光标

    public func setGuestCursor(w: Int, h: Int, hotX: Int, hotY: Int, pixels: Data) {
        guard w > 0, h > 0 else { return }
        var data = pixels
        let img = data.withUnsafeMutableBytes { raw -> NSImage? in
            guard let provider = CGDataProvider(dataInfo: nil, data: raw.baseAddress!,
                                                size: raw.count, releaseData: { _, _, _ in }),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue:
                                        CGImageAlphaInfo.premultipliedFirst.rawValue |
                                        CGBitmapInfo.byteOrder32Little.rawValue),
                                   provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            // 尺寸单位必须是**点**,不是像素。
            //
            // guest 送来的位图是 w×h 个 **guest 像素**,而 guest 像素与屏幕物理
            // 像素是 1:1 的(点对点)。NSImage/NSCursor 的尺寸以点计,所以要除以
            // 屏幕缩放倍数。直接拿像素数当点数,在 2 倍屏上光标会画成两倍大 ——
            // 200% DPI 下 Windows 用 64px 光标,结果被画成 128 物理像素,巨大。
            // 热点同理,否则点击位置会偏。
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
        guard let image = img else { return }
        MainActor.assumeIsolated {
            let scale = window?.backingScaleFactor ?? 2
            image.size = NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
            guestCursor = NSCursor(image: image,
                                   hotSpot: NSPoint(x: CGFloat(hotX) / scale,
                                                    y: CGFloat(hotY) / scale))
            lastCursorPixels = (w, h, hotX, hotY, pixels)
            window?.invalidateCursorRects(for: self)
        }
    }

    public func setCursorVisible(_ on: Bool) {
        MainActor.assumeIsolated {
            cursorVisible = on
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 宿主最近一次发给 guest 的坐标 —— 用于与 guest 回报的位置比对,量化延迟
    private var lastSentPoint: (x: Int32, y: Int32, at: CFTimeInterval)?

    /// guest 报回它认为的光标位置。与我们发出的坐标比对即可得出往返延迟。
    public func reportGuestCursor(x: Int, y: Int) {
        guard cursorDebug, let sent = lastSentPoint else { return }
        let dx = Int(sent.x) - x, dy = Int(sent.y) - y
        if dx != 0 || dy != 0 {
            let ms = (CACurrentMediaTime() - sent.at) * 1000
            print(String(format: "[cursor] 滞后 %d,%d px  距上次发送 %.1f ms", dx, dy, ms))
        }
    }

    /// agent 上报的形状名 → 原生 NSCursor
    private static func cursor(named n: String) -> NSCursor {
        switch n {
        case "ibeam":    return .iBeam
        case "cross":    return .crosshair
        case "hand":     return .pointingHand
        case "no":       return .operationNotAllowed
        case "sizewe":   return .resizeLeftRight
        case "sizens":   return .resizeUpDown
        case "sizeall":  return .openHand
        case "up":       return .resizeUp
        // macOS 没有公开的对角缩放光标。用左右缩放顶着,形状不完全对,
        // 但比退回箭头更能表达「这里可以拖」。
        case "sizenwse", "sizenesw": return .resizeLeftRight
        // wait / appstarting / help 在 macOS 没有对应物,一律用箭头。
        default:         return .arrow
        }
    }

    public func setHostCursor(name: String, showing: Bool) {
        MainActor.assumeIsolated {
            let changed = hostCursorName != name || hostCursorShowing != showing
            hostCursorName = name
            hostCursorShowing = showing
            hostCursorAt = CACurrentMediaTime()
            hostCursorEverActive = true
            if changed { window?.invalidateCursorRects(for: self) }
            // 上报断了之后光标要退回箭头,但没人会再来 invalidate —— 定个 2 秒后的检查
            hostCursorExpiry?.cancel()
            hostCursorExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.1))
                guard !Task.isCancelled, let self, !hostCursorActive else { return }
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    /// agent 掉线或没开启接管时为 false
    private var hostCursorActive: Bool {
        hostCursorName != nil && CACurrentMediaTime() - hostCursorAt < 2.0
    }

    /// 供 state 命令查看当前光标接管状态
    public func setFallbackArrow(_ on: Bool) {
        MainActor.assumeIsolated {
            guard fallbackArrow != on else { return }
            fallbackArrow = on
            window?.invalidateCursorRects(for: self)
        }
    }

    public var cursorStatus: String {
        if hostCursorActive {
            return "宿主绘制/形状轮询(\(hostCursorName ?? "?"), 可见=\(hostCursorShowing))"
        }
        if hostCursorEverActive { return "上报已断,回退箭头" }
        if fallbackArrow && guestCursor == nil { return "兜底箭头(等 guest 接管确认)" }
        // 收到过位图 = guest 开了硬件光标:位图来自 guest,绘制由 macOS 完成
        if guestCursor != nil { return "硬件光标(guest 上报位图,macOS 绘制)" }
        return "guest 画进帧缓冲"
    }

    /// `deliberate` 表示这是用户主动切回 guest 绘制,而不是 agent 掉线。
    /// 两者的兜底不同:主动切回时 guest 会自己画,宿主必须完全让开;
    /// 掉线时 guest 的光标很可能还是透明的,宿主得留一个箭头。
    public func dropHostCursor(deliberate: Bool = false) {
        MainActor.assumeIsolated {
            hostCursorName = nil
            if deliberate { hostCursorEverActive = false }
            window?.invalidateCursorRects(for: self)
        }
    }

    public override func resetCursorRects() {
        // 用 guest 的光标样子,但由 macOS 绘制 —— 位置完全不经过 guest
        if cursorDebug {
            // 调试:保留宿主箭头,与 guest 自绘的光标并存,间距即延迟
            addCursorRect(bounds, cursor: .arrow)
        } else if hostCursorActive, let n = hostCursorName {
            // agent 已把 guest 的系统光标换成透明位图,这里画的是唯一的光标。
            // 位置来自宿主,不经过 guest,所以是 120Hz 且零往返。
            addCursorRect(bounds, cursor: hostCursorShowing ? Self.cursor(named: n)
                                                           : NSCursor.hidden)
        } else if hostCursorEverActive {
            // 接管过但上报断了:agent 多半没来得及还原系统光标,
            // guest 那边现在是透明的。多一个光标可以忍,一个都没有不行。
            addCursorRect(bounds, cursor: .arrow)
        } else if let c = guestCursor, cursorVisible {
            // guest 提供了硬件光标位图 —— 由 macOS 绘制,零延迟
            addCursorRect(bounds, cursor: c)
        } else if fallbackArrow {
            // 不确定 guest 画不画 —— 宁可多一个光标,也不能一个都没有
            addCursorRect(bounds, cursor: .arrow)
        } else {
            // guest 把光标画进了帧缓冲(viogpudo 不用硬件光标)。
            // 隐藏宿主箭头,否则会同时看到两个光标。
            addCursorRect(bounds, cursor: NSCursor.hidden)
        }
    }

    // MARK: 输入

    public override var acceptsFirstResponder: Bool { true }

    private func guestPoint(_ event: NSEvent) -> (Int32, Int32)? {
        guard let fb = framebuffer, fb.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let sx = CGFloat(fb.width) / bounds.width
        let sy = CGFloat(fb.height) / bounds.height
        let gx = Int32((p.x * sx).rounded())
        let gy = Int32(((bounds.height - p.y) * sy).rounded())   // AppKit 原点在左下
        return (max(0, min(gx, Int32(fb.width - 1))),
                max(0, min(gy, Int32(fb.height - 1))))
    }

    private func sendMotion(_ event: NSEvent) {
        guard let (x, y) = guestPoint(event) else { return }
        lastSentPoint = (x, y, CACurrentMediaTime())
        channel?.send(.mouseAbs, x, y)
    }

    public override func mouseMoved(with e: NSEvent)    { sendMotion(e) }
    public override func mouseDragged(with e: NSEvent)  { sendMotion(e) }
    public override func rightMouseDragged(with e: NSEvent) { sendMotion(e) }
    public override func otherMouseDragged(with e: NSEvent) { sendMotion(e) }

    public override func mouseDown(with e: NSEvent)  { pointerPressed(e); channel?.send(.mouseBtn, 0, 1) }
    public override func mouseUp(with e: NSEvent)    { sendMotion(e); channel?.send(.mouseBtn, 0, 0) }
    public override func rightMouseDown(with e: NSEvent) { pointerPressed(e); channel?.send(.mouseBtn, 2, 1) }
    public override func rightMouseUp(with e: NSEvent)   { sendMotion(e); channel?.send(.mouseBtn, 2, 0) }
    public override func otherMouseDown(with e: NSEvent) { pointerPressed(e); channel?.send(.mouseBtn, 1, 1) }

    /// 按下前先把挂起的 ⌘ 落实成 Super —— GNOME 的 Super+拖动移窗口要它
    private func pointerPressed(_ e: NSEvent) {
        sendMotion(e)
        send(commandKeys.pointerPressed())
    }
    public override func otherMouseUp(with e: NSEvent)   { sendMotion(e); channel?.send(.mouseBtn, 1, 0) }

    /// 触控板的精确滚动一次只有一两个像素,直接取整全丢掉 —— 表现为
    /// 「轻轻滑不动,稍快就跳」。这里把小数余量攒着,够一格才发一格。
    /// 手指换方向或新一轮手势开始时清零,免得反向时先把旧余量吐出来。
    private var scrollRemainder = CGPoint.zero

    public override func scrollWheel(with e: NSEvent) {
        if e.phase == .began || e.momentumPhase == .began { scrollRemainder = .zero }
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if e.hasPreciseScrollingDeltas { dx /= 10; dy /= 10 }
        if (dy != 0 && (dy < 0) != (scrollRemainder.y < 0)) { scrollRemainder.y = 0 }
        if (dx != 0 && (dx < 0) != (scrollRemainder.x < 0)) { scrollRemainder.x = 0 }
        scrollRemainder.y += dy
        scrollRemainder.x += dx
        let cy = scrollRemainder.y.rounded(.towardZero)
        let cx = scrollRemainder.x.rounded(.towardZero)
        scrollRemainder.y -= cy
        scrollRemainder.x -= cx
        if cy != 0 || cx != 0 { channel?.send(.scroll, Int32(cy), Int32(cx)) }
    }

    /// 当前按下的普通键。窗口失焦时要把它们全部抬起,否则 guest 里那个键就一直按着。
    private var pressedKeys = Set<Int32>()
    /// ⌘ 何时当 Ctrl、何时当 Super,见 CommandKeys.swift
    private var commandKeys = CommandKeyTranslator()

    private func send(_ events: [CommandKeyTranslator.Event]) {
        for ev in events { channel?.send(.key, ev.code, ev.down ? 1 : 0) }
    }

    public override func keyDown(with e: NSEvent) {
        // 按住不放时 macOS 会连发 keyDown。guest 自己有重复逻辑,连发只会把通道刷满。
        guard !e.isARepeat else { return }
        let q = qcode(for: e.keyCode)
        pressedKeys.insert(q)
        send(commandKeys.keyDown(q))
    }
    public override func keyUp(with e: NSEvent) {
        let q = qcode(for: e.keyCode)
        pressedKeys.remove(q)
        send(commandKeys.keyUp(q))
    }

    /// Cmd 组合键截下来发给 guest,而不是交给 macOS 的菜单。
    ///
    /// guest 里 Cmd 就是 Win 键:不截的话 Win+Q 会退出整个应用并挂起所有虚拟机,
    /// Win+W 关窗口,Win+H 把窗口藏起来。Ctrl+Cmd 的组合留给宿主
    /// (Ctrl+Cmd+F 全屏之类),这样键盘上仍有一条路能碰到 macOS。
    /// 只在本视图是第一响应者时生效 —— 弹出面板里的输入框不受影响。
    public override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard Preferences.captureCommandKey, e.type == .keyDown,
              window?.firstResponder === self,
              e.modifierFlags.contains(.command),
              !e.modifierFlags.contains(.control) else {
            // 这个 ⌘ 组合归宿主了(⌃⌘F 之类,或者关掉了截获):⌘ 抬起时别再给 guest 补一次单击
            if e.type == .keyDown, e.modifierFlags.contains(.command) { commandKeys.hostHandledShortcut() }
            return false
        }
        keyDown(with: e)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        releaseAllKeys()
        return super.resignFirstResponder()
    }

    @objc private func windowResignedKey() { releaseAllKeys() }

    /// 焦点离开时把 guest 里所有按着的键都抬起。
    private func releaseAllKeys() {
        for q in pressedKeys { send(commandKeys.keyUp(q)) }
        pressedKeys.removeAll()
        for (flag, code) in Self.modifierMap where lastFlags.contains(flag) {
            channel?.send(.key, code, 0)
        }
        send(commandKeys.releaseAll())
        commandKeys.physicalControl = false
        lastFlags = []
    }

    /// 调试:按 `cmd+shift+v` 这样的写法造一组 NSEvent,依次走 flagsChanged / performKeyEquivalent
    /// (不收就 keyDown)/ keyUp / flagsChanged,与真按键同一条路径。出错返回原因。
    public func debugHostKey(_ spec: String) -> String? {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, key.count == 1, let ch = key.first else { return "用法: hostkey cmd+shift+v" }
        let letters: [Character: UInt16] = ["a": 0x00, "c": 0x08, "e": 0x0E, "v": 0x09, "x": 0x07, "z": 0x06]
        guard let keyCode = letters[ch] else { return "只支持 a c e v x z" }
        var flags: NSEvent.ModifierFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            case "alt": flags.insert(.option)
            default: return "不认识的修饰键 \(m)"
            }
        }
        func ev(_ type: NSEvent.EventType, _ f: NSEvent.ModifierFlags, _ code: UInt16) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window?.windowNumber ?? 0, context: nil,
                             characters: type == .flagsChanged ? "" : String(ch),
                             charactersIgnoringModifiers: type == .flagsChanged ? "" : String(ch),
                             isARepeat: false, keyCode: code)
        }
        guard let fDown = ev(.flagsChanged, flags, 0x37), let kDown = ev(.keyDown, flags, keyCode),
              let kUp = ev(.keyUp, flags, keyCode), let fUp = ev(.flagsChanged, [], 0x37) else { return "NSEvent 造不出来" }
        flagsChanged(with: fDown)
        if !performKeyEquivalent(with: kDown) { keyDown(with: kDown) }
        keyUp(with: kUp)
        flagsChanged(with: fUp)
        return nil
    }

    /// ⌘ 不在表里:它交给 commandKeys,按下时不一定立刻发
    private static let modifierMap: [(NSEvent.ModifierFlags, Int32)] = [
        (.shift, QKeyCode.shift), (.control, QKeyCode.ctrl), (.option, QKeyCode.alt),
    ]

    public override func flagsChanged(with e: NSEvent) {
        for (flag, code) in Self.modifierMap where e.modifierFlags.contains(flag) != lastFlags.contains(flag) {
            channel?.send(.key, code, e.modifierFlags.contains(flag) ? 1 : 0)
        }
        commandKeys.physicalControl = e.modifierFlags.contains(.control)
        if e.modifierFlags.contains(.command) != lastFlags.contains(.command) {
            let down = e.modifierFlags.contains(.command)
            if down { commandKeys.enabled = Preferences.commandAsControl }
            send(commandKeys.commandChanged(down: down))
        }
        // Caps Lock 在 macOS 上没有 keyDown,只有这个标志位的翻转,而且翻转的是锁定状态
        // 不是按键状态。宿主每翻一次就给 guest 按一下,两边的锁定状态才同步。
        if e.modifierFlags.contains(.capsLock) != lastFlags.contains(.capsLock) {
            channel?.send(.key, QKeyCode.capsLock, 1)
            channel?.send(.key, QKeyCode.capsLock, 0)
        }
        lastFlags = e.modifierFlags
    }
    private var lastFlags: NSEvent.ModifierFlags = []

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
}

