// guest 显示尺寸的边界与钳制。
//
// 纯值逻辑,与运行时状态无关,测试直接覆盖它。

import Foundation

public enum VMDisplay {
    public static let minWidth: CGFloat = 800
    public static let minHeight: CGFloat = 600
    public static let maxWidth: CGFloat = 7680
    public static let maxHeight: CGFloat = 4320

    /// guest 分辨率的总像素上限:5K 屏全屏(5120x2880)。
    ///
    /// 这不是随手定的,是两层限制放开之后的结果(详见 docs/DISPLAY.md):
    ///   1. viogpudo 在驱动启动时按「模式表里最大的一档」分配一次帧缓冲段,之后超过就回
    ///      DISP_CHANGE_BADMODE。模式表来自 QEMU 的 EDID,最大 5120x2160。宿主经 agent 在
    ///      设备注册表写 PersistentDispMode0Width/Height = 5120x2880,重启后段就够大(见 DisplayMemory.swift)
    ///   2. QEMU 2D 模式的控制队列只有 64,viogpudo 挂 5K 帧缓冲的内存要 59 个描述符,塞不进去。
    ///      patches/0003 改成 256
    /// Linux 的 virtio-gpu 内核驱动没有第 1 层限制。
    public static let maxPixels: CGFloat = 5120 * 2880

    /// 没重启过、注册表还没生效的 Windows 的上限:段按 5120x2160 分的,取 11.0M 留一点余量。
    /// 实测 4096x2688 = 11.01M 可以,4480x2520 = 11.29M 不行。
    ///
    /// 超过上限一律等比缩小。宁可整体略微放大一点点,也不要退回模式表里长宽比不对的
    /// 那一档(5K 屏全屏时会退成 21:9,画面直接变形)。
    public static let legacyMaxPixels: CGFloat = 11_000_000

    public static func clamp(_ s: CGSize, maxPixels budget: CGFloat = maxPixels) -> CGSize {
        var w = min(max(s.width.rounded(),  minWidth),  maxWidth)
        var h = min(max(s.height.rounded(), minHeight), maxHeight)
        let area = w * h
        if area > budget {
            // 缩出来的宽高向下取**偶数**:2 倍屏上窗口只能是整数个点,奇数像素换算回去差半个点,
            // 窗口贴合 guest 时就差 1 个像素 —— 整幅画面又得重新采样(实测 4690x2345 → 窗口 2346 高)
            let k = (budget / area).squareRoot()
            w = max(minWidth,  ((w * k) / 2).rounded(.down) * 2)
            h = max(minHeight, ((h * k) / 2).rounded(.down) * 2)
        }
        return CGSize(width: w, height: h)
    }
}
