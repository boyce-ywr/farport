import Foundation
import ImageIO

public enum TerminalGraphics {
    public static let program = "Farport-Kitty"
    public static let environmentKeys = ["TERM_PROGRAM_VERSION", "KITTY_WINDOW_ID", "KITTY_PID", "WEZTERM_EXECUTABLE", "WEZTERM_VERSION", "ITERM_SESSION_ID", "ITERM_PROFILE", "ITERM_PROFILE_NAME", "GHOSTTY_RESOURCES_DIR", "WT_SESSION"]
    public static var loginCommand: String {
        let script = "export TERM_PROGRAM=\(RemotePath.quote(program)); unset \(environmentKeys.joined(separator: " ")); exec \"${SHELL:-/bin/sh}\" -l"
        return "/bin/sh -c " + RemotePath.quote(script)
    }
}

public struct TerminalGraphicsInput {
    private enum State { case text, escape, apc, apcEscape, discard, discardEscape }
    private var state = State.text
    private var utf8Remaining = 0
    private var command = [UInt8]()
    private var pending = [UInt8]()
    private var payload = [UInt8]()
    private var firstControl: [String: String]?
    public private(set) var displayedImages = 0
    private static let limit = 16 * 1024 * 1024
    public init() {}

    public mutating func filter(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var result = [UInt8](); result.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .text:
                if utf8Remaining > 0, byte & 0xc0 == 0x80 { utf8Remaining -= 1; result.append(byte) }
                else {
                    utf8Remaining = byte >= 0xc2 && byte <= 0xdf ? 1 : (byte >= 0xe0 && byte <= 0xef ? 2 : (byte >= 0xf0 && byte <= 0xf4 ? 3 : 0))
                    if byte == 27 { state = .escape }
                    else if byte == 0x9f { command = []; state = .apc }
                    else { result.append(byte) }
                }
            case .escape:
                if byte == 95 { command = []; state = .apc }
                else { result.append(27); if byte != 27 { result.append(byte); state = .text } }
            case .apc:
                if byte == 27 { state = .apcEscape }
                else if byte == 0x9c || byte == 7 { result.append(contentsOf: finish()); command = []; state = .text }
                else if byte == 24 || byte == 26 { command = []; resetImage(); state = .text; result.append(byte) }
                else if command.count >= Self.limit { command = []; resetImage(); state = .discard }
                else { command.append(byte) }
            case .apcEscape:
                if byte == 92 { result.append(contentsOf: finish()); command = []; state = .text }
                else { command = []; resetImage(); state = .discard }
            case .discard:
                if byte == 27 { state = .discardEscape }
                else if byte == 24 || byte == 26 || byte == 0x9c || byte == 7 { state = .text }
            case .discardEscape:
                state = byte == 92 ? .text : .discard
            }
        }
        return result
    }
    private mutating func resetImage() { pending = []; payload = []; firstControl = nil }
    private mutating func finish() -> [UInt8] {
        let framed = [UInt8]([27, 95]) + command + [27, 92]
        guard command.first == 71 else { return framed }
        guard let separator = command.firstIndex(of: 59), separator < 1024,
              let header = String(bytes: command[1..<separator], encoding: .ascii) else { resetImage(); return [] }
        var control = [String: String]()
        for part in header.split(separator: ",") {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, control[String(pair[0])] == nil else { resetImage(); return [] }
            control[String(pair[0])] = String(pair[1])
        }
        guard control["t"] == nil || control["t"] == "d", control["o"] == nil else { resetImage(); return [] }
        for key in ["c", "r", "s", "v", "x", "y", "w", "h", "X", "Y"] {
            if let value = control[key] {
                guard let number = Int(value), number >= 0, number <= (["c", "r"].contains(key) ? 512 : 4096) else { resetImage(); return [] }
            }
        }
        if ["d", "D", "p"].contains(control["a"] ?? "") { resetImage(); return framed }
        let initial = firstControl ?? control
        guard ["t", "T", "q"].contains(initial["a"] ?? "t"), pending.count + framed.count <= Self.limit else { resetImage(); return [] }
        pending.append(contentsOf: framed); payload.append(contentsOf: command[(separator + 1)...]); firstControl = initial
        if control["m"] == "1" { return [] }
        defer { resetImage() }
        guard let data = Data(base64Encoded: Data(payload)) else { return [] }
        if initial["f"] == "100" {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096 else { return [] }
        } else {
            guard ["24", "32"].contains(initial["f"] ?? "32"),
                  let width = Int(initial["s"] ?? ""), let height = Int(initial["v"] ?? ""),
                  width > 0, height > 0, width <= 4096, height <= 4096,
                  data.count == width * height * (initial["f"] == "24" ? 3 : 4) else { return [] }
        }
        if initial["a"] == "T" { displayedImages += 1 }
        return pending
    }
}
