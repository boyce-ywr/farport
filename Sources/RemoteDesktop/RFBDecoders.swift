import Foundation
import zlib
import CoreGraphics
import ImageIO

/// 客户端帧缓冲：32 位像素，内存顺序 B,G,R,X（对应请求的像素格式：小端、红 16/绿 8/蓝 0）。解码线程写入、渲染线程读取，均需持锁。
public final class RFBFramebuffer: @unchecked Sendable {
    public private(set) var width = 0
    public private(set) var height = 0
    private(set) var pixels: UnsafeMutablePointer<UInt32>?
    private let lock = NSLock()
    private var dirty: CGRect?
    /// 尺寸或内容整体变化的代数，渲染端据此重建纹理。
    public private(set) var generation: UInt64 = 0

    deinit { pixels?.deallocate() }
    func resize(width: Int, height: Int) {
        lock.withLock {
            pixels?.deallocate()
            self.width = max(0, width); self.height = max(0, height)
            let count = max(1, self.width * self.height)
            pixels = .allocate(capacity: count); pixels!.initialize(repeating: 0xFF000000, count: count)
            dirty = CGRect(x: 0, y: 0, width: self.width, height: self.height); generation &+= 1
        }
    }
    func withPixels<T>(_ body: (UnsafeMutablePointer<UInt32>, Int, Int) throws -> T) rethrows -> T {
        try lock.withLock { try body(pixels!, width, height) }
    }
    func markDirty(_ rect: CGRect) { lock.withLock { dirty = dirty.map { $0.union(rect) } ?? rect } }
    /// 渲染端取走脏区域并在持锁期间读取像素。
    public func consume(_ body: (UnsafePointer<UInt32>, Int, Int, CGRect?, UInt64) -> Void) {
        lock.withLock {
            guard let pixels else { return }
            let region = dirty; dirty = nil
            body(UnsafePointer(pixels), width, height, region, generation)
        }
    }
    /// 拷贝当前画面（截图、测试比对用）。
    public func snapshot() -> (width: Int, height: Int, pixels: [UInt32]) {
        lock.withLock {
            guard let pixels else { return (0, 0, []) }
            return (width, height, Array(UnsafeBufferPointer(start: pixels, count: width * height)))
        }
    }
}

/// 持续使用的 zlib 解压流（ZRLE 一个、Tight 四个，按 RFB 规范在整个连接内保持状态）。
final class RFBInflater {
    private var stream = z_stream()
    private var ready = false
    deinit { if ready { inflateEnd(&stream) } }
    func reset() { if ready { inflateEnd(&stream); ready = false } }
    func inflate(_ input: [UInt8], expected: Int? = nil) throws -> [UInt8] {
        if !ready {
            stream = z_stream()
            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RFBError.protocolViolation("zlib init") }
            ready = true
        }
        var output = [UInt8](repeating: 0, count: max(expected ?? input.count * 4, 1024))
        var produced = 0
        var source = input
        try source.withUnsafeMutableBufferPointer { inputPointer in
            stream.next_in = inputPointer.baseAddress; stream.avail_in = uInt(inputPointer.count)
            while true {
                if produced == output.count {
                    if let expected, produced >= expected { break }
                    output += [UInt8](repeating: 0, count: output.count)
                }
                let status: Int32 = output.withUnsafeMutableBufferPointer { outputPointer in
                    stream.next_out = outputPointer.baseAddress! + produced; stream.avail_out = uInt(outputPointer.count - produced)
                    let result = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    produced = outputPointer.count - Int(stream.avail_out)
                    return result
                }
                if status == Z_BUF_ERROR && stream.avail_in == 0 { break }
                guard status == Z_OK || status == Z_STREAM_END else { throw RFBError.protocolViolation("zlib \(status)") }
                if stream.avail_in == 0 && stream.avail_out > 0 { break }
                if status == Z_STREAM_END { break }
            }
        }
        if let expected, produced != expected { throw RFBError.protocolViolation("zlib length \(produced)/\(expected)") }
        return Array(output.prefix(produced))
    }
}

