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
                Text("更改将在重新打开应用后生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("新建虚拟机") {
                Picker("默认网络", selection: $defaultNetwork) {
                    ForEach(NetworkMode.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("虚拟机窗口") {
                Toggle("同步文本剪贴板", isOn: $clipboardSync)
                Toggle("将 ⌘ 快捷键发送到虚拟机", isOn: $captureCommandKey)
                Text("开启后，⌘Q、⌘W 等快捷键也会发送到虚拟机（⌘ 在 Windows 中是 Win 键，在 Linux 中是 Super 键）。"
                     + "要使用 macOS 快捷键，请同时按住 ⌃。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("将 ⌘C、⌘V 等编辑快捷键映射为 Ctrl", isOn: $commandAsControl)
                Text("⌘ 与 A、C、V、X、Z、Y、F、S、N、O、P、T、W 组合时发送为 Ctrl 组合，其他情况仍为 Win / Super 键。"
                     + "在 Linux 终端中粘贴请按 ⌘⇧V。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("启动时重新打开上次的虚拟机窗口", isOn: $restoreWindows)
                Text("重新打开窗口会同时启动对应的虚拟机。更改将在重新打开应用后生效。")
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
