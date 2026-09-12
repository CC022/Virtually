# USB 透传(M7)

## 两条完全不同的路

| | 靠什么工作 | 需要 libusb |
|---|---|---|
| `usb-storage` / `usb-tablet` / `usb-kbd` | QEMU 用软件**合成**设备行为 | 否 |
| `usb-host` | 把宿主上**真实存在**的设备转发给 guest | 是 |

工具盘、传输盘走的是第一条,从来不需要 libusb。绝对坐标鼠标(`usb-tablet`)也是。

## 为什么是 libusb 而不是自写 IOKit 后端

考虑过「只跑 macOS,自己写个 IOKit 后端更简洁」。读完源码后结论相反:

- `hw/usb/host-libusb.c` 共 **1964 行,其中真正调用 libusb API 的只有 142 行(7%)**
- 其余 93% 是端点解析与映射、`USBPacket` 异步状态机、请求取消与流控、
  isochronous 分包、错误码转换、QOM 属性与 vmstate ——
  **换成任何底层 API 都一行省不掉**
- 主循环接入是决定性的:libusb 通过 `libusb_get_pollfds()` 暴露内部 fd,
  QEMU 用 `qemu_set_fd_handler()` 直接挂上(`host-libusb.c:246-308`)。
  IOKit 的异步完成走 `IONotificationPortRef` / CFRunLoopSource,拿不到可 poll 的 fd,
  必须自己起一条跑 CFRunLoop 的线程再用 bottom-half 跨线程送回主循环 ——
  这是整件事里最容易出隐蔽 bug 的部分,而 libusb 免费解决

QEMU 里 `usb-host` 只有这一个实现,`hw/usb/meson.build:86` 也只有这一个分支。
早年那份 Linux 专用的 usbfs 实现多年前已删除。

旁证:UTM.app 同样打包 libusb(`usb-1.0.0.framework`,356KB)。

## 构建

```
ThirdParty/qemu/build-deps.sh   # libusb 1.0.27 与其他依赖一起编进 sysroot
ThirdParty/qemu/build.sh
```

判据:`qemu-system-aarch64 -device help | grep usb-host` 有输出。

**踩过的坑**:`build.sh` 原先只在 `build.ninja` 不存在时才 configure,
于是事后往 sysroot 里加了 libusb、重跑脚本、构建成功,而 `usb-host` 依然不存在 ——
新依赖被静默忽略了。现在脚本会检查 `build.ninja` 里有没有 `host-libusb` 的编译规则,
不一致就自动重新 configure。

## macOS 上的能力边界

设备要交给用户态,宿主内核驱动必须先放手。macOS 会自动把 **HID(键鼠)、
音频、网卡**这些类的设备绑给内核驱动并独占打开,无论用 libusb 还是直接调 IOKit
都抢不到。要突破只能随 app 附带 DriverKit 扩展抢在系统驱动之前匹配,
那需要 Apple 特批的 `com.apple.developer.driverkit.transport.usb`,不在当前范围。

**能透传的是没有匹配内核驱动的设备**:加密狗、安全密钥、调试器、自定义硬件。
这也正是当前的目标设备,所以不需要 DriverKit。

`VirtuallyKit/USB/USB.swift` 会按设备名预判并说明原因,而不是让用户去试一个注定失败的设备;
集线器直接不显示(没有透传意义,只会撑长列表),挂在它下面的设备照常递归展开。

## 用法

```
usb list            列出可透传的设备
usb attach <序号>   热插进 guest
usb detach <序号>   拔出
```

走 QMP 的 `device_add` / `device_del`,**不需要重启虚拟机**。
匹配用 `vendorid` / `productid` 加 `hostbus` / `hostaddr`:后两个来自 IOKit 的 `locationID`
(高 8 位就是 libusb darwin 后端的 bus number)与 `USB Address`。
没有它们,两只同型号的加密狗 QEMU 永远抓到第一只,QOM id 也会重复。
列表与透传状态按 `USBDevice.key`(VID:PID@locationID)区分。

透传状态存在 `VMSession.attachedUSB` 里,不在面板的 @State 里 —— 面板关了再开要对得上。
QEMU 的 `DEVICE_DELETED` 事件会同步这份状态。存快照与挂起前会自动把透传设备全部拔掉,
原因见 `SNAPSHOTS.md`。
