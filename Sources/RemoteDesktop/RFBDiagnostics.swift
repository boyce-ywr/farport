import Foundation

/// 供测试程序验证内部算法（模幂、VNC 口令响应），不在应用中使用。
public enum RFBDiagnostics {
    public static func modPow(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
        RFBBigUInt.modPow(RFBBigUInt(bigEndian: base), RFBBigUInt(bigEndian: exponent), RFBBigUInt(bigEndian: modulus)).bigEndian(length: modulus.count)
    }
    public static func vncResponse(challenge: [UInt8], password: String) throws -> [UInt8] { try RFBSecurity.vncResponse(challenge: challenge, password: password) }
}
