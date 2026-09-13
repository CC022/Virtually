// USB 设备透传(M7)。
//
// 枚举走 **IOKit**,不用 system_profiler。
//
// 原因是实测出来的:`system_profiler SPUSBDataType` 在这台 Mac 上返回**空数组**,
// 连纯文本模式都没有任何输出,插上相机也一样;而 IOKit 同时看得见 34 个设备。
// 另外枚举要能频繁刷新以反映热插拔,spawn 一个 1–3 秒的进程本来也做不到。
//
// 注意这与「libusb 还是自写 IOKit 后端」那个决定不冲突:那说的是**传输**,
// 这里只是**枚举**,不涉及任何 USB 事务。

import Foundation
import IOKit
import IOKit.usb

public struct USBDevice {
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let vendorName: String
    /// IOKit 的 locationID:编码了设备插在哪条总线的哪个端口上。
    /// 两只同型号的加密狗 VID:PID 一样,只有它能区分。高 8 位就是 libusb 眼里的 bus number。
    public let locationID: Int?
    /// 总线上的设备地址,libusb 的 device_address。与 locationID 高 8 位一起对应
    /// QEMU usb-host 的 hostbus / hostaddr。
    public let address: Int?
    /// 为什么大概率透传不了;nil 表示看起来可以透传。
    ///
    /// macOS 会自动把 HID、大容量存储、音频、网卡这些类的设备匹配给内核驱动并独占打开,
    /// 之后用户态(libusb 也好、直接调 IOKit 也好)都拿不到它。要突破这一层只能随 app
    /// 附带 DriverKit 扩展抢在系统驱动之前匹配,那需要 Apple 特批的 entitlement,
    /// 不在当前范围内。所以这里只做**预判并说明原因**,而不是让用户去试一个注定失败的设备。
    public let blockedReason: String?

    public var idString: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// 列表与透传状态用的唯一键。有 locationID 就按插口区分,没有退回 VID:PID。
    public var key: String {
        if let loc = locationID { return String(format: "%04x:%04x@%08x", vendorID, productID, loc) }
        return idString
    }

    public var hostBus: Int? { locationID.map { ($0 >> 24) & 0xff } }

    public init(name: String, vendorID: Int, productID: Int, vendorName: String, locationID: Int? = nil, address: Int? = nil, blockedReason: String? = nil) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.vendorName = vendorName
        self.locationID = locationID
        self.address = address
        self.blockedReason = blockedReason
    }
}

public enum USBEnumerator {

    /// USB 设备类代码 9 = 集线器
    private static let hubDeviceClass = 9

    /// 名字里出现这些词的设备,macOS 基本都已经绑给内核驱动了。
    /// 按类别给出不同的说明,因为用户能做的事不一样。
    private static let blockedByClass: [(keywords: [String], reason: String)] = [
        (["Keyboard", "Mouse", "Trackpad", "Touch Bar", "键盘", "鼠标"],
         "键盘、鼠标等输入设备由 macOS 独占使用"),
        (["Headset", "Audio", "Microphone", "Speaker", "音频"],
         "音频设备由 macOS 独占使用"),
        (["Ethernet", "LAN", "Wi-Fi", "网卡"],
         "网络设备由 macOS 独占使用"),
        (["Camera", "FaceTime", "iSight", "摄像"],
         "摄像头由 macOS 独占使用"),
        (["Bluetooth", "Ambient Light", "Display", "Studio Display"],
         "Mac 内置或显示器自带的设备无法连接到虚拟机"),
    ]

    /// USB 接口类 → 被 macOS 内核驱动占用的原因。
    ///
    /// 按**接口类**判定,不靠名字猜。实测教训:一只 Razer 鼠标叫
    /// "DeathAdder V4 Pro",名字里没有 Mouse/Keyboard 任何关键词,
    /// 于是被名字匹配判成「可透传」—— 而它显然是 HID,macOS 早就占住了。
    /// 设备名是厂商随便起的,接口类才是协议事实。
    public static func reasonForInterfaceClass(_ cls: Int) -> String? {
        switch cls {
        case 1:       return "音频设备由 macOS 独占使用"
        // 2/10 是 CDC:CDC-ACM 串口(Arduino、ST-Link 的 VCP、大多数调试器)和 CDC 网卡都在这里。
        // macOS 会给它们绑 AppleUSBACM / 网卡驱动,用户态一样抢不到。
        // 别写成「网卡类」—— 用户手里的多半是块调试器,看到「网卡」只会困惑。
        case 2, 10:   return "串口或网络设备由 macOS 独占使用"
        case 3:       return "键盘、鼠标等输入设备由 macOS 独占使用"
        case 6:       return "相机设备由 macOS 独占使用"
        case 7:       return "打印机由 macOS 独占使用"
        case 8:       return "磁盘已被 macOS 装载，请先在访达中推出"
        case 9:       return "USB 集线器无法连接到虚拟机"
        case 14:      return "摄像头由 macOS 独占使用"
        case 224:     return "蓝牙设备由 macOS 独占使用"
        default:      return nil          // 0xFF 厂商自定义等:通常没有内核驱动匹配
        }
    }

    /// 单独抽出来是为了能在自检里直接验 —— 枚举本身依赖真实硬件,分类逻辑不该也依赖。
    ///
    /// 优先用接口类;拿不到接口类时(复合设备的某些形态)才退回名字匹配。
    public static func blockedReason(name: String, deviceClass: Int?,
                              interfaceClasses: [Int] = []) -> String? {
        if deviceClass == hubDeviceClass { return "USB 集线器无法连接到虚拟机" }
        for cls in interfaceClasses {
            if let r = reasonForInterfaceClass(cls) { return r }
        }
        if let deviceClass, let r = reasonForInterfaceClass(deviceClass) { return r }
        return blockedByClass.first { entry in
            entry.keywords.contains { name.localizedCaseInsensitiveContains($0) }
        }?.reason
    }

