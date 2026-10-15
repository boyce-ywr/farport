import Foundation

public struct PacketWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func byte(_ value: UInt8) { data.append(value) }
    public mutating func uint32(_ value: UInt32) { data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    public mutating func uint64(_ value: UInt64) { uint32(UInt32(truncatingIfNeeded: value >> 32)); uint32(UInt32(truncatingIfNeeded: value)) }
    public mutating func bytes(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
    public mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    public mutating func append(_ value: Data) { data.append(value) }
    public var framed: Data { var result = PacketWriter(); result.uint32(UInt32(data.count)); result.append(data); return result.data }
}

public struct PacketReader {
    private let data: Data
    private var offset: Int = 0
    public init(_ data: Data) { self.data = Data(data) }
    public var remaining: Int { data.count - offset }
    public mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw WorkbenchError.protocolViolation(L10n.text("数据包被截断")) }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    public mutating func byte() throws -> UInt8 { try take(1)[0] }
    public mutating func uint32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    public mutating func uint64() throws -> UInt64 { let high = try uint32(); return (UInt64(high) << 32) | UInt64(try uint32()) }
    public mutating func bytes() throws -> Data { let count = try uint32(); guard count <= 8 * 1024 * 1024 else { throw WorkbenchError.protocolViolation(L10n.text("字段长度超出限制")) }; return try take(Int(count)) }
    public mutating func string() throws -> String {
        guard let result = String(data: try bytes(), encoding: .utf8) else { throw WorkbenchError.protocolViolation(L10n.text("文本字段不是有效 UTF-8")) }
        return result
    }
    public mutating func directoryEntry(parent: String) throws -> RemoteFile? {
        let rawName = try bytes()
        _ = try bytes()
        let attributes = try attributes()
        guard let name = String(data: rawName, encoding: .utf8) else { return nil }
        guard !name.isEmpty, !name.contains("/"), name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return RemoteFile(name: name, path: RemotePath.join(parent, name), attributes: attributes)
    }
    public mutating func attributes() throws -> FileAttributes {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw WorkbenchError.protocolViolation(L10n.text("不支持的文件属性")) }
        var result = FileAttributes()
        if flags & 1 != 0 { result.size = try uint64() }
        if flags & 2 != 0 { result.uid = try uint32(); result.gid = try uint32() }
        if flags & 4 != 0 { result.permissions = try uint32() }
        if flags & 8 != 0 { _ = try uint32(); result.modified = try uint32() }
        if flags & 0x80000000 != 0 {
            let count = try uint32()
            guard count < 1024 else { throw WorkbenchError.protocolViolation(L10n.text("扩展属性过多")) }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        return result
    }
}
