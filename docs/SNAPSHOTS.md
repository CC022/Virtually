# 快照

`savevm` 存的是**整机状态**:磁盘 + 内存 + 每一个设备的寄存器。
因此快照能不能恢复,取决于恢复时的设备拓扑与存的时候是否一致。

## 内存状态落在哪块盘上(2026-09-11 修正)

`savevm` 把内存状态写到**第一个可写且支持快照的块设备**上
(`block/snapshot.c` `bdrv_all_find_vmstate_bs`,按 BlockBackend 创建顺序 = 命令行顺序)。
以前 nvram 的 `-drive if=pflash` 排在系统盘前面,于是每条快照 4GB 的内存状态
全进了那个 64MB 的 EFI 变量文件 —— 实测 `nvram.qcow2` 膨胀到 15–30GB,
`disk.qcow2` 里同名快照的 VM_SIZE 是 0。

现在系统盘的 `-drive` 排在 pflash 之前(`QemuCommand.arguments()`),自检有断言。
`-drive` 不进指纹,但内存状态换了地方,旧快照在新位置读不到 ——
所以指纹加了版本前缀(`QemuCommand.fingerprintVersion`,现为 `v2`),
旧快照一律按「配置不符」拒绝。旧的 `__suspend__` 开机时自动删掉;
用户自己的旧快照要手动删,删完 `qemu-img convert` 重写一遍 nvram.qcow2 才能把空洞收回来。

## 快照名

只允许字母、数字、`_ - .`,最多 64 字符(`VMSession.snapshotNameProblem`)。
名字进 HMP 命令行按空格切参数,`info snapshots` 的输出也按空格切列。`__suspend__` 是内部保留名。

## 存快照前先拔 USB

`usb-host` 是可迁移设备,带着它 savevm 会成功,但恢复时命令行上没有它,
`loadvm` 报 `Unknown savevm section`。存快照与挂起前 `VMSession.detachAllUSB` 先把透传设备全部拔掉。

## 失败方式很危险,必须提前挡

`migration/savevm.c` 里 `load_snapshot()` 的顺序是:

```
bdrv_all_goto_snapshot()   ← 磁盘先回滚
qemu_system_reset()        ← CPU 复位
qemu_loadvm_state()        ← 最后才读内存,这一步才会报错
```

也就是说读内存失败时,**磁盘已经换成快照那一刻的了**。此时:

- `cont` 会让一台刚复位的机器在一块被掉包的磁盘上继续跑,把文件系统写坏。
  实测就是这么毁掉过一台虚拟机:之后固件阶段 100% CPU 空转,再也引导不起来
  (用 `qemu-img snapshot -a <tag>` 把 disk 与 nvram 一起回滚才救回来)。
- 停在 `restore-vm` 状态不动,界面上看就是彻底卡死。

所以代码里的处理是两层:

1. **恢复前比对设备指纹**(`QemuCommand.migrationFingerprint()`),对不上直接拒绝,
   一个字节都不动。指纹存在 `config.json` 的 `snapshotShapes` 里,存快照时写入。
   没有指纹记录的旧快照一律拒绝 —— 它们确实恢复不了。
2. 万一还是失败了(指纹相同但 QEMU 仍报错),**断电**,并告诉用户磁盘停在快照那一刻,
   重新开机即可。绝不 `cont`。

## 网卡永远在场

网络开关曾经是热插拔 `virtio-net-pci`。这让快照在网络开关前后不兼容:

```
Error: Unknown ramblock "0000:00:04.0:00.0/virtio-net-pci.rom", cannot accept migration
```

现在网卡是开机就在的固定设备,联网与否只改链路(`set_link nic0 on|off`),
等价于插拔网线,设备拓扑不变。

不能改后端(`netdev_del` + `netdev_add`)的原因在 `net/net.c`:
`qemu_del_net_client()` 对有 NIC 对端的 netdev 只是把 NIC 标成 `peer_deleted`
并置链路断开,后续的 `netdev_add` **不会重新配对**。

断网的严密性:开机即无网络时,`VMSession` 在 QMP 握手一完成就 `set_link off`,
那时 guest 还没开始加载网卡驱动。SLIRP 是纯用户态 NAT,guest 不发包就什么都出不去。

## 已验证

| 项 | 结果 |
|---|---|
| 存快照(联网态)→ 切断网 → 恢复 | 成功,4s |
| 恢复后 guest 可操作 | agent 正常执行命令 |
| 恢复后链路状态 | 按用户当前选择重压,不跟随快照(`HTTP=000`) |
| 恢复指纹不符的旧快照 | 拒绝,虚拟机继续运行,磁盘未动 |
| 断电后重新开机 | 正常引导 |
