// SHA-512 crypt(`$6$…`)—— Ubuntu 的 autoinstall 要把用户密码以这种形式写进应答文件。
//
// 为什么自己实现:macOS 上**没有**现成工具。
//   * LibreSSL 3.3 的 `openssl passwd` 没有 `-6`(只有 -1/-apr1/-crypt)
//   * Xcode 自带 python 3.9 的 `crypt` 模块在 macOS 上退化成 DES,`$6$` 盐会被忽略
//   * 调 libc 的 `crypt(3)`?macOS 的实现同样只有 DES
// 而明文密码不能写进 autoinstall —— 那份文件会留在 guest 的 /var/log/installer 里。
//
// 算法是 Ulrich Drepper 的 SHA-crypt 规范,实现前先用 Python 对过规范自带的测试向量,
// 自检里钉着同一组向量(见 SelfTest.swift)。

import Foundation
import CryptoKit

public enum SHA512Crypt {

    /// crypt(3) 的自定义 base64 字母表。**顺序与标准 base64 不同**,不能用 Data.base64EncodedString。
    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// 盐用的字符集:与字母表同一套
    private static let saltAlphabet = alphabet

    /// 默认轮数。规范的默认值,`$6$` 后不带 `rounds=` 时就是这个。
    public static let defaultRounds = 5000
    /// 规范规定的取值范围,超出就夹到边界
    public static let minRounds = 1000, maxRounds = 999_999_999

    /// 生成 16 字符随机盐
    public static func randomSalt(length: Int = 16) -> String {
        String((0..<length).map { _ in saltAlphabet.randomElement()! })
    }

    /// 返回 `$6$<salt>$<hash>`。salt 超过 16 字符会被截断(规范如此)。
    public static func hash(password: String, salt: String, rounds: Int = defaultRounds) -> String {
        let pw = Array(password.utf8)
        let salt = Array(salt.utf8.prefix(16))
        let rounds = min(max(rounds, minRounds), maxRounds)

        // B = SHA512(pw + salt + pw)
        let B = digest(pw + salt + pw)

        // A = SHA512(pw + salt + B 重复到 pw 长度 + 按 pw 长度的二进制位交替加 B / pw)
        var a = pw + salt
        a += repeated(B, toLength: pw.count)
        var cnt = pw.count
        while cnt > 0 {
            a += (cnt & 1) != 0 ? B : pw
            cnt >>= 1
        }
        let A = digest(a)

        // P = SHA512(pw 重复 len(pw) 次) 重复到 pw 长度
        let DP = digest(repeatedSequence(pw, times: pw.count))
        let P = repeated(DP, toLength: pw.count)

        // S = SHA512(salt 重复 16 + A[0] 次) 重复到 salt 长度
        let DS = digest(repeatedSequence(salt, times: 16 + Int(A[0])))
        let S = repeated(DS, toLength: salt.count)

        // 主循环:按 i 的奇偶与模 3、模 7 决定拼接顺序
        var C = A
        for i in 0..<rounds {
            var input: [UInt8] = []
            input += (i & 1) != 0 ? P : C
            if i % 3 != 0 { input += S }
            if i % 7 != 0 { input += P }
            input += (i & 1) != 0 ? C : P
            C = digest(input)
        }

        // 轮数非默认时必须写进前缀,否则校验方不知道该迭代多少次
        let prefix = rounds == defaultRounds ? "$6$" : "$6$rounds=\(rounds)$"
        return prefix + String(decoding: salt, as: UTF8.self) + "$" + encode(C)
    }

    // MARK: - 内部

    private static func digest(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA512.hash(data: bytes))
    }

    /// 把 `block` 首尾相接铺到 `length` 字节(最后一段截断)
    private static func repeated(_ block: [UInt8], toLength length: Int) -> [UInt8] {
        guard length > 0, !block.isEmpty else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        while out.count + block.count <= length { out += block }
        out += block.prefix(length - out.count)
        return out
    }

    private static func repeatedSequence(_ block: [UInt8], times: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(block.count * max(0, times))
        for _ in 0..<max(0, times) { out += block }
        return out
    }

    /// 24 位一组取 6 位,**从低位开始**
    private static func b64(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, _ n: Int) -> String {
        var w = (UInt32(b2) << 16) | (UInt32(b1) << 8) | UInt32(b0)
        var out = ""
        for _ in 0..<n {
            out.append(alphabet[Int(w & 0x3f)])
            w >>= 6
        }
        return out
    }

    /// 最终编码。**这个字节顺序是规范写死的**,不是简单的顺序扫描 ——
    /// 21 组三字节按固定下标取,最后一组只出 2 个字符。
    private static func encode(_ c: [UInt8]) -> String {
        let groups: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26),
            (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32),
            (12, 33, 54), (34, 55, 13), (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38),
            (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var out = ""
        for (x, y, z) in groups { out += b64(c[x], c[y], c[z], 4) }
        out += b64(0, 0, c[63], 2)
        return out
    }
}
