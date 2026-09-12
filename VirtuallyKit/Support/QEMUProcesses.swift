import Foundation

public enum QEMUProcesses {
    /// 有没有正在跑的 qemu 把这个文件挂上了。返回它的 pid。
    ///
    /// qcow2 的写锁是独占的,另一个 QEMU 攥着时启动会立刻失败,而 QEMU 的错误只写在日志里。
    /// 工具盘同理:guest 缓存着 FAT 与簇,跑着的时候重建镜像,guest 读到的是失效数据。
    public static func holding(path: String) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("qemu-system"), line.contains(path) else { continue }
            return line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        }
        return nil
    }
}
