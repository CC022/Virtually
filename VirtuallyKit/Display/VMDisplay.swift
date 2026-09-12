// guest 显示尺寸的边界与钳制。
//
// 纯值逻辑,与运行时状态无关,测试直接覆盖它。

import Foundation

public enum VMDisplay {
    public static let minWidth: CGFloat = 800
    public static let minHeight: CGFloat = 600
    public static let maxWidth: CGFloat = 7680
    public static let maxHeight: CGFloat = 4320

    /// viogpudo 对**动态**分辨率有总像素上限,实测边界:
    ///   4096x2688 = 11.01M  可以
    ///   4480x2520 = 11.29M  不行
    /// 上限恰好落在 5120x2160 = 11.06M 附近 —— 也就是它内置模式表里最大的一项,
    /// 看起来是按那一档的显存预算卡的。取 11.0M 留一点余量。
    ///
    /// 超过就等比缩小。宁可整体略微放大一点点,也不要退回模式表里长宽比不对的
    /// 那一档(5K 屏全屏时会退成 21:9,画面直接变形)。
    public static let maxPixels: CGFloat = 11_000_000

    public static func clamp(_ s: CGSize) -> CGSize {
        var w = min(max(s.width.rounded(),  minWidth),  maxWidth)
        var h = min(max(s.height.rounded(), minHeight), maxHeight)
        let area = w * h
        if area > maxPixels {
            let k = (maxPixels / area).squareRoot()
            w = max(minWidth,  (w * k).rounded(.down))
            h = max(minHeight, (h * k).rounded(.down))
        }
        return CGSize(width: w, height: h)
    }
}
