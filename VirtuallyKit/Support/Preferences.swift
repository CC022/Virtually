// 偏好设置的键与读取。存 UserDefaults,键名集中在这里,别处只引用常量。
// 界面(PreferencesView)在 app 里;引擎和命令行工具也要读,所以放 Kit。

import Foundation

public enum Preferences {
    public static let libraryPathKey = "libraryPath"          // 空 = 默认位置
    public static let defaultNetworkKey = "defaultNetwork"    // NetworkMode.rawValue
    public static let clipboardSyncKey = "clipboardSync"
    public static let captureCommandKeyKey = "captureCommandKey"
    public static let restoreWindowsKey = "restoreWindows"
    public static let commandAsControlKey = "commandAsControl"

    /// app 与命令行工具共用一份偏好。命令行工具没有 bundle,`standard` 读不到 app 的域,
    /// 所以按 app 的 bundle ID 取;app 自己则必须用 `standard`(拿自己的 ID 当 suite 名会被拒绝)。
    public static let defaults: UserDefaults = {
        let appID = "org.virtually.Virtually"
        if Bundle.main.bundleIdentifier == appID { return .standard }
        return UserDefaults(suiteName: appID) ?? .standard
    }()

    public static var clipboardSync: Bool { defaults.object(forKey: clipboardSyncKey) as? Bool ?? true }
    public static var captureCommandKey: Bool { defaults.object(forKey: captureCommandKeyKey) as? Bool ?? true }
    public static var commandAsControl: Bool { defaults.object(forKey: commandAsControlKey) as? Bool ?? true }
    public static var restoreWindows: Bool { defaults.object(forKey: restoreWindowsKey) as? Bool ?? true }
    public static var defaultNetwork: NetworkMode {
        NetworkMode(rawValue: defaults.string(forKey: defaultNetworkKey) ?? "") ?? .none
    }

    /// 资源库位置:偏好设置里改过就用它,否则默认位置
    public static var libraryURL: URL {
        if let path = defaults.string(forKey: libraryPathKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return VMBundle.defaultLibraryURL
    }
}
