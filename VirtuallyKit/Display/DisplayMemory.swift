// 让 Windows 的 viogpudo 预留够 5K 全屏用的帧缓冲。
//
// viogpudo 在驱动启动时按「模式表里最大的一档」分配一次帧缓冲段(HWInit 里的 m_FrameSegment),
// 之后改分辨率超过这个段就回 DISP_CHANGE_BADMODE。模式表来自 QEMU 的 EDID,最大 5120x2160,
// 于是动态分辨率卡在约 1100 万像素 —— 5K 屏上窗口一开大,画面就要被宿主放大,发虚。
//
// 驱动启动时会读自己设备注册表键下的 PersistentDispMode0Width/Height,把它当成一档自定义模式
// 并入模式表(BuildModeList)。写成 5120x2880,段就按它分。**要重启 Windows 才生效**,
// 没重启之前宿主靠 VMSession 里的 pixelBudget 退回旧上限。
//
// 和扩分区一样走 agent 已有的 exec,不改协议:已经装好的机器也能直接用。详见 docs/DISPLAY.md。

import Foundation

public enum DisplayMemory {

    /// 要预留的尺寸。与 VMDisplay.maxPixels 对应
    public static let width = 5120
    public static let height = 2880

    public enum Outcome: Equatable {
        /// 注册表里已经够大
        case ready
        /// 刚写进去,下次重启 Windows 生效
        case written
        /// 没找到 virtio 显卡(还在用 ramfb 之类)
        case noDevice
        case failed(String)
    }

    /// 发给 agent 的一行命令。同 PartitionGrow:EncodedCommand 免掉 cmd /c 的引号问题
    public static var agentCommand: String {
        let encoded = Data(windowsScript.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
            .base64EncodedString()
        return "exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand \(encoded)"
    }

    /// 只认 `out VADISP …`
    public static func parse(_ line: String) -> Outcome? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 3, f[0] == "out", f[1] == "VADISP" else { return nil }
        switch f[2] {
        case "ready":   return .ready
        case "written": return .written
        case "none":    return .noDevice
        case "failed":  return .failed(f.dropFirst(3).joined(separator: " "))
        default:        return nil
        }
    }

    /// SYSTEM 身份跑,只用 ASCII。设备键是 DEVPKEY_Device_Driver 指向的 Class 子键 ——
    /// 序号(0000、0001…)不固定,不能写死。已经不小于目标就不动,别覆盖用户自己设的更大值。
    static let windowsScript = """
    $ErrorActionPreference = 'Stop'
    try {
        $d = Get-PnpDevice -Class Display -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\\VEN_1AF4*' } | Select-Object -First 1
        if (-not $d) { 'VADISP none'; exit 0 }
        $drv = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_Driver).Data
        $key = "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\$drv"
        $p = Get-ItemProperty $key
        $w = [int]$p.PersistentDispMode0Width
        $h = [int]$p.PersistentDispMode0Height
        if ($w * $h -ge \(width) * \(height)) { 'VADISP ready'; exit 0 }
        New-ItemProperty -Path $key -Name PersistentDispMode0Width -PropertyType DWord -Value \(width) -Force | Out-Null
        New-ItemProperty -Path $key -Name PersistentDispMode0Height -PropertyType DWord -Value \(height) -Force | Out-Null
        'VADISP written'
    } catch {
        'VADISP failed ' + ($_.Exception.Message -replace '\\s+', ' ')
    }
    """
}

extension VMSession {

    /// agent 上线时调,只对 Windows。每次会话只查一次,查询本身很快
    func reserveDisplayMemoryIfNeeded() {
        guard bundle.settings.os == .windows, bundle.settings.install == nil,
              !displayMemoryChecked else { return }
        displayMemoryChecked = true
        Task {
            // 排在扩分区(10 秒)之后:Windows 的 exec 是同步执行的,错开免得互相等
            try? await Task.sleep(for: .seconds(15))
            guard agent.isConnected, state.acceptsCommands else { return }
            agent.send(DisplayMemory.agentCommand)
        }
    }

    func displayMemoryReported(_ outcome: DisplayMemory.Outcome) {
        switch outcome {
        case .ready:
            print("[显示] Windows 已预留 \(DisplayMemory.width)x\(DisplayMemory.height) 的帧缓冲")
        case .written:
            print("[显示] 已为 \(DisplayMemory.width)x\(DisplayMemory.height) 预留帧缓冲,下次重启 Windows 后生效")
        case .noDevice:
            print("[显示] guest 里没找到 virtio 显卡,不预留帧缓冲")
        case .failed(let why):
            print("[显示] 预留帧缓冲失败:\(why)")
        }
    }
}
