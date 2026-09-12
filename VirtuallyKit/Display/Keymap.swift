// 由 QEMU 的 subprojects/keycodemapdb/data/keymaps.csv 自动生成 —— 请勿手改。
// macOS 虚拟键码 → QEMU QKeyCode 序号。
//
// 之所以从上游表生成而不是手写:QKeyCode 有 162 个值,手写既易错又难维护。
// CSV 中同一 OS-X 键码可能出现多行(不同 Linux 键名映射到同一物理键),此处取首个。

public enum QKeyCode {
    public static let shift: Int32 = 1
    public static let ctrl: Int32 = 5
    public static let alt: Int32 = 3
    public static let meta: Int32 = 117
    public static let capsLock: Int32 = 61
}

/// macOS keyCode → QKeyCode
public let macKeyToQCode: [UInt16: Int32] = [
    0x00: 36,       // a
    0x01: 37,       // s
    0x02: 38,       // d
    0x03: 39,       // f
    0x04: 41,       // h
    0x05: 40,       // g
    0x06: 49,       // z
    0x07: 50,       // x
    0x08: 51,       // c
    0x09: 52,       // v
    0x0a: 91,       // less
    0x0b: 53,       // b
    0x0c: 23,       // q
    0x0d: 24,       // w
    0x0e: 25,       // e
    0x0f: 26,       // r
    0x10: 28,       // y
    0x11: 27,       // t
    0x12: 9,        // 1
    0x13: 10,       // 2
    0x14: 11,       // 3
    0x15: 12,       // 4
    0x16: 14,       // 6
    0x17: 13,       // 5
    0x18: 20,       // equal
    0x19: 17,       // 9
    0x1a: 15,       // 7
    0x1b: 19,       // minus
    0x1c: 16,       // 8
    0x1d: 18,       // 0
    0x1e: 34,       // bracket_right
    0x1f: 31,       // o
    0x20: 29,       // u
    0x21: 33,       // bracket_left
    0x22: 30,       // i
    0x23: 32,       // p
    0x24: 35,       // ret
    0x25: 44,       // l
    0x26: 42,       // j
    0x27: 46,       // apostrophe
    0x28: 43,       // k
    0x29: 45,       // semicolon
    0x2a: 48,       // backslash
    0x2b: 56,       // comma
    0x2c: 58,       // slash
    0x2d: 54,       // n
    0x2e: 55,       // m
    0x2f: 57,       // dot
    0x30: 22,       // tab
    0x31: 60,       // spc
    0x32: 47,       // grave_accent
    0x33: 21,       // backspace
    0x35: 8,        // esc
    0x36: 118,      // meta_r
    0x37: 117,      // meta_l
    0x38: 1,        // shift
    0x39: 61,       // caps_lock
    0x3a: 3,        // alt
    0x3b: 5,        // ctrl
    0x3c: 2,        // shift_r
    0x3d: 4,        // alt_r
    0x3e: 6,        // ctrl_r
    0x40: 154,      // f17
    0x41: 79,       // kp_decimal
    0x43: 59,       // asterisk
    0x45: 77,       // kp_add
    0x47: 72,       // num_lock
    0x48: 137,      // volumeup
    0x49: 138,      // volumedown
    0x4a: 136,      // audiomute
    0x4b: 74,       // kp_divide
    0x4c: 78,       // kp_enter
    0x4e: 76,       // kp_subtract
    0x4f: 155,      // f18
    0x50: 156,      // f19
    0x51: 128,      // kp_equals
    0x52: 81,       // kp_0
    0x53: 82,       // kp_1
    0x54: 83,       // kp_2
    0x55: 84,       // kp_3
    0x56: 85,       // kp_4
    0x57: 86,       // kp_5
    0x58: 87,       // kp_6
    0x59: 88,       // kp_7
    0x5a: 157,      // f20
    0x5b: 89,       // kp_8
    0x5c: 90,       // kp_9
    0x5d: 124,      // yen
    0x5e: 121,      // ro
    0x60: 66,       // f5
    0x61: 67,       // f6
    0x62: 68,       // f7
    0x63: 64,       // f3
    0x64: 69,       // f8
    0x65: 70,       // f9
    0x66: 149,      // lang2
    0x67: 92,       // f11
    0x68: 148,      // lang1
    0x69: 150,      // f13
    0x6a: 153,      // f16
    0x6b: 151,      // f14
    0x6d: 71,       // f10
    0x6e: 119,      // compose
    0x6f: 93,       // f12
    0x71: 152,      // f15
    0x72: 116,      // help
    0x73: 95,       // home
    0x74: 96,       // pgup
    0x75: 104,      // delete
    0x76: 65,       // f4
    0x77: 98,       // end
    0x78: 63,       // f2
    0x79: 97,       // pgdn
    0x7a: 62,       // f1
    0x7b: 99,       // left
    0x7c: 102,      // right
    0x7d: 101,      // down
    0x7e: 100,      // up
]

public func qcode(for macKeyCode: UInt16) -> Int32 {
    macKeyToQCode[macKeyCode] ?? 0
}

/// 字符 → (QKeyCode, 是否需要 shift)。供调试控制通道的 `type` 命令使用。
public func qcodeForCharacter(_ ch: Character) -> (code: Int32, shift: Bool) {
    let plain: [Character: UInt16] = [
        " ": 0x31, "\n": 0x24, "\t": 0x30, "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E,
        "\\": 0x2A, ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32,
    ]
    let shifted: [Character: Character] = [
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", "~": "`", "!": "1", "@": "2", "#": "3",
        "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]
    let letters: [Character: UInt16] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03, "g": 0x05,
        "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D,
        "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11, "u": 0x20,
        "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10, "z": 0x06,
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
    ]
    if let k = plain[ch]                    { return (qcode(for: k), false) }
    if let base = shifted[ch], let k = plain[base] ?? letters[base] { return (qcode(for: k), true) }
    if let k = letters[ch]                  { return (qcode(for: k), false) }
    if ch.isUppercase, let k = letters[Character(ch.lowercased())] { return (qcode(for: k), true) }
    return (0, false)
}
