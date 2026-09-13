# 扩大系统盘

建好的虚拟机可以在设置面板(或 `virtually resize-disk <名字> <GB>`)里把系统盘改大。
代码在 `VirtuallyKit/Disk/DiskResize.swift`。

```
宿主,关机态:qemu-img resize disk.qcow2 <N>G → config.json 记 growPartition = true
下次开机,agent 上线 10 秒后:宿主经 exec 发扩分区脚本 → guest 回一行 VAGROW … → 清标记
```

## 只能关机改,挂起也不行

`block/qcow2-snapshot.c` 的 `qcow2_snapshot_goto()`:快照记着存的那一刻的盘大小(`sn->disk_size`),
**恢复快照时会把盘 truncate 回那个大小**。

- 挂起状态 `__suspend__` 本身就是一条快照,指纹里又不含盘的大小,所以开机 `loadvm` 能过 ——
  但盘被悄悄缩回原样,扩了等于没扩。面板在挂起时把磁盘项灰掉,要求开机后从系统里关机
- 扩容**前**存的用户快照照样能恢复,盘会回到当时的大小,数据和分区表也是当时的,前后一致。
  所以当前大小一律读 `qemu-img info` 的 `virtual-size`,不信 `settings.diskSizeGB`
- 安装中也灰掉:Windows Setup 分区时 `Extend=true` 已经按当时的盘占满,中途改只会留一截没人管的空间

`block/qcow2.c` 的 `qcow2_co_truncate()` 只在 **v2 镜像带快照**时拒绝改大小。
`qemu-img create` / `convert` 默认出 v3(compat=1.1),带快照也能扩(测试 `DiskTests` 有覆盖)。

只扩不缩:`qemu-img resize` 不带 `--shrink`,`growDisk` 也会先拦下。缩小会切掉 guest 的分区。

## guest 里扩分区:借 `exec`,不改协议

两份 agent 早就有 `exec`(Windows 以 SYSTEM 身份 `cmd /c`,Linux 以 root 身份 `/bin/sh -c`)。
给 agent 加一条专门的命令当然更整齐,但已经装好的机器拿不到:
Linux agent 不会自己更新(LINUX.md),Windows 要重建工具盘再 `--tools` 开一次机。
走 `exec` 的话,任何一台现有的机器扩完容就能用。

脚本**只用 ASCII**,结果统一是一行 `VAGROW grown <旧字节> <新字节> | nochange | blocked <代号> | failed <原因>`,
中文由宿主按代号拼(`PartitionGrow.explainBlocked`)。Windows 的 `exec` 经 cmd.exe 取输出,非 ASCII 会按代码页乱掉。

| | Windows | Ubuntu |
|---|---|---|
| 怎么送进去 | `powershell.exe -EncodedCommand <UTF-16LE base64>`,整条命令没有引号(避开 GUEST-AGENT.md 坑 5) | `echo <base64> \| base64 -d \| sh` |
| 扩分区 | 删掉挡路的 WinRE 恢复分区(见下)→ `Resize-Partition -Size (Get-PartitionSupportedSize).SizeMax` | `growpart <盘> <号>`(cloud-guest-utils,26.04.1 桌面版 minimal 清单里就有) |
| 扩文件系统 | NTFS 随分区一起 | `resize2fs`,**每次都跑**,补上次分区扩了而文件系统没扩完的情况 |
| 什么都不做 | 盘尾空闲不到 256MB(`nochange`) | growpart 报 NOCHANGE |
| blocked | C: 后面有**恢复分区以外**的分区 | 根不是 ext4、根不在普通分区上(LVM 之类) |

- `grown` / `nochange` / `blocked` 都清标记;`failed` 留着,下次开机再试
- 每次会话只发一次。Windows 的 `exec` 是同步跑的,存储 cmdlet 可能要几秒,
  这期间 agent 不处理别的命令 —— 所以等 agent 上线 10 秒后再发,和开机时的光标接管错开
- Ubuntu 的 `direct` 布局是 ESP + ext4 根分区,根在最后,growpart 能直接扩;交换是 swapfile,不挡路

## Windows:C: 后面有个恢复分区挡着

应答文件只建了 EFI + MSR + C:(`Extend=true`),**但 Setup 自己从 C: 尾部切了 853MB 出来当 WinRE 恢复分区**
(实测 Win11 25H2 中文 ARM64:第 4 分区,GptType `{de94bba4-06d1-4d40-a16a-bfd50179d6ac}`,
`reagentc /info` 指向 `harddisk0\partition4\Recovery\WindowsRE`)。所以这个 app 装出来的每台 Windows,
C: 都不在最后,直接 `Resize-Partition` 扩不动,磁盘管理里「扩展卷」也是灰的。

处理办法是**删掉它、让 WinRE 搬进 C:**,而不是挪到盘尾重建:步骤少,以后再扩容只要一步;
WinRE 放在系统分区上是 Windows 支持的布局。顺序:

1. `reagentc /disable`:winre.wim 挪回 `C:\Windows\System32\Recovery`
2. **核对 `reagentc /info` 不再指向那个分区**,才删。不看 `/disable` 的返回码:上次跑到一半、WinRE 已经关着时
   它会回什么没验证过,核对位置更稳;
   比对用字符串 `Contains`,不能用 `-match` —— 路径里的 `\p` 在 .NET 正则里是转义,会直接抛异常
3. `Remove-Partition`
4. `Resize-Partition` 扩 C:
5. `reagentc /enable`:WinRE 落到 `C:\Recovery\WindowsRE`。失败了不算扩容失败,
   回报里带 `winre-off`,状态条上提示用户自己 `reagentc /enable`

盘尾空闲不到 256MB 时整段跳过:没得可扩的时候,绝不去删恢复分区。

## 实测(2026-09-12)

在两台现有虚拟机的 APFS 克隆上各跑了一遍,原机不动:

| | 过程 | 结果 |
|---|---|---|
| 挂起态 `resize-disk` | CLI 直接拒绝 | 「虚拟机已挂起…」,rc=1 |
| 缩小 `resize-disk … 60` | 拒绝 | 「磁盘只能扩大,不能缩小(当前 64 GB)」 |
| Ubuntu 26.04.1,64 → 96GB | guest 里关机 → 扩 → 冷启动 | `VAGROW grown`,vda2 67.6GB → 101.9GB,`df` 94G,`sfdisk --verify` 无错,标记清掉 |
| Ubuntu 扩完后挂起再恢复 | `ctl.sh stop` → `run` | 恢复成功,大小不变,不会再发一次扩分区 |
| Windows 11 25H2,96 → 128GB | 同上 | `VAGROW grown 101933121536 137148481024`,恢复分区没了,C: 占满,WinRE `Enabled` 位于 partition3 |
| Windows 扩完后重启 | `shutdown /r` | 正常起来,agent 回连,C: 仍是 128GB |
