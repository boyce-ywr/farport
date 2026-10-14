import Foundation

public enum FileSortColumn: String, CaseIterable, Sendable {
    case name, type, size, modified, permissions
    public var title: String {
        switch self { case .name: return "名称"; case .type: return "文件类型"; case .size: return "大小"; case .modified: return "修改时间"; case .permissions: return "权限" }
    }
}

public struct FileSort: Equatable, Sendable {
    public private(set) var column: FileSortColumn?
    public private(set) var descending = false
    public init() {}
    public mutating func cycle(_ next: FileSortColumn) {
        if column != next { column = next; descending = false }
        else if !descending { descending = true }
        else { column = nil; descending = false }
    }
    public var description: String { column.map { "\($0.title) · \(descending ? "降序" : "升序")" } ?? "默认 · 文件夹优先，名称自然排序" }
    public func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted(using: FileSortComparator(column: column ?? .name, order: descending ? .reverse : .forward))
    }
}

public struct FileSortComparator: SortComparator, Sendable {
    public let column: FileSortColumn
    public var order: SortOrder
    public init(column: FileSortColumn, order: SortOrder = .forward) { self.column = column; self.order = order }
    public func compare(_ left: RemoteFile, _ right: RemoteFile) -> ComparisonResult {
        if left.attributes.isDirectory != right.attributes.isDirectory { return left.attributes.isDirectory ? .orderedAscending : .orderedDescending }
        var result: ComparisonResult
        switch column {
        case .name: result = left.name.localizedStandardCompare(right.name)
        case .type: result = left.typeLabel.localizedStandardCompare(right.typeLabel)
        case .size: result = compareNumber(left.attributes.size, right.attributes.size)
        case .modified: result = compareNumber(left.attributes.modified, right.attributes.modified)
        case .permissions: result = compareNumber(left.attributes.permissions & 0o777, right.attributes.permissions & 0o777)
        }
        if result == .orderedSame { result = left.name.localizedStandardCompare(right.name) }
        if result == .orderedSame { result = left.path.compare(right.path) }
        if order == .reverse { return result == .orderedAscending ? .orderedDescending : (result == .orderedDescending ? .orderedAscending : .orderedSame) }
        return result
    }
    private func compareNumber<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult { left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame) }
}

public extension RemoteFile {
    var typeLabel: String {
        if attributes.isSymbolicLink { return "符号链接" }
        if attributes.isDirectory { return "文件夹" }
        if !attributes.isRegularFile { return "特殊文件" }
        let suffix = (name as NSString).pathExtension.lowercased()
        switch suffix {
        case "html", "htm": return "HTML 网页"
        case "pdf": return "PDF 文档"
        case "txt", "log": return suffix == "log" ? "日志文件" : "文本文件"
        case "md", "markdown": return "Markdown 文档"
        case "json": return "JSON 数据"
        case "csv", "tsv": return "表格数据"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg": return suffix.uppercased() + " 图片"
        case "py": return "Python 脚本"
        case "sh", "bash", "zsh": return "Shell 脚本"
        case "js", "mjs", "ts", "tsx", "jsx", "swift", "rs", "go", "c", "h", "cpp": return suffix.uppercased() + " 源码"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return "压缩文件"
        case "mp4", "mov", "mkv", "webm": return "视频文件"
        case "mp3", "wav", "flac", "m4a": return "音频文件"
        case "": return "文件"
        default: return suffix.uppercased() + " 文件"
        }
    }
}
