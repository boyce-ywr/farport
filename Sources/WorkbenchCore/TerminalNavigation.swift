import Foundation

public enum TerminalNavigationAction: Equatable {
    case previous, next, number(Int), agents
    public static func resolve(keyCode: UInt16, text: String, command: Bool, option: Bool, control: Bool, shift: Bool) -> Self? {
        guard command, !control else { return nil }
        if option, !shift {
            if keyCode == 123 { return .previous }
            if keyCode == 124 { return .next }
            if text.lowercased() == "j" { return .agents }
            if text.count == 1, let number = Int(text), (1...9).contains(number) { return .number(number) }
        }
        if shift, !option {
            if ["[", "{"].contains(text) { return .previous }
            if ["]", "}"].contains(text) { return .next }
        }
        return nil
    }
}
