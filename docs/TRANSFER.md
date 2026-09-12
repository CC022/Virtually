# 传文件与剪贴板

## 传文件:一张来回插拔的 U 盘

没有走 virtio-fs 或 SMB:前者要 guest 装 WinFsp 且 ARM64 支持未验,后者宿主没有 samba。
复用已经跑通的那条路 —— 安装介质就是这么进 guest 的:

```
宿主 → guest   拖文件 → FATImageBuilder 打成 FAT32 raw 镜像(包内 transfer-<时间>.img)
               → QMP blockdev-add(raw 节点)+ device_add usb-storage,removable=on
               → Windows 里出现一个可移动磁盘
guest → 宿主   用户把文件放到那个盘上 → 「取回并弹出」→ device_del(guest 侧等于拔 U 盘)
               → 等 DEVICE_DELETED 事件 → blockdev-del → 宿主只读挂载镜像
               → 复制到 ~/Downloads/<虚拟机名>-传出-<时间>/ → 在访达里露出来 → 删镜像
```

- 入口:「传文件」面板的拖放区、面板里的「选择文件…」、直接拖到画面上。
  调试通道:`xfer <路径>...` / `xfer retrieve`,与界面走同一条 `VMSession` 路径。
- 一次只有一张盘在 guest 上。镜像大小 = 文件总量 × 1.1 + 32MB,最少 64MB(FAT32 有簇数下限)。
- Windows 对可移动盘默认「快速删除」策略,不缓存写入,直接拔是安全的。
- **这张盘是 raw,savevm 不认**。挂起与存快照前 `VMSession.detachAllUSB` 会先把它拔掉,
  镜像留在包里;下次打开面板会列出「上次没取回」的盘,可以直接复制出来。
- 状态活在 `VMSession.transfer` 里,不在面板的 @State 里(面板一关就没了)。

## 剪贴板:只同步文本

agent 的 `clipget` / `clipset <base64>`,走 session 角色 —— 剪贴板是每会话的,
SYSTEM 在会话 0 看不到用户那份。

宿主每秒一次:先看 `NSPasteboard.changeCount` 变没变,变了就 `clipset` 推给 guest;
没变就 `clipget` 问一下。两个方向都记住「上次是谁写的」(`guestClipLast`、`hostClipSeen`),
否则 A 写给 B、B 又写回 A,来回抖。只在窗口是 key 时同步。guest 复制了图片或文件时
`Get-Clipboard` 回空,空文本不推,免得把宿主的剪贴板清掉。

老 agent 没有这两条命令,回 `err unknown clipget`,宿主看到就停掉轮询并提示更新 agent
(`virtually build-tools` 重建工具盘,再 `virtually run --vm <包> --tools` 开一次机)。