    public static func isHub(name: String, deviceClass: Int?) -> Bool {
        if deviceClass == hubDeviceClass { return true }
        return name.localizedCaseInsensitiveContains("Hub") || name.contains("集线器")
    }

    public static func devices() -> [USBDevice] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [USBDevice] = []
        var seen = Set<String>()

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let vid = intProperty(service, "idVendor"),
                  let pid = intProperty(service, "idProduct") else { continue }
            let name = stringProperty(service, "USB Product Name")
                    ?? stringProperty(service, "kUSBProductString")
                    ?? "未知设备"
            let vendor = stringProperty(service, "USB Vendor Name")
                      ?? stringProperty(service, "kUSBVendorString") ?? ""
            let deviceClass = intProperty(service, "bDeviceClass")

            // 集线器不显示(透传没有意义,只会把列表撑长),但它下面挂的设备
            // 在 IOKit 里是平铺枚举的,不会因此丢掉。
            if isHub(name: name, deviceClass: deviceClass) { continue }

            let device = USBDevice(
                name: name, vendorID: vid, productID: pid,
                vendorName: vendor.trimmingCharacters(in: .whitespaces),
                locationID: intProperty(service, "locationID"),
                address: intProperty(service, "USB Address"),
                blockedReason: blockedReason(name: name, deviceClass: deviceClass,
                                             interfaceClasses: interfaceClasses(of: service)))
            // 同一个物理设备可能有多个 IOUSBHostDevice 条目(复合设备),按插口去重。
            // 以前按 VID:PID 去重,两只一样的加密狗只显示一只,第二只也插不进去。
            guard seen.insert(device.key).inserted else { continue }
            out.append(device)
        }
        return out.sorted { $0.name < $1.name }
    }

    /// 复合设备的 bDeviceClass 是 0,真正的类在各个接口上,所以要往下看一层。
    private static func interfaceClasses(of device: io_service_t) -> [Int] {
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }

        var classes: [Int] = []
        while true {
            let child = IOIteratorNext(iter)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            if let c = intProperty(child, "bInterfaceClass") { classes.append(c) }
        }
        return classes
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                       kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return cf.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString,
                                        kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

/// 热插拔通知。设备插上或拔掉时回调,列表不用靠手动刷新。
///
/// IOKit 的匹配通知要挂在 run loop 上,这里挂主 run loop;回调里必须把迭代器读空,
/// 否则同一通知不会再来。
public final class USBWatcher {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    public var onChange: (() -> Void)?

    public init() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // 读空迭代器:这是重新武装通知的条件
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            // matching 字典会被 IOServiceAddMatchingNotification 消费,每次要新建
            guard let matching = IOServiceMatching("IOUSBHostDevice"),
                  IOServiceAddMatchingNotification(port, kind, matching, callback, me, &it) == KERN_SUCCESS
            else { continue }
            // 首次调用要把已有设备读空,通知才会武装
            while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
            iterators.append(it)
        }
    }

    deinit {
        for it in iterators { IOObjectRelease(it) }
        if let port { IONotificationPortDestroy(port) }
    }
}

extension QMPClient {
    /// QOM id 里带上插口,两只同型号设备才能各有各的 id(重复 id 会被 device_add 拒绝)。
    public static func usbDeviceID(_ d: USBDevice) -> String {
        if let loc = d.locationID {
            return String(format: "usbhost_%04x_%04x_%08x", d.vendorID, d.productID, loc)
        }
        return String(format: "usbhost_%04x_%04x", d.vendorID, d.productID)
    }

    /// 热插入一台宿主 USB 设备。
    ///
    /// 走 qemu-xhci 的 usb.0 总线 —— USB 总线本身支持热插拔,
    /// 不像 PCIe 根总线那样需要预留根端口。
    ///
    /// 匹配条件除了 vendorid/productid 还带 hostbus/hostaddr(host-libusb.c 的
    /// usb_host_open 会把四个条件一起比),否则两只一样的设备 QEMU 永远抓到第一只。
    public func attachUSB(_ d: USBDevice) async -> String? {
        var args: [String: Any] = [
            "driver": "usb-host",
            "id": Self.usbDeviceID(d),
            "bus": "usb.0",
            "vendorid": d.vendorID,
            "productid": d.productID,
        ]
        if let bus = d.hostBus, let addr = d.address {
            args["hostbus"] = bus
            args["hostaddr"] = addr
        }
        return Self.errorText(await execute("device_add", arguments: args))
    }

    public func detachUSB(_ d: USBDevice) async -> String? {
        Self.errorText(await execute("device_del", arguments: ["id": Self.usbDeviceID(d)]))
    }

    /// 插一个**模拟**的 USB 鼠标,用来验证 QMP 热插拔通路本身。
    ///
    /// 在 macOS 上没法凭空造一个宿主侧虚拟 USB 设备给 libusb 看见
    /// (那要 DriverKit 扩展和 Apple 特批的 entitlement),
    /// 但模拟设备走的是**完全相同**的 device_add 路径,差别只在后端是模拟还是 libusb。
    /// 所以它能验掉除 libusb 本身之外的整条链路。
    public func attachTestUSBDevice() async -> String? {
        Self.errorText(await execute("device_add", arguments: [
            "driver": "usb-mouse", "id": "usbtest0", "bus": "usb.0",
        ]))
    }

    public func detachTestUSBDevice() async -> String? {
        Self.errorText(await execute("device_del", arguments: ["id": "usbtest0"]))
    }
}