/// 一次性 zlib 压缩（扩展剪贴板 Provide 消息）。
func rfbDeflate(_ input: [UInt8]) -> [UInt8] {
    var length = compressBound(uLong(input.count))
    var output = [UInt8](repeating: 0, count: Int(length))
    guard compress2(&output, &length, input, uLong(input.count), 6) == Z_OK else { return [] }
    return Array(output.prefix(Int(length)))
}

struct RFBRect { let x: Int, y: Int, width: Int, height: Int }

final class RFBDecoders {
    let framebuffer: RFBFramebuffer
    private let zrle = RFBInflater()
    private let tight = [RFBInflater(), RFBInflater(), RFBInflater(), RFBInflater()]
    /// Tight 的 3 字节像素顺序；默认 R,G,B，测试可对照 Raw 校验。
    var tightRGBOrder = true
    init(framebuffer: RFBFramebuffer) { self.framebuffer = framebuffer }

    private func check(_ rect: RFBRect) throws {
        guard rect.width >= 0, rect.height >= 0, rect.x + rect.width <= framebuffer.width, rect.y + rect.height <= framebuffer.height else {
            throw RFBError.protocolViolation("矩形越界 \(rect)")
        }
    }
    private func fill(_ rect: RFBRect, _ color: UInt32) {
        framebuffer.withPixels { pixels, stride, _ in
            for row in rect.y..<rect.y + rect.height { (pixels + row * stride + rect.x).update(repeating: color, count: rect.width) }
        }
    }

    func raw(_ rect: RFBRect, _ stream: RFBStream) throws {
        try check(rect)
        try framebuffer.withPixels { pixels, stride, _ in
            for row in rect.y..<rect.y + rect.height { try stream.read(into: pixels + row * stride + rect.x, count: rect.width * 4) }
        }
    }

    func copyRect(_ rect: RFBRect, _ stream: RFBStream) throws {
        let sourceX = Int(try stream.u16()), sourceY = Int(try stream.u16())
        try check(rect); try check(RFBRect(x: sourceX, y: sourceY, width: rect.width, height: rect.height))
        framebuffer.withPixels { pixels, stride, _ in
            let rows = Array(0..<rect.height)
            for offset in (sourceY < rect.y ? rows.reversed() : rows) {
                memmove(pixels + (rect.y + offset) * stride + rect.x, pixels + (sourceY + offset) * stride + sourceX, rect.width * 4)
            }
        }
    }

    func hextile(_ rect: RFBRect, _ stream: RFBStream) throws {
        try check(rect)
        var background: UInt32 = 0, foreground: UInt32 = 0
        func pixel() throws -> UInt32 { let bytes = try stream.read(4); return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | 0xFF000000 }
        for tileY in stride(from: rect.y, to: rect.y + rect.height, by: 16) {
            for tileX in stride(from: rect.x, to: rect.x + rect.width, by: 16) {
                let tile = RFBRect(x: tileX, y: tileY, width: min(16, rect.x + rect.width - tileX), height: min(16, rect.y + rect.height - tileY))
                let flags = try stream.u8()
                if flags & 1 != 0 { try raw(tile, stream); continue }
                if flags & 2 != 0 { background = try pixel() }
                if flags & 4 != 0 { foreground = try pixel() }
                fill(tile, background)
                guard flags & 8 != 0 else { continue }
                let count = Int(try stream.u8())
                for _ in 0..<count {
                    let color = flags & 16 != 0 ? try pixel() : foreground
                    let position = try stream.u8(), size = try stream.u8()
                    let sub = RFBRect(x: tileX + Int(position >> 4), y: tileY + Int(position & 15), width: Int(size >> 4) + 1, height: Int(size & 15) + 1)
                    guard sub.x + sub.width <= tile.x + tile.width, sub.y + sub.height <= tile.y + tile.height else { throw RFBError.protocolViolation("hextile") }
                    fill(sub, color)
                }
            }
        }
    }

