import Foundation
import CommonCrypto
import CryptoKit
import Security
import WorkbenchCore

/// 无符号大整数：只实现 ARD Diffie-Hellman 所需的模幂运算（模数为奇素数，使用 Montgomery 乘法）。数据以 32 位小端分段存储。
struct RFBBigUInt: Equatable {
    var limbs: [UInt32]
    init(bigEndian bytes: [UInt8]) {
        var values: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            let lower = max(0, index - 4)
            var value: UInt32 = 0
            for byte in bytes[lower..<index] { value = value << 8 | UInt32(byte) }
            values.append(value); index = lower
        }
        limbs = values.isEmpty ? [0] : values
        normalize()
    }
    init(limbs: [UInt32]) { self.limbs = limbs.isEmpty ? [0] : limbs; normalize() }
    private mutating func normalize() { while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() } }
    func bigEndian(length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        for (index, limb) in limbs.enumerated() {
            for shift in 0..<4 {
                let position = length - 1 - (index * 4 + shift)
                if position >= 0 { bytes[position] = UInt8(truncatingIfNeeded: limb >> (8 * UInt32(shift))) }
            }
        }
        return bytes
    }
    var isOdd: Bool { limbs[0] & 1 == 1 }
    var bitWidth: Int { (limbs.count - 1) * 32 + (32 - limbs.last!.leadingZeroBitCount) }
    func bit(_ index: Int) -> Bool { index / 32 < limbs.count && (limbs[index / 32] >> UInt32(index % 32)) & 1 == 1 }

    /// base^exponent mod modulus；modulus 必须为大于 1 的奇数。
    static func modPow(_ base: RFBBigUInt, _ exponent: RFBBigUInt, _ modulus: RFBBigUInt) -> RFBBigUInt {
        let n = modulus.limbs.count
        let m = modulus.limbs
        // n' = -m^{-1} mod 2^32（牛顿迭代求逆）
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- m[0] &* inverse) }
        let mPrime = 0 &- inverse
        func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
            for index in stride(from: n - 1, through: 0, by: -1) where a[index] != b[index] { return a[index] < b[index] ? -1 : 1 }
            return 0
        }
        func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
            var borrow: UInt64 = 0
            for index in 0..<n {
                let difference = UInt64(a[index]) &- UInt64(b[index]) &- borrow
                a[index] = UInt32(truncatingIfNeeded: difference); borrow = (difference >> 63) & 1
            }
        }
        func montgomery(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: n + 2)
            for i in 0..<n {
                var carry: UInt64 = 0
                for j in 0..<n {
                    let sum = UInt64(t[j]) + UInt64(a[j]) * UInt64(b[i]) + carry
                    t[j] = UInt32(truncatingIfNeeded: sum); carry = sum >> 32
                }
                var sum = UInt64(t[n]) + carry; t[n] = UInt32(truncatingIfNeeded: sum); t[n + 1] = UInt32(sum >> 32)
                let factor = t[0] &* mPrime
                carry = (UInt64(t[0]) + UInt64(factor) * UInt64(m[0])) >> 32
                for j in 1..<n {
                    let value = UInt64(t[j]) + UInt64(factor) * UInt64(m[j]) + carry
                    t[j - 1] = UInt32(truncatingIfNeeded: value); carry = value >> 32
                }
                sum = UInt64(t[n]) + carry; t[n - 1] = UInt32(truncatingIfNeeded: sum)
                t[n] = t[n + 1] + UInt32(sum >> 32); t[n + 1] = 0
            }
            var result = Array(t[0..<n])
            if t[n] != 0 || compare(result, m) >= 0 { subtract(&result, m) }
            return result
        }
        // value mod m，用逐位左移加条件减法完成（只在初始化时使用）。
        func reduce(_ value: RFBBigUInt, extraShift: Int) -> [UInt32] {
            var remainder = [UInt32](repeating: 0, count: n)
            func shiftIn(_ bit: Bool) {
                var carry: UInt32 = bit ? 1 : 0
                for index in 0..<n { let next = remainder[index] >> 31; remainder[index] = remainder[index] << 1 | carry; carry = next }
                if carry != 0 || compare(remainder, m) >= 0 { subtract(&remainder, m) }
            }
            for index in stride(from: value.bitWidth - 1, through: 0, by: -1) { shiftIn(value.bit(index)) }
            for _ in 0..<extraShift { shiftIn(false) }
            return remainder
        }
        let rSquared = reduce(RFBBigUInt(limbs: [1]), extraShift: 2 * 32 * n)
        var one = [UInt32](repeating: 0, count: n); one[0] = 1
        let baseReduced = reduce(base, extraShift: 0)
        var result = montgomery(rSquared, one)                  // R mod m
        let factor = montgomery(baseReduced, rSquared)           // base·R mod m
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = montgomery(result, result)
            if exponent.bit(index) { result = montgomery(result, factor) }
        }
        return RFBBigUInt(limbs: montgomery(result, one))
    }
}

enum RFBSecurity {
    /// VNC 口令认证：口令取前 8 字节（不足补零），每字节位序反转后作为 DES 密钥加密 16 字节挑战。
    static func vncResponse(challenge: [UInt8], password: String) throws -> [UInt8] {
        guard challenge.count == 16 else { throw RFBError.protocolViolation("VNC challenge") }
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in Array(password.utf8.prefix(8)).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 1 << (7 - bit) }
            key[index] = reversed
        }
        return try crypt(algorithm: CCAlgorithm(kCCAlgorithmDES), key: key, input: challenge)
    }

    /// Apple Remote Desktop（security type 30）：DH 交换后用 MD5(共享密钥) 作 AES-128-ECB 密钥加密 128 字节凭据。
    static func ardResponse(generator: [UInt8], prime: [UInt8], serverPublic: [UInt8], username: String, password: String) throws -> [UInt8] {
        let length = prime.count
        guard length >= 16, length <= 1024, serverPublic.count == length else { throw RFBError.protocolViolation("ARD key length") }
        let modulus = RFBBigUInt(bigEndian: prime)
        guard modulus.isOdd else { throw RFBError.protocolViolation("ARD prime") }
        // 私钥取 256 位：DH 私钥长度只需达到安全强度的两倍，远超该密钥长度对应的强度；用与模数等长的私钥会让认证慢上十几倍。
        var secret = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else { throw RFBError.io("random") }
        let privateKey = RFBBigUInt(bigEndian: secret)
        let clientPublic = RFBBigUInt.modPow(RFBBigUInt(bigEndian: generator), privateKey, modulus).bigEndian(length: length)
        let shared = RFBBigUInt.modPow(RFBBigUInt(bigEndian: serverPublic), privateKey, modulus).bigEndian(length: length)
        let key = Array(Insecure.MD5.hash(data: Data(shared)))
        var credentials = [UInt8](repeating: 0, count: 128)
        guard SecRandomCopyBytes(kSecRandomDefault, 128, &credentials) == errSecSuccess else { throw RFBError.io("random") }
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard user.count < 64, pass.count < 64 else { throw RFBError.authenticationFailed(L10n.text("用户名或密码过长（各限 63 字节）")) }
        for (index, byte) in user.enumerated() { credentials[index] = byte }; credentials[user.count] = 0
        for (index, byte) in pass.enumerated() { credentials[64 + index] = byte }; credentials[64 + pass.count] = 0
        return try crypt(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: key, input: credentials) + clientPublic
    }

    private static func crypt(algorithm: CCAlgorithm, key: [UInt8], input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode), key, key.count, nil, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else { throw RFBError.io("crypto \(status)") }
        return Array(output.prefix(moved))
    }
}
