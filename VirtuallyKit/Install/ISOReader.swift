// 自己读 ISO9660(带 Joliet 扩展),不经 hdiutil。
//
// 为什么必须自己读:**hdiutil 挂不了 Ubuntu 26.04 的桌面版 ISO**。
//   hdiutil attach → "no mountable file systems";imageinfo → "internal error"
//   而镜像本身完好:PVD 在 lba 16,Joliet SVD 在 lba 18,外加一张 GPT。
//   (Windows 的 ISO hdiutil 能挂,所以这个坑一直没暴露。)
//
// 只读、只要目录树与文件内容,所以不解析 Rock Ridge:Joliet 的名字已经是长名 UCS-2BE,
// 够我们找 `casper/vmlinuz`、`EFI/boot/*.efi`、`.disk/info` 这些固定路径了。
//
// 规范要点(都在 ECMA-119 里):
//   扇区 2048 字节;卷描述符从 lba 16 起,一个一个排,type 255 结束
//   type 1 = PVD,type 2 = SVD(escape 序列是 %/@ %/C %/E 之一时为 Joliet)
//   目录记录:[0]=记录长度 [2..5]=区段 LBA(小端) [10..13]=长度 [25]=flags(bit1=目录)
//            [32]=名字长度 [33...]=名字

import Foundation

public struct ISOReader {

    public struct Entry {
        public let name: String
        public let lba: UInt32
        public let size: UInt32
        public let isDirectory: Bool

        public init(name: String, lba: UInt32, size: UInt32, isDirectory: Bool) {
            self.name = name
            self.lba = lba
            self.size = size
            self.isDirectory = isDirectory
        }
    }

