# 显示分辨率上限

guest 分辨率跟随窗口的物理像素（点对点），总像素上限是 **5120×2880**（`VMDisplay.maxPixels`），
即 5K 屏全屏。超过就等比缩小（宽高取偶数），由 CAMetalLayer 放大铺满窗口，画面会发软。

以前上限只有约 1100 万像素，在 5K 屏上窗口一开大就糊。原因是下面两层限制叠在一起，现在两层都放开了。

## 第 1 层：viogpudo 的帧缓冲段（Windows）

证据来自 viogpudo 源码（virtio-win `viogpu/viogpudo/viogpudo.cpp`、`viogpu/common/viogpu_queue.cpp`）加实测：

- `VioGpuAdapter::HWInit` 在**驱动启动时只分配一次** `m_FrameSegment`，大小取以下几项的最大值：
  - 16MB
  - 启动时画面的字节数
  - PCI BAR0 的大小
  - **当时模式表里最大那一档的像素数 × 4**
- 之后每次改分辨率，`IsSupportedVidPn` 拿「宽 × 高 × 4」和段大小比，超过就拒绝，agent 收到 `setres rc=-2`。
- 模式表来自 QEMU 的 EDID，外加一档「自定义模式」。EDID 里最大的是 5120×2160（CTA VIC 125），
  段就是 44,236,800 字节，和实测边界完全吻合：4096×2688 可以，4480×2520 不行。
- 改 EDID 没用：viogpudo 的 VIC 表只认 1 到 127（最大就是 5120×2160），也不从详细时序块里读分辨率。
- **能用的开关**：`BuildModeList` 会读设备注册表键下的 `PersistentDispMode0Width` 和 `PersistentDispMode0Height`，
  把它们当成自定义模式并入模式表。写成 5120×2880，**重启 Windows 后**段就是 58,982,400 字节。

宿主怎么做（`VirtuallyKit/Display/DisplayMemory.swift`）：
- agent 上线 15 秒后，经 `exec` 检查并写入这两个值。设备键由 `DEVPKEY_Device_Driver` 定位，序号不固定。
- 已经不小于目标就不动。协议没有改动，和扩分区同一套做法，已经装好的机器直接可用。

**写入后还没重启**的会话里，超过旧上限的请求会被拒。`VMSession.handleResolutionFailure` 的处理：
1. 退回旧上限 `VMDisplay.legacyMaxPixels`（1100 万）；
2. 先切到模式表里预算之内的一档；
3. 成功后再请求等比缩小的尺寸。

第 2 步不能省。实测被拒之后直接请求缩小的尺寸，会连续两次 `rc=-2`，Windows 要先成功提交一次模式，才重新接受自定义尺寸。
不能退到模式表里的 5120×2160 就停下，那一档长宽比不对，画面会变形。

开机时不会被撑到 5120×2880。实测重启后依次是 640×480（固件）→ 宿主上次请求的尺寸 → Windows 自己选的尺寸。

## 第 2 层：QEMU 的 virtio-gpu 控制队列（Windows）

- 帧缓冲段够大之后，5120×2700、5120×2880 仍然失败：驱动建了资源，却**没发** `RESOURCE_ATTACH_BACKING`，
  QEMU 报 `virtio_gpu_set_scanout: no backing storage`，画面映射不出来。
- 原因：viogpudo 挂内存时，每个页条目 16 字节，每 4K 条目占一个描述符，而且**不用间接描述符**
  （`CtrlQueue::QueueBuffer` → `AddBuf(..., NULL, 0)`）。5120×2880 共 14,400 页，要 57 个数据描述符，加上头和回复共 59 个。
  QEMU 2D 模式的控制队列只有 **64**（3D 模式是 256），队列里只要还有几条命令没回来就塞不进去，驱动不重试。
- 修法：`patches/0002-virtio-gpu-ctrl-queue.patch` 把 2D 控制队列改成 256。
- 快照兼容：`vring.num` 随迁移流保存（`virtio_save` / `virtio_load`）。旧 QEMU 存的挂起状态恢复后仍是 64，
  和 guest 里驱动已分配的环形缓冲区一致；冷启动后驱动才用上 256。

QEMU 里还有两处限制，5K 都碰不到，要支持 6K（6016×3384）时再看：
- 单次挂内存最多 16384 个条目（`virtio_gpu_create_mapping_iov`），折合约 1670 万像素；
- `max_hostmem` 默认 256MB。

## Linux

virtio-gpu 内核驱动没有第 1 层限制，而且用间接描述符。实测新 QEMU 冷启动后 5120×2880 正常，旧挂起状态恢复后改分辨率也正常。

## 排查方法

调试通道的 `hmp` 命令把一行 HMP 转发给 QEMU，输出进 `/tmp/virtually-qemu.log`：

```
Scripts/ctl.sh send hmp log guest_errors
Scripts/ctl.sh send "hmp trace-event virtio_gpu_cmd_* on"
```

用 `uiinfo W H` 加 `setres W H` 直接请求某个尺寸时要注意：guest 一改分辨率，宿主就让窗口跟随，
接着按窗口大小再发一次请求，会盖掉手动请求的尺寸。看 trace 里 `res_create_2d` 实际建了多大的资源。

## 实测（2026-09-13，Studio Display 5K，Windows 11 25H2 与 Ubuntu 26.04.1 的克隆）

| 场景 | 结果 |
|---|---|
| 旧设置（段 44MB、队列 64）：4480×2520 | `rc=-2`，QEMU 没收到任何命令 |
| 写注册表并重启，队列仍是 64：4480×2520 | 成功 |
| 同上：5120×2700、5120×2880 | 驱动接受，但没发挂内存命令，`no backing storage` |
| 注册表加队列 256：边晃鼠标边在 5120×2880、4480×2520、5120×2700、3200×1920 之间切 6 次 | 全部成功，截图 1:1 清楚 |
| 新宿主逻辑，写入后未重启，窗口开到最大 | 5120×2560 被拒 → 切 4096×2160 → 4690×2345 成功（改偶数取整之前） |
| 重启后窗口开到最大 / 全屏 | 5120×2560、5120×2800 点对点 |
| 旧 QEMU 存的 Windows 与 Ubuntu 挂起状态，用新 QEMU 恢复 | 正常，改分辨率正常 |
| Ubuntu 冷启动后 5120×2880 | 正常 |
