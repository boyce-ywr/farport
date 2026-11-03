import Foundation

/// macOS 键盘到 X11 keysym 的映射（RFB KeyEvent 只传 keysym）。
public enum RFBKeyboard {
    /// 远端为 Linux/Windows 时 ⌘ 映射为 Ctrl（Mac 习惯）；远端为 macOS 时原样映射为 Super。
    public enum CommandMapping: String, Sendable, CaseIterable { case native, control }

    public static let shiftLeft: UInt32 = 0xFFE1, shiftRight: UInt32 = 0xFFE2
    public static let controlLeft: UInt32 = 0xFFE3, controlRight: UInt32 = 0xFFE4
    public static let altLeft: UInt32 = 0xFFE9, altRight: UInt32 = 0xFFEA
    public static let superLeft: UInt32 = 0xFFEB, superRight: UInt32 = 0xFFEC
    public static let capsLock: UInt32 = 0xFFE5

    /// 修饰键：按 macOS 虚拟键码返回 keysym。
    public static func modifier(keyCode: UInt16, mapping: CommandMapping) -> UInt32? {
        switch keyCode {
        case 56: return shiftLeft
        case 60: return shiftRight
        case 59: return controlLeft
        case 62: return controlRight
        case 58: return altLeft
        case 61: return altRight
        case 55: return mapping == .control ? controlLeft : superLeft
        case 54: return mapping == .control ? controlRight : superRight
        case 57: return capsLock
        default: return nil
        }
    }

    /// 与布局无关的功能键（回车、方向、功能键等）。
    public static func special(keyCode: UInt16) -> UInt32? {
        let table: [UInt16: UInt32] = [
            36: 0xFF0D, 76: 0xFF8D, 48: 0xFF09, 49: 0x0020, 51: 0xFF08, 117: 0xFFFF, 53: 0xFF1B,
            123: 0xFF51, 126: 0xFF52, 124: 0xFF53, 125: 0xFF54, 115: 0xFF50, 119: 0xFF57, 116: 0xFF55, 121: 0xFF56, 114: 0xFF63,
            122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3, 98: 0xFFC4, 100: 0xFFC5,
            101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9, 105: 0xFFCA, 107: 0xFFCB, 113: 0xFFCC, 106: 0xFFCD,
            71: 0xFF7F, 81: 0xFFBD, 75: 0xFFAF, 67: 0xFFAA, 78: 0xFFAD, 69: 0xFFAB, 65: 0xFFAE,
            82: 0xFFB0, 83: 0xFFB1, 84: 0xFFB2, 85: 0xFFB3, 86: 0xFFB4, 87: 0xFFB5, 88: 0xFFB6, 89: 0xFFB7, 91: 0xFFB8, 92: 0xFFB9,
        ]
        return table[keyCode]
    }

    /// 可打印字符：Latin-1 直接使用码值，其余用 Unicode keysym（0x01000000 + 码点）。
    public static func character(_ text: String) -> UInt32? {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        if scalar.value < 0x100 { return scalar.value }
        if (0xF700...0xF8FF).contains(scalar.value) { return nil } // AppKit 功能键私有区
        return 0x0100_0000 + scalar.value
    }
}
