// 共享帧缓冲 → Metal 纹理,零拷贝。
// mmap 共享文件 → MTLBuffer(bytesNoCopy:) → MTLTexture,Apple Silicon 统一内存下
// GPU 直接读的就是 QEMU 写入的那块内存。缩略图也从这里抓。

import AppKit
import Metal
import QuartzCore
import Darwin

// MARK: - 共享帧缓冲 → Metal 纹理(零拷贝)

public final class Framebuffer {
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var stride = 0
    public private(set) var texture: MTLTexture?

    private var map: UnsafeMutableRawPointer?
    private var mapLen = 0
    private var buffer: MTLBuffer?
    private let device: MTLDevice
    private let path: String

    public init(device: MTLDevice, path: String) {
        self.device = device
        self.path = path
    }

    /// 把共享文件映射成 MTLBuffer,再在其上建纹理 —— 两步都不拷贝像素。
    /// Apple Silicon 统一内存下,GPU 直接读的就是 QEMU 写入的那块内存。
    public func remap(width: Int, height: Int, stride: Int) {
        // 尺寸未变则不重建 —— 重建 MTLBuffer/纹理是白费,
        // 且与 QEMU 侧复用同一块共享内存的前提一致
        if width == self.width, height == self.height,
           stride == self.stride, texture != nil {
            return
        }
        release()
        let pageSize = Int(getpagesize())
        let needed = stride * height
        mapLen = (needed + pageSize - 1) / pageSize * pageSize

        let fd = open(path, O_RDWR)
        guard fd >= 0 else { print("[fb] 打开失败 \(path)"); return }
        defer { close(fd) }

        guard let m = mmap(nil, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              m != MAP_FAILED else {
            print("[fb] mmap 失败"); return
        }
        map = m

        guard let buf = device.makeBuffer(bytesNoCopy: m, length: mapLen,
                                          options: .storageModeShared, deallocator: nil) else {
            print("[fb] makeBuffer 失败"); return
        }
        buffer = buf

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        texture = buf.makeTexture(descriptor: desc, offset: 0, bytesPerRow: stride)
        if texture == nil {
            print("[fb] makeTexture 失败 (stride=\(stride) 可能未按 GPU 要求对齐)")
        }

        self.width = width; self.height = height; self.stride = stride
        print("[fb] 映射 \(width)x\(height) stride=\(stride) 零拷贝纹理=\(texture != nil)")
    }

    /// QEMU 退出且缩略图抓完之后调用。不释放的话每开一次虚拟机就漏一段共享映射。
    public func release() {
        texture = nil
        buffer = nil
        if let m = map { munmap(m, mapLen); map = nil }
        width = 0; height = 0; stride = 0
    }

    // MARK: 抓图
    //
    // 共享内存里是 BGRA8,每行 stride 字节。转 CGImage 的写法与本文件
    // setGuestCursor 里那段一致,两处不同:bytesPerRow 用 stride(不是 w*4),
    // alpha 用 noneSkipFirst —— 帧缓冲的 A 通道是废的,当成 premultiplied
    // 会把整幅画面按垃圾 alpha 重算一遍。

    /// 当前画面的等比缩略图。**必须画进新的位图**:原图直接指向 QEMU 还在写的
    /// 共享内存,留着它等于留一个随时会变、还会被 munmap 掉的指针。
    public func snapshot(maxWidth: Int) -> CGImage? {
        guard let m = map, width > 0, height > 0 else { return nil }
        guard let provider = CGDataProvider(dataInfo: nil, data: m, size: stride * height,
                                            releaseData: { _, _, _ in }),
              let full = CGImage(width: width, height: height,
                                 bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.noneSkipFirst.rawValue |
                                    CGBitmapInfo.byteOrder32Little.rawValue),
                                 provider: provider, decode: nil,
                                 shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        let w = min(maxWidth, width)
        let h = max(1, Int((Double(w) * Double(height) / Double(width)).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 近乎纯色就当没内容。guest 息屏时 QEMU 写的是
    /// "Display output is not active" 那张几乎全黑的图 —— 存下来还不如留着上一张。
    public static func looksBlank(_ cg: CGImage) -> Bool {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return true }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                                  CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return true }

        var lo = (b: 255, g: 255, r: 255), hi = (b: 0, g: 0, r: 0)
        // 不能写 stride(from:to:by:) —— 本类有个同名属性 stride,会被解析到它身上
        for n in 0 ..< (side * side) {
            let i = n * 4
            let b = Int(pixels[i]), g = Int(pixels[i + 1]), r = Int(pixels[i + 2])
            lo = (min(lo.b, b), min(lo.g, g), min(lo.r, r))
            hi = (max(hi.b, b), max(hi.g, g), max(hi.r, r))
        }
        // 阈值 12:够挡住纯黑与那行小字,又不会把深色桌面壁纸误判成空白
        return (hi.b - lo.b) < 12 && (hi.g - lo.g) < 12 && (hi.r - lo.r) < 12
    }
}

