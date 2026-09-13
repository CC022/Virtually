import Foundation

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 手写的参数解析:位置参数按顺序取,`--键 值` 与 `--开关` 随处可放。
struct Arguments {
    private var items: [String]

    init(_ items: [String]) { self.items = items }

    /// 取下一个位置参数(跳过 --选项 及其值由调用方先取走)
    mutating func next() -> String? {
        guard let i = items.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
        return items.remove(at: i)
    }

    mutating func option(_ name: String) -> String? {
        guard let i = items.firstIndex(of: "--\(name)"), i + 1 < items.count else { return nil }
        let value = items[i + 1]
        items.removeSubrange(i...(i + 1))
        return value
    }

    mutating func int(_ name: String) throws -> Int? {
        guard let raw = option(name) else { return nil }
        guard let v = Int(raw) else { throw CLIError("--\(name) 必须是整数，收到的是 \(raw)") }
        return v
    }

    mutating func flag(_ name: String) -> Bool {
        guard let i = items.firstIndex(of: "--\(name)") else { return false }
        items.remove(at: i)
        return true
    }

    mutating func required(_ what: String) throws -> String {
        guard let v = next() else { throw CLIError("缺少参数：\(what)") }
        return v
    }

    /// 剩下的全部(send 用:命令本身可以带空格)
    mutating func rest() -> [String] {
        defer { items.removeAll() }
        return items
    }
}
