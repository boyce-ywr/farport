import Foundation

public enum ShellMarkerAction: Equatable {
    case prompt, input, begin, end(Int?), invalidate
}

public struct ShellMarkerEvent: Equatable {
    public let endIndex: Int
    public let action: ShellMarkerAction
}

public struct ShellMarkerStream {
    private enum State { case text, escape, csi, osc, oscEscape, string, stringEscape }
    private var state = State.text
    private var control: [UInt8] = []
    private var overflow = false
    private var utf8Remaining = 0
    private var utf8Lead: UInt8 = 0
    public init() {}
    public mutating func scan(_ bytes: [UInt8]) -> [ShellMarkerEvent] {
        var events: [ShellMarkerEvent] = []
        for (index, byte) in bytes.enumerated() {
            func emit(_ action: ShellMarkerAction) { events.append(ShellMarkerEvent(endIndex: index + 1, action: action)) }
            if utf8Remaining > 0, byte & 0xc0 == 0x80 {
                utf8Remaining -= 1
                if state == .osc { append(byte) }
                if utf8Lead == 0xc2, byte < 0xa0 { emit(.invalidate) }
                continue
            }
            utf8Remaining = byte >= 0xc2 && byte <= 0xdf ? 1 : (byte >= 0xe0 && byte <= 0xef ? 2 : (byte >= 0xf0 && byte <= 0xf4 ? 3 : 0))
            utf8Lead = byte
            if byte == 24 || byte == 26 { state = .text; control = []; emit(.invalidate); continue }
            switch state {
            case .text:
                if byte == 27 { state = .escape }
                else if byte == 0x9d { start(.osc) }
                else if byte == 0x9b { start(.csi) }
                else if [0x90, 0x98, 0x9e, 0x9f].contains(byte) { state = .string }
            case .escape:
                if byte == 93 { start(.osc) }
                else if byte == 91 { start(.csi) }
                else if [80, 88, 94, 95].contains(byte) { state = .string }
                else if byte != 27 { state = .text; if byte == 99 { emit(.invalidate) } }
            case .csi:
                if byte == 27 { state = .escape; emit(.invalidate) }
                else if (0x40...0x7e).contains(byte) {
                    let parameters = String(decoding: control, as: UTF8.self)
                    if overflow || [74, 114, 83, 84, 76, 77].contains(byte) || ((byte == 104 || byte == 108) && ["?47", "?1047", "?1049"].contains(parameters)) { emit(.invalidate) }
                    state = .text; control = []
                } else { append(byte) }
            case .osc:
                if byte == 7 || byte == 0x9c { if let action = finishOSC() { emit(action) }; state = .text }
                else if byte == 27 { state = .oscEscape }
                else { append(byte) }
            case .oscEscape:
                if byte == 92 { if let action = finishOSC() { emit(action) }; state = .text }
                else {
                    emit(.invalidate)
                    if byte == 93 { start(.osc) } else if byte == 91 { start(.csi) } else { state = byte == 27 ? .escape : .text }
                }
            case .string:
                if byte == 27 { state = .stringEscape } else if byte == 0x9c { state = .text }
            case .stringEscape:
                if byte == 92 { state = .text } else if byte != 27 { emit(.invalidate); state = .string }
            }
        }
        return events
    }
    private mutating func start(_ value: State) { state = value; control = []; overflow = false }
    private mutating func append(_ byte: UInt8) { if control.count < 256 { control.append(byte) } else { overflow = true } }
    private mutating func finishOSC() -> ShellMarkerAction? {
        defer { control = []; overflow = false }
        let code = Int(String(decoding: control.prefix { $0 != 59 }, as: UTF8.self))
        if overflow { return code == 133 || code == nil ? .invalidate : nil }
        guard let raw = String(bytes: control, encoding: .utf8), code == 133, let separator = raw.firstIndex(of: ";") else { return nil }
        let text = "133;" + raw[raw.index(after: separator)...]
        switch text {
        case "133;A", "133;A;k=i": return .prompt
        case "133;B": return .input
        case "133;C": return .begin
        case "133;D": return .end(nil)
        case "133;A;k=r", "133;A;k=s", "133;A;k=c", "133;P;k=r", "133;P;k=s", "133;P;k=c": return nil
        default:
            if text.hasPrefix("133;D;"), let status = Int(text.dropFirst(6)), (-2147483648...2147483647).contains(status) { return .end(status) }
            return .invalidate
        }
    }
}