    public enum ISOError: LocalizedError {
        case notISO9660(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .notISO9660(let p): return "\(p) 不是可识别的 ISO9660 镜像"
            case .notFound(let p):   return "镜像里找不到 \(p)"
            }
        }
    }

    private static let sector = 2048

    private let handle: FileHandle
    /// 根目录记录
    private let root: Entry
    /// 名字是不是 UCS-2BE(Joliet)
    private let joliet: Bool

    public init(iso: URL) throws {
        handle = try FileHandle(forReadingFrom: iso)
        var chosen: (root: Entry, joliet: Bool)?
        // 卷描述符链。最多扫 32 个,正常镜像三四个就到 type 255 了。
        for i in 16..<48 {
            guard let block = try Self.read(handle, lba: UInt32(i), count: Self.sector),
                  block.count == Self.sector,
                  block[1...5].elementsEqual(Array("CD001".utf8)) else { break }
            let type = block[0]
            if type == 255 { break }                      // 终止符
            guard type == 1 || type == 2 else { continue }
            // 根目录记录在卷描述符偏移 156 处,34 字节
            guard let rootEntry = Self.parseRecord(Array(block[156..<190]), joliet: false) else { continue }
            if type == 2 {
                // escape 序列在偏移 88;%/@ %/C %/E 都表示 Joliet 的 UCS-2 级别
                let esc = Array(block[88..<91])
                let isJoliet = esc[0] == 0x25 && esc[1] == 0x2F && [0x40, 0x43, 0x45].contains(esc[2])
                if isJoliet {
                    chosen = (rootEntry, true)            // Joliet 优先:长文件名
                    break
                }
            } else if chosen == nil {
                chosen = (rootEntry, false)
            }
        }
        guard let chosen else {
            try? handle.close()
            throw ISOError.notISO9660(iso.lastPathComponent)
        }
        root = chosen.root
        joliet = chosen.joliet
    }

    public func close() { try? handle.close() }

    // MARK: - 对外

    public func exists(_ path: String) -> Bool { (try? locate(path)) != nil }

    public func list(_ path: String) throws -> [Entry] {
        let dir = try locate(path)
        guard dir.isDirectory else { throw ISOError.notFound(path) }
        return try children(of: dir)
    }

    /// 读整个文件。**大文件别用这个** —— initrd 有 147 MB。
    public func read(_ path: String) throws -> Data {
        let e = try locate(path)
        return try read(entry: e, offset: 0, count: Int(e.size))
    }

    /// 读文件的前 n 字节。解析 WIM 头部这种场景用它。
    public func read(_ path: String, upTo n: Int) throws -> Data {
        let e = try locate(path)
        return try read(entry: e, offset: 0, count: min(n, Int(e.size)))
    }

    /// 从文件中间读一段。WIM 的 XML 元数据在尾部,靠这个取。
    public func read(_ path: String, offset: UInt64, count: Int) throws -> Data {
        let e = try locate(path)
        return try read(entry: e, offset: offset, count: count)
    }

    /// 流式拷出来,不把整个文件读进内存
    public func copy(_ path: String, to dest: URL) throws {
        let e = try locate(path)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        fm.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        var written: UInt64 = 0
        let chunk = 4 * 1024 * 1024
        while written < UInt64(e.size) {
            let n = min(chunk, Int(UInt64(e.size) - written))
            let data = try read(entry: e, offset: written, count: n)
            guard !data.isEmpty else { break }
            try out.write(contentsOf: data)
            written += UInt64(data.count)
        }
    }

    // MARK: - 内部

    private func read(entry: Entry, offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let start = UInt64(entry.lba) * UInt64(Self.sector) + offset
        try handle.seek(toOffset: start)
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func read(_ handle: FileHandle, lba: UInt32, count: Int) throws -> [UInt8]? {
        try handle.seek(toOffset: UInt64(lba) * UInt64(sector))
        guard let d = try handle.read(upToCount: count) else { return nil }
        return Array(d)
    }

    /// 目录项。目录内容按扇区对齐,记录长度 0 表示「本扇区剩下的是填充」。
    private func children(of dir: Entry) throws -> [Entry] {
        let data = try read(entry: dir, offset: 0, count: Int(dir.size))
        var out: [Entry] = []
        var off = 0
        let bytes = Array(data)
        while off < bytes.count {
            let len = Int(bytes[off])
            if len == 0 {
                // 跳到下一个扇区边界
                off = (off / Self.sector + 1) * Self.sector
                continue
            }
            guard off + len <= bytes.count else { break }
            if let e = Self.parseRecord(Array(bytes[off..<(off + len)]), joliet: joliet),
               e.name != ".", e.name != ".." {
                out.append(e)
            }
            off += len
        }
        return out
    }

    private func locate(_ path: String) throws -> Entry {
        var current = root
        for part in path.split(separator: "/") where !part.isEmpty {
            let name = String(part)
            guard current.isDirectory else { throw ISOError.notFound(path) }
            let kids = try children(of: current)
            // ISO9660 的名字大小写不可靠(Joliet 保留原样,PVD 全大写),一律忽略大小写
            guard let hit = kids.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { throw ISOError.notFound(path) }
            current = hit
        }
        return current
    }

    private static func parseRecord(_ r: [UInt8], joliet: Bool) -> Entry? {
        guard r.count >= 33 else { return nil }
        let len = Int(r[0])
        guard len >= 33, r.count >= len else { return nil }
        let lba = UInt32(r[2]) | UInt32(r[3]) << 8 | UInt32(r[4]) << 16 | UInt32(r[5]) << 24
        let size = UInt32(r[10]) | UInt32(r[11]) << 8 | UInt32(r[12]) << 16 | UInt32(r[13]) << 24
        let isDir = (r[25] & 0x02) != 0
        let nameLen = Int(r[32])
        guard 33 + nameLen <= len else { return nil }
        let raw = Array(r[33..<(33 + nameLen)])
        var name: String
        if nameLen == 1 && raw[0] == 0 { name = "." }
        else if nameLen == 1 && raw[0] == 1 { name = ".." }
        else if joliet {
            // UCS-2 大端。Swift 没有直接的 decoder,自己拼 UTF-16。
            var units: [UInt16] = []
            var i = 0
            while i + 1 < raw.count { units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1])); i += 2 }
            name = String(decoding: units, as: UTF16.self)
        } else {
            name = String(decoding: raw, as: UTF8.self)
        }
        // 文件名尾部的版本号 ";1"
        if let semi = name.lastIndex(of: ";") { name = String(name[name.startIndex..<semi]) }
        // ISO9660 给无扩展名的文件留一个尾点
        if name.hasSuffix(".") && name.count > 1 { name.removeLast() }
        return Entry(name: name, lba: lba, size: size, isDirectory: isDir)
    }
}
