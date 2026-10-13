import Foundation

public enum TerminalFontSize {
    public static let limits = 10.0...28.0
    public static func scaled(base: Double, magnification: Double) -> Double {
        guard base.isFinite, magnification.isFinite else { return base.isFinite ? min(limits.upperBound, max(limits.lowerBound, base)) : 13 }
        return min(limits.upperBound, max(limits.lowerBound, base * (1 + magnification)))
    }
}