    func zrle(_ rect: RFBRect, _ stream: RFBStream) throws {
        try check(rect)
        let length = Int(try stream.u32())
        let data = try zrle.inflate(try stream.read(length))
        // 指针直写：逐像素解码是热点，避免数组边界检查与闭包开销。
        try data.withUnsafeBufferPointer { buffer in
            guard let source = buffer.baseAddress else { return }
            let total = buffer.count
            var index = 0
            func need(_ count: Int) throws { guard index + count <= total else { throw RFBError.protocolViolation("zrle 数据不足") } }
            func cpixel() -> UInt32 {
                defer { index += 3 }
                return UInt32(source[index]) | UInt32(source[index + 1]) << 8 | UInt32(source[index + 2]) << 16 | 0xFF000000
            }
            try framebuffer.withPixels { pixels, stride, _ in
                var palette = [UInt32](repeating: 0, count: 128)
                for tileY in Swift.stride(from: rect.y, to: rect.y + rect.height, by: 64) {
                    for tileX in Swift.stride(from: rect.x, to: rect.x + rect.width, by: 64) {
                        let width = min(64, rect.x + rect.width - tileX), height = min(64, rect.y + rect.height - tileY)
                        let origin = pixels + tileY * stride + tileX
                        try need(1)
                        let mode = Int(source[index]); index += 1
                        let rle = mode & 128 != 0, paletteSize = mode & 127
                        try need(paletteSize * 3)
                        for entry in 0..<paletteSize { palette[entry] = cpixel() }
                        if !rle && paletteSize == 0 {
                            try need(width * height * 3)
                            for y in 0..<height { let row = origin + y * stride; for x in 0..<width { row[x] = cpixel() } }
                        } else if !rle && paletteSize == 1 {
                            for y in 0..<height { (origin + y * stride).update(repeating: palette[0], count: width) }
                        } else if !rle {
                            let bits = paletteSize == 2 ? 1 : paletteSize <= 4 ? 2 : 4
                            let mask = (1 << bits) - 1
                            try need((width * bits + 7) / 8 * height)
                            for y in 0..<height {
                                let row = origin + y * stride
                                var current = 0, remaining = 0
                                for x in 0..<width {
                                    if remaining == 0 { current = Int(source[index]); index += 1; remaining = 8 }
                                    remaining -= bits
                                    let value = (current >> remaining) & mask
                                    guard value < paletteSize else { throw RFBError.protocolViolation("zrle palette") }
                                    row[x] = palette[value]
                                }
                            }
                        } else {
                            guard paletteSize != 1 else { throw RFBError.protocolViolation("zrle mode 129") }
                            var position = 0
                            let count = width * height
                            func runLength() throws -> Int {
                                var run = 1, value = 255
                                repeat { try need(1); value = Int(source[index]); index += 1; run += value } while value == 255
                                return run
                            }
                            while position < count {
                                let color: UInt32, run: Int
                                if paletteSize == 0 { try need(3); color = cpixel(); run = try runLength() }
                                else {
                                    try need(1)
                                    let entry = Int(source[index]); index += 1
                                    guard entry & 127 < paletteSize else { throw RFBError.protocolViolation("zrle palette") }
                                    color = palette[entry & 127]; run = entry & 128 != 0 ? try runLength() : 1
                                }
                                guard position + run <= count else { throw RFBError.protocolViolation("zrle run") }
                                // 按行分段填充，长游程直接整段写入。
                                var remaining = run, at = position
                                while remaining > 0 {
                                    let x = at % width, y = at / width, span = min(remaining, width - x)
                                    (origin + y * stride + x).update(repeating: color, count: span)
                                    remaining -= span; at += span
                                }
                                position += run
                            }
                        }
                    }
                }
            }
        }
    }

    private func compactLength(_ stream: RFBStream) throws -> Int {
        var length = 0
        for shift in [0, 7, 14] {
            let byte = Int(try stream.u8())
            length |= (shift == 14 ? byte : byte & 0x7F) << shift
            if shift == 14 || byte & 0x80 == 0 { break }
        }
        return length
    }
    private func tpixel(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        let a = UInt32(bytes[bytes.startIndex]), b = UInt32(bytes[bytes.startIndex + 1]), c = UInt32(bytes[bytes.startIndex + 2])
        return (tightRGBOrder ? (a << 16 | b << 8 | c) : (c << 16 | b << 8 | a)) | 0xFF000000
    }

