import AppKit
import VirtuallyKit

/// 找到 Virtually.app。命令行工具自己不带 QEMU,用的是 app 里嵌着的那份。
enum AppLocator {
    static let bundleID = "org.virtually.Virtually"

    static func app(_ args: inout Arguments) throws -> Bundle {
        var candidates: [URL] = []
        if let explicit = args.option("app") { candidates.append(URL(fileURLWithPath: explicit)) }
        // Xcode 的构建目录里,命令行工具与 Virtually.app 在同一层
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("Virtually.app"))
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            candidates.append(installed)
        }
        for url in candidates {
            if let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID { return bundle }
        }
        throw CLIError("找不到 Virtually.app。先在 Xcode 里构建一次,或用 --app <路径> 指定。")
    }

    static func tools(_ args: inout Arguments) throws -> ToolPaths {
        let tools = ToolPaths(appBundle: try app(&args))
        guard tools.isComplete else {
            throw CLIError("\(tools.qemu.deletingLastPathComponent().path) 里没有完整的 QEMU,这个 app 构建不完整。")
        }
        return tools
    }
}
