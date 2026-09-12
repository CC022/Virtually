// 偏好设置(⌘,)。键名与读取在 VirtuallyKit 的 Preferences 里。

import SwiftUI
import VirtuallyKit

struct PreferencesView: View {
    @AppStorage(Preferences.libraryPathKey, store: Preferences.defaults) private var libraryPath = ""
    @AppStorage(Preferences.defaultNetworkKey, store: Preferences.defaults) private var defaultNetwork = NetworkMode.none.rawValue
    @AppStorage(Preferences.clipboardSyncKey, store: Preferences.defaults) private var clipboardSync = true
    @AppStorage(Preferences.captureCommandKeyKey, store: Preferences.defaults) private var captureCommandKey = true
    @AppStorage(Preferences.restoreWindowsKey, store: Preferences.defaults) private var restoreWindows = true
    @AppStorage(Preferences.commandAsControlKey, store: Preferences.defaults) private var commandAsControl = true
    @State private var pickingLibrary = false

    var body: some View {
        Form {
            Section("资源库") {
                LabeledContent("位置") {
                    HStack {
                        Text(libraryPath.isEmpty ? VMBundle.defaultLibraryURL.path : libraryPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("选择…") { pickingLibrary = true }
                        if !libraryPath.isEmpty { Button("默认") { libraryPath = "" } }
                    }
                }
                Text("改了位置要重新打开应用才生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("新虚拟机") {
                Picker("默认网络", selection: $defaultNetwork) {
                    ForEach(NetworkMode.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("虚拟机窗口") {
                Toggle("同步文本剪贴板", isOn: $clipboardSync)
                Toggle("⌘ 组合键发给虚拟机", isOn: $captureCommandKey)
                Text("开着时 ⌘Q、⌘W 都会发给虚拟机(Windows 里是 Win 键,Linux 里是 Super 键);"
                     + "要操作 macOS 用 ⌃⌘ 组合或鼠标点菜单。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("⌘C、⌘V 等编辑快捷键按 Ctrl 发送", isOn: $commandAsControl)
                Text("⌘ 加 A C V X Z Y F S N O P T W 发成 Ctrl 组合,⌘ 单按和其他组合仍是 Win / Super 键。"
                     + "Linux 终端里粘贴是 ⌘⇧V。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("启动时恢复上次开着的虚拟机窗口", isOn: $restoreWindows)
                Text("恢复窗口等于把那台虚拟机开起来。改了要重新打开应用才生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fileImporter(isPresented: $pickingLibrary, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { libraryPath = url.path }
        }
    }
}