    func tight(_ rect: RFBRect, _ stream: RFBStream) throws {
        try check(rect)
        let control = try stream.u8()
        for index in 0..<4 where control & (1 << index) != 0 { tight[index].reset() }
        let kind = control >> 4
        if kind == 8 { fill(rect, tpixel(try stream.read(3)[...])); return }
        if kind == 9 {
            let data = Data(try stream.read(try compactLength(stream)))
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == rect.width, image.height == rect.height else { throw RFBError.protocolViolation("tight jpeg") }
            framebuffer.withPixels { pixels, stride, _ in
                guard rect.width > 0, rect.height > 0,
                      let context = CGContext(data: pixels + rect.y * stride + rect.x, width: rect.width, height: rect.height, bitsPerComponent: 8, bytesPerRow: stride * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            }
            return
        }
        guard kind & 8 == 0 else { throw RFBError.protocolViolation("tight 压缩类型 \(kind)") }
        let streamIndex = Int(kind & 3)
        let filter = kind & 4 != 0 ? try stream.u8() : 0
        var palette: [UInt32] = []
        var bitsPerPixel = 24
        if filter == 1 {
            let count = Int(try stream.u8()) + 1
            let bytes = try stream.read(count * 3)
            palette = (0..<count).map { tpixel(bytes[$0 * 3..<$0 * 3 + 3]) }
            bitsPerPixel = count <= 2 ? 1 : 8
        } else if filter > 2 { throw RFBError.protocolViolation("tight filter \(filter)") }
        let rowBytes = bitsPerPixel == 1 ? (rect.width + 7) / 8 : bitsPerPixel == 8 ? rect.width : rect.width * 3
        let expected = rowBytes * rect.height
        let data: [UInt8]
        if expected < 12 { data = try stream.read(expected) }
        else { data = try tight[streamIndex].inflate(try stream.read(try compactLength(stream)), expected: expected) }
        framebuffer.withPixels { pixels, stride, _ in
            for y in 0..<rect.height {
                let row = pixels + (rect.y + y) * stride + rect.x
                let base = y * rowBytes
                for x in 0..<rect.width {
                    switch (filter, bitsPerPixel) {
                    case (1, 1): row[x] = palette[min(palette.count - 1, Int(data[base + x / 8] >> UInt8(7 - x % 8)) & 1)]
                    case (1, _): row[x] = palette[min(palette.count - 1, Int(data[base + x]))]
                    case (2, _):
                        // 梯度过滤：预测值 = 左 + 上 - 左上（逐分量截断到 0...255），数据为差值。
                        var value: UInt32 = 0xFF000000
                        for component in 0..<3 {
                            let shift = UInt32(16 - component * 8)
                            func at(_ dx: Int, _ dy: Int) -> Int {
                                let px = x + dx, py = y + dy
                                guard px >= 0, py >= 0 else { return 0 }
                                return Int((pixels[(rect.y + py) * stride + rect.x + px] >> shift) & 0xFF)
                            }
                            let predicted = max(0, min(255, at(-1, 0) + at(0, -1) - at(-1, -1)))
                            let channel = tightRGBOrder ? component : 2 - component
                            value |= UInt32((predicted + Int(data[base + x * 3 + channel])) & 0xFF) << shift
                        }
                        row[x] = value
                    default: row[x] = tpixel(data[base + x * 3..<base + x * 3 + 3])
                    }
                }
            }
        }
    }

    /// 光标伪编码：返回 RGBA（非预乘）像素，透明度来自位掩码。
    func cursor(_ rect: RFBRect, _ stream: RFBStream) throws -> [UInt8] {
        let pixelBytes = try stream.read(rect.width * rect.height * 4)
        let maskBytes = try stream.read((rect.width + 7) / 8 * rect.height)
        var rgba = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        let maskRow = (rect.width + 7) / 8
        for y in 0..<rect.height {
            for x in 0..<rect.width {
                let index = y * rect.width + x
                let visible = maskBytes[y * maskRow + x / 8] & (0x80 >> UInt8(x % 8)) != 0
                rgba[index * 4] = pixelBytes[index * 4 + 2]; rgba[index * 4 + 1] = pixelBytes[index * 4 + 1]; rgba[index * 4 + 2] = pixelBytes[index * 4]
                rgba[index * 4 + 3] = visible ? 255 : 0
            }
        }
        return rgba
    }
}
